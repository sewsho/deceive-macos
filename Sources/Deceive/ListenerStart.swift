import Foundation
import Network

extension NWListener {
    /// Starts the listener on `queue` and returns the port it bound to once it is ready.
    func startAndWaitForPort(queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // Once resumed, swap in a handler that only logs, so the continuation is resumed exactly once.
            let logFailures: @Sendable (NWListener.State) -> Void = { state in
                if case .failed(let error) = state { Log.write("Listener failed: \(error)") }
            }
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.stateUpdateHandler = logFailures
                    continuation.resume(returning: self?.port?.rawValue ?? 0)
                case .failed(let error):
                    self?.stateUpdateHandler = logFailures
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }
}

extension NWParameters {
    /// TCP parameters that only accept connections on 127.0.0.1, at a port chosen by the system.
    static func loopbackParameters(tls: NWProtocolTLS.Options? = nil) -> NWParameters {
        let parameters = tls.map { NWParameters(tls: $0) } ?? .tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }
}
