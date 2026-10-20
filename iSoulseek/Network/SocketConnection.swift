import Foundation
import Network

/// A framed TCP connection to the server, a peer or a file-transfer partner.
///
/// All callbacks are delivered on the `queue` passed to the initialiser; the client uses one shared
/// serial queue so that no locking is required anywhere in the protocol layer.
final class SocketConnection {

    enum State: Equatable {
        case setup
        case ready
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .failed, .cancelled: return true
            case .setup, .ready: return false
            }
        }
    }

    let label: String
    private(set) var state: State = .setup

    var onReady: (() -> Void)?
    var onFrame: ((Frame) -> Void)?
    var onBytes: ((Data) -> Void)?
    /// Called exactly once when the connection ends, with an error if it failed.
    var onClosed: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder: FrameDecoder
    private var hasReportedClose = false
    private var connectTimeoutWorkItem: DispatchWorkItem?
    /// Holds the connection open until it finishes, so callers do not have to own it.
    private var selfReference: SocketConnection?

    var isReady: Bool { state == .ready }
    var isFinished: Bool { state.isFinished }

    init(host: String, port: UInt16, mode: FrameMode, label: String, queue: DispatchQueue) {
        self.label = label
        self.queue = queue
        self.decoder = FrameDecoder(mode: mode)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 0
        )
        self.connection = NWConnection(to: endpoint, using: SocketConnection.parameters())
    }

    init(adopting connection: NWConnection, mode: FrameMode, label: String, queue: DispatchQueue) {
        self.label = label
        self.queue = queue
        self.decoder = FrameDecoder(mode: mode)
        self.connection = connection
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 45
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 4
        return NWParameters(tls: nil, tcp: tcp)
    }

    func start(connectTimeout: TimeInterval = 15) {
        selfReference = self
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.state = .ready
                self.onReady?()
                self.receive()
            case .failed(let error):
                self.finish(with: error.localizedDescription)
            case .cancelled:
                self.finish(with: nil)
            case .waiting:
                // Keep waiting: the connect timeout below is the authority on giving up.
                break
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isFinished, self.state != .ready else { return }
            self.finish(with: "Timed out connecting")
        }
        connectTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + connectTimeout, execute: timeout)

        connection.start(queue: queue)
    }

    /// Switches framing, e.g. from the peer-init channel to the established peer channel.
    func setMode(_ mode: FrameMode) {
        decoder.mode = mode
        flushRawBufferIfNeeded()
    }

    func send(code: UInt32, payload: Data, completion: ((String?) -> Void)? = nil) {
        var writer = ByteWriter()
        writer.write(UInt32(payload.count + 4))
        writer.write(code)
        writer.write(raw: payload)
        send(raw: writer.data, completion: completion)
    }

    func send(initCode: UInt8, payload: Data, completion: ((String?) -> Void)? = nil) {
        var writer = ByteWriter()
        writer.write(UInt32(payload.count + 1))
        writer.write(initCode)
        writer.write(raw: payload)
        send(raw: writer.data, completion: completion)
    }

    func send(raw data: Data, completion: ((String?) -> Void)? = nil) {
        guard !state.isFinished else {
            completion?("Connection is closed")
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error?.localizedDescription)
        })
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with reason: String?) {
        guard !hasReportedClose else { return }
        hasReportedClose = true
        if let reason {
            AppLog.peers.debug("connection \"\(self.label, privacy: .public)\" failed: \(reason, privacy: .public)")
        } else {
            AppLog.peers.debug("connection \"\(self.label, privacy: .public)\" closed")
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        state = reason == nil ? .cancelled : .failed(reason ?? "")
        onClosed?(reason)
        // Drop the self-reference once this call has returned, so the object can be released.
        queue.async { [weak self] in
            self?.selfReference = nil
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.hasReportedClose else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                do {
                    try self.drain()
                } catch {
                    let message = (error as? ProtocolError).map { "\($0)" } ?? error.localizedDescription
                    self.finish(with: message)
                    return
                }
            }

            if let error {
                self.finish(with: error.localizedDescription)
                return
            }
            if isComplete {
                self.finish(with: nil)
                return
            }
            self.receive()
        }
    }

    private func drain() throws {
        while true {
            if decoder.mode == .raw {
                flushRawBufferIfNeeded()
                return
            }
            guard let frame = try decoder.next() else { return }
            onFrame?(frame)
        }
    }

    /// Hands any buffered bytes to `onBytes` once the channel stops being framed.
    private func flushRawBufferIfNeeded() {
        guard decoder.mode == .raw, decoder.bufferedCount > 0 else { return }
        let bytes = decoder.takeBuffered()
        if !bytes.isEmpty {
            onBytes?(bytes)
        }
    }
}
