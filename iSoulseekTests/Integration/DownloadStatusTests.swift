import Combine
import XCTest
@testable import iSoulseek

/// What the Transfers screen says while a download waits for an uploader, and how the client
/// recovers from an uploader that never answers or stops sending.
final class DownloadStatusTests: XCTestCase {

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

    private func states(in transfers: [Transfer], filename: String) -> [TransferState] {
        transfers.filter { !$0.isUpload && $0.filename == filename }.map(\.state)
    }

    /// A download is not simply "waiting for a peer slot" from the start: it connects, queues with
    /// the uploader, waits for the slot, then opens the file connection.
    func testDownloadReportsEachStepOfTheWait() {
        let payload = makePayload(4096)
        env.peer.downloadPayload = payload
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let filename = "Music\\song.bin"
        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("the download never started", timeout: 3) {
            self.states(in: transfers, filename: filename).contains(.transferring)
        }

        let observed = states(in: transfers, filename: filename)
        XCTAssertTrue(observed.contains(.connecting), "\(observed)")
        XCTAssertTrue(observed.contains(.queued(place: 0)), "\(observed)")
        XCTAssertTrue(observed.contains(.negotiating), "\(observed)")

        let connecting = transfers.first { !$0.isUpload && $0.state == .connecting }
        XCTAssertEqual(connecting?.stateDescription, "Connecting…")
        let queued = transfers.first { !$0.isUpload && $0.state == .queued(place: 0) }
        XCTAssertEqual(queued?.stateDescription, "Waiting for peer slot")
    }

    /// While queued, the client asks the uploader for its place and shows it.
    func testQueuePositionFromThePeerIsShown() {
        env.peer.downloadPayload = makePayload(64)
        env.peer.ignoresQueueUpload = true
        env.peer.placeInQueueAnswer = 3
        env.client.transferManager.queuePollInterval = 0.1
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let filename = "Music\\queued.bin"
        env.client.download(username: "MockPeer", filename: filename, size: 64)

        assertEventually("the peer's queue position never arrived", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.state == .queued(place: 3) }
        }
        let queued = transfers.last { !$0.isUpload && $0.state == .queued(place: 3) }
        XCTAssertEqual(queued?.stateDescription, "Queued (#3)")
        XCTAssertTrue(env.peer.placeRequests.contains(filename))
    }

    /// An offline peer fails straight away with a reason instead of looking like a long queue wait.
    func testOfflinePeerFailsWithAClearReason() {
        env.server.offlinePeers = ["OfflinePeer"]
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        env.client.download(username: "OfflinePeer", filename: "Music\\missing.bin", size: 10)

        assertEventually("the download did not report the peer as offline", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.state == .failed("Peer is offline") }
        }
    }

    /// An uploader that never answers the queue request gets one automatic retry, then a failure.
    func testNoResponseFromPeerIsRetriedOnceThenFails() {
        env.peer.downloadPayload = makePayload(64)
        env.peer.ignoresQueueUpload = true
        let manager = env.client.transferManager
        manager.negotiateTimeout = 0.2
        manager.retryDelay = 0.1
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let filename = "Music\\ignored.bin"
        env.client.download(username: "MockPeer", filename: filename, size: 64)

        assertEventually("the download never gave up after the retry", timeout: 3) {
            transfers.contains { !$0.isUpload && $0.state == .failed("No response from peer") }
        }
        XCTAssertEqual(env.peer.queueUploads.filter { $0 == filename }.count, 2,
                       "the queue request should be sent exactly twice")
        XCTAssertEqual(states(in: transfers, filename: filename).filter { $0 == .connecting }.count, 2,
                       "the retry should show as a new connection attempt")
    }

    /// A transfer that stops receiving data is retried from the bytes already on disk, then fails.
    func testStalledDownloadRetriesFromTheBytesAlreadyReceived() {
        let payload = makePayload(1000)
        env.peer.downloadPayload = payload
        env.peer.downloadStallAfter = 100
        let manager = env.client.transferManager
        manager.stallTimeout = 0.2
        manager.retryDelay = 0.1
        XCTAssertTrue(env.connectAndWaitForLogin())

        var transfers: [Transfer] = []
        let cancellable = env.client.transferChanges.sink { transfers.append($0) }
        defer { cancellable.cancel() }

        let filename = "Music\\stalled.bin"
        env.client.download(username: "MockPeer", filename: filename, size: UInt64(payload.count))

        assertEventually("the stalled download never failed", timeout: 4) {
            transfers.contains { !$0.isUpload && $0.state == .failed("Download stalled") }
        }
        XCTAssertEqual(transfers.last { !$0.isUpload && $0.state == .failed("Download stalled") }?.transferred,
                       200, "the retry must receive bytes from the offset it resumed at")
        XCTAssertEqual(env.peer.downloadAskedOffset, 100,
                       "the retry must resume at the number of bytes already received")
        XCTAssertEqual(states(in: transfers, filename: filename).filter { $0 == .connecting }.count, 2)
    }
}
