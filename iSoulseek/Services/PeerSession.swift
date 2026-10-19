import Foundation

/// One `P` connection to another user.
///
/// Outbound sessions perform their handshake as soon as the socket is ready; inbound sessions are
/// handed over once the client has already read the handshake. Messages sent before the handshake
/// completes are queued, so the peer-init frame always goes out first.
final class PeerSession {

    enum Handshake {
        case peerInit
        case pierceFireWall(token: UInt32)
    }

    let username: String
    private(set) var isReady = false
    /// Whether this client dialled the peer, which decides who cleanups the session up.
    var wasInitiatedLocally = true

    var onReady: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onClosed: ((String?) -> Void)?
    /// Returning `false` drops a message before it is decoded (used for cheap token checks).
    var preDecodeFilter: ((UInt32, Data) -> Bool)?

    private let connection: SocketConnection
    private let ownUsername: String
    private var queuedSends: [(PeerRequest, ((String?) -> Void)?)] = []

    /// Outbound session: dials the user and performs the handshake.
    init(outboundTo username: String, ip: String, port: UInt16, ownUsername: String,
         handshake: Handshake, label: String, queue: DispatchQueue) {
        self.username = username
        self.ownUsername = ownUsername
        self.connection = SocketConnection(host: ip, port: port, mode: .initChannel,
                                          label: label, queue: queue)
        connection.onFrame = { [weak self] frame in
            guard let self, case .message(let code, let payload) = frame else { return }
            self.process(code: code, payload: payload)
        }
        connection.onClosed = { [weak self] reason in
            self?.onClosed?(reason)
        }
        connection.onReady = { [weak self] in
            guard let self else { return }
            switch handshake {
            case .peerInit:
                var payload = ByteWriter()
                payload.write(string: self.ownUsername)
                payload.write(string: ConnectionType.peer.rawValue)
                payload.write(UInt32(0))
                self.connection.send(initCode: InitCode.peerInit.rawValue, payload: payload.data)
            case .pierceFireWall(let token):
                var payload = ByteWriter()
                payload.write(token)
                self.connection.send(initCode: InitCode.pierceFireWall.rawValue, payload: payload.data)
            }
            self.connection.setMode(.peer)
            self.markReady()
        }
        connection.start()
    }

    /// Inbound session adopted after the client read a `PeerInit` from the peer.
    init(adopting connection: SocketConnection, username: String, ownUsername: String,
         wasInitiatedLocally: Bool = false) {
        self.username = username
        self.ownUsername = ownUsername
        self.wasInitiatedLocally = wasInitiatedLocally
        self.connection = connection
        connection.onFrame = { [weak self] frame in
            guard let self, case .message(let code, let payload) = frame else { return }
            self.process(code: code, payload: payload)
        }
        connection.onClosed = { [weak self] reason in
            self?.onClosed?(reason)
        }
        connection.setMode(.peer)
        isReady = true
    }

    func close() {
        connection.cancel()
    }

    var isClosed: Bool { connection.isFinished }

    func send(_ request: PeerRequest, completion: ((String?) -> Void)? = nil) {
        guard isReady else {
            queuedSends.append((request, completion))
            return
        }
        sendNow(request, completion: completion)
    }

    private func markReady() {
        isReady = true
        onReady?()
        let pending = queuedSends
        queuedSends.removeAll()
        for (request, completion) in pending {
            sendNow(request, completion: completion)
        }
    }

    private func process(code: UInt32, payload: Data) {
        if let preDecodeFilter, !preDecodeFilter(code, payload) { return }
        guard let message = try? PeerMessage.decode(code: code, payload: payload) else { return }
        onMessage?(message)
    }

    private func sendNow(_ request: PeerRequest, completion: ((String?) -> Void)?) {
        guard let payload = try? request.payload() else {
            completion?("Unable to encode message")
            return
        }
        if request.usesInitChannel {
            connection.send(initCode: UInt8(truncatingIfNeeded: request.code), payload: payload,
                            completion: completion)
        } else {
            connection.send(code: request.code, payload: payload, completion: completion)
        }
    }
}
