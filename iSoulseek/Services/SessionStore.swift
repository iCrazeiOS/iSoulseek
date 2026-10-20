import Foundation

/// User preferences, persisted in `UserDefaults` apart from this session's temporary search
/// overrides. The password itself lives in the Keychain.
final class SessionStore {

    private enum Key {
        static let username = "username"
        static let serverHost = "serverHost"
        static let serverPort = "serverPort"
        static let listeningPort = "listeningPort"
        static let status = "status"
        static let searchSortOrder = "searchSortOrder"
        static let searchOptions = "searchOptions"
        static let downloadSortOrder = "downloadSortOrder"
        static let downloadLayout = "downloadLayout"
        static let transferTab = "transferTab"
    }

    static let defaultServerHost = "server.slsknet.org"
    static let defaultServerPort: UInt16 = 2242
    static let defaultListeningPort: UInt16 = 2234

    private let defaults: UserDefaults
    private let keychainService: String
    private let documentsOverride: URL?

    /// Filters and sort order in effect for this session. The Search screen edits these only; they
    /// start at the saved defaults and are never written back, so tweaking a search leaves the
    /// defaults set in Settings alone. Cleared when the account signs out.
    private var sessionSearchOptions: SearchOptions?
    private var sessionSearchSortOrder: SearchSortOrder?

    init(defaults: UserDefaults = .standard, keychainService: String = Keychain.defaultService,
         documentsDirectory: URL? = nil) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.documentsOverride = documentsDirectory
    }

    var username: String {
        get { defaults.string(forKey: Key.username) ?? "" }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    var password: String {
        get { Keychain.password(account: username, service: keychainService) ?? "" }
        set { Keychain.setPassword(newValue, account: username, service: keychainService) }
    }

    var serverHost: String {
        get { defaults.string(forKey: Key.serverHost) ?? Self.defaultServerHost }
        set { defaults.set(newValue, forKey: Key.serverHost) }
    }

    var serverPort: UInt16 {
        get { UInt16(clamping: defaults.object(forKey: Key.serverPort) as? Int ?? Int(Self.defaultServerPort)) }
        set { defaults.set(Int(newValue), forKey: Key.serverPort) }
    }

    var preferredListeningPort: UInt16 {
        get { UInt16(clamping: defaults.object(forKey: Key.listeningPort) as? Int ?? Int(Self.defaultListeningPort)) }
        set { defaults.set(Int(newValue), forKey: Key.listeningPort) }
    }

    var status: UserStatus {
        get {
            let stored = UserStatus(rawValue: UInt32(defaults.integer(forKey: Key.status)))
            return stored == .away ? .away : .online
        }
        set { defaults.set(Int(newValue.rawValue), forKey: Key.status) }
    }

    /// Sort order for this session. Changing it from the Search screen does not save a default.
    var searchSortOrder: SearchSortOrder {
        get { sessionSearchSortOrder ?? defaultSearchSortOrder }
        set { sessionSearchSortOrder = newValue }
    }

    /// The saved sort order edited from Settings.
    private(set) var defaultSearchSortOrder: SearchSortOrder {
        get {
            SearchSortOrder(rawValue: defaults.integer(forKey: Key.searchSortOrder)) ?? .arrival
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.searchSortOrder)
        }
    }

    /// Filters for this session. Changing them from the Search screen does not save a default.
    var searchOptions: SearchOptions {
        get { sessionSearchOptions ?? defaultSearchOptions }
        set { sessionSearchOptions = newValue }
    }

    /// The saved filters edited from Settings.
    private(set) var defaultSearchOptions: SearchOptions {
        get {
            guard let data = defaults.data(forKey: Key.searchOptions),
                  let options = try? JSONDecoder().decode(SearchOptions.self, from: data) else {
                return SearchOptions()
            }
            return options
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.searchOptions)
        }
    }

    /// Saves new defaults and applies them right away, replacing any temporary changes.
    func setDefaultSearchSortOrder(_ order: SearchSortOrder) {
        defaultSearchSortOrder = order
        sessionSearchSortOrder = order
    }

    /// Saves new defaults and applies them right away, replacing any temporary changes.
    func setDefaultSearchOptions(_ options: SearchOptions) {
        defaultSearchOptions = options
        sessionSearchOptions = options
    }

    /// Drops temporary search changes so the saved defaults apply again.
    func clearSearchOverrides() {
        sessionSearchOptions = nil
        sessionSearchSortOrder = nil
    }

    var downloadSortOrder: DownloadSortOrder {
        get {
            guard defaults.object(forKey: Key.downloadSortOrder) != nil else { return .newest }
            return DownloadSortOrder(rawValue: defaults.integer(forKey: Key.downloadSortOrder)) ?? .newest
        }
        set { defaults.set(newValue.rawValue, forKey: Key.downloadSortOrder) }
    }

    var downloadLayout: DownloadLayout {
        get { DownloadLayout(rawValue: defaults.integer(forKey: Key.downloadLayout)) ?? .list }
        set { defaults.set(newValue.rawValue, forKey: Key.downloadLayout) }
    }

    var transferTab: TransferTab {
        get { TransferTab(rawValue: defaults.integer(forKey: Key.transferTab)) ?? .downloading }
        set { defaults.set(newValue.rawValue, forKey: Key.transferTab) }
    }

    var isConfigured: Bool { !username.isEmpty && !password.isEmpty }

    // MARK: Files

    var documentsDirectory: URL {
        let url = documentsOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ensureDirectory(url)
        return url
    }

    var downloadsDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    var shareDirectory: URL {
        let url = documentsDirectory.appendingPathComponent("Shared", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    private func ensureDirectory(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
}

/// Turns remote-supplied paths into safe locations inside the downloads directory.
enum PathSanitizer {

    static let maximumComponents = 16
    static let maximumComponentLength = 128

    /// Splits a virtual path, discarding anything that could escape the destination directory.
    static func components(from virtualPath: String) -> [String] {
        let unified = virtualPath.replacingOccurrences(of: "\\", with: "/")
        var result: [String] = []

        for raw in unified.split(separator: "/") {
            if raw == "." || raw == ".." { continue }
            let cleaned = raw.unicodeScalars.filter { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F && scalar != ":" && scalar != "/"
                    && scalar != "\\" && scalar != "\u{0}"
            }
            var name = String(String.UnicodeScalarView(cleaned))
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !name.isEmpty else { continue }
            if name.count > maximumComponentLength {
                name = String(name.prefix(maximumComponentLength))
            }
            result.append(name)
        }

        if result.count > maximumComponents {
            result = Array(result.suffix(maximumComponents))
        }
        return result
    }

    /// Returns where a download from `virtualPath` belongs, or `nil` when the path is unusable.
    ///
    /// Only the uploader and the album directory — the virtual path's final folder — are kept, so
    /// the remote hierarchy is never recreated: `Music\Artist\Album\song.flac` becomes
    /// `<root>/artist/Album/song.flac`. Files without a directory sit straight in the uploader's
    /// folder. This is also the entire path metadata the app stores.
    static func downloadDestination(in root: URL, username: String, virtualPath: String) -> URL? {
        let path = components(from: virtualPath)
        guard let uploader = components(from: username).first, path.last != nil else { return nil }

        let parts = [uploader] + path.suffix(2)
        var url = root
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(part, isDirectory: index < parts.count - 1)
        }
        let standardized = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard standardized.path.hasPrefix(rootPath + "/") else { return nil }
        return standardized
    }
}
