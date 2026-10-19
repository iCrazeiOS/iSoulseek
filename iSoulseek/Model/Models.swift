import Foundation

/// A single file as it appears in a share listing or a search response.
struct ShareFile: Hashable {
    var name: String
    var size: UInt64
    var fileExtension: String
    var attributes: [UInt32: UInt32]

    init(name: String, size: UInt64, fileExtension: String = "", attributes: [UInt32: UInt32] = [:]) {
        self.name = name
        self.size = size
        self.fileExtension = fileExtension
        self.attributes = attributes
    }

    /// Bitrate in kbit/s, when the peer supplied it.
    var bitrate: UInt32? { attributes[SearchAttribute.bitrate.rawValue] }

    /// Length in seconds, when the peer supplied it.
    var duration: UInt32? { attributes[SearchAttribute.duration.rawValue] }
}

/// A directory of a user's share.
struct ShareFolder: Hashable {
    var path: String
    var files: [ShareFile]

    init(path: String, files: [ShareFile]) {
        self.path = path
        self.files = files
    }

    /// Splits a virtual path (`Music\Album`) into its components.
    static func components(of path: String) -> [String] {
        path.split(separator: "\\").map(String.init).filter { !$0.isEmpty }
    }
}

/// One result returned by a peer for a search we issued.
struct SearchResult: Hashable {
    var username: String
    var token: UInt32
    var file: ShareFile
    var isSlotFree: Bool
    var averageSpeed: UInt32
    var queueLength: UInt32

    /// Full virtual path, using `\` as the separator.
    var fullPath: String { file.name }

    /// The folder containing the file, using `\` as the separator.
    var folderPath: String {
        ShareFolder.components(of: fullPath).dropLast().joined(separator: "\\")
    }
}

/// Ordering applied to the results in a search.
enum SearchSortOrder: Int, CaseIterable {
    case arrival
    case largest
    case smallest
    case bitrate
    case duration

    var displayName: String {
        switch self {
        case .arrival: return "Default"
        case .largest: return "Largest first"
        case .smallest: return "Smallest first"
        case .bitrate: return "Highest bitrate"
        case .duration: return "Longest"
        }
    }

    /// Strict ordering between two results; returns false both ways when they are equal.
    func isOrderedBefore(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        switch self {
        case .arrival: return false
        case .largest: return lhs.file.size > rhs.file.size
        case .smallest: return lhs.file.size < rhs.file.size
        case .bitrate: return (lhs.file.bitrate ?? 0) > (rhs.file.bitrate ?? 0)
        case .duration: return (lhs.file.duration ?? 0) > (rhs.file.duration ?? 0)
        }
    }
}

/// What we know about another user.
struct UserStatusInfo: Hashable {
    var username: String
    var status: UserStatus
    var isPrivileged: Bool
}

enum UserStatus: UInt32 {
    case offline = 0
    case away = 1
    case online = 2

    var displayName: String {
        switch self {
        case .offline: return "Offline"
        case .away: return "Away"
        case .online: return "Online"
        }
    }
}

/// A user's public profile, fetched over a peer connection.
struct UserInfo: Hashable {
    var description: String
    var hasPicture: Bool
    var picture: Data?
    var totalUploads: UInt32
    var queueSize: UInt32
    var slotsFree: Bool
}

/// Connection lifecycle as seen by the UI.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connectingToServer
    case loggedIn(username: String)
    /// The saved credentials cannot be used, so the login form is required. Temporary
    /// connection problems are reported as `.disconnected` instead.
    case failed(String)

    var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connectingToServer: return "Signing in…"
        case .loggedIn(let username): return "Connected as \(username)"
        case .failed(let reason): return "Disconnected: \(reason)"
        }
    }
}

enum SearchAttribute: UInt32 {
    case bitrate = 0
    case duration = 1
    case vbr = 2
    case encoder = 3
    case sampleRate = 4
    case bitDepth = 5
}

enum ShareSearch: Equatable {
    /// All words must appear somewhere in the file path (case-insensitive), in any order.
    static func matches(query: String, path: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return false }
        let haystack = path.lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: count))
    }

    static func duration(_ seconds: UInt32) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    static func speed(_ bytesPerSecond: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytesPerSecond)) + "/s"
    }
}
