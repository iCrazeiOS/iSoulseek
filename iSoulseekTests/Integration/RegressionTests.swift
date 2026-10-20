import Combine
import XCTest
@testable import iSoulseek

/// Regression tests for the batch of transfer, search and browse fixes. Every test drives a real
/// `SoulseekClient` against the in-process mock server/peer and asserts what the user would see.
final class RegressionTests: XCTestCase {

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

    private func downloads(_ relative: String) -> URL {
        env.downloadsDirectory.appendingPathComponent(relative)
    }

    // MARK: Downloads

    /// A download whose name collides with an existing folder must be filed beside it: the folder
    /// and its contents survive, and the new file lands as "Album (2)".
    func testDownloadIntoOccupiedFolderKeepsTheFolder() throws {
        let payload = makePayload(512)
        env.peer.downloadPayload = payload

        let folder = downloads("MockPeer/Album")
        let keptFile = folder.appendingPathComponent("song.bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: keptFile)

        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: "Album", size: UInt64(payload.count))

        assertEventually("the download never completed", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.state == .completed }
        }

        XCTAssertEqual((try? Data(contentsOf: keptFile)), Data("keep me".utf8),
                       "the existing folder's file was destroyed")
        XCTAssertEqual((try? Data(contentsOf: downloads("MockPeer/Album (2)"))), payload,
                       "the new file was not filed next to the occupied folder name")
    }

    /// A partial download larger than the size the peer actually has must restart from zero and
    /// finish with the peer's bytes instead of waiting forever for bytes that will never come.
    func testResumePastPeerSizeRestartsAndCompletes() throws {
        let payload = makePayload(500)
        env.peer.downloadPayload = payload

        let filename = "Music\\song.bin"
        let destination = downloads("MockPeer/Music/song.bin")
        let partial = downloads(".partials/MockPeer/Music/song.bin")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 800).write(to: partial)

        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: 1000)

        assertEventually("the download hung with a resume offset past the peer's size", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.state == .completed }
        }
        assertEventually("the file was not completed with the peer's payload", timeout: 3) {
            (try? Data(contentsOf: destination)) == payload
        }
        XCTAssertEqual(env.peer.downloadAskedOffset, 0,
                       "the transfer must restart at zero when the partial is past the peer's size")
    }

    /// Two downloads from the same peer in the same moment need distinct transfer tokens; both
    /// files must complete rather than one being mistaken for the other.
    func testTwoIndirectDownloadsFromOnePeerBothComplete() {
        let payload = makePayload(3000)
        env.peer.downloadPayload = payload
        env.peer.downloadViaIndirect = true

        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let first = "Music\\first.bin"
        let second = "Music\\second.bin"
        env.client.download(username: "MockPeer", filename: first, size: UInt64(payload.count))
        env.client.download(username: "MockPeer", filename: second, size: UInt64(payload.count))

        assertEventually("the first indirect download never completed", timeout: 5) {
            transfers.contains { !$0.isUpload && $0.filename == first && $0.state == .completed }
        }
        assertEventually("the second indirect download never completed", timeout: 5) {
            transfers.contains { !$0.isUpload && $0.filename == second && $0.state == .completed }
        }
        XCTAssertEqual((try? Data(contentsOf: downloads("MockPeer/Music/first.bin"))), payload)
        XCTAssertEqual((try? Data(contentsOf: downloads("MockPeer/Music/second.bin"))), payload)
    }

    /// Re-queueing a file that previously failed must retire the stale failure row, even when the
    /// retry was started outside the Transfers screen.
    func testRetryingAFailedDownloadRetiresTheFailure() {
        let payload = makePayload(256)
        env.peer.downloadPayload = payload
        env.peer.denyQueueUploadReason = "File not shared."
        let filename = "Music\\retry.bin"

        XCTAssertTrue(env.connectAndWaitForLogin())

        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))
        assertEventually("the failed download was never recorded", timeout: 3) {
            env.client.recentFailedDownloads.transfers.contains { $0.filename == filename }
        }

        env.peer.denyQueueUploadReason = nil

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("the stale failure was not retired when the file was queued again",
                         timeout: 3) {
            !env.client.recentFailedDownloads.transfers.contains { $0.filename == filename }
        }
        assertEventually("the retry never completed", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.filename == filename && $0.state == .completed }
        }
    }

    // MARK: Uploads

    /// Cancelling an upload that has already taken the only upload slot must release it, so the
    /// next upload actually starts instead of sitting in the queue for the rest of the session.
    func testCancellingAStreamingUploadReleasesItsSlot() throws {
        let bigSize = 128 * 1024 * 1024
        let firstFile = env.shareDirectory.appendingPathComponent("first.bin")
        let secondFile = env.shareDirectory.appendingPathComponent("second.bin")
        let secondPayload = makePayload(1024)

        // A sparse file keeps the first upload streaming long enough to cancel it mid-transfer.
        FileManager.default.createFile(atPath: firstFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: firstFile)
        try handle.truncate(atOffset: UInt64(bigSize))
        try handle.close()
        try secondPayload.write(to: secondFile)

        // Smaller chunks keep the streaming phase long enough for the test to observe and cancel.
        env.client.transferManager.uploadChunkSize = 4 * 1024

        XCTAssertTrue(env.connectAndWaitForLogin())
        assertEventually("the client never advertised a listening port", timeout: 3) {
            env.server.clientListeningPort > 0
        }
        env.client.rescanShares()
        assertEventually("the share index was not scanned", timeout: 5) {
            env.client.shares.value.fileCount == 2
        }

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.peer.requestUpload(virtualPath: "Shared\\first.bin")
        assertEventually("the first upload never started streaming", timeout: 5) {
            transfers.contains { $0.isUpload && $0.filename == "Shared\\first.bin"
                && $0.state == .transferring }
        }
        guard let firstID = transfers.last(where: { $0.isUpload && $0.filename == "Shared\\first.bin" })?.id else {
            return XCTFail("no upload transfer was observed")
        }

        env.client.cancelTransfers(ids: [firstID])
        assertEventually("the streaming upload was not cancelled", timeout: 3) {
            transfers.contains { $0.id == firstID && $0.state == .cancelled }
        }

        env.peer.requestUpload(virtualPath: "Shared\\second.bin")
        assertEventually("the next upload never got the released slot", timeout: 5) {
            transfers.contains { $0.isUpload && $0.filename == "Shared\\second.bin"
                && $0.state == .completed }
        }
    }

    /// A transfer that streams for more than a second reports its throughput, which the Transfers
    /// screen shows next to the byte count.
    func testStreamingUploadReportsSpeed() throws {
        let bigFile = env.shareDirectory.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: bigFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bigFile)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()

        // Small chunks keep the upload streaming long enough for a speed to be measured.
        env.client.transferManager.uploadChunkSize = 4 * 1024
        XCTAssertTrue(env.connectAndWaitForLogin())
        assertEventually("the client never advertised a listening port", timeout: 3) {
            env.server.clientListeningPort > 0
        }
        env.client.rescanShares()
        assertEventually("the share index was not scanned", timeout: 5) {
            env.client.shares.value.fileCount == 1
        }

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.peer.requestUpload(virtualPath: "Shared\\big.bin")
        assertEventually("the upload never reported a speed", timeout: 5) {
            transfers.contains { $0.isUpload && $0.averageSpeed > 0 }
        }

        guard let upload = transfers.last(where: { $0.isUpload }) else {
            return XCTFail("no upload was observed")
        }
        XCTAssertGreaterThan(upload.transferred, 0)
        env.client.cancelTransfers(ids: [upload.id])
    }

    // MARK: Search

    /// A search response that inflates past the small prefix-check limit must still be delivered
    /// in full instead of being discarded as if it were not ours.
    func testLargeSearchResponseDeliversAllResults() {
        env.peer.searchFiles = (0..<60).map { index in
            ShareFile(name: "Music\\track-\(index)-\(String(repeating: "x", count: 100)).mp3",
                      size: UInt64(index + 1), fileExtension: "mp3",
                      attributes: [SearchAttribute.bitrate.rawValue: 320])
        }
        XCTAssertTrue(env.connectAndWaitForLogin())

        var results: [SearchResult] = []
        let cancellable = env.client.searchResults.sink { results.append($0) }
        defer { cancellable.cancel() }

        guard let token = env.client.search("large response") else {
            return XCTFail("search returned no token")
        }

        assertEventually("the large search response was dropped", timeout: 5) {
            results.count == 60
        }
        XCTAssertTrue(results.allSatisfy { $0.token == token })
        XCTAssertEqual(results.first?.file.size, 1)
        XCTAssertEqual(results.last?.file.size, 60)
    }

    /// Disconnecting with a search still open must tell the UI the search is over, or its
    /// spinner would run until the 90-second lifetime expires.
    func testSearchFinishedIsEmittedOnDisconnect() {
        env.peer.searchTokenOverride = 0x7FFF_FFFF
        XCTAssertTrue(env.connectAndWaitForLogin())

        var finished: [UInt32] = []
        let cancellable = env.client.searchFinished.sink { finished.append($0) }
        defer { cancellable.cancel() }

        guard let token = env.client.search("never answered") else {
            return XCTFail("search returned no token")
        }
        assertEventually("FileSearch did not reach the server") {
            env.server.searches.contains { $0.token == token }
        }

        env.client.disconnect()

        assertEventually("searchFinished was never emitted on disconnect", timeout: 3) {
            finished.contains(token)
        }
    }

    // MARK: Browse

    /// A browse in flight when the connection drops must report its failure instead of leaving
    /// the browser spinning forever.
    func testBrowseCompletesWithFailureWhenDisconnectedMidRequest() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        var outcome: Result<[ShareFolder], Error>?
        env.client.browse(username: "MockPeer") { outcome = $0 }
        env.client.disconnect()

        assertEventually("the browse never completed after the disconnect", timeout: 3) {
            outcome != nil
        }
        guard case .failure? = outcome else {
            return XCTFail("a browse cut off by a disconnect reported success: \(String(describing: outcome))")
        }
    }

    /// Two screens (or a double tap) may ask for the same user's tree at once; both callers must
    /// receive the folders rather than the second request being silently dropped.
    func testConcurrentBrowsesForSameUserBothComplete() {
        env.peer.shareFolders = [
            ShareFolder(path: "Music", files: [
                ShareFile(name: "Music\\a.mp3", size: 10, fileExtension: "mp3")
            ]),
            ShareFolder(path: "Music\\Album", files: [
                ShareFile(name: "Music\\Album\\b.flac", size: 20, fileExtension: "flac")
            ])
        ]
        XCTAssertTrue(env.connectAndWaitForLogin())

        var first: Result<[ShareFolder], Error>?
        var second: Result<[ShareFolder], Error>?
        env.client.browse(username: "MockPeer") { first = $0 }
        env.client.browse(username: "MockPeer") { second = $0 }

        assertEventually("not both concurrent browses completed", timeout: 3) {
            first != nil && second != nil
        }
        guard case .success(let firstFolders)? = first,
              case .success(let secondFolders)? = second else {
            return XCTFail("a concurrent browse failed: \(String(describing: first)) / \(String(describing: second))")
        }
        XCTAssertEqual(firstFolders.map(\.path), secondFolders.map(\.path),
                       "both callers must receive the same folder list")
        XCTAssertEqual(firstFolders.count, 2)
    }
}
