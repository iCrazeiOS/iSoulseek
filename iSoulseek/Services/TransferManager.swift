import Foundation

/// Owns the download queue and the files we serve to other users.
///
/// Every method runs on the client's serial queue; file I/O is pushed to a private queue so that a
/// slow disk never stalls the network loop.
final class TransferManager {

    // MARK: Configuration

    var downloadsDirectory: URL
    var shareSnapshot: ShareSnapshot = .empty
    var ownUsername = ""
    var maximumConcurrentUploads = 1
    var negotiateTimeout: TimeInterval = 1800
    var uploadStartTimeout: TimeInterval = 60
    var uploadChunkSize = 64 * 1024

    // MARK: Wiring

    /// Asks the client for an established peer connection to a user.
    var sessionProvider: ((String, @escaping (PeerSession?) -> Void) -> Void)?
    /// Asks the client for a user's address, for outbound file connections.
    /// Calls back with an empty address when the user is offline.
    var addressProvider: ((String, @escaping (String, UInt16) -> Void) -> Void)?
    /// Asks the client to send `ConnectToPeer` of type `F` and returns the token it used, or 0 when
    /// the request could not be sent. The peer answers by dialling us back.
    var indirectUploadRequest: ((String) -> UInt32)?
    var onUpdate: ((Transfer) -> Void)?
    var onUploadFinished: ((UInt64, TimeInterval) -> Void)?
    /// Called when nothing else is outstanding for a user, so the client can drop the peer session.
    var onUserWorkFinished: ((String) -> Void)?

    private struct Download {
        let id: UInt32
        let username: String
        let filename: String
        let key: String
        let url: URL
        var expectedSize: UInt64
        var offset: UInt64
        var transferred: UInt64
        var isStarted = false
        /// Set once the peer has sent `TransferRequest`, i.e. a file connection may now arrive.
        var awaitingFileConnection = false
        var timeout: DispatchWorkItem?
    }

    private struct PendingUpload {
        let id: UInt32
        let username: String
        let filename: String
        let key: String
        let url: URL
        let size: UInt64
        var session: PeerSession?
        var isWaitingForSlot = true
        /// True once we have begun streaming over a file connection.
        var isTransferring = false
        var timeout: DispatchWorkItem?
    }

    private let queue: DispatchQueue
    private let ioQueue: DispatchQueue
    private var transfers: [Transfer] = []
    private var nextToken: UInt32

    private var downloads: [UInt32: Download] = [:]
    private var downloadsByKey: [String: UInt32] = [:]
    private var peerTokenToDownload: [UInt32: UInt32] = [:]
    private var downloadConnections: [UInt32: SocketConnection] = [:]
    private var openHandles: [UInt32: FileHandle] = [:]
    private var progressMarks: [UInt32: Date] = [:]

    private var uploads: [UInt32: PendingUpload] = [:]
    private var uploadsByKey: [String: UInt32] = [:]
    private var uploadQueue: [UInt32] = []
    private var activeUploads = 0
    private var uploadConnections: [UInt32: SocketConnection] = [:]
    private var pendingUploadPierce: [UInt32: UInt32] = [:]

    init(queue: DispatchQueue, downloadsDirectory: URL, ioQueue: DispatchQueue = DispatchQueue(label: "com.icraze.transfers.io")) {
        self.queue = queue
        self.ioQueue = ioQueue
        self.downloadsDirectory = downloadsDirectory
        self.nextToken = UInt32.random(in: 1...UInt32.max / 2)
    }

    var allTransfers: [Transfer] { transfers }

    /// Whether we still owe or expect work involving this user on their peer session.
    func hasPendingWork(username: String) -> Bool {
        let wanted = username.lowercased()
        if downloads.values.contains(where: { $0.username.lowercased() == wanted }) { return true }
        return uploads.values.contains { $0.username.lowercased() == wanted }
    }

    var activeUploadCount: Int { activeUploads }

    var queueSize: UInt32 { UInt32(min(activeUploads + uploadQueue.count, Int(UInt32.max))) }

    // MARK: Downloads

