import Foundation

/// A public room from the server's room list.
struct ChatRoom: Hashable, Identifiable {
    var name: String
    var userCount: UInt32
    var isPrivate: Bool = false

    var id: String { name }
}

/// A user currently in a room, as reported by the join response.
struct ChatRoomUser: Hashable {
    var username: String
    var status: UserStatus = .online
}

enum ChatMessageKind: Hashable {
    case normal
    /// A `/me` action, rendered in the third person.
    case action
    /// A notice from the server (username `server`).
    case system
}

struct ChatMessage: Identifiable, Hashable {
    let id: UInt64
    var room: String
    var username: String
    var text: String
    var timestamp: Date
    var kind: ChatMessageKind
}

/// Changes to room membership and incoming messages. Room lists are published separately by
/// `SoulseekClient.chatRoomList`.
enum ChatEvent {
    case joined(room: String, users: [ChatRoomUser])
    case userJoined(room: String, user: ChatRoomUser)
    case userLeft(room: String, username: String)
    case message(ChatMessage)
    case left(room: String)
    case error(String)
}

/// Validation shared by the client and the chat screens.
enum ChatRules {

    static let maximumRoomNameLength = 24
    static let maximumMessageBytes = 2_048

    /// Trims and collapses spaces, then rejects anything the server would refuse. Returns `nil`
    /// when the name cannot be used.
    static func normalizedRoomName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let collapsed = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        guard (1...maximumRoomNameLength).contains(collapsed.count) else { return nil }
        guard collapsed.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F
        }) else { return nil }
        return collapsed
    }

    /// The server drops messages containing newlines, so replace them with spaces. Empty or
    /// oversized messages are rejected.
    static func normalizedMessage(_ raw: String) -> String? {
        let text = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumMessageBytes else { return nil }
        return text
    }
}
