import Combine
import XCTest
@testable import Soulseek

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
    }

    func testDownloadResumesFromExistingBytes() {
        let payload = makePayload(1000)
        env.peer.downloadPayload = payload
        let filename = "Music\\resume.bin"
        let destination = env.downloadsDirectory.appendingPathComponent("Music/resume.bin")

        // Pre-create a partial download with the first 300 bytes already on disk.
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? payload.prefix(300).write(to: destination)

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
