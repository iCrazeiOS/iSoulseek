import Combine
import XCTest
@testable import iSoulseek

/// Opt-in smoke test against the real network. Skipped unless `SOULSEEK_LIVE=1` and credentials are
/// present, so it never runs in CI and never needs internet access by default.
final class LiveNetworkTests: XCTestCase {

    func testLiveLoginAndSearch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULSEEK_LIVE"] == "1",
                          "Set SOULSEEK_LIVE=1 to run the live smoke test")

        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["SOULSEEK_LIVE_USER"], !username.isEmpty,
              let password = environment["SOULSEEK_LIVE_PASS"], !password.isEmpty else {
            throw XCTSkip("SOULSEEK_LIVE_USER and SOULSEEK_LIVE_PASS must both be set")
        }

        let suiteName = "iSoulseekLiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let documents = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iSoulseekLiveTests-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(defaults: defaults,
                                 keychainService: "com.icraze.livetests.\(UUID().uuidString)",
                                 documentsDirectory: documents)
        store.username = username
        store.password = password
        store.serverHost = "server.slsknet.org"
        store.serverPort = 2242
        store.preferredListeningPort = 0
        store.status = .online

        let client = SoulseekClient(store: store)
        defer {
            client.disconnect()
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: documents)
        }

        client.connect()
        XCTAssertTrue(waitUntil(30) { client.stateChanges.value.isLoggedIn },
                      "did not log in to the real server")

        var resultCount = 0
        let cancellable = client.searchResults.sink { _ in resultCount += 1 }
        defer { cancellable.cancel() }

        guard let token = client.search("mp3") else {
            return XCTFail("search returned no token")
        }
        XCTAssertNotNil(token)
        XCTAssertTrue(waitUntil(60) { resultCount > 0 },
                      "no search results arrived within 60 seconds")
        client.disconnect()
    }
}
