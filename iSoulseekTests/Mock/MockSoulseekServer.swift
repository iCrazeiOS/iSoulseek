import CryptoKit
import Foundation
import Network
@testable import iSoulseek

/// An in-process Soulseek server speaking the real wire format to a real `SoulseekClient`.
final class MockSoulseekServer {

    enum LoginOutcome {
        case success(greeting: String, ownIP: String, isSupporter: Bool)
        case reject(reason: String, detail: String)
    }

    let queue = DispatchQueue(label: "mock.soulseek.server")
    var loginOutcome: LoginOutcome = .success(greeting: "Welcome to Soulseek!",
                                              ownIP: "127.0.0.1", isSupporter: false)
    weak var peer: MockPeer?

    private var listener: NWListener?
    private var _port: UInt16 = 0
    var port: UInt16 { queue.sync { _port } }

    private var channels: [MockChannel] = []

    // Records, mutated only on `queue`.
    private var recordedSetWaitPorts: [UInt16] = []
    private var recordedHaveNoParent: [Bool] = []
    private var recordedSetStatus: [UInt32] = []
    private var recordedWatchUser: [String] = []
    private var recordedSharedFoldersFiles: [(directories: UInt32, files: UInt32)] = []
    private var recordedSearches: [(token: UInt32, query: String)] = []
    private var recordedUploadSpeeds: [UInt32] = []
    private var recordedGetPeerAddress: [String] = []
    private var recordedConnectToPeer: [(token: UInt32, username: String, type: String)] = []
    private var recordedPingCount = 0
    private var recordedCheckPrivilegesCount = 0
    private var recordedLogins: [(username: String, password: String, major: UInt32, minor: UInt32)] = []
    private var recordedCodeOrder: [UInt32] = []
    private var recordedRoomListRequests = 0
    private var recordedJoinRooms: [(room: String, type: UInt32)] = []
    private var recordedSays: [(room: String, message: String)] = []
    private var recordedLeaveRooms: [String] = []
    private var recordedAcks: [UInt32] = []

    /// When set, the server reports this port for every user, so tests can break the direct route.
    var peerPortOverride: UInt16?
    /// Users the server reports as offline (no address), like a real `GetPeerAddress` failure.
    var offlinePeers: Set<String> = []

