import Combine
import XCTest
@testable import iSoulseek

/// Integration tests that drive a real `SoulseekClient` against the in-process mock server/peer.
final class ConnectionIntegrationTests: XCTestCase {

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

    // MARK: Login / presence

    func testLoginHandshakeAndPresence() {
        XCTAssertTrue(env.connectAndWaitForLogin(), "client did not log in")
        XCTAssertEqual(env.client.stateChanges.value, .loggedIn(username: env.username))

        // Credentials reach the server exactly as configured.
        let login = env.server.logins.first
        XCTAssertEqual(login?.username, env.username)
        XCTAssertEqual(login?.password, env.password)
        XCTAssertEqual(login?.major, 177)
        XCTAssertEqual(login?.minor, 1)

        // The listener binds an ephemeral port and the client advertises it.
        assertEventually("client never advertised a listening port") {
            env.server.setWaitPorts.contains { $0 > 0 }
        }
        let listeningPort = env.client.listeningPort.value
        XCTAssertGreaterThan(listeningPort, 0)
        XCTAssertEqual(env.server.clientListeningPort, listeningPort)

        assertEventually("HaveNoParent(true) was not sent") { env.server.haveNoParent.contains(true) }
        assertEventually("SetStatus(online) was not sent") { env.server.setStatus.contains(2) }
        XCTAssertEqual(env.server.watchedUsers.map { $0.lowercased() }, [env.username.lowercased()])
        assertEventually("SharedFoldersFiles was not sent") { !env.server.sharedFoldersFiles.isEmpty }
        assertEventually("CheckPrivileges was not sent") { env.server.checkPrivilegesCount >= 1 }
    }

    /// The client must surface the server's rejection reason and keep it as the final state.
    func testLoginRejection() {
        env.server.loginOutcome = .reject(reason: "INVALIDPASS", detail: "")

        let states = Locked<[ConnectionState]>([])
        let cancellable = env.client.stateChanges.sink { state in
            states.mutate { $0.append(state) }
        }
        defer { cancellable.cancel() }

        env.client.connect()

        assertEventually("no failed state was ever published") {
            states.value.contains { if case .failed = $0 { return true } else { return false } }
        }
        let reasons = states.value.compactMap { state -> String? in
            if case .failed(let reason) = state { return reason } else { return nil }
        }
        XCTAssertTrue(reasons.contains { $0.contains("Incorrect username or password") },
                      "failure reasons seen: \(reasons)")
        _ = waitUntil(0.5) { false }
        if case .failed = env.client.stateChanges.value {} else {
            XCTFail("final state was \(env.client.stateChanges.value), expected .failed")
        }
    }

    /// The server ignores any session that sends something other than Login first, so the client
    /// must not announce shares or ports before it is authenticated.
    func testLoginIsTheFirstMessageSent() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        let order = env.server.codeOrder
        guard let loginIndex = order.firstIndex(of: 1) else {
            return XCTFail("the client never sent Login, order: \(order)")
        }
        XCTAssertEqual(order[..<loginIndex], [],
                       "messages sent before Login: \(Array(order[..<loginIndex]))")
    }

    // MARK: Search

    func testSearchDeliversResults() {
        env.peer.searchFiles = [
            ShareFile(name: "Music\\song.mp3", size: 0x1234, fileExtension: "mp3",
                      attributes: [SearchAttribute.bitrate.rawValue: 320])
        ]
        env.peer.searchAverageSpeed = 4242
        env.peer.searchSlotFree = true
        XCTAssertTrue(env.connectAndWaitForLogin())

        var results: [SearchResult] = []
        let cancellable = env.client.searchResults.sink { results.append($0) }
        defer { cancellable.cancel() }

        guard let token = env.client.search("query music") else {
            return XCTFail("search returned no token")
        }
        assertEventually("FileSearch did not reach the server") {
            env.server.searches.contains { $0.token == token }
        }
        XCTAssertEqual(env.server.searches.last?.query, "query music")

        assertEventually("no result was published") { !results.isEmpty }
        guard let result = results.first else { return }
        XCTAssertEqual(result.token, token)
        XCTAssertEqual(result.username, "MockPeer")
        XCTAssertEqual(result.file.name, "Music\\song.mp3")
        XCTAssertEqual(result.file.size, 0x1234)
        XCTAssertEqual(result.file.bitrate, 320)
        XCTAssertTrue(result.isSlotFree)
        XCTAssertEqual(result.averageSpeed, 4242)
    }

    func testSearchResultForUnknownTokenIsIgnored() {
        env.peer.searchFiles = [ShareFile(name: "should-not-arrive.mp3", size: 1)]
        env.peer.searchTokenOverride = 0x7FFF_FFFF
        XCTAssertTrue(env.connectAndWaitForLogin())

        var results: [SearchResult] = []
        let cancellable = env.client.searchResults.sink { results.append($0) }
        defer { cancellable.cancel() }

        guard let token = env.client.search("ignored") else { return XCTFail("no token") }
        assertEventually("search did not reach the server") {
            env.server.searches.contains { $0.token == token }
        }
        assertEventually("mock never sent its mismatched response") {
            env.peer.searchTokens.contains(0x7FFF_FFFF)
        }

        // Let the (rejected) response be processed, then confirm nothing was delivered.
        _ = waitUntil(0.5) { false }
        XCTAssertTrue(results.isEmpty, "a result for an unknown token was published: \(results)")
    }

    // MARK: Inbound peer handling

    /// A peer that dials the client must be read and answered.
    func testInboundPeerConnectionIsServiced() {
        XCTAssertTrue(env.connectAndWaitForLogin())

        env.peer.requestUserInfo()
        assertEventually("the client never answered an inbound UserInfoRequest", timeout: 3) {
            env.peer.userInfoResponseCount > 0
        }
    }

    // MARK: Browse

    func testBrowseReturnsTree() {
        env.peer.shareFolders = [
            ShareFolder(path: "Music", files: [
                ShareFile(name: "Music\\a.mp3", size: 10, fileExtension: "mp3")
            ]),
            ShareFolder(path: "Music\\Album", files: [
                ShareFile(name: "Music\\Album\\b.flac", size: 20, fileExtension: "flac")
            ])
        ]
        XCTAssertTrue(env.connectAndWaitForLogin())

        var outcome: Result<[ShareFolder], Error>?

        env.client.browse(username: "MockPeer") { outcome = $0 }

        assertEventually("browse did not complete", timeout: 3) { outcome != nil }
        guard case .success(let folders)? = outcome else {
            return XCTFail("browse failed: \(String(describing: outcome))")
        }
        XCTAssertEqual(folders.count, 2)
        XCTAssertTrue(folders.contains { $0.path == "Music" && $0.files.first?.size == 10 })
        XCTAssertTrue(folders.contains { $0.path == "Music\\Album" && $0.files.first?.size == 20 })
    }
}
