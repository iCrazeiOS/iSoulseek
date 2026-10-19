import XCTest
@testable import Soulseek

/// Wires a real `SoulseekClient` to an in-process mock server and peer, with all persistent state
/// isolated to throwaway locations so tests never touch the app's real defaults, keychain or files.
final class TestEnvironment {

    let username: String
    let password: String
    let store: SessionStore
    let server: MockSoulseekServer
    let peer: MockPeer
    let client: SoulseekClient

    private let defaultsSuiteName: String
    private let keychainService: String

    init(username: String = "testsoulseeker", password: String = "hunter2") {
        self.username = username
        self.password = password
        defaultsSuiteName = "SoulseekTests.\(UUID().uuidString)"
        keychainService = "org.soulseekkit.tests.\(UUID().uuidString)"
        let documents = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SoulseekTests-\(UUID().uuidString)", isDirectory: true)

        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        store = SessionStore(defaults: defaults, keychainService: keychainService,
                             documentsDirectory: documents)

        let server = MockSoulseekServer()
        let peer = MockPeer()
        server.peer = peer
        peer.server = server

        server.start()
        peer.start()
        XCTAssertTrue(waitUntil(5) { server.port != 0 && peer.port != 0 },
                      "mock listeners did not bind")

        self.server = server
        self.peer = peer

        store.username = username
        store.password = password
        store.serverHost = "127.0.0.1"
        store.serverPort = server.port
        store.preferredListeningPort = 0
        store.status = .online

        client = SoulseekClient(store: store)
    }

    var downloadsDirectory: URL { store.downloadsDirectory }
    var shareDirectory: URL { store.shareDirectory }

    @discardableResult
    func connectAndWaitForLogin(timeout: TimeInterval = 5) -> Bool {
        client.connect()
        return waitUntil(timeout) { client.stateChanges.value.isLoggedIn }
    }

    func tearDown() {
        client.disconnect()
        _ = waitUntil(1.0) { client.stateChanges.value == .disconnected }
        server.stop()
        peer.stop()
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        Keychain.deletePassword(account: username, service: keychainService)
        try? FileManager.default.removeItem(at: store.documentsDirectory)
    }
}
