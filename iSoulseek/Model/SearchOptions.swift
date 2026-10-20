import Foundation

/// Client-side filters for search results.
///
/// The Soulseek search request carries only a query, so every extra condition is applied to
/// responses as they arrive. Keeping the filters separate from the query means they can be
/// changed without searching again.
struct SearchOptions: Equatable, Codable {

    /// Lowercase extensions without a leading dot. Empty means every type is allowed.
    var fileTypes: [String] = []

    /// Words that must not occur in a result's path. Empty means no exclusions.
    var excludedWords: [String] = []

    /// Inclusive size limits in decimal megabytes.
    var minimumSizeMB: Int?
    var maximumSizeMB: Int?

    /// Inclusive bitrate floor in kbit/s. Results without a bitrate are hidden.
    var minimumBitrate: UInt32?

    /// Shows only lossless files. The bitrate floor is not applied while this is set; the UI
    /// keeps the two controls mutually exclusive.
    var requiresLossless = false

    /// Hides results from users whose upload queue is full.
    var requiresFreeSlot = false

    static let bitrateChoices: [UInt32] = [128, 192, 256, 320]
    static let maximumSizeMB = 1_000_000

    var isActive: Bool {
        !fileTypes.isEmpty || !excludedWords.isEmpty || minimumSizeMB != nil
            || maximumSizeMB != nil || minimumBitrate != nil || requiresLossless || requiresFreeSlot
    }

    /// A short description for Settings, e.g. `flac, mp3 · ≥ 192 kbps`.
    var summary: String {
        guard isActive else { return "Off" }
        var parts: [String] = []
        if !fileTypes.isEmpty { parts.append(fileTypes.joined(separator: ", ")) }
        if requiresLossless {
            parts.append("lossless")
        } else if let minimumBitrate {
            parts.append("≥ \(minimumBitrate) kbps")
        }
        if let minimumSizeMB { parts.append("≥ \(minimumSizeMB) MB") }
        if let maximumSizeMB { parts.append("≤ \(maximumSizeMB) MB") }
        if !excludedWords.isEmpty {
            let noun = excludedWords.count == 1 ? "word" : "words"
            parts.append("excluding \(excludedWords.count) \(noun)")
        }
        if requiresFreeSlot { parts.append("free slots") }
        return parts.joined(separator: " · ")
    }

    func matches(_ result: SearchResult) -> Bool {
        let file = result.file

        if !fileTypes.isEmpty, !fileTypes.contains(file.normalizedExtension) {
            return false
        }

        if !excludedWords.isEmpty {
            let path = file.name.lowercased()
            if excludedWords.contains(where: { path.contains($0.lowercased()) }) { return false }
        }

        if let minimumSizeMB, file.size < Self.byteCount(minimumSizeMB) { return false }
        if let maximumSizeMB, file.size > Self.byteCount(maximumSizeMB) { return false }

        if requiresLossless {
            if !file.isLossless { return false }
        } else if let minimumBitrate, (file.bitrate ?? 0) < minimumBitrate {
            return false
        }

        if requiresFreeSlot, !result.isSlotFree { return false }

        return true
    }

    /// Decimal megabytes, capped so an edited defaults file cannot overflow the conversion.
    private static func byteCount(_ megabytes: Int) -> UInt64 {
        UInt64(min(max(megabytes, 0), maximumSizeMB)) * 1_000_000
    }

    // MARK: Parsing

    /// Splits a user-entered list into lowercase, dot-free words. Commas, semicolons, pipes and
    /// whitespace all act as separators, so `"FLAC, m4a;*.mp3"` becomes `["flac", "m4a", "mp3"]`.
    static func parseWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",;|").union(.whitespacesAndNewlines))
            .map { word in
                var word = word.trimmingCharacters(in: .whitespaces)
                while word.hasPrefix("*") || word.hasPrefix(".") {
                    word.removeFirst()
                }
                return word
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case fileTypes
        case excludedWords
        case minimumSizeMB
        case maximumSizeMB
        case minimumBitrate
        case requiresLossless
        case requiresFreeSlot
    }

    /// Decodes missing keys to their defaults so filters added in a later version do not wipe the
    /// options saved by an older one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileTypes = try container.decodeIfPresent([String].self, forKey: .fileTypes) ?? []
        excludedWords = try container.decodeIfPresent([String].self, forKey: .excludedWords) ?? []
        minimumSizeMB = try container.decodeIfPresent(Int.self, forKey: .minimumSizeMB)
        maximumSizeMB = try container.decodeIfPresent(Int.self, forKey: .maximumSizeMB)
        minimumBitrate = try container.decodeIfPresent(UInt32.self, forKey: .minimumBitrate)
        requiresLossless = try container.decodeIfPresent(Bool.self, forKey: .requiresLossless) ?? false
        requiresFreeSlot = try container.decodeIfPresent(Bool.self, forKey: .requiresFreeSlot) ?? false
    }

    init() {}
}
