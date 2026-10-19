import XCTest
@testable import Soulseek

final class MessageDecodingTests: XCTestCase {

    private func zlib(_ body: Data) -> Data { try! Zlib.compress(body) }

    private func searchFileBody(name: String, size: UInt64, extension ext: String = "",
                                attributes: [(UInt32, UInt32)] = []) -> Data {
        var writer = ByteWriter()
        writer.write(UInt8(1))
        writer.write(string: name)
        writer.write(size)
        writer.write(string: ext)
        writer.write(UInt32(attributes.count))
        for (code, value) in attributes {
            writer.write(code)
            writer.write(value)
        }
        return writer.data
    }

    // MARK: Login

    func testLoginSuccess() throws {
        var writer = ByteWriter()
        writer.write(true)
        writer.write(string: "Welcome to Soulseek!")
        writer.write(ip: "1.2.3.4")
        writer.write(string: "1a1dc91c907325c69271ddf0c944bc72")
        writer.write(true)

        let message = try ServerMessage.decode(code: 1, payload: writer.data)
        guard case .login(let result) = message else { return XCTFail("expected login") }
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.greeting, "Welcome to Soulseek!")
        XCTAssertEqual(result.ownIP, "1.2.3.4")
        XCTAssertTrue(result.isSupporter)
    }

    func testLoginFailureWithDetail() throws {
        var writer = ByteWriter()
        writer.write(false)
        writer.write(string: "INVALIDPASS")
        writer.write(string: "check your password")

        let message = try ServerMessage.decode(code: 1, payload: writer.data)
        guard case .login(let result) = message else { return XCTFail("expected login") }
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.rejectionReason, "INVALIDPASS")
        XCTAssertEqual(result.rejectionDetail, "check your password")
    }

    func testLoginFailureWithoutDetail() throws {
        var writer = ByteWriter()
        writer.write(false)
        writer.write(string: "SVRFULL")

        guard case .login(let result) = try ServerMessage.decode(code: 1, payload: writer.data) else {
            return XCTFail("expected login")
        }
        XCTAssertEqual(result.rejectionReason, "SVRFULL")
        XCTAssertEqual(result.rejectionDetail, "")
    }

    // MARK: Server messages

    func testGetPeerAddress() throws {
        var writer = ByteWriter()
        writer.write(string: "bob")
        writer.write(ip: "192.168.0.7")
        writer.write(UInt32(2234))

        guard case .peerAddress(let address) = try ServerMessage.decode(code: 3, payload: writer.data) else {
            return XCTFail("expected peerAddress")
        }
        XCTAssertEqual(address.username, "bob")
        XCTAssertEqual(address.ip, "192.168.0.7")
        XCTAssertEqual(address.port, 2234)
    }

    func testConnectToPeerWithTrailingPrivilegedAndObfuscation() throws {
        var writer = ByteWriter()
        writer.write(string: "bob")
        writer.write(string: "P")
        writer.write(ip: "10.0.0.1")
        writer.write(UInt32(5000))
        writer.write(UInt32(0x00C0_FFEE))
        writer.write(true)          // privileged
        writer.write(UInt32(1))     // obfuscation type (ignored)
        writer.write(UInt32(12345)) // obfuscated port (ignored)

        guard case .connectToPeer(let info) = try ServerMessage.decode(code: 18, payload: writer.data) else {
            return XCTFail("expected connectToPeer")
        }
        XCTAssertEqual(info.username, "bob")
        XCTAssertEqual(info.connectionType, "P")
        XCTAssertEqual(info.ip, "10.0.0.1")
        XCTAssertEqual(info.port, 5000)
        XCTAssertEqual(info.token, 0x00C0_FFEE)
        XCTAssertTrue(info.isPrivileged)
    }

    func testConnectToPeerWithoutTrailingFields() throws {
        var writer = ByteWriter()
        writer.write(string: "bob")
        writer.write(string: "P")
        writer.write(ip: "10.0.0.1")
        writer.write(UInt32(5000))
        writer.write(UInt32(1))

        guard case .connectToPeer(let info) = try ServerMessage.decode(code: 18, payload: writer.data) else {
            return XCTFail("expected connectToPeer")
        }
        XCTAssertFalse(info.isPrivileged)
    }

    func testGetUserStats() throws {
        var writer = ByteWriter()
        writer.write(string: "bob")
        writer.write(UInt32(1234))  // average speed
        writer.write(UInt32(56))    // uploads (uploadnum)
        writer.write(UInt32(0))     // unknown
        writer.write(UInt32(789))   // files
        writer.write(UInt32(12))    // directories

        guard case .userStats(let username, let speed, let uploads, let files, let directories)
            = try ServerMessage.decode(code: 36, payload: writer.data) else {
            return XCTFail("expected userStats")
        }
        XCTAssertEqual(username, "bob")
        XCTAssertEqual(speed, 1234)
        XCTAssertEqual(uploads, 56)
        XCTAssertEqual(files, 789)
        XCTAssertEqual(directories, 12)
    }

    func testExcludedSearchPhrases() throws {
        var writer = ByteWriter()
        writer.write(UInt32(2))
        writer.write(string: "*.exe")
        writer.write(string: "badword")

        guard case .excludedSearchPhrases(let phrases)
            = try ServerMessage.decode(code: 160, payload: writer.data) else {
            return XCTFail("expected excludedSearchPhrases")
        }
        XCTAssertEqual(phrases, ["*.exe", "badword"])
    }

    func testCheckPrivilegesReply() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0))
        guard case .privilegesRemaining(let seconds)
            = try ServerMessage.decode(code: 92, payload: writer.data) else {
            return XCTFail("expected privilegesRemaining")
        }
        XCTAssertEqual(seconds, 0)
    }

    func testUnknownServerCodeIsUnhandled() throws {
        guard case .unhandled(let code) = try ServerMessage.decode(code: 9999, payload: Data()) else {
            return XCTFail("expected unhandled")
        }
        XCTAssertEqual(code, 9999)
    }

    func testTruncatedServerMessageThrows() {
        XCTAssertThrowsError(try ServerMessage.decode(code: 3, payload: Data([0x01]))) { error in
            XCTAssertEqual(error as? ProtocolError, .truncated)
        }
    }

    // MARK: Peer messages

    func testSharedFileListResponse() throws {
        let folders = [
            ShareFolder(path: "Music", files: [
                ShareFile(name: "Music\\a.mp3", size: 100, fileExtension: "mp3", attributes: [0: 192])
            ])
        ]
        var body = ByteWriter()
        body.write(raw: ShareCodec.encode(folders: folders))
        body.write(UInt32(0)) // trailing field official clients send

        guard case .sharedFileList(let decoded) = try PeerMessage.decode(code: 5, payload: zlib(body.data)) else {
            return XCTFail("expected sharedFileList")
        }
        XCTAssertEqual(decoded, folders)
    }

    func testFileSearchResponseWithAttributes() throws {
        var body = ByteWriter()
        body.write(string: "bob")
        body.write(UInt32(0x1122_3344))
        body.write(UInt32(1))
        body.write(raw: searchFileBody(name: "Music\\song.mp3", size: 500_000, extension: "mp3",
                                       attributes: [(0, 320), (1, 200)]))
        body.write(true)          // slot free
        body.write(UInt32(4200))  // average speed
        body.write(UInt32(3))     // queue length
        body.write(UInt32(0))     // unknown / private block absent

        guard case .fileSearchResponse(let results) = try PeerMessage.decode(code: 9, payload: zlib(body.data)) else {
            return XCTFail("expected fileSearchResponse")
        }
        XCTAssertEqual(results.username, "bob")
        XCTAssertEqual(results.token, 0x1122_3344)
        XCTAssertEqual(results.files.count, 1)
        XCTAssertEqual(results.files[0].size, 500_000)
        XCTAssertEqual(results.files[0].fileExtension, "mp3")
        XCTAssertEqual(results.files[0].bitrate, 320)
        XCTAssertEqual(results.files[0].duration, 200)
        XCTAssertTrue(results.isSlotFree)
        XCTAssertEqual(results.averageSpeed, 4200)
        XCTAssertEqual(results.queueLength, 3)
    }

    func testFileSearchResponseWithoutOptionalTrailingFields() throws {
        var body = ByteWriter()
        body.write(string: "bob")
        body.write(UInt32(7))
        body.write(UInt32(1))
        body.write(raw: searchFileBody(name: "song.mp3", size: 10))

        guard case .fileSearchResponse(let results) = try PeerMessage.decode(code: 9, payload: zlib(body.data)) else {
            return XCTFail("expected fileSearchResponse")
        }
        XCTAssertEqual(results.files.count, 1)
        XCTAssertFalse(results.isSlotFree)
        XCTAssertEqual(results.averageSpeed, 0)
        XCTAssertEqual(results.queueLength, 0)
    }

    func testFolderContentsResponse() throws {
        let folders = [ShareFolder(path: "Music", files: [ShareFile(name: "Music\\a.mp3", size: 1)])]
        var body = ByteWriter()
        body.write(UInt32(0xABCD))
        body.write(string: "Music")
        body.write(raw: ShareCodec.encode(folders: folders))

        guard case .folderContentsResponse(let token, let folder, let decoded)
            = try PeerMessage.decode(code: 37, payload: zlib(body.data)) else {
            return XCTFail("expected folderContentsResponse")
        }
        XCTAssertEqual(token, 0xABCD)
        XCTAssertEqual(folder, "Music")
        XCTAssertEqual(decoded, folders)
    }

    func testTransferRequestUploadForm() throws {
        var writer = ByteWriter()
        writer.write(UInt32(1))
        writer.write(UInt32(0x55))
        writer.write(string: "f.mp3")
        writer.write(UInt64(1234))

        guard case .transferRequest(let info) = try PeerMessage.decode(code: 40, payload: writer.data) else {
            return XCTFail("expected transferRequest")
        }
        XCTAssertEqual(info.direction, .upload)
        XCTAssertEqual(info.token, 0x55)
        XCTAssertEqual(info.filename, "f.mp3")
        XCTAssertEqual(info.size, 1234)
    }

    func testTransferRequestDownloadFormHasNoSize() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0))
        writer.write(UInt32(0x55))
        writer.write(string: "f.mp3")

        guard case .transferRequest(let info) = try PeerMessage.decode(code: 40, payload: writer.data) else {
            return XCTFail("expected transferRequest")
        }
        XCTAssertEqual(info.direction, .download)
        XCTAssertNil(info.size)
    }

    func testTransferResponseAllowedWithSize() throws {
        var writer = ByteWriter()
        writer.write(UInt32(9))
        writer.write(true)
        writer.write(UInt64(2048))

        guard case .transferResponse(let info) = try PeerMessage.decode(code: 41, payload: writer.data) else {
            return XCTFail("expected transferResponse")
        }
        XCTAssertTrue(info.isAllowed)
        XCTAssertEqual(info.size, 2048)
        XCTAssertNil(info.reason)
    }

    func testTransferResponseAllowedWithoutSize() throws {
        var writer = ByteWriter()
        writer.write(UInt32(9))
        writer.write(true)

        guard case .transferResponse(let info) = try PeerMessage.decode(code: 41, payload: writer.data) else {
            return XCTFail("expected transferResponse")
        }
        XCTAssertTrue(info.isAllowed)
        XCTAssertNil(info.size)
    }

    func testTransferResponseDeniedWithReason() throws {
        var writer = ByteWriter()
        writer.write(UInt32(9))
        writer.write(false)
        writer.write(string: "Queued")

        guard case .transferResponse(let info) = try PeerMessage.decode(code: 41, payload: writer.data) else {
            return XCTFail("expected transferResponse")
        }
        XCTAssertFalse(info.isAllowed)
        XCTAssertEqual(info.reason, "Queued")
    }

    func testPlaceInQueueResponse() throws {
        var writer = ByteWriter()
        writer.write(string: "f.mp3")
        writer.write(UInt32(4))
        guard case .placeInQueueResponse(let filename, let place)
            = try PeerMessage.decode(code: 44, payload: writer.data) else {
            return XCTFail("expected placeInQueueResponse")
        }
        XCTAssertEqual(filename, "f.mp3")
        XCTAssertEqual(place, 4)
    }

    func testUploadDenied() throws {
        var writer = ByteWriter()
        writer.write(string: "f.mp3")
        writer.write(string: "File not shared.")
        guard case .uploadDenied(let filename, let reason)
            = try PeerMessage.decode(code: 50, payload: writer.data) else {
            return XCTFail("expected uploadDenied")
        }
        XCTAssertEqual(filename, "f.mp3")
        XCTAssertEqual(reason, "File not shared.")
    }

    func testUnknownPeerCodeIsUnhandled() throws {
        guard case .unhandled(let code) = try PeerMessage.decode(code: 1234, payload: Data()) else {
            return XCTFail("expected unhandled")
        }
        XCTAssertEqual(code, 1234)
    }

    func testCorruptCompressedPeerMessageThrows() {
        XCTAssertThrowsError(try PeerMessage.decode(code: 5, payload: Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? ProtocolError, .compressionFailed)
        }
    }

    // MARK: Init channel

    func testInitMessageDecodePeerInit() throws {
        var writer = ByteWriter()
        writer.write(string: "alice")
        writer.write(string: "P")
        writer.write(UInt32(0x42))

        guard case .peerInit(let username, let type, let token)
            = try InitMessage.decode(code: 1, payload: writer.data) else {
            return XCTFail("expected peerInit")
        }
        XCTAssertEqual(username, "alice")
        XCTAssertEqual(type, "P")
        XCTAssertEqual(token, 0x42)
    }

    func testInitMessageDecodePierceFireWall() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0xCAFE))
        guard case .pierceFireWall(let token) = try InitMessage.decode(code: 0, payload: writer.data) else {
            return XCTFail("expected pierceFireWall")
        }
        XCTAssertEqual(token, 0xCAFE)
    }

    func testInitMessageRejectsUnknownCode() {
        XCTAssertThrowsError(try InitMessage.decode(code: 9, payload: Data())) { error in
            guard case .unsupportedMessage = (error as? ProtocolError) else {
                return XCTFail("expected unsupportedMessage, got \(error)")
            }
        }
    }

    func testInitMessagePeerInitWithoutTokenDefaultsToZero() throws {
        var writer = ByteWriter()
        writer.write(string: "alice")
        writer.write(string: "F")
        guard case .peerInit(_, let type, let token) = try InitMessage.decode(code: 1, payload: writer.data) else {
            return XCTFail("expected peerInit")
        }
        XCTAssertEqual(type, "F")
        XCTAssertEqual(token, 0)
    }
}
