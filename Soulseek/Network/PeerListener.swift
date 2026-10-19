import Foundation
import Network

/// Listens for inbound peer and file-transfer connections.
final class PeerListener {

    var onConnection: ((SocketConnection) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReady: ((UInt16) -> Void)?

    private(set) var port: UInt16 = 0
    private let queue: DispatchQueue
    private var listener: NWListener?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Binds `preferredPort`, falling back to an ephemeral port when it is unavailable.
    func start(preferredPort: UInt16?) {
        stop()
        if let preferredPort, let bound = makeListener(on: preferredPort) {
            listener = bound
        } else {
            listener = makeListener(on: nil)
        }
        guard let listener else {
            onFailure?("Unable to open a listening socket")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let socket = SocketConnection(adopting: connection, mode: .initChannel,
                                          label: "inbound", queue: self.queue)
            self.onConnection?(socket)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener?.port?.rawValue ?? 0
                self.onReady?(self.port)
            case .failed(let error):
                self.onFailure?(error.localizedDescription)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func makeListener(on port: UInt16?) -> NWListener? {
        let parameters = SocketConnection.parameters()
        parameters.allowLocalEndpointReuse = true
        do {
            if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
                return try NWListener(using: parameters, on: endpointPort)
            }
            return try NWListener(using: parameters)
        } catch {
            return nil
        }
    }
}
