import XCTest
@testable import iSoulseek

final class MessageEncodingTests: XCTestCase {

    // MARK: Server requests

    func testLoginPayload() {
        let payload = ServerRequest.login(username: "user", password: "pass",
                                          major: 177, minor: 1).payload()

        var expected = ByteWriter()
        expected.write(string: "user")
        expected.write(string: "pass")
        expected.write(UInt32(177))
        expected.write(string: "63e780c3f321d13109c71bf81805476e") // md5hex("userpass")
        expected.write(UInt32(1))
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testFileSearchPayload() {
        let payload = ServerRequest.fileSearch(token: 0x1122_3344, query: "abc").payload()
        var expected = ByteWriter()
        expected.write(UInt32(0x1122_3344))
        expected.write(string: "abc")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testSetWaitPortPayload() {
        let payload = ServerRequest.setWaitPort(2234).payload()
        XCTAssertEqual(Array(payload), [0xBA, 0x08, 0x00, 0x00])
    }

    func testSetStatusAndSharedFoldersAndHaveNoParent() {
        XCTAssertEqual(Array(ServerRequest.setStatus(.online).payload()), [0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(ServerRequest.setStatus(.away).payload()), [0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(ServerRequest.sharedFoldersFiles(directories: 3, files: 9).payload()),
                       [0x03, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(ServerRequest.haveNoParent(true).payload()), [0x01])
        XCTAssertEqual(Array(ServerRequest.haveNoParent(false).payload()), [0x00])
    }

    func testConnectToPeerPayload() {
        let payload = ServerRequest.connectToPeer(token: 0x00AABBCC, username: "bob",
                                                  type: .peer).payload()
        var expected = ByteWriter()
        expected.write(UInt32(0x00AA_BBCC))
        expected.write(string: "bob")
        expected.write(string: "P")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testEmptyPayloadRequestsProduceNoBytes() {
        XCTAssertTrue(ServerRequest.serverPing.payload().isEmpty)
        XCTAssertTrue(ServerRequest.checkPrivileges.payload().isEmpty)
    }

    func testRequestCodes() {
        XCTAssertEqual(ServerRequest.login(username: "a", password: "b", major: 1, minor: 2).code, .login)
        XCTAssertEqual(ServerRequest.setWaitPort(1).code, .setWaitPort)
        XCTAssertEqual(ServerRequest.haveNoParent(true).code, .haveNoParent)
        XCTAssertEqual(ServerRequest.checkPrivileges.code, .checkPrivileges)
        XCTAssertEqual(ServerRequest.sendUploadSpeed(10).code, .sendUploadSpeed)
        XCTAssertEqual(ServerRequest.cantConnectToPeer(token: 1, username: "x").code, .cantConnectToPeer)
    }

    // MARK: Peer requests

    func testQueueUploadPayload() throws {
        let payload = try PeerRequest.queueUpload(filename: "Music\\song.mp3").payload()
        var expected = ByteWriter()
        expected.write(string: "Music\\song.mp3")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferRequestUploadIncludesSize() throws {
        let payload = try PeerRequest.transferRequest(TransferRequestInfo(
            direction: .upload, token: 0x0102_0304, filename: "f", size: 0xFF
        )).payload()

        var expected = ByteWriter()
        expected.write(UInt32(1))                 // direction = upload
        expected.write(UInt32(0x0102_0304))
        expected.write(string: "f")
        expected.write(UInt64(0xFF))
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferRequestDownloadOmitsSize() throws {
        let payload = try PeerRequest.transferRequest(TransferRequestInfo(
            direction: .download, token: 7, filename: "f", size: 999
        )).payload()

        var expected = ByteWriter()
        expected.write(UInt32(0))                 // direction = download
        expected.write(UInt32(7))
        expected.write(string: "f")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferResponseAllowedWithSize() throws {
        let payload = try PeerRequest.transferResponse(TransferResponseInfo(
            token: 3, isAllowed: true, size: 0x0102_0304_0506_0708, reason: nil
        )).payload()
        var expected = ByteWriter()
        expected.write(UInt32(3))
        expected.write(true)
        expected.write(UInt64(0x0102_0304_0506_0708))
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferResponseAllowedWithoutSize() throws {
        let payload = try PeerRequest.transferResponse(TransferResponseInfo(
            token: 3, isAllowed: true, size: nil, reason: nil
        )).payload()
        var expected = ByteWriter()
        expected.write(UInt32(3))
        expected.write(true)
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferResponseDeniedCarriesReason() throws {
        let payload = try PeerRequest.transferResponse(TransferResponseInfo(
            token: 3, isAllowed: false, size: nil, reason: "Queued"
        )).payload()
        var expected = ByteWriter()
        expected.write(UInt32(3))
        expected.write(false)
        expected.write(string: "Queued")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testTransferResponseDeniedDefaultsToQueued() throws {
        let payload = try PeerRequest.transferResponse(TransferResponseInfo(
            token: 3, isAllowed: false, size: nil, reason: nil
        )).payload()
        var expected = ByteWriter()
        expected.write(UInt32(3))
        expected.write(false)
        expected.write(string: "Queued")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testUploadDeniedPayload() throws {
        let payload = try PeerRequest.uploadDenied(filename: "f.mp3",
                                                   reason: "File not shared.").payload()
        var expected = ByteWriter()
        expected.write(string: "f.mp3")
        expected.write(string: "File not shared.")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testPeerInitPayloadAndChannel() throws {
        let request = PeerRequest.peerInit(username: "me", connectionType: .peer, token: 0)
        XCTAssertTrue(request.usesInitChannel)
        var expected = ByteWriter()
        expected.write(string: "me")
        expected.write(string: "P")
        expected.write(UInt32(0))
        XCTAssertEqual(Array(try request.payload()), Array(expected.data))
        XCTAssertEqual(try PeerRequest.getShareFileList.payload(), Data())
    }

    func testPierceFireWallPayloadAndChannel() throws {
        let request = PeerRequest.pierceFireWall(token: 0xDEAD_BEEF)
        XCTAssertTrue(request.usesInitChannel)
        var expected = ByteWriter()
        expected.write(UInt32(0xDEAD_BEEF))
        XCTAssertEqual(Array(try request.payload()), Array(expected.data))
    }

    func testMD5HexKnownVector() {
        XCTAssertEqual(MD5Hex.hash("userpass"), "63e780c3f321d13109c71bf81805476e")
        XCTAssertEqual(MD5Hex.hash(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5Hex.hash("secret"), "5ebe2294ecd0e0f08eab7690d2a6ee69")
    }
}
