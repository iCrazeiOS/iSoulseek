import XCTest
@testable import iSoulseek

final class TransferManagerTests: XCTestCase {

    private var root: URL!
    private var manager: TransferManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager = TransferManager(queue: DispatchQueue(label: "TransferManagerTests"),
                                  downloadsDirectory: root)
    }

    override func tearDownWithError() throws {
        manager = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    func testSamePathFromDifferentUsersGetsSeparateFiles() {
        guard case .added = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac",
                                                    size: 100) else {
            return XCTFail("first download was not added")
        }
        guard case .added = manager.enqueueDownload(username: "bob", filename: "Music\\song.flac",
                                                    size: 100) else {
            return XCTFail("second download was not added")
        }

        XCTAssertEqual(manager.allTransfers.count, 2)
    }

    func testCompleteFileIsReportedAsAlreadyDownloaded() throws {
        _ = try write("alice/Music/song.flac", bytes: 100)

        let result = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac", size: 100)
        guard case .alreadyDownloaded(let transfer) = result else {
            return XCTFail("complete file should not be downloaded again")
        }

        XCTAssertEqual(transfer.state, .completed)
        XCTAssertTrue(manager.allTransfers.isEmpty)
    }

    func testDifferentSizeExistingFileRestartsFromZero() throws {
        _ = try write("alice/Music/song.flac", bytes: 200)

        let result = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac", size: 100)
        guard case .added(let transfer) = result else {
            return XCTFail("different file should be downloaded again")
        }

        XCTAssertEqual(transfer.transferred, 0)
        XCTAssertEqual(transfer.state, .negotiating)
    }

    func testPartialExistingFileResumes() throws {
        _ = try write(".partials/alice/Music/song.flac", bytes: 40)

        let result = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac", size: 100)
        guard case .added(let transfer) = result else {
            return XCTFail("partial file should be resumed")
        }

        XCTAssertEqual(transfer.transferred, 40)
        XCTAssertEqual(transfer.state, .negotiating)
    }

    func testCancelDiscardsPartialFile() throws {
        let partial = try write(".partials/alice/Music/song.flac", bytes: 40)

        let result = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac", size: 100)
        guard case .added(let transfer) = result else {
            return XCTFail("download was not added")
        }

        manager.cancel(id: transfer.id)

        assertEventually("the partial file was left on disk") {
            !FileManager.default.fileExists(atPath: partial.path)
        }
    }

    // MARK: Failure surfacing

    /// A download whose session can never be established must publish its failure with a reason
    /// before being dropped from the in-memory list; the Transfers screen keeps the row visible.
    func testFailedDownloadIsPublishedThenDropped() {
        var published: [Transfer] = []
        manager.onUpdate = { published.append($0) }
        manager.sessionProvider = { _, completion in completion(nil) }

        guard case .added = manager.enqueueDownload(username: "alice",
                                                    filename: "Music\\song.flac", size: 100) else {
            return XCTFail("download was not queued")
        }

        XCTAssertEqual(published.count, 2, "the queued and failed states must both be published")
        XCTAssertEqual(published.last?.state, .failed("Could not connect to alice"),
                       "the failure must surface with its reason")
        XCTAssertTrue(published.last.map { !$0.isUpload } ?? false)
        XCTAssertTrue(manager.allTransfers.isEmpty,
                      "failed transfers are dropped from the list; the UI keeps them visible")
    }

    func testFailedDownloadReleasesTheUserSession() {
        var releasedUsernames: [String] = []
        manager.onUserWorkFinished = { releasedUsernames.append($0) }
        manager.sessionProvider = { _, completion in completion(nil) }

        _ = manager.enqueueDownload(username: "alice", filename: "Music\\song.flac", size: 100)

        assertEventually("the failed download did not release the user's session") {
            releasedUsernames == ["alice"]
        }
    }
}
