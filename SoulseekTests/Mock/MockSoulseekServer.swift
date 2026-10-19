import CryptoKit
import Foundation
import Network
@testable import Soulseek

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
                recordedSetWaitPorts.append(UInt16(truncatingIfNeeded: value))
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
                peer?.dialPierce(token: token)
            }

        case 121: // SendUploadSpeed
            if let value = try? reader.u32() { recordedUploadSpeeds.append(value) }

        default:
            break
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
        guard let peer, peer.port > 0 else { return }
        var writer = MockWriter()
        writer.string(user)
        writer.ip("127.0.0.1")
        writer.u32(UInt32(peer.port))
        channel.send(code: 3, payload: writer.data)
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
