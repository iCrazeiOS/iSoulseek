import Combine
import Foundation

enum SoulseekError: LocalizedError {
    case notConnected
    case peerUnavailable(String)
    case timedOut
    case invalidUsername
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the Soulseek server"
        case .peerUnavailable(let user): return "Could not reach \(user)"
        case .timedOut: return "The peer did not respond"
        case .invalidUsername: return "Usernames use letters, numbers, dots, dashes and underscores"
        case .invalidQuery: return "Enter a search term"
        }
    }
}

/// The single entry point to the Soulseek network.
///
/// Everything protocol-related runs on one serial queue, so no state is shared across threads.
/// Observable state is republished on the main queue for the UI.
final class SoulseekClient {

    static let shared = SoulseekClient()

    static let majorVersion: UInt32 = 177
    static let minorVersion: UInt32 = 1
    static let searchLifetime: TimeInterval = 90
    static let maximumResultsPerSearch = 5_000
    static let peerConnectTimeout: TimeInterval = 15
    static let addressTimeout: TimeInterval = 10
    static let browseTimeout: TimeInterval = 60
    static let handshakeTimeout: TimeInterval = 20
    static let maximumPeerSessions = 32
    static let maximumQueryLength = 200

    // MARK: Published state

    let stateChanges = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    let searchResults = PassthroughSubject<SearchResult, Never>()
    let searchFinished = PassthroughSubject<UInt32, Never>()
    let transferChanges = PassthroughSubject<Transfer, Never>()
    let messages = PassthroughSubject<String, Never>()
    let shares = CurrentValueSubject<ShareSnapshot, Never>(.empty)
    let listeningPort = CurrentValueSubject<UInt16, Never>(0)
    let excludedPhrases = CurrentValueSubject<[String], Never>([])

    let store: SessionStore
    let transferManager: TransferManager

    // MARK: Internals

    private let queue: DispatchQueue
    private let shareQueue = DispatchQueue(label: "org.soulseekkit.shares")
    private var server: SocketConnection?
    private var listener: PeerListener
    private var sessions: [String: PeerSession] = [:]
    private var sessionRequests: [String: [(PeerSession?) -> Void]] = [:]
    private var sessionTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingPierce: [UInt32: (username: String, created: Date)] = [:]
    private var fileDialsInFlight: Set<String> = []
    private var addressCache: [String: (ip: String, port: UInt16, created: Date)] = [:]
    private var addressRequests: [String: [(String, UInt16) -> Void]] = [:]
    private var browseRequests: [String: (Result<[ShareFolder], Error>) -> Void] = [:]
    private var browseTimers: [String: DispatchWorkItem] = [:]
    private var searchTokens: Set<UInt32> = []
    private var searchResultCounts: [UInt32: Int] = [:]
    private var shareSnapshot: ShareSnapshot = .empty
    private var port: UInt16 = 0
    private var ownUsername = ""
    private var currentState: ConnectionState = .disconnected
    private var pingTimer: DispatchSourceTimer?
    private let tokenLock = NSLock()
    private var tokenCounter = UInt32.random(in: 1...(UInt32.max / 2))

    init(store: SessionStore = SessionStore(),
         queue: DispatchQueue = DispatchQueue(label: "org.soulseekkit.client")) {
        self.store = store
        self.queue = queue
        self.transferManager = TransferManager(queue: queue, downloadsDirectory: store.downloadsDirectory)
        self.listener = PeerListener(queue: queue)
        configureTransfers()
    }

    // MARK: Connection

    func connect() {
        queue.async { self.connectLocked() }
    }

    func disconnect() {
        queue.async { self.disconnectLocked(reason: nil) }
    }

    func setStatus(_ status: UserStatus) {
        store.status = status
        queue.async { self.send(.setStatus(status)) }
    }

    func rescanShares() {
        queue.async { self.rescanSharesLocked() }
    }

    // MARK: Requests

    @discardableResult
    func search(_ query: String) -> UInt32? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumQueryLength else { return nil }

