import Foundation

/// A top-level place the app can open to. Used for the startup tab saved in Settings and for the
/// Home Screen quick actions, so both routes agree on where "Search" and "Downloads" point.
///
/// `downloads` is the Transfers tab showing the files already on disk, not the queue of active
/// transfers.
enum AppTab: Int, CaseIterable {
    case search
    case downloads

    var displayName: String {
        switch self {
        case .search: return "Search"
        case .downloads: return "Downloads"
        }
    }

    /// Matches the `UIApplicationShortcutItemType` values declared under `UIApplicationShortcutItems`
    /// in Info.plist. Those strings are static, so they cannot be composed from the bundle identifier.
    var shortcutType: String {
        switch self {
        case .search: return "com.icraze.iSoulseek.search"
        case .downloads: return "com.icraze.iSoulseek.downloads"
        }
    }

    init?(shortcutType: String) {
        guard let tab = AppTab.allCases.first(where: { $0.shortcutType == shortcutType }) else {
            return nil
        }
        self = tab
    }
}
