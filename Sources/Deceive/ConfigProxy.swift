import Foundation
import Network

/// Proxies the Riot Client's requests to the clientconfig service, rewriting the chat servers in the
/// response to point at our local chat proxy.
final class ConfigProxy {
    static let configURL = "https://clientconfig.rpg.riotgames.com"
    static let geoPasURL = URL(string: "https://riot-geo.pas.si.riotgames.com/pas/v1/service/chat")!
    static let localhostDomain = "deceive-localhost.molenzwiebel.xyz"

    private let chatPort: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "deceive.config-proxy")
    private let session = URLSession(configuration: .ephemeral)

    /// Called on the main queue with the original chat host and port each time a config is patched.
    var onPatchedChatServer: ((String, Int) -> Void)?

    init(chatPort: UInt16) throws {
        self.chatPort = chatPort
        listener = try NWListener(using: .loopbackParameters())
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
    }

    /// Starts the HTTP server and returns the port it is listening on.
    func start() async throws -> UInt16 {
        try await listener.startAndWaitForPort(queue: queue)
    }

    // MARK: Minimal HTTP/1.1 server

    private struct Request {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let request = Self.parse(head: buffer[..<end.lowerBound]) else {
                    self.send(status: 400, body: Data(), on: connection)
                    return
                }
                Task { await self.respond(to: request, on: connection) }
            } else if isComplete || error != nil || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.readRequest(on: connection, buffer: buffer)
            }
        }
    }

    private static func parse(head: Data) -> Request? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers)
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        guard request.method == "GET" else {
            send(status: 405, body: Data(), on: connection)
            return
        }
        let (status, body) = await proxyAndRewrite(request)
        send(status: status, body: body, on: connection)
    }

    private func send(status: Int, body: Data, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Rewriting

    /// Proxies a request to the clientconfig service and rewrites any chat servers to point at localhost.
    private func proxyAndRewrite(_ request: Request) async -> (Int, Data) {
        let url = Self.configURL + request.target
        Log.write("Received client proxy request to URL: \(url)")

        guard let upstreamURL = URL(string: url) else { return (400, Data()) }
        var upstream = URLRequest(url: upstreamURL)
        // Cloudflare rejects requests without a user agent.
        upstream.setValue(request.headers["user-agent"], forHTTPHeaderField: "User-Agent")
        // Authorization headers for player config.
        if let entitlements = request.headers["x-riot-entitlements-jwt"] {
            upstream.setValue(entitlements, forHTTPHeaderField: "X-Riot-Entitlements-JWT")
        }
        if let authorization = request.headers["authorization"] {
            upstream.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: upstream)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 502
        } catch {
            Log.write("Failed to reach clientconfig service: \(error)")
            return (502, Data())
        }
        Log.write("Received response from clientconfig service with status code: \(status)")
        Log.write("ORIGINAL CLIENTCONFIG: \(String(decoding: data, as: UTF8.self))")

        // Riot sometimes answers with an internal error that is not JSON. Forward it; the Riot Client retries.
        guard (200..<300).contains(status) else { return (status, data) }

        do {
            guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }

            var riotChatHost: String?
            var riotChatPort = 0

            // Point the fallback host at localhost.
            if let host = config["chat.host"] as? String {
                riotChatHost = host
                config["chat.host"] = Self.localhostDomain
            }

            if let port = config["chat.port"] as? Int {
                riotChatPort = port
                config["chat.port"] = Int(chatPort)
            }

            // Point every chat affinity at localhost, remembering the one this player would have used.
            if var affinities = config["chat.affinities"] as? [String: Any] {
                if config["chat.affinity.enabled"] as? Bool ?? false,
                   let affinity = await playerAffinity(authorization: request.headers["authorization"]) {
                    riotChatHost = affinities[affinity] as? String
                    Log.write("AFFINITY: \(affinity) -> \(riotChatHost ?? "nil")")
                }
                for key in affinities.keys { affinities[key] = Self.localhostDomain }
                config["chat.affinities"] = affinities
            }

            let modified = try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])
            Log.write("MODIFIED CLIENTCONFIG: \(String(decoding: modified, as: UTF8.self))")

            if let riotChatHost, riotChatPort != 0 {
                DispatchQueue.main.async { self.onPatchedChatServer?(riotChatHost, riotChatPort) }
            }
            return (status, modified)
        } catch {
            Log.write("Failed to rewrite clientconfig: \(error)")
            // Forwarding the original config would reveal our status, so stop instead of failing silently.
            await MainActor.run { () -> Never in
                Alert.show(
                    "Deceive was unable to rewrite a League of Legends configuration file. This normally happens " +
                    "because Riot changed something on their end. Please check \(Utils.repositoryURL.absoluteString) for " +
                    "a new version, or file a bug report there.\n\n\(error)",
                    style: .critical
                )
                exit(0)
            }
        }
    }

    /// Reads the player's chat affinity from the geo PAS token, if available.
    private func playerAffinity(authorization: String?) async -> String? {
        var request = URLRequest(url: Self.geoPasURL)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await session.data(for: request)
            let jwt = String(decoding: data, as: UTF8.self)
            let parts = jwt.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let decoded = Data(base64Encoded: payload),
                  let json = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
                return nil
            }
            return json["affinity"] as? String
        } catch {
            Log.write("Error getting player affinity token, using default chat server: \(error)")
            return nil
        }
    }
}