        let token = allocateToken()
        queue.async { [weak self] in
            guard let self, self.server != nil else { return }
            self.searchTokens.insert(token)
            self.send(.fileSearch(token: token, query: trimmed))
            self.queue.asyncAfter(deadline: .now() + Self.searchLifetime) { [weak self] in
                guard let self, self.searchTokens.remove(token) != nil else { return }
                self.searchResultCounts.removeValue(forKey: token)
                self.publish { self.searchFinished.send(token) }
            }
        }
        return token
    }

    func cancelSearch(_ token: UInt32) {
        queue.async {
            guard self.searchTokens.remove(token) != nil else { return }
            self.searchResultCounts.removeValue(forKey: token)
            self.publish { self.searchFinished.send(token) }
        }
    }

    func browse(username: String, completion: @escaping (Result<[ShareFolder], Error>) -> Void) {
        guard !username.isEmpty else {
            completion(.failure(SoulseekError.peerUnavailable("")))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let key = username.lowercased()
            guard self.server != nil else {
                self.replyToMain { completion(.failure(SoulseekError.notConnected)) }
                return
            }
            guard self.browseRequests[key] == nil else { return }
            self.browseRequests[key] = completion

            self.provideSession(username: username) { [weak self] session in
                guard let self else { return }
                guard let session else {
                    if let pending = self.browseRequests.removeValue(forKey: key) {
                        self.replyToMain { pending(.failure(SoulseekError.peerUnavailable(username))) }
                    }
                    return
                }
                session.send(.getShareFileList)
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.browseRequests.removeValue(forKey: key) else { return }
                    self.replyToMain { pending(.failure(SoulseekError.timedOut)) }
                    self.releaseSessionIfIdle(username: username)
                }
                self.browseTimers[key] = timer
                self.queue.asyncAfter(deadline: .now() + Self.browseTimeout, execute: timer)
            }
        }
    }

    func download(username: String, filename: String, size: UInt64,
                  completion: ((Transfer?) -> Void)? = nil) {
        queue.async {
            let transfer = self.transferManager.enqueueDownload(username: username,
                                                               filename: filename, size: size)
            if let completion {
                self.replyToMain { completion(transfer) }
            }
        }
    }

    func cancelTransfer(id: UInt32) {
        queue.async { self.transferManager.cancel(id: id) }
    }

    func clearFinishedTransfers() {
        queue.async { self.transferManager.clearFinished() }
    }

    /// Removes a finished transfer; a completed download's file is deleted when `deleteFile` is set.
    func deleteTransfer(id: UInt32, deleteFile: Bool) {
        queue.async { self.transferManager.remove(id: id, deleteFile: deleteFile) }
    }

    func transfers() -> [Transfer] {
        var result: [Transfer] = []
        queue.sync { result = self.transferManager.allTransfers }
        return result
    }

    // MARK: Server session

    private func connectLocked() {
        guard server == nil else { return }
        ownUsername = store.username

        guard Self.isValidUsername(ownUsername) else {
            setState(.failed(SoulseekError.invalidUsername.localizedDescription))
            return
        }
        guard !store.password.isEmpty else {
            setState(.failed("Enter your Soulseek password"))
            return
        }

        setState(.connecting)
        transferManager.ownUsername = ownUsername
        startListener()
        rescanSharesLocked()

        let connection = SocketConnection(host: store.serverHost, port: store.serverPort,
                                          mode: .server, label: "server", queue: queue)
        connection.onReady = { [weak self] in
            guard let self else { return }
            self.setState(.connectingToServer)
            self.send(.login(username: self.ownUsername, password: self.store.password,
                             major: Self.majorVersion, minor: Self.minorVersion))
        }
        connection.onFrame = { [weak self] frame in
            guard let self, case .message(let code, let payload) = frame else { return }
            guard let message = try? ServerMessage.decode(code: code, payload: payload) else { return }
            self.handleServer(message)
        }
        connection.onClosed = { [weak self] reason in
            guard let self else { return }
            let wasFailed: Bool
            if case .failed = self.currentState { wasFailed = true } else { wasFailed = false }
            self.server = nil
            self.stopPing()
            self.closeAllSessions()
            if !wasFailed {
                self.setState(.disconnected)
            }
            if let reason {
                self.publish { self.messages.send("Disconnected: \(reason)") }
            }
        }
        server = connection
        connection.start()
    }

    private func disconnectLocked(reason: String?) {
        stopPing()
        closeAllSessions()
        listener.stop()
        port = 0
        publish { self.listeningPort.send(0) }

        let connection = server
        server = nil
        connection?.onClosed = nil
        connection?.cancel()

        searchTokens.removeAll()
        searchResultCounts.removeAll()
        addressCache.removeAll()
        pendingPierce.removeAll()
        fileDialsInFlight.removeAll()
        transferManager.reset()
        setState(.disconnected)
        if let reason {
            publish { self.messages.send(reason) }
        }
    }

    private func handleServer(_ message: ServerMessage) {
        switch message {
        case .login(let result):
            guard result.isSuccess else {
                let reason = Self.describe(rejection: result.rejectionReason, detail: result.rejectionDetail)
                setState(.failed(reason))
                publish { self.messages.send(reason) }
                server?.cancel()
                server = nil
                return
            }
            setState(.loggedIn(username: ownUsername))
            send(.haveNoParent(true))
            send(.checkPrivileges)
            send(.setStatus(store.status))
            send(.watchUser(ownUsername))
            send(.setWaitPort(port))
            reportSharesLocked()
            startPing()
            publish {
                self.messages.send(result.greeting.isEmpty ? "Connected to the Soulseek network" : result.greeting)
            }

        case .peerAddress(let address):
            let key = address.username.lowercased()
            addressCache[key] = (address.ip, address.port, Date())
            let waiters = addressRequests.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter(address.ip, address.port) }

        case .connectToPeer(let info):
            handleServerConnectToPeer(info)

        case .excludedSearchPhrases(let phrases):
            publish { self.excludedPhrases.send(phrases) }

        case .relogged:
            disconnectLocked(reason: "Signed in from another client")

        default:
            break
        }
    }

    private func send(_ request: ServerRequest) {
        guard let server else { return }
        // The server ignores sessions that send anything before Login, so enforce the handshake.
        guard currentState.isLoggedIn || request.code == .login else { return }
        server.send(code: request.code.rawValue, payload: request.payload())
    }

    // MARK: Listeners and shares

    private func startListener() {
        listener.onReady = { [weak self] port in
            guard let self else { return }
            self.port = port
            self.publish { self.listeningPort.send(port) }
            // SetWaitPort must never precede Login: it is re-sent once the session is authenticated.
            if self.currentState.isLoggedIn {
                self.send(.setWaitPort(port))
            }
            self.reportSharesLocked()
        }
        listener.onFailure = { [weak self] reason in
            self?.publish { self?.messages.send("Listening socket failed: \(reason)") }
        }
        listener.onConnection = { [weak self] connection in
            self?.handleInbound(connection)
        }
        listener.start(preferredPort: store.preferredListeningPort)
    }

    private func reportSharesLocked() {
        guard server != nil else { return }
        send(.sharedFoldersFiles(
            directories: UInt32(clamping: shareSnapshot.folderCount),
            files: UInt32(clamping: shareSnapshot.fileCount)
        ))
    }

    private func rescanSharesLocked() {
        let root = store.shareDirectory
        ShareIndex.scan(root: root, queue: shareQueue) { [weak self] snapshot in
            self?.queue.async {
                guard let self else { return }
                self.shareSnapshot = snapshot
                self.transferManager.shareSnapshot = snapshot
                self.reportSharesLocked()
                self.publish { self.shares.send(snapshot) }
            }
        }
    }

    // MARK: Inbound connections

    private func handleInbound(_ connection: SocketConnection) {
        // A connection that never completes its peer-init handshake must not be held open forever.
        let handshake = DispatchWorkItem { [weak connection] in connection?.cancel() }
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: handshake)

        connection.onFrame = { [weak self, weak connection] frame in
            guard let self, let connection else { return }
            guard case .initMessage(let code, let payload) = frame else { return }
            guard let message = try? InitMessage.decode(code: code, payload: payload) else {
                connection.cancel()
                return
            }
            handshake.cancel()
            switch message {
            case .peerInit(let username, let type, _):
                self.handleInboundPeerInit(connection: connection, username: username, type: type)
            case .pierceFireWall(let token):
                self.handleInboundPierce(connection: connection, token: token)
            }
        }
        connection.start()
    }

    private func handleInboundPeerInit(connection: SocketConnection, username: String, type: String) {
        guard let kind = ConnectionType(rawValue: type) else {
            connection.cancel()
            return
        }
        switch kind {
        case .peer:
            guard !username.isEmpty, username.lowercased() != ownUsername.lowercased() else {
                connection.cancel()
                return
            }
            let key = username.lowercased()
            if let existing = sessions[key], existing.isReady {
                // One connection per peer: keep ours unless it is idle and the peer reconnected.
                if transferManager.hasPendingWork(username: username) {
                    connection.cancel()
                    return
                }
                sessions.removeValue(forKey: key)
                existing.close()
            }
            guard sessions.count < Self.maximumPeerSessions else {
                connection.cancel()
                return
            }
            let session = PeerSession(adopting: connection, username: username,
                                      ownUsername: ownUsername)
            wire(session, key: key)
            activate(session, key: key)

        case .fileTransfer:
            transferManager.handleFileConnection(connection)
            connection.setMode(.raw)

        case .distributed:
            connection.cancel()
        }
    }

    private func handleInboundPierce(connection: SocketConnection, token: UInt32) {
        guard let pending = pendingPierce.removeValue(forKey: token) else {
            // Not one of our pending peer sessions; it may be a downloader answering `ConnectToPeer`.
            if !transferManager.adoptIndirectUploadConnection(connection, token: token) {
                connection.cancel()
            }
            return
        }
        let key = pending.username.lowercased()
        if let existing = sessions[key], existing.isReady {
            connection.cancel()
            return
        }
        guard sessions.count < Self.maximumPeerSessions else {
            connection.cancel()
            return
        }
        // We asked the peer to dial us; this connection is the result of our own request.
        let session = PeerSession(adopting: connection, username: pending.username,
                                  ownUsername: ownUsername, wasInitiatedLocally: true)
        wire(session, key: key)
        activate(session, key: key)
    }

    private func handleServerConnectToPeer(_ info: ConnectToPeerInfo) {
        switch ConnectionType(rawValue: info.connectionType) {
        case .peer:
            handleServerPeerRequest(info)
        case .fileTransfer:
            dialFileConnection(info)
        default:
            break
        }
    }

    private func handleServerPeerRequest(_ info: ConnectToPeerInfo) {
        guard !info.ip.isEmpty, info.ip != "0.0.0.0", info.port > 0 else { return }
        let key = info.username.lowercased()
        guard sessions[key] == nil else { return }
        guard sessions.count < Self.maximumPeerSessions else { return }
        guard info.username.lowercased() != ownUsername.lowercased() else { return }

        addressCache[key] = (info.ip, info.port, Date())
        let session = PeerSession(outboundTo: info.username, ip: info.ip, port: info.port,
                                  ownUsername: ownUsername,
                                  handshake: .pierceFireWall(token: info.token),
                                  label: "pierce:\(info.username)", queue: queue)
        wire(session, key: key)
    }

    /// An uploader that cannot reach our listening port asks us to dial it and push a file through.
    private func dialFileConnection(_ info: ConnectToPeerInfo) {
        guard !info.ip.isEmpty, info.ip != "0.0.0.0", info.port > 0 else { return }
        guard info.username.lowercased() != ownUsername.lowercased() else { return }

        let key = info.username.lowercased()
        guard !fileDialsInFlight.contains(key) else { return }
        guard transferManager.expectsFileConnection(username: info.username) else { return }
        fileDialsInFlight.insert(key)

        let connection = SocketConnection(host: info.ip, port: info.port, mode: .initChannel,
                                          label: "file-download:\(info.username)", queue: queue)
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            var payload = ByteWriter()
            payload.write(info.token)
            connection.send(initCode: InitCode.pierceFireWall.rawValue, payload: payload.data)
            // Register the raw handler before switching, so a coalesced file token is not lost.
            self.transferManager.handleFileConnection(connection)
            connection.setMode(.raw)
        }
        connection.onClosed = { [weak self] _ in
            self?.fileDialsInFlight.remove(key)
        }
        connection.start()
    }

    // MARK: Peer sessions

    private func provideSession(username: String, completion: @escaping (PeerSession?) -> Void) {
        let key = username.lowercased()
        if let session = sessions[key], session.isReady {
            completion(session)
            return
        }
        if sessionRequests[key] != nil {
            sessionRequests[key]?.append(completion)
            return
        }
        guard sessions.count < Self.maximumPeerSessions else {
            completion(nil)
            return
        }
        sessionRequests[key] = [completion]

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.sessions[key] == nil else { return }
            self.failSessionRequests(key: key)
        }
        sessionTimeouts[key] = timeout
        queue.asyncAfter(deadline: .now() + Self.peerConnectTimeout, execute: timeout)

        resolveAddress(username: username) { [weak self] ip, port in
            guard let self else { return }
            guard !ip.isEmpty, ip != "0.0.0.0", port > 0 else {
                self.failSessionRequests(key: key)
                return
            }
            self.purgePendingPierce()
            let token = self.allocateToken()
            self.pendingPierce[token] = (username, Date())
            self.send(.connectToPeer(token: token, username: username, type: .peer))

            let session = PeerSession(outboundTo: username, ip: ip, port: port,
                                      ownUsername: self.ownUsername, handshake: .peerInit,
                                      label: "peer:\(username)", queue: self.queue)
            self.wire(session, key: key)
        }
    }

    private func wire(_ session: PeerSession, key: String) {
        session.onReady = { [weak self] in
            self?.activate(session, key: key)
        }
        session.onMessage = { [weak self] message in
            self?.handlePeer(message, from: session)
        }
        session.onClosed = { [weak self] _ in
            self?.sessionClosed(key: key, session: session)
        }
        session.preDecodeFilter = { [weak self] code, payload in
            guard code == PeerCode.fileSearchResponse.rawValue else { return true }
            return self?.isWantedSearchResponse(payload) ?? false
        }
    }

    private func activate(_ session: PeerSession, key: String) {
        if let existing = sessions[key], existing.isReady, existing !== session {
            session.close()
            return
        }
        sessions[key] = session
        sessionTimeouts.removeValue(forKey: key)?.cancel()
        let waiters = sessionRequests.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter(session) }
    }

    private func sessionClosed(key: String, session: PeerSession) {
        if sessions[key] === session {
            sessions.removeValue(forKey: key)
        }
        if let pending = browseRequests.removeValue(forKey: key) {
            browseTimers.removeValue(forKey: key)?.cancel()
            replyToMain { pending(.failure(SoulseekError.peerUnavailable(session.username))) }
        }
        if sessions[key] == nil {
            failSessionRequests(key: key)
        }
    }

    private func failSessionRequests(key: String) {
        sessionTimeouts.removeValue(forKey: key)?.cancel()
        let waiters = sessionRequests.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter(nil) }
    }

    private func releaseSessionIfIdle(username: String) {
        let key = username.lowercased()
        guard let session = sessions[key], session.wasInitiatedLocally else { return }
        guard !transferManager.hasPendingWork(username: username) else { return }
        sessions.removeValue(forKey: key)
        session.close()
    }

    private func closeAllSessions() {
        let open = sessions.values
        sessions.removeAll()
        sessionRequests.removeAll()
        sessionTimeouts.removeAll()
        for session in open { session.close() }
    }

    private func resolveAddress(username: String, completion: @escaping (String, UInt16) -> Void) {
        let key = username.lowercased()
        if let cached = addressCache[key], Date().timeIntervalSince(cached.created) < 300, cached.port > 0 {
            completion(cached.ip, cached.port)
            return
        }
        if addressRequests[key] != nil {
            addressRequests[key]?.append(completion)
            return
        }
        addressRequests[key] = [completion]
        send(.getPeerAddress(username))
        queue.asyncAfter(deadline: .now() + Self.addressTimeout) { [weak self] in
            guard let self, let waiters = self.addressRequests.removeValue(forKey: key) else { return }
            for waiter in waiters { waiter("", 0) }
        }
    }

    private func purgePendingPierce() {
        let cutoff = Date().addingTimeInterval(-120)
        pendingPierce = pendingPierce.filter { $0.value.created > cutoff }
    }

    // MARK: Peer messages

    private func handlePeer(_ message: PeerMessage, from session: PeerSession) {
        let key = session.username.lowercased()
        switch message {
        case .sharedFileList(let folders):
            browseTimers.removeValue(forKey: key)?.cancel()
            if let pending = browseRequests.removeValue(forKey: key) {
                replyToMain { pending(.success(folders)) }
            }
            releaseSessionIfIdle(username: session.username)

        case .getShareFileList:
            session.send(.sharedFileList(shareSnapshot.folders))

        case .folderContentsRequest(let token, let folder):
            session.send(.folderContentsResponse(token: token, folder: folder,
                                                 folders: shareSnapshot.folders(matching: folder)))

        case .userInfoRequest:
            session.send(.userInfo(UserInfo(
                description: "",
                hasPicture: false,
                picture: nil,
                totalUploads: UInt32(clamping: transferManager.allTransfers.filter { $0.isUpload && $0.state == .completed }.count),
                queueSize: transferManager.queueSize,
                slotsFree: transferManager.activeUploadCount < transferManager.maximumConcurrentUploads
            )))

        case .fileSearchResponse(let results):
            deliver(results)

        default:
            transferManager.handle(message, from: session)
        }
    }

    private func deliver(_ results: FileSearchResults) {
        guard searchTokens.contains(results.token) else { return }
        var stored = searchResultCounts[results.token] ?? 0
        for file in results.files where !file.name.isEmpty {
            guard stored < Self.maximumResultsPerSearch else { break }
            let result = SearchResult(username: results.username, token: results.token, file: file,
                                      isSlotFree: results.isSlotFree,
                                      averageSpeed: results.averageSpeed,
                                      queueLength: results.queueLength)
            publish { self.searchResults.send(result) }
            stored += 1
        }
        searchResultCounts[results.token] = stored
    }

    /// Cheap token check on the first few bytes, before the whole response is inflated.
    private func isWantedSearchResponse(_ payload: Data) -> Bool {
        guard let prefix = try? Zlib.decompress(payload, limit: 4096) else { return false }
        var reader = ByteReader(prefix)
        guard (try? reader.readString()) != nil, let token = try? reader.readUInt32() else { return false }
        return searchTokens.contains(token)
    }

    // MARK: Transfers

    private func configureTransfers() {
        transferManager.onUpdate = { [weak self] transfer in
            self?.publish { self?.transferChanges.send(transfer) }
        }
        transferManager.onUploadFinished = { [weak self] bytes, elapsed in
            guard let self else { return }
            let speed = UInt64(Double(bytes) / max(0.001, elapsed))
            self.send(.sendUploadSpeed(UInt32(clamping: speed)))
        }
        transferManager.onUserWorkFinished = { [weak self] username in
            self?.releaseSessionIfIdle(username: username)
        }
        transferManager.sessionProvider = { [weak self] username, completion in
            guard let self else { completion(nil); return }
            self.provideSession(username: username, completion: completion)
        }
        transferManager.addressProvider = { [weak self] username, completion in
            guard let self else { completion("", 0); return }
            self.resolveAddress(username: username, completion: completion)
        }
        transferManager.indirectUploadRequest = { [weak self] username in
            guard let self, self.server != nil, self.currentState.isLoggedIn else { return 0 }
            let token = self.allocateToken()
            self.send(.connectToPeer(token: token, username: username, type: .fileTransfer))
            return token
        }
    }

    // MARK: Keepalive

    private func startPing() {
        stopPing()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.send(.serverPing)
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: Helpers

    private func allocateToken() -> UInt32 {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        tokenCounter &+= 1
        if tokenCounter == 0 { tokenCounter = 1 }
        return tokenCounter
    }

    private func setState(_ state: ConnectionState) {
        currentState = state
        publish { self.stateChanges.send(state) }
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    /// Runs a callback on the main queue from code that already holds the client queue.
    private func replyToMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private static func isValidUsername(_ username: String) -> Bool {
        guard (1...30).contains(username.count) else { return false }
        return username.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
    }

    private static func describe(rejection: String, detail: String) -> String {
        let base: String
        switch rejection {
        case "INVALIDUSERNAME": base = "That username is not allowed"
        case "EMPTYPASSWORD": base = "Enter your Soulseek password"
        case "INVALIDPASS": base = "Incorrect username or password"
        case "INVALIDVERSION": base = "This client version was rejected"
        case "SVRFULL": base = "The server is full, try again later"
        case "SVRPRIVATE": base = "The server is not accepting connections"
        case "": base = "Disconnected before signing in"
        default: base = "The server rejected the login (\(rejection))"
        }
        return detail.isEmpty ? base : "\(base): \(detail)"
    }
}
