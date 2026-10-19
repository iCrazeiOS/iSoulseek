import Combine
import XCTest
@testable import iSoulseek

/// Download/upload integration tests.
final class TransferIntegrationTests: XCTestCase {

    private var env: TestEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = TestEnvironment()
    }

    override func tearDownWithError() throws {
        env?.tearDown()
        env = nil
        try super.tearDownWithError()
    }

    private func makePayload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 7 &+ 3) & 0xFF) })
    }

    // MARK: Download

    func testDownloadCompletesAndWritesFile() {
        let payload = makePayload(4096)
        env.peer.downloadPayload = payload
        let filename = "Music\\song.bin"
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }


        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        let destination = env.downloadsDirectory.appendingPathComponent("Music/song.bin")
        assertEventually("file was not written", timeout: 3) {
            (try? Data(contentsOf: destination))?.count == payload.count
        }
        XCTAssertEqual((try? Data(contentsOf: destination)), payload)
        XCTAssertTrue(env.client.transfers().isEmpty,
                      "completed downloads belong to the filesystem, not the transfer list")
    }

    /// Peers may omit the size and signal completion by closing the file connection.
    func testDownloadCompletesWhenPeerOmitsSize() {
        let payload = makePayload(2048)
        env.peer.downloadPayload = payload
        env.peer.downloadReportsSize = false
        let filename = "Music\\unsized.bin"
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: 0)

        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        let destination = env.downloadsDirectory.appendingPathComponent("Music/unsized.bin")
        assertEventually("file was not written", timeout: 3) {
            (try? Data(contentsOf: destination)) == payload
        }
        XCTAssertTrue(env.client.transfers().isEmpty,
                      "completed downloads belong to the filesystem, not the transfer list")
    }

    func testDownloadResumesFromExistingBytes() {
        let payload = makePayload(1000)
        env.peer.downloadPayload = payload
        let filename = "Music\\resume.bin"
        let destination = env.downloadsDirectory.appendingPathComponent("Music/resume.bin")
        let partial = env.downloadsDirectory.appendingPathComponent(".partials/Music/resume.bin")

        // Pre-create a partial download with the first 300 bytes already on disk.
        try? FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? payload.prefix(300).write(to: partial)

        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }


        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("mock was never asked for an offset", timeout: 3) {
            env.peer.downloadAskedOffset != nil
        }
        XCTAssertEqual(env.peer.downloadAskedOffset, 300,
                       "the client must resume from the bytes already on disk")

        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }
        assertEventually("file was not completed", timeout: 3) {
            (try? Data(contentsOf: destination))?.count == payload.count
        }
        XCTAssertEqual((try? Data(contentsOf: destination)), payload)
    }

    /// A different file already occupying the destination must be replaced, not appended to.
    func testExistingLargerFileIsReplaced() {
        let payload = makePayload(512)
        env.peer.downloadPayload = payload
        let filename = "Music\\replace.bin"
        let destination = env.downloadsDirectory.appendingPathComponent("Music/replace.bin")

        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(repeating: 0xEE, count: payload.count * 2).write(to: destination)

        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))
        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        XCTAssertEqual((try? Data(contentsOf: destination)), payload)
    }

    /// The uploader cannot reach our listener, so it asks the server to have us dial it instead.
    func testDownloadCompletesViaIndirectConnection() {
        let payload = makePayload(3000)
        env.peer.downloadPayload = payload
        env.peer.downloadViaIndirect = true
        let filename = "Music\\indirect.bin"
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("the client never dialled the peer back", timeout: 3) {
            !env.peer.filePierceTokens.isEmpty
        }
        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        let destination = env.downloadsDirectory.appendingPathComponent("Music/indirect.bin")
        XCTAssertEqual((try? Data(contentsOf: destination)), payload)
    }

    /// Deleting a completed download removes the file and any folders it left empty.
    func testDeletingCompletedDownloadRemovesFile() {
        let payload = makePayload(2048)
        env.peer.downloadPayload = payload
        let filename = "Music\\Album\\deleteme.bin"
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))
        assertEventually("download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        let destination = env.downloadsDirectory.appendingPathComponent("Music/Album/deleteme.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        DownloadedFiles.delete(destination, upTo: env.downloadsDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(env.client.transfers().isEmpty)
        assertEventually("empty folders were not cleaned up", timeout: 3) {
            !FileManager.default.fileExists(atPath: env.downloadsDirectory.appendingPathComponent("Music").path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.downloadsDirectory.path),
                      "the downloads root must be kept")
    }

    /// Deleting downloads one at a time keeps shared folders until their last file is gone.
    func testDeletingDownloadsOneByOneCleansFoldersWhenEmpty() {
        let payload = makePayload(1024)
        env.peer.downloadPayload = payload
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let firstFilename = "Artist\\Album\\one.bin"
        let secondFilename = "Artist\\Album\\two.bin"
        env.client.download(username: "MockPeer", filename: firstFilename, size: UInt64(payload.count))
        assertEventually("first download never completed", timeout: 3) {
            transfers.last(where: { $0.filename == firstFilename })?.state == .completed
        }
        env.client.download(username: "MockPeer", filename: secondFilename, size: UInt64(payload.count))
        assertEventually("second download never completed", timeout: 3) {
            transfers.last(where: { $0.filename == secondFilename })?.state == .completed
        }

        let first = env.downloadsDirectory.appendingPathComponent("Artist/Album/one.bin")
        let second = env.downloadsDirectory.appendingPathComponent("Artist/Album/two.bin")
        let album = env.downloadsDirectory.appendingPathComponent("Artist/Album")
        let artist = env.downloadsDirectory.appendingPathComponent("Artist")

        DownloadedFiles.delete(first, upTo: env.downloadsDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: album.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artist.path))

        DownloadedFiles.delete(second, upTo: env.downloadsDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artist.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.downloadsDirectory.path),
                      "the downloads root must be kept")
    }

    /// Deleting all downloads removes every file and clears their transfer entries.
    func testDeletingAllDownloadsRemovesFiles() {
        let payload = makePayload(2048)
        env.peer.downloadPayload = payload
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: "Music\\Album\\one.bin",
                            size: UInt64(payload.count))
        assertEventually("first download never completed", timeout: 3) {
            transfers.last(where: { !$0.isUpload })?.state == .completed
        }

        env.client.download(username: "MockPeer", filename: "Music\\Album\\two.bin",
                            size: UInt64(payload.count))
        assertEventually("second download never completed", timeout: 3) {
            transfers.filter { !$0.isUpload && $0.state == .completed }.count == 2
        }

        let first = env.downloadsDirectory.appendingPathComponent("Music/Album/one.bin")
        let second = env.downloadsDirectory.appendingPathComponent("Music/Album/two.bin")
        let partial = env.downloadsDirectory.appendingPathComponent(".partials/Music/Album/three.bin")
        try? FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(repeating: 0xEE, count: 10).write(to: partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        env.client.deleteAllDownloads()

        assertEventually("download files were not deleted", timeout: 3) {
            !FileManager.default.fileExists(atPath: first.path)
                && !FileManager.default.fileExists(atPath: second.path)
                && !FileManager.default.fileExists(atPath: partial.path)
        }
        XCTAssertTrue(env.client.transfers().isEmpty)
        assertEventually("empty folders were not cleaned up", timeout: 3) {
            !FileManager.default.fileExists(atPath: env.downloadsDirectory.appendingPathComponent("Music").path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.downloadsDirectory.path),
                      "the downloads root must be kept")
    }

    // MARK: Upload

    func testUploadServesSharedFile() {
        let payload = makePayload(2048)
        let virtualPath = "Shared\\served.bin"
        let sharedFile = env.shareDirectory.appendingPathComponent("served.bin")
        try? payload.write(to: sharedFile)

        XCTAssertTrue(env.connectAndWaitForLogin())
        env.client.rescanShares()
        assertEventually("share index was not scanned") { env.client.shares.value.fileCount == 1 }

        env.peer.uploadExpectedSize = payload.count


        env.peer.requestUpload(virtualPath: virtualPath)

        assertEventually("no TransferRequest reached the peer", timeout: 3) {
            !env.peer.transferRequests.isEmpty
        }
        let request = env.peer.transferRequests.first
        XCTAssertEqual(request?.direction, .upload)
        XCTAssertEqual(request?.filename, virtualPath)
        XCTAssertEqual(request?.size, UInt64(payload.count))

        assertEventually("the client did not stream the file bytes", timeout: 3) {
            env.peer.receivedUploadBytes.count >= payload.count
        }
        XCTAssertEqual(env.peer.receivedUploadBytes, payload)

        assertEventually("SendUploadSpeed was not reported", timeout: 3) {
            !env.server.uploadSpeeds.isEmpty
        }
    }

    /// The direct route is unreachable, so the client must ask the downloader to dial it back.
    func testUploadServesSharedFileViaIndirectConnection() {
        let payload = makePayload(2048)
        let virtualPath = "Shared\\served-indirect.bin"
        let sharedFile = env.shareDirectory.appendingPathComponent("served-indirect.bin")
        try? payload.write(to: sharedFile)

        // Report an unreachable address so the direct dial fails and the indirect path is used.
        env.server.peerPortOverride = 1
        env.peer.uploadExpectedSize = payload.count

        XCTAssertTrue(env.connectAndWaitForLogin())
        env.client.rescanShares()
        assertEventually("share index was not scanned") { env.client.shares.value.fileCount == 1 }

        env.peer.requestUpload(virtualPath: virtualPath)

        assertEventually("the client never requested an indirect connection", timeout: 3) {
            env.server.connectToPeerRequests.contains { $0.type == "F" }
        }
        assertEventually("the client did not stream the file bytes", timeout: 3) {
            env.peer.receivedUploadBytes.count >= payload.count
        }
        XCTAssertEqual(env.peer.receivedUploadBytes, payload)
    }

    func testUploadDeniedForUnsharedFile() {
        XCTAssertTrue(env.connectAndWaitForLogin())
        env.client.rescanShares()
        // An empty share tree still has the synthetic root folder; wait for the scan to finish.
        assertEventually("share scan did not finish") { env.client.shares.value.folderCount >= 1 }


        env.peer.requestUpload(virtualPath: "Shared\\not-shared.mp3")

        assertEventually("no UploadDenied reached the peer", timeout: 3) {
            !env.peer.uploadDenied.isEmpty
        }
        XCTAssertEqual(env.peer.uploadDenied.first?.filename, "Shared\\not-shared.mp3")
        XCTAssertEqual(env.peer.uploadDenied.first?.reason, "File not shared.")
    }

    /// An inbound file connection whose token we never issued must be refused, not served.
    func testInboundFileConnectionWithUnknownTokenIsRefused() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        env.peer.sendUnsolicitedFileTransfer(token: 0xDEAD_BEEF)

        assertEventually("the client kept an unsolicited file connection open", timeout: 5) {
            env.peer.unsolicitedFileConnectionClosed
        }
        XCTAssertEqual(env.peer.unsolicitedOffsetBytes, 0,
                       "the client must not answer an unknown transfer token")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: env.downloadsDirectory.path)) ?? []
        XCTAssertEqual(written, [], "nothing should have been written to disk")
    }
}
