import Foundation

/// Persisted user preferences. The password itself lives in the Keychain.
final class SessionStore {

    private enum Key {
        static let username = "username"
        static let serverHost = "serverHost"
        static let serverPort = "serverPort"
        static let listeningPort = "listeningPort"
        static let status = "status"
    }

    static let defaultServerHost = "server.slsknet.org"
    static let defaultServerPort: UInt16 = 2242
    static let defaultListeningPort: UInt16 = 2234

    private let defaults = UserDefaults.standard

    var username: String {
        get { defaults.string(forKey: Key.username) ?? "" }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    var password: String {
        get { Keychain.password(account: username) ?? "" }
        set { Keychain.setPassword(newValue, account: username) }
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
        get { UserStatus(rawValue: UInt32(defaults.integer(forKey: Key.status))) ?? .online }
        set { defaults.set(Int(newValue.rawValue), forKey: Key.status) }
    }

    var isConfigured: Bool { !username.isEmpty && !password.isEmpty }

    // MARK: Files

    var documentsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    /// Returns a destination inside `root`, or `nil` when the path is unusable.
    static func destination(in root: URL, virtualPath: String) -> URL? {
        let parts = components(from: virtualPath)
        guard !parts.isEmpty else { return nil }

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
