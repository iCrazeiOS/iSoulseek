import Combine
import XCTest
@testable import iSoulseek

/// Drives the chat room protocol through a real `SoulseekClient` and the in-process mock server.
final class ChatIntegrationTests: XCTestCase {

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

    func testRoomListIsRequestedAndPublishedAfterLogin() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        assertEventually("the client never requested the room list") {
            env.server.roomListRequests > 0
        }
        assertEventually("the room list was not published") {
            Set(env.client.chatRoomList.value.map(\.name)) == ["Music", "Chat"]
        }
    }

    func testJoinSendAndLeave() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        var messages: [ChatMessage] = []
        let cancellable = env.client.chatEvents.sink { event in
            if case .message(let message) = event { messages.append(message) }
        }
        defer { cancellable.cancel() }

        env.client.joinRoom("Music")
        assertEventually("JoinRoom did not reach the server") {
            env.server.joinRooms.contains { $0.room == "Music" }
        }
        assertEventually("the room was not joined") {
            env.client.joinedRooms.value.contains("Music")
        }
        assertEventually("the join response's users were not stored") {
            env.client.users(inRoom: "Music").count == 2
        }

        env.client.sendChatMessage("hello", to: "Music")
        assertEventually("SayChatroom did not reach the server") {
            env.server.says.contains { $0.room == "Music" && $0.message == "hello" }
        }
        assertEventually("the echoed message was not published") {
            messages.contains { $0.room == "Music" && $0.text == "hello" && $0.username == "testsoulseeker" }
        }

        env.client.leaveRoom("Music")
        assertEventually("LeaveRoom did not reach the server") {
            env.server.leaveRooms.contains("Music")
        }
        assertEventually("the room stayed joined") {
            !env.client.joinedRooms.value.contains("Music")
        }
    }

    func testJoiningTheSameRoomTwiceDoesNotSendASecondJoin() {
        XCTAssertTrue(env.connectAndWaitForLogin())
        env.client.joinRoom("Music")
        assertEventually { env.client.joinedRooms.value.contains("Music") }

        env.client.joinRoom("Music")
        // The second call republishes the cached users instead of waiting for a response the
        // server would never send.
        assertEventually { env.client.users(inRoom: "Music").count == 2 }
        XCTAssertEqual(env.server.joinRooms.filter { $0.room == "Music" }.count, 1)
    }

    func testServerNoticeIsPublishedAndAcknowledged() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        var errors: [String] = []
        let cancellable = env.client.chatEvents.sink { event in
            if case .error(let text) = event { errors.append(text) }
        }
        defer { cancellable.cancel() }

        env.server.sendServerNotice("Room name empty")

        assertEventually("the server notice was not published") {
            errors.contains("Room name empty")
        }
        assertEventually("the server notice was not acknowledged") {
            env.server.acks.contains(1)
        }
    }
}