    @discardableResult
    func enqueueDownload(username: String, filename: String, size: UInt64) -> Transfer? {
        guard let url = PathSanitizer.destination(in: downloadsDirectory, virtualPath: filename) else {
            return nil
        }

        let key = Self.key(username: username, filename: filename)
        if let existing = downloadsByKey[key], let transfer = transfers.first(where: { $0.id == existing }) {
            return transfer
        }

        let id = allocateToken()
        var download = Download(id: id, username: username, filename: filename, key: key,
                                url: url, expectedSize: size, offset: 0, transferred: 0)
        download.offset = existingSize(of: url, limit: size)

        var transfer = Transfer(id: id, username: username, filename: filename,
                                size: size > 0 ? size : download.offset, isUpload: false)
        transfer.transferred = download.offset
        transfer.state = download.offset > 0 && download.offset == size ? .completed : .negotiating
        transfers.append(transfer)
        onUpdate?(transfer)

        guard transfer.state != .completed else { return transfer }

        downloads[id] = download
        downloadsByKey[key] = id

        sessionProvider?(username) { [weak self] session in
            guard let self, var current = self.downloads[id] else { return }
            guard let session else {
                self.updateTransfer(id) { transfer in
                    transfer.state = .failed("Could not connect to \(username)")
                }
                return
            }
            if current.isStarted { return }
            current.isStarted = true
            self.downloads[id] = current
            session.send(.queueUpload(filename: filename))
            self.scheduleNegotiationTimeout(id)
        }

        return transfer
    }

    func cancel(id: UInt32) {
        if let download = downloads.removeValue(forKey: id) {
            download.timeout?.cancel()
            downloadsByKey.removeValue(forKey: download.key)
            downloadConnections.removeValue(forKey: id)?.cancel()
            openHandles.removeValue(forKey: id)?.closeFile()
            updateTransfer(id) { $0.state = .cancelled }
            return
        }
        if let upload = uploads.removeValue(forKey: id) {
            upload.timeout?.cancel()
            uploadsByKey.removeValue(forKey: upload.key)
            uploadQueue.removeAll { $0 == id }
            pendingUploadPierce = pendingUploadPierce.filter { $0.value != id }
            uploadConnections.removeValue(forKey: id)?.cancel()
            updateTransfer(id) { $0.state = .cancelled }
            pumpUploadQueue()
            return
        }
        updateTransfer(id) { $0.state = .cancelled }
    }

    func clearFinished() {
        transfers.removeAll { !$0.state.isActive }
    }

    /// Removes one finished transfer. A completed download's file is deleted when `deleteFile` is set;
    /// partial files from failed or cancelled downloads are kept so a future attempt can resume.
    @discardableResult
    func remove(id: UInt32, deleteFile: Bool) -> Bool {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return false }
        let transfer = transfers[index]
        guard !transfer.state.isActive else { return false }
        transfers.remove(at: index)

