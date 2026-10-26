import XCTest
@testable import iSoulseek

final class ChatProtocolTests: XCTestCase {

    // MARK: Outgoing requests

    func testJoinRoomPayload() {
        let payload = ServerRequest.joinRoom(name: "Music", isPrivate: false).payload()
        var expected = ByteWriter()
        expected.write(string: "Music")
        expected.write(UInt32(0))
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testJoinPrivateRoomPayload() {
        let payload = ServerRequest.joinRoom(name: "Secret", isPrivate: true).payload()
        var expected = ByteWriter()
        expected.write(string: "Secret")
        expected.write(UInt32(1))
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testLeaveRoomPayload() {
        let payload = ServerRequest.leaveRoom(name: "Music").payload()
        var expected = ByteWriter()
        expected.write(string: "Music")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testSayChatroomPayload() {
        let payload = ServerRequest.sayChatroom(room: "Music", message: "hello").payload()
        var expected = ByteWriter()
        expected.write(string: "Music")
        expected.write(string: "hello")
        XCTAssertEqual(Array(payload), Array(expected.data))
    }

    func testAcknowledgeMessagePayload() {
        let payload = ServerRequest.acknowledgeMessage(id: 0x0102_0304).payload()
        XCTAssertEqual(Array(payload), [0x04, 0x03, 0x02, 0x01])
    }

    func testRoomListRequestHasNoPayloadAndExpectedCode() {
        XCTAssertTrue(ServerRequest.getRoomList.payload().isEmpty)
        XCTAssertEqual(ServerRequest.getRoomList.code, .roomList)
        XCTAssertEqual(ServerRequest.joinRoom(name: "a", isPrivate: false).code, .joinRoom)
        XCTAssertEqual(ServerRequest.leaveRoom(name: "a").code, .leaveRoom)
        XCTAssertEqual(ServerRequest.sayChatroom(room: "a", message: "b").code, .sayChatroom)
        XCTAssertEqual(ServerRequest.acknowledgeMessage(id: 1).code, .messageAcked)
    }

    // MARK: Incoming messages

    func testRoomListDecodesNamesAndCounts() throws {
        var writer = ByteWriter()
        writer.write(UInt32(2))
        writer.write(string: "Music")
        writer.write(string: "Chat")
        writer.write(UInt32(2))
        writer.write(UInt32(12))
        writer.write(UInt32(3))

        guard case .roomList(let rooms) = try ServerMessage.decode(code: 64, payload: writer.data) else {
            return XCTFail("expected roomList")
        }
        XCTAssertEqual(rooms, [ChatRoom(name: "Music", userCount: 12),
                               ChatRoom(name: "Chat", userCount: 3)])
    }

    func testRoomListIgnoresPrivateRoomTails() throws {
        var writer = ByteWriter()
        writer.write(UInt32(1))
        writer.write(string: "Music")
        writer.write(UInt32(1))
        writer.write(UInt32(7))

        // Owned private rooms.
        writer.write(UInt32(1))
        writer.write(string: "My Room")
        writer.write(UInt32(1))
        writer.write(UInt32(2))
        // Member private rooms.
        writer.write(UInt32(0))
        writer.write(UInt32(0))
        // Operated private rooms (names only).
        writer.write(UInt32(1))
        writer.write(string: "Moderated")

        guard case .roomList(let rooms) = try ServerMessage.decode(code: 64, payload: writer.data) else {
            return XCTFail("expected roomList")
        }
        XCTAssertEqual(rooms, [ChatRoom(name: "Music", userCount: 7)])
    }

    func testJoinRoomDecodesUsersAndStatuses() throws {
        var writer = ByteWriter()
        writer.write(string: "Music")
        writer.write(UInt32(2))
        writer.write(string: "me")
        writer.write(string: "bob")
        writer.write(UInt32(2))
        writer.write(UInt32(2)) // online
        writer.write(UInt32(1)) // away
        writer.write(UInt32(2)) // stats records
        for _ in 0..<2 {
            writer.write(UInt32(100))
            writer.write(UInt32(5))
            writer.write(UInt32(0))
            writer.write(UInt32(10))
            writer.write(UInt32(2))
        }
        writer.write(UInt32(2)) // slots
        writer.write(UInt32(0))
        writer.write(UInt32(0))
        writer.write(UInt32(2)) // countries
        writer.write(string: "US")
        writer.write(string: "DE")

        guard case .joinedRoom(let name, let users)
            = try ServerMessage.decode(code: 14, payload: writer.data) else {
            return XCTFail("expected joinedRoom")
        }
        XCTAssertEqual(name, "Music")
        XCTAssertEqual(users, [ChatRoomUser(username: "me", status: .online),
                               ChatRoomUser(username: "bob", status: .away)])
    }

    func testJoinRoomAcceptsOldServerUserListOnly() throws {
        var writer = ByteWriter()
        writer.write(string: "Music")
        writer.write(UInt32(1))
        writer.write(string: "bob")

        guard case .joinedRoom(let name, let users)
            = try ServerMessage.decode(code: 14, payload: writer.data) else {
            return XCTFail("expected joinedRoom")
        }
        XCTAssertEqual(name, "Music")
        XCTAssertEqual(users, [ChatRoomUser(username: "bob", status: .online)])
    }

    func testChatMessageDecodes() throws {
        var writer = ByteWriter()
        writer.write(string: "Music")
        writer.write(string: "bob")
        writer.write(string: "hello")

        guard case .chatMessage(let room, let username, let text)
            = try ServerMessage.decode(code: 13, payload: writer.data) else {
            return XCTFail("expected chatMessage")
        }
        XCTAssertEqual(room, "Music")
        XCTAssertEqual(username, "bob")
        XCTAssertEqual(text, "hello")
    }

    func testUserJoinedAndLeftDecode() throws {
        var joined = ByteWriter()
        joined.write(string: "Music")
        joined.write(string: "bob")
        joined.write(UInt32(1)) // away

        guard case .userJoined(let joinedRoom, let user)
            = try ServerMessage.decode(code: 16, payload: joined.data) else {
            return XCTFail("expected userJoined")
        }
        XCTAssertEqual(joinedRoom, "Music")
        XCTAssertEqual(user, ChatRoomUser(username: "bob", status: .away))

        var left = ByteWriter()
        left.write(string: "Music")
        left.write(string: "bob")

        guard case .userLeft(let leftRoom, let username)
            = try ServerMessage.decode(code: 17, payload: left.data) else {
            return XCTFail("expected userLeft")
        }
        XCTAssertEqual(leftRoom, "Music")
        XCTAssertEqual(username, "bob")
    }

    func testLeaveRoomDecodes() throws {
        var writer = ByteWriter()
        writer.write(string: "Music")

        guard case .leftRoom(let room) = try ServerMessage.decode(code: 15, payload: writer.data) else {
            return XCTFail("expected leftRoom")
        }
        XCTAssertEqual(room, "Music")
    }

    func testCannotCreateRoomDecodes() throws {
        var writer = ByteWriter()
        writer.write(string: "Secret")

        guard case .cantCreateRoom(let room)
            = try ServerMessage.decode(code: 1003, payload: writer.data) else {
            return XCTFail("expected cantCreateRoom")
        }
        XCTAssertEqual(room, "Secret")
    }

    func testServerNoticeDecodes() throws {
        var writer = ByteWriter()
        writer.write(UInt32(42))
        writer.write(UInt32(1_700_000_000))
        writer.write(string: "server")
        writer.write(string: "Room name empty")
        writer.write(true)

        guard case .privateMessage(let id, let username, let text, let isNew)
            = try ServerMessage.decode(code: 22, payload: writer.data) else {
            return XCTFail("expected privateMessage")
        }
        XCTAssertEqual(id, 42)
        XCTAssertEqual(username, "server")
        XCTAssertEqual(text, "Room name empty")
        XCTAssertTrue(isNew)
    }

    func testPrivateMessageWithoutIsNewDefaultsToNew() throws {
        var writer = ByteWriter()
        writer.write(UInt32(7))
        writer.write(UInt32(1_700_000_000))
        writer.write(string: "bob")
        writer.write(string: "hi")

        guard case .privateMessage(_, _, _, let isNew)
            = try ServerMessage.decode(code: 22, payload: writer.data) else {
            return XCTFail("expected privateMessage")
        }
        XCTAssertTrue(isNew)
    }

    // MARK: Validation

    func testRoomNameNormalization() {
        XCTAssertEqual(ChatRules.normalizedRoomName("  Music  "), "Music")
        XCTAssertEqual(ChatRules.normalizedRoomName("My   Room"), "My Room")
        XCTAssertEqual(ChatRules.normalizedRoomName("A"), "A")
        XCTAssertNil(ChatRules.normalizedRoomName(""))
        XCTAssertNil(ChatRules.normalizedRoomName("   "))
        XCTAssertNil(ChatRules.normalizedRoomName(String(repeating: "a", count: 25)))
        XCTAssertNil(ChatRules.normalizedRoomName("bad\nroom"))
        XCTAssertNil(ChatRules.normalizedRoomName("naïve"))
    }

    func testMessageNormalization() {
        XCTAssertEqual(ChatRules.normalizedMessage("  hello  "), "hello")
        XCTAssertEqual(ChatRules.normalizedMessage("one\ntwo"), "one two")
        XCTAssertNil(ChatRules.normalizedMessage("   "))
        XCTAssertNil(ChatRules.normalizedMessage(String(repeating: "a", count: 2_049)))
    }
}
