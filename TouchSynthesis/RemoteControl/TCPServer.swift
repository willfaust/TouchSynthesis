import Foundation
import Network

/// TCP server on a local port with Bonjour advertising.
/// Hands accepted NWConnections to a callback for CommandServer to manage.
class TCPServer {
    private var listener: NWListener?
    private let port: UInt16
    var onConnection: ((NWConnection) -> Void)?
    var onStateChange: ((NWListener.State) -> Void)?

    init(port: UInt16 = 8347) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        listener = try NWListener(using: params, on: nwPort)
        listener?.service = NWListener.Service(name: "TouchSynthesis", type: "_touchsynth._tcp")

        listener?.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var isRunning: Bool {
        if case .ready = listener?.state { return true }
        return false
    }
}