        guard deleteFile, !transfer.isUpload, transfer.state == .completed,
              let url = PathSanitizer.destination(in: downloadsDirectory,
                                                  virtualPath: transfer.filename) else {
            return true
        }
        let root = downloadsDirectory.standardizedFileURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            Self.removeEmptyParents(of: url, upTo: root)
        }
        return true
    }

    func reset() {
        for (_, download) in downloads {
            download.timeout?.cancel()
        }
        for (_, upload) in uploads {
            upload.timeout?.cancel()
        }
        for (_, handle) in openHandles { handle.closeFile() }
        for (_, connection) in downloadConnections { connection.cancel() }
        for (_, connection) in uploadConnections { connection.cancel() }
        downloads.removeAll()
        downloadsByKey.removeAll()
        peerTokenToDownload.removeAll()
        downloadConnections.removeAll()
        openHandles.removeAll()
        uploads.removeAll()
        uploadsByKey.removeAll()
        uploadQueue.removeAll()
        uploadConnections.removeAll()
        pendingUploadPierce.removeAll()
        activeUploads = 0
        transfers.removeAll()
    }

    // MARK: Inbound peer messages

    func handle(_ message: PeerMessage, from session: PeerSession) {
        switch message {
        case .queueUpload(let filename):
            enqueueUpload(filename: filename, session: session)
        case .transferRequest(let info):
            handleTransferRequest(info, from: session)
        case .transferResponse(let info):
            handleTransferResponse(info, from: session)
        case .placeInQueueRequest(let filename):
            handlePlaceInQueueRequest(filename: filename, from: session)
        case .uploadDenied(let filename, let reason):
            failDownload(username: session.username, filename: filename, reason: reason)
        case .uploadFailed(let filename):
            failDownload(username: session.username, filename: filename, reason: "Upload failed")
        default:
            break
        }
    }

    private func handleTransferRequest(_ info: TransferRequestInfo, from session: PeerSession) {
        // Only the "I am about to upload to you" direction is supported; legacy pull requests
        // are ignored, since every current client uses QueueUpload.
        guard info.direction == .upload else { return }

        let key = Self.key(username: session.username, filename: info.filename)
        guard let id = downloadsByKey[key], var download = downloads[id] else { return }

        peerTokenToDownload[info.token] = id
        download.awaitingFileConnection = true
        if let size = info.size, size > 0 {
            download.expectedSize = size
            updateTransfer(id) { $0.size = size }
        }
        downloads[id] = download
        session.send(.transferResponse(TransferResponseInfo(token: info.token, isAllowed: true,
                                                            size: nil, reason: nil)))
    }

    /// Whether a download from this user is waiting for the uploader to push a file to us.
    func expectsFileConnection(username: String) -> Bool {
        let wanted = username.lowercased()
        return downloads.values.contains { $0.username.lowercased() == wanted && $0.awaitingFileConnection }
    }

    /// The uploader sends the token of its `TransferRequest` as the first bytes of a raw `F` stream,
    /// whether it dialled us (direct) or we dialled it after `ConnectToPeer` (indirect).
    func handleFileConnection(_ connection: SocketConnection) {
        var header = Data()
        connection.onBytes = { [weak self] data in
            guard let self else { return }
            header.append(data)
            guard header.count >= 4 else { return }

            let base = header.startIndex
            let token = UInt32(header[base]) | (UInt32(header[base + 1]) << 8)
                | (UInt32(header[base + 2]) << 16) | (UInt32(header[base + 3]) << 24)
            let remainder = Data(header[(base + 4)...])
            header.removeAll()

            guard let id = self.peerTokenToDownload[token], let download = self.downloads[id] else {
                connection.cancel()
                return
            }
            guard self.downloadConnections[id] == nil else {
                // Both the direct and the indirect connection were established; use the first one.
                connection.cancel()
                return
            }
            self.downloadConnections[id] = connection

            // A peer that never states a size signals completion by closing the connection.
            let previousOnClosed = connection.onClosed
            connection.onClosed = { [weak self] reason in
                previousOnClosed?(reason)
                self?.completeDownload(id: id)
            }

            self.prepareDownloadFile(id: id, download: download) { handle in
                guard let handle else {
                    self.failDownload(username: download.username, filename: download.filename,
                                      reason: "Cannot write to disk")
                    return
                }
                self.openHandles[id] = handle

                var offset = ByteWriter()
                offset.write(download.offset)
                connection.send(raw: offset.data)

                connection.onBytes = { chunk in
                    self.write(chunk, to: id, connection: connection)
                }
                if !remainder.isEmpty {
                    connection.onBytes?(remainder)
                }

                var current = download
                current.transferred = download.offset
                current.awaitingFileConnection = false
                self.downloads[id] = current
                self.updateTransfer(id) { $0.state = .transferring }
            }
        }
    }

    // MARK: Uploads

    private func enqueueUpload(filename: String, session: PeerSession) {
        guard let url = shareSnapshot.localURL(forVirtualPath: filename),
              let size = fileSize(of: url) else {
            session.send(.uploadDenied(filename: filename, reason: TransferDenialReason.fileNotShared))
            return
        }

        let key = Self.key(username: session.username, filename: filename)
        if let existing = uploadsByKey[key] {
            if uploads[existing]?.isWaitingForSlot == true {
                sendPlaceInQueue(existing, session: session)
            }
            return
        }

        let id = allocateToken()
        uploads[id] = PendingUpload(id: id, username: session.username, filename: filename,
                                    key: key, url: url, size: size, session: session)
        uploadsByKey[key] = id

        var transfer = Transfer(id: id, username: session.username, filename: filename,
                                size: size, isUpload: true)
        transfer.state = .queued(place: 0)
        transfers.append(transfer)
        onUpdate?(transfer)

        uploadQueue.append(id)
        pumpUploadQueue()
    }

    private func pumpUploadQueue() {
        while activeUploads < maximumConcurrentUploads, !uploadQueue.isEmpty {
            let id = uploadQueue.removeFirst()
            guard var upload = uploads[id], upload.isWaitingForSlot else { continue }
            upload.isWaitingForSlot = false
            uploads[id] = upload
            activeUploads += 1
            updateTransfer(id) { $0.state = .negotiating }
            upload.session?.send(.transferRequest(TransferRequestInfo(
                direction: .upload, token: id, filename: upload.filename, size: upload.size
            )))
        }
    }

    private func handleTransferResponse(_ info: TransferResponseInfo, from session: PeerSession) {
        guard var upload = uploads[info.token] else { return }
        guard info.isAllowed else {
            failUpload(info.token, reason: info.reason ?? "Declined")
            return
        }
        upload.session = session
        uploads[info.token] = upload

        // Ask the peer to dial us back as well, so a blocked direct route does not stall the upload.
        requestIndirectUpload(for: info.token)
        scheduleUploadStartTimeout(info.token)
        openUploadConnection(for: info.token)
    }

    /// Registers an `F` dial-back with the server; the peer answers by connecting with `PierceFireWall`.
    private func requestIndirectUpload(for id: UInt32) {
        guard let upload = uploads[id], let request = indirectUploadRequest else { return }
        let token = request(upload.username)
        if token != 0 {
            pendingUploadPierce[token] = id
        }
    }

    /// Adopts a connection the downloader opened after our `ConnectToPeer`; returns false if the token
    /// does not belong to one of our uploads.
    @discardableResult
    func adoptIndirectUploadConnection(_ connection: SocketConnection, token: UInt32) -> Bool {
        guard let id = pendingUploadPierce.removeValue(forKey: token),
              let upload = uploads[id], !upload.isWaitingForSlot else {
            return false
        }
        if let existing = uploadConnections[id], !existing.isFinished {
            guard !upload.isTransferring else {
                connection.cancel()
                return true
            }
            uploadConnections[id] = nil
            existing.cancel()
        }
        uploadConnections[id] = connection
        wireUploadConnection(id: id, connection: connection)
        connection.setMode(.raw)
        beginUploadTransfer(id: id, connection: connection)
        return true
    }

    private func handlePlaceInQueueRequest(filename: String, from session: PeerSession) {
        let key = Self.key(username: session.username, filename: filename)
        guard let id = uploadsByKey[key] else { return }
        sendPlaceInQueue(id, session: session)
    }

    private func sendPlaceInQueue(_ id: UInt32, session: PeerSession) {
        guard let upload = uploads[id] else { return }
        var place: UInt32 = 1
        if upload.isWaitingForSlot, let index = uploadQueue.firstIndex(of: id) {
            place = UInt32(index + 1)
        }
        session.send(.placeInQueueResponse(filename: upload.filename, place: place))
        updateTransfer(id) { $0.state = .queued(place: place) }
    }

    private func openUploadConnection(for id: UInt32) {
        guard let upload = uploads[id] else { return }
        addressProvider?(upload.username) { [weak self] ip, port in
            guard let self else { return }
            // An empty address rules out the direct route, but the indirect dial-back may still work.
            guard !ip.isEmpty, port > 0 else { return }
            guard let current = self.uploads[id], !current.isWaitingForSlot, !current.isTransferring else { return }
            if let existing = self.uploadConnections[id], !existing.isFinished { return }

            let connection = SocketConnection(host: ip, port: port, mode: .initChannel,
                                              label: "file-upload", queue: self.queue)
            self.uploadConnections[id] = connection
            self.wireUploadConnection(id: id, connection: connection)
            connection.onReady = { [weak self, weak connection] in
                guard let self, let connection else { return }
                guard self.uploadConnections[id] === connection, self.uploads[id] != nil else {
                    connection.cancel()
                    return
                }
                var initPayload = ByteWriter()
                initPayload.write(string: self.ownUsername)
                initPayload.write(string: ConnectionType.fileTransfer.rawValue)
                initPayload.write(UInt32(0))
                connection.send(initCode: InitCode.peerInit.rawValue, payload: initPayload.data)
                connection.setMode(.raw)
                self.beginUploadTransfer(id: id, connection: connection)
            }
            connection.start()
        }
    }

    /// Tracks the connection that carries an upload; a failure only ends the transfer once the
    /// connection was the active one, so a losing race between the direct and indirect routes is safe.
    private func wireUploadConnection(id: UInt32, connection: SocketConnection) {
        connection.onBytes = { _ in }
        connection.onClosed = { [weak self, weak connection] reason in
            guard let self, let connection, let upload = self.uploads[id],
                  !upload.isWaitingForSlot, self.uploadConnections[id] === connection else { return }
            self.uploadConnections.removeValue(forKey: id)
            guard upload.isTransferring else { return }
            if self.transfers.first(where: { $0.id == id })?.state != .completed {
                self.updateTransfer(id) { $0.state = .failed(reason ?? "Connection closed by peer") }
            }
            self.teardownUpload(id)
        }
    }

    /// Sends the `TransferRequest` token and waits for the downloader's offset. The connection must
    /// already be in raw mode.
    private func beginUploadTransfer(id: UInt32, connection: SocketConnection) {
        guard var upload = uploads[id] else {
            connection.cancel()
            return
        }
        upload.isTransferring = true
        upload.timeout?.cancel()
        uploads[id] = upload

        var token = ByteWriter()
        token.write(id)
        connection.send(raw: token.data)
        readUploadOffset(id: id, connection: connection)
    }

    private func readUploadOffset(id: UInt32, connection: SocketConnection) {
        var header = Data()
        connection.onBytes = { [weak self] data in
            guard let self else { return }
            header.append(data)
            guard header.count >= 8 else { return }
            let base = header.startIndex
            var offset: UInt64 = 0
            for index in stride(from: 7, through: 0, by: -1) {
                offset = (offset << 8) | UInt64(header[base + index])
            }
            connection.onBytes = { _ in }
            header.removeAll()

            guard let upload = self.uploads[id], offset <= upload.size else {
                self.failUpload(id, reason: "Peer asked for an invalid offset")
                return
            }
            self.startSending(id: id, connection: connection, offset: offset)
        }
    }

    private func scheduleUploadStartTimeout(_ id: UInt32) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let upload = self.uploads[id], !upload.isWaitingForSlot,
                  !upload.isTransferring else { return }
            self.failUpload(id, reason: "Peer did not answer")
        }
        uploads[id]?.timeout = work
        queue.asyncAfter(deadline: .now() + uploadStartTimeout, execute: work)
    }

    private func startSending(id: UInt32, connection: SocketConnection, offset: UInt64) {
        guard let upload = uploads[id] else { return }
        ioQueue.async {
            guard let handle = try? FileHandle(forReadingFrom: upload.url) else {
                self.queue.async { self.failUpload(id, reason: "Cannot read shared file") }
                return
            }
            try? handle.seek(toOffset: offset)
            let started = Date()
            self.queue.async {
                self.updateTransfer(id) { transfer in
                    transfer.transferred = offset
                    transfer.state = .transferring
                }
                self.pumpUploadChunk(id: id, connection: connection, handle: handle, startedAt: started)
            }
        }
    }

    private func pumpUploadChunk(id: UInt32, connection: SocketConnection, handle: FileHandle,
                                 startedAt: Date) {
        guard uploads[id] != nil, !connection.isFinished else {
            try? handle.close()
            return
        }
        ioQueue.async {
            let chunk = (try? handle.read(upToCount: self.uploadChunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? handle.close()
                self.queue.async {
                    self.completeUpload(id, startedAt: startedAt)
                }
                return
            }
            self.queue.async {
                connection.send(raw: chunk) { error in
                    if let error {
                        try? handle.close()
                        self.failUpload(id, reason: error)
                        return
                    }
                    self.updateTransfer(id) { $0.transferred += UInt64(chunk.count) }
                    self.pumpUploadChunk(id: id, connection: connection, handle: handle,
                                         startedAt: startedAt)
                }
            }
        }
    }

    /// Marks an upload finished and releases its slot. The connection is kept open briefly because
    /// the downloader closes first, and an abrupt cancel could discard buffered data.
    private func completeUpload(_ id: UInt32, startedAt: Date) {
        guard uploads[id] != nil else { return }
        let sent = transfers.first { $0.id == id }?.transferred ?? 0
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        updateTransfer(id) { $0.state = .completed }
        onUploadFinished?(sent, elapsed)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.teardownUpload(id)
            self.uploadConnections.removeValue(forKey: id)?.cancel()
        }
    }

    // MARK: Download plumbing

    private func write(_ chunk: Data, to id: UInt32, connection: SocketConnection) {
        guard var download = downloads[id], let handle = openHandles[id] else {
            connection.cancel()
            return
        }
        download.transferred += UInt64(chunk.count)
        downloads[id] = download

        let total = download.transferred
        let expected = download.expectedSize
        ioQueue.async {
            try? handle.write(contentsOf: chunk)
            if expected > 0 && total >= expected {
                try? handle.close()
                self.queue.async {
                    self.completeDownload(id: id)
                    connection.cancel()
                }
                return
            }
            self.queue.async { self.reportProgress(id: id) }
        }
    }

    /// Marks a download finished and releases everything it held.
    private func completeDownload(id: UInt32) {
        guard let download = downloads[id] else { return }
        let reachedEnd = download.expectedSize > 0
            ? download.transferred >= download.expectedSize
            : download.transferred > 0
        guard reachedEnd else {
            failDownload(username: download.username, filename: download.filename,
                         reason: "Connection closed early")
            return
        }
        downloads.removeValue(forKey: id)
        download.timeout?.cancel()
        downloadsByKey.removeValue(forKey: download.key)
        downloadConnections.removeValue(forKey: id)?.cancel()
        openHandles.removeValue(forKey: id)?.closeFile()
        updateTransfer(id) { $0.state = .completed }
        if !hasPendingWork(username: download.username) {
            onUserWorkFinished?(download.username)
        }
    }

    private func reportProgress(id: UInt32) {
        guard downloads[id] != nil else { return }
        let now = Date()
        if let last = progressMarks[id], now.timeIntervalSince(last) < 0.25 { return }
        progressMarks[id] = now
        let transferred = downloads[id]?.transferred ?? 0
        updateTransfer(id) { $0.transferred = transferred }
    }

    private func prepareDownloadFile(id: UInt32, download: Download, completion: @escaping (FileHandle?) -> Void) {
        let url = download.url
        let offset = download.offset
        ioQueue.async {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                self.queue.async { completion(nil) }
                return
            }
            try? handle.seek(toOffset: offset)
            self.queue.async { completion(handle) }
        }
    }

    private func failDownload(username: String, filename: String, reason: String) {
        let key = Self.key(username: username, filename: filename)
        guard let id = downloadsByKey[key] else { return }
        downloads.removeValue(forKey: id)
        downloadsByKey.removeValue(forKey: key)
        downloadConnections.removeValue(forKey: id)?.cancel()
        openHandles.removeValue(forKey: id)?.closeFile()
        updateTransfer(id) { $0.state = .failed(reason.isEmpty ? "Refused" : reason) }
        if !hasPendingWork(username: username) {
            onUserWorkFinished?(username)
        }
    }

    private func scheduleNegotiationTimeout(_ id: UInt32) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let download = self.downloads[id] else { return }
            guard let transfer = self.transfers.first(where: { $0.id == id }), transfer.state.isActive,
                  transfer.state != .transferring else { return }
            self.failDownload(username: download.username, filename: download.filename,
                              reason: "No response from peer")
        }
        downloads[id]?.timeout = work
        queue.asyncAfter(deadline: .now() + negotiateTimeout, execute: work)
    }

    private func failUpload(_ id: UInt32, reason: String) {
        guard uploads[id] != nil else { return }
        updateTransfer(id) { $0.state = .failed(reason) }
        let connection = uploadConnections.removeValue(forKey: id)
        teardownUpload(id)
        connection?.cancel()
    }

    /// Releases an upload's slot and queue entry. Safe to call more than once.
    private func teardownUpload(_ id: UInt32) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        upload.timeout?.cancel()
        pendingUploadPierce = pendingUploadPierce.filter { $0.value != id }
        uploadsByKey.removeValue(forKey: upload.key)
        uploadQueue.removeAll { $0 == id }
        if !upload.isWaitingForSlot {
            activeUploads = max(0, activeUploads - 1)
        }
        pumpUploadQueue()
    }

    // MARK: Helpers

    private func allocateToken() -> UInt32 {
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        return nextToken
    }

    private func updateTransfer(_ id: UInt32, _ mutate: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[index])
        onUpdate?(transfers[index])
    }

    private func existingSize(of url: URL, limit: UInt64) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        let value = size.uint64Value
        if limit > 0 && value >= limit { return limit }
        return value
    }

    private func fileSize(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    /// Deletes now-empty directories left behind after a file is removed, without touching the root.
    private static func removeEmptyParents(of url: URL, upTo root: URL) {
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(root.path), directory.path != root.path {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: directory)
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }

    private static func key(username: String, filename: String) -> String {
        username.lowercased() + "\u{0}" + filename.replacingOccurrences(of: "/", with: "\\").lowercased()
    }
}
