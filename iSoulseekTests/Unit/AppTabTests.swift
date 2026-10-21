import XCTest
@testable import iSoulseek

final class AppTabTests: XCTestCase {

    func testStartupTabDefaultsToSearchAndPersists() {
        let suite = "AppTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.startupTab, .search)

        store.startupTab = .downloads
        XCTAssertEqual(defaults.integer(forKey: "startupTab"), AppTab.downloads.rawValue)

        let reloaded = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(reloaded.startupTab, .downloads)
    }

    func testQuickActionTypesMapToTabs() {
        XCTAssertEqual(AppTab(shortcutType: AppTab.search.shortcutType), .search)
        XCTAssertEqual(AppTab(shortcutType: AppTab.downloads.shortcutType), .downloads)
        XCTAssertNil(AppTab(shortcutType: "com.icraze.iSoulseek.unknown"))
    }

    /// The shortcut types live in Info.plist and in `AppTab`; this keeps the two in step.
    func testShortcutTypesAreDeclaredInInfoPlist() throws {
        let items = try XCTUnwrap(
            Bundle(for: SoulseekClient.self).object(forInfoDictionaryKey: "UIApplicationShortcutItems")
                as? [[String: Any]])
        let declared = Set(items.compactMap { $0["UIApplicationShortcutItemType"] as? String })
        XCTAssertEqual(declared, Set(AppTab.allCases.map(\.shortcutType)))
    }
}
