import Foundation
import Network
import Security

/// TLS listener that the Riot Client connects to instead of the real chat server.
final class ChatProxy {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "deceive.chat-proxy")
    private var upstream: (host: String, port: Int)?
    private var pending: [NWConnection] = []

    /// Called on the main queue for every accepted connection, with the real chat server to bridge it to.
    var onConnection: ((NWConnection, String, Int) -> Void)?

    init(identity: ProxyIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create_with_certificates(identity.identity, identity.chain as CFArray) else {
            throw ProxyCertificateError.identityUnavailable
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)

        listener = try NWListener(using: .loopbackParameters(tls: tls))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // Hold connections until we know which chat server they belong to.
            if let upstream = self.upstream {
                self.dispatch(connection, to: upstream)
            } else {
                self.pending.append(connection)
            }
        }
    }

    func start() async throws -> UInt16 {
        try await listener.startAndWaitForPort(queue: queue)
    }

    /// Sets the real chat server. Only the first call has an effect, as in upstream.
    func setUpstream(host: String, port: Int) {
        queue.async {
            guard self.upstream == nil else { return }
            let upstream = (host: host, port: port)
            self.upstream = upstream
            self.pending.forEach { self.dispatch($0, to: upstream) }
            self.pending.removeAll()
        }
    }

    private func dispatch(_ connection: NWConnection, to upstream: (host: String, port: Int)) {
        DispatchQueue.main.async { self.onConnection?(connection, upstream.host, upstream.port) }
    }
}