    // MARK: Lifecycle

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try? NWListener(using: parameters)
        self.listener = listener
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self._port = self.listener?.port?.rawValue ?? 0
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for channel in channels { channel.cancel() }
        channels.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let channel = MockChannel(connection: connection, mode: .server, label: "client", queue: queue)
        channels.append(channel)
        channel.onMessage = { [weak self, weak channel] code, payload in
            guard let self, let channel else { return }
            self.handle(code: code, payload: payload, channel: channel)
        }
        channel.onClosed = { [weak self, weak channel] _ in
            guard let self, let channel else { return }
            self.channels.removeAll { $0 === channel }
        }
        channel.start()
    }

    // MARK: Snapshot accessors (safe to read from the test thread)

    var setWaitPorts: [UInt16] { queue.sync { recordedSetWaitPorts } }
    var haveNoParent: [Bool] { queue.sync { recordedHaveNoParent } }
    var setStatus: [UInt32] { queue.sync { recordedSetStatus } }
    var watchedUsers: [String] { queue.sync { recordedWatchUser } }
    var sharedFoldersFiles: [(directories: UInt32, files: UInt32)] { queue.sync { recordedSharedFoldersFiles } }
    var searches: [(token: UInt32, query: String)] { queue.sync { recordedSearches } }
    var uploadSpeeds: [UInt32] { queue.sync { recordedUploadSpeeds } }
    var peerAddressRequests: [String] { queue.sync { recordedGetPeerAddress } }
    var connectToPeerRequests: [(token: UInt32, username: String, type: String)] { queue.sync { recordedConnectToPeer } }
    var pingCount: Int { queue.sync { recordedPingCount } }
    var checkPrivilegesCount: Int { queue.sync { recordedCheckPrivilegesCount } }
    var logins: [(username: String, password: String, major: UInt32, minor: UInt32)] { queue.sync { recordedLogins } }
    /// Every message code the client sent, in order.
    var codeOrder: [UInt32] { queue.sync { recordedCodeOrder } }
    var roomListRequests: Int { queue.sync { recordedRoomListRequests } }
    var joinRooms: [(room: String, type: UInt32)] { queue.sync { recordedJoinRooms } }
    var says: [(room: String, message: String)] { queue.sync { recordedSays } }
    var leaveRooms: [String] { queue.sync { recordedLeaveRooms } }
    var acks: [UInt32] { queue.sync { recordedAcks } }

    /// The most recent non-zero port the client asked to be reached on.
    var clientListeningPort: UInt16 {
        queue.sync { recordedSetWaitPorts.last(where: { $0 > 0 }) ?? 0 }
    }

    // MARK: Message handling

    private func handle(code: UInt32, payload: Data, channel: MockChannel) {
        recordedCodeOrder.append(code)
        var reader = MockReader(payload)
        switch code {
        case 1: // Login
            let username = (try? reader.string()) ?? ""
            let password = (try? reader.string()) ?? ""
            let major = (try? reader.u32()) ?? 0
            _ = try? reader.string() // md5 hex
            let minor = (try? reader.u32()) ?? 0
            recordedLogins.append((username, password, major, minor))
            replyToLogin(password: password, channel: channel)

        case 2: // SetWaitPort
            if let value = try? reader.u32() {
                let port = UInt16(truncatingIfNeeded: value)
                recordedSetWaitPorts.append(port)
                if port > 0 { peer?.clientPortHint = port }
            }

        case 71: // HaveNoParent
            if let value = try? reader.bool() { recordedHaveNoParent.append(value) }

        case 28: // SetStatus
            if let value = try? reader.u32() { recordedSetStatus.append(value) }

        case 5: // WatchUser
            if let value = try? reader.string() { recordedWatchUser.append(value) }

        case 35: // SharedFoldersFiles
            if let directories = try? reader.u32(), let files = try? reader.u32() {
                recordedSharedFoldersFiles.append((directories, files))
            }

        case 32: // ServerPing
            recordedPingCount += 1

        case 92: // CheckPrivileges
            recordedCheckPrivilegesCount += 1
            var writer = MockWriter()
            writer.u32(0)
            channel.send(code: 92, payload: writer.data)

        case 3: // GetPeerAddress
            let user = (try? reader.string()) ?? ""
            recordedGetPeerAddress.append(user)
            replyWithPeerAddress(for: user, channel: channel)

        case 26: // FileSearch
            if let token = try? reader.u32(), let query = try? reader.string() {
                recordedSearches.append((token, query))
                peer?.sendSearchResponse(token: token)
            }

        case 18: // ConnectToPeer
            if let token = try? reader.u32(),
               let user = try? reader.string(),
               let type = try? reader.string() {
                recordedConnectToPeer.append((token, user, type))
                if type == "F" {
                    peer?.dialFilePierce(token: token)
                } else {
                    peer?.dialPierce(token: token)
                }
            }

        case 64: // RoomList
            recordedRoomListRequests += 1
            replyWithRoomList(channel: channel)

        case 14: // JoinRoom
            let room = (try? reader.string()) ?? ""
            let type = (try? reader.u32()) ?? 0
            recordedJoinRooms.append((room, type))
            replyToJoinRoom(room: room, channel: channel)

        case 13: // SayChatroom
            let room = (try? reader.string()) ?? ""
            let message = (try? reader.string()) ?? ""
            recordedSays.append((room, message))
            var writer = MockWriter()
            writer.string(room)
            writer.string("testsoulseeker")
            writer.string(message)
            channel.send(code: 13, payload: writer.data)

        case 15: // LeaveRoom
            let room = (try? reader.string()) ?? ""
            recordedLeaveRooms.append(room)
            var writer = MockWriter()
            writer.string(room)
            channel.send(code: 15, payload: writer.data)

        case 23: // MessageAcked
            if let id = try? reader.u32() { recordedAcks.append(id) }

        case 121: // SendUploadSpeed
            if let value = try? reader.u32() { recordedUploadSpeeds.append(value) }

        default:
            break
        }
    }

    private func replyWithRoomList(channel: MockChannel) {
        var writer = MockWriter()
        writer.u32(2)
        writer.string("Music")
        writer.string("Chat")
        writer.u32(2)
        writer.u32(12)
        writer.u32(3)
        channel.send(code: 64, payload: writer.data)
    }

    private func replyToJoinRoom(room: String, channel: MockChannel) {
        let names = ["testsoulseeker", "bob"]
        var writer = MockWriter()
        writer.string(room)
        writer.u32(UInt32(names.count))
        for name in names { writer.string(name) }

        writer.u32(UInt32(names.count))
        writer.u32(2) // online
        writer.u32(2) // online

        writer.u32(UInt32(names.count))
        for _ in names {
            writer.u32(100) // average speed
            writer.u32(0)   // uploads
            writer.u32(0)   // unknown
            writer.u32(10)  // files
            writer.u32(2)   // directories
        }

        writer.u32(UInt32(names.count))
        writer.u32(0) // slots free
        writer.u32(0)

        writer.u32(UInt32(names.count))
        writer.string("US")
        writer.string("DE")

        channel.send(code: 14, payload: writer.data)
    }

    /// Sends a server notice the way the real server reports a rejected room name or join.
    func sendServerNotice(_ text: String) {
        queue.async { [weak self] in
            guard let self, let channel = self.channels.first else { return }
            var writer = MockWriter()
            writer.u32(1)
            writer.u32(UInt32(Date().timeIntervalSince1970))
            writer.string("server")
            writer.string(text)
            writer.bool(true)
            channel.send(code: 22, payload: writer.data)
        }
    }

    private func replyToLogin(password: String, channel: MockChannel) {
        var writer = MockWriter()
        switch loginOutcome {
        case .success(let greeting, let ownIP, let isSupporter):
            writer.bool(true)
            writer.string(greeting)
            writer.ip(ownIP)
            writer.string(Self.md5Hex(password))
            writer.bool(isSupporter)
        case .reject(let reason, let detail):
            writer.bool(false)
            writer.string(reason)
            if !detail.isEmpty { writer.string(detail) }
        }
        channel.send(code: 1, payload: writer.data)
    }

    private func replyWithPeerAddress(for user: String, channel: MockChannel) {
        guard let peer, peer.port > 0 || peerPortOverride != nil else { return }
        var writer = MockWriter()
        writer.string(user)
        if offlinePeers.contains(user) {
            writer.ip("0.0.0.0")
            writer.u32(0)
        } else {
            writer.ip("127.0.0.1")
            writer.u32(UInt32(peerPortOverride ?? peer.port))
        }
        channel.send(code: 3, payload: writer.data)
    }

    /// Forwards an uploader's `ConnectToPeer` (type `F`) to the connected client, as the real server
    /// does when a peer cannot reach the client's listening port directly.
    func forwardConnectToPeer(from username: String, port: UInt16, token: UInt32) {
        queue.async { [weak self] in
            guard let self, let channel = self.channels.first else { return }
            var writer = MockWriter()
            writer.string(username)
            writer.string("F")
            writer.ip("127.0.0.1")
            writer.u32(UInt32(port))
            writer.u32(token)
            writer.bool(false)
            channel.send(code: 18, payload: writer.data)
        }
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
