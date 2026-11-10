import Network
import XCTest
@testable import Deceive

/// Exercises the real network path without touching the Riot Client. Needs network access and the
/// upstream certificate: DECEIVE_TEST_PFX=/path/to/localhost.pfx DECEIVE_INTEGRATION=1 swift test
final class IntegrationTests: XCTestCase {
    private var connections: [ProxiedConnection] = []

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DECEIVE_INTEGRATION"] == "1" else {
            throw XCTSkip("DECEIVE_INTEGRATION not set")
        }
    }

    /// The Riot Client connects to deceive-localhost.molenzwiebel.xyz:<port> and validates the certificate
    /// with the system trust store; the proxy then bridges to the real chat server.
    func testChatProxyBridgesToRealChatServer() async throws {
        let pfxPath = try XCTUnwrap(ProcessInfo.processInfo.environment["DECEIVE_TEST_PFX"])
        let identity = try ProxyCertificate.load(pfx: Data(contentsOf: URL(fileURLWithPath: pfxPath)))

        let chatProxy = try ChatProxy(identity: identity)
        let settings = Settings()
        chatProxy.onConnection = { [unowned self] incoming, host, port in
            let connection = ProxiedConnection(incoming: incoming, chatHost: host, chatPort: port, settings: settings)
            self.connections.append(connection)
            connection.start()
        }
        let port = try await chatProxy.start()
        chatProxy.setUpstream(host: "euw1.chat.si.riotgames.com", port: 5223)

        let client = NWConnection(host: NWEndpoint.Host(ConfigProxy.localhostDomain),
                                  port: NWEndpoint.Port(rawValue: port)!, using: .tls)
        let queue = DispatchQueue(label: "test.client")
        let ready = expectation(description: "TLS handshake with proxy")
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case .failed(let error) = state { XCTFail("Client failed: \(error)") }
        }
        client.start(queue: queue)
        await fulfillment(of: [ready], timeout: 10)

        let header = "<?xml version='1.0'?><stream:stream to='eu1.pvp.net' version='1.0' xmlns:stream='http://etherx.jabber.org/streams'>"
        client.send(content: Data(header.utf8), completion: .idempotent)

        let reply = expectation(description: "XMPP stream header from Riot's chat server")
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            print("Chat server replied: \(text.prefix(300))")
            if text.contains("stream:stream") || text.contains("stream:features") { reply.fulfill() }
        }
        await fulfillment(of: [reply], timeout: 15)
        client.cancel()
    }

    func testConfigProxyForwardsClientConfig() async throws {
        let configProxy = try ConfigProxy(chatPort: 12345)
        let port = try await configProxy.start()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/config/public?os=mac&region=EUW&app=Riot%20Client")!)
        request.setValue("RiotClient/142.0.0 (CEF)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.isEmpty)
    }
}
