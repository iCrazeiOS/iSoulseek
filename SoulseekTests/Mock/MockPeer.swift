import Foundation
import Network
@testable import Soulseek

/// A scripted peer. It listens for inbound peer/file connections and can dial the client back the
/// way a real peer does after `GetPeerAddress`/`ConnectToPeer`, or after the client asks to upload.
final class MockPeer {

    let queue = DispatchQueue(label: "mock.soulseek.peer")
    weak var server: MockSoulseekServer?

    var username = "MockPeer"

    // Search response configuration.
    var searchUsername: String?
    var searchFiles: [ShareFile] = []
    var searchSlotFree = true
    var searchAverageSpeed: UInt32 = 1_000
    var searchQueueLength: UInt32 = 0
    var searchTokenOverride: UInt32?

    // Browse configuration.
    var shareFolders: [ShareFolder] = []

    // Download configuration: bytes we serve when the client downloads from us.
    var downloadPayload = Data()
    var downloadToken: UInt32 = 0x0FFF_0001

    // Upload configuration: how many bytes we expect to receive when the client uploads to us.
    var uploadExpectedSize = 0
    var placeInQueueAnswer: UInt32 = 1

    private var listener: NWListener?
    private var _port: UInt16 = 0
    var port: UInt16 { queue.sync { _port } }

    private var channels: [MockChannel] = []

    // Records, mutated only on `queue`.
    private var recordedPeerInitTypes: [String] = []
    private var recordedPeerInitUsernames: [String] = []
    private var recordedQueueUploads: [String] = []
    private var recordedTransferRequests: [TransferRequestInfo] = []
    private var recordedTransferResponses: [(token: UInt32, allowed: Bool, reason: String?)] = []
    private var recordedUploadDenied: [(filename: String, reason: String)] = []
    private var recordedPlaceRequests: [String] = []
    private var _downloadAskedOffset: UInt64?
    private var _receivedUploadBytes = Data()
    private var recordedSearchTokens: [UInt32] = []
    private var recordedPierceTokens: [UInt32] = []
    private var recordedUserInfoResponses = 0

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

    // MARK: Records (safe to read from the test thread)

    var peerInitTypes: [String] { queue.sync { recordedPeerInitTypes } }
    var peerInitUsernames: [String] { queue.sync { recordedPeerInitUsernames } }
    var queueUploads: [String] { queue.sync { recordedQueueUploads } }
    var transferRequests: [TransferRequestInfo] { queue.sync { recordedTransferRequests } }
    var transferResponses: [(token: UInt32, allowed: Bool, reason: String?)] { queue.sync { recordedTransferResponses } }
    var uploadDenied: [(filename: String, reason: String)] { queue.sync { recordedUploadDenied } }
    var placeRequests: [String] { queue.sync { recordedPlaceRequests } }
    var downloadAskedOffset: UInt64? { queue.sync { _downloadAskedOffset } }
    var receivedUploadBytes: Data { queue.sync { _receivedUploadBytes } }
    var searchTokens: [UInt32] { queue.sync { recordedSearchTokens } }
    var pierceTokens: [UInt32] { queue.sync { recordedPierceTokens } }
    var userInfoResponseCount: Int { queue.sync { recordedUserInfoResponses } }

    // MARK: Outbound (test/server driven)

    /// Dials the client and sends a compressed `FileSearchResponse` for `token`.
    func sendSearchResponse(token: UInt32) {
        queue.async { [weak self] in
            guard let self, let port = self.clientPort() else { return }
            self.recordedSearchTokens.append(self.searchTokenOverride ?? token)
            let channel = self.dial(port: port, label: "peer-search")
            channel.onReady = { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.sendPeerInit(on: channel)
                channel.setMode(.peer)

                var body = MockWriter()
                body.string(self.searchUsername ?? self.username)
                body.u32(self.searchTokenOverride ?? token)
                body.u32(UInt32(self.searchFiles.count))
                for file in self.searchFiles { body.raw(self.encode(file: file)) }
                body.bool(self.searchSlotFree)
                body.u32(self.searchAverageSpeed)
                body.u32(self.searchQueueLength)
                body.u32(0)
                channel.send(code: 9, payload: (try? Zlib.compress(body.data)) ?? Data())
            }
            channel.start()
        }
    }

    /// Dials the client and sends `PierceFireWall(token)` as the first message.
    func dialPierce(token: UInt32) {
        queue.async { [weak self] in
            guard let self, let port = self.clientPort() else { return }
            self.recordedPierceTokens.append(token)
            let channel = self.dial(port: port, label: "peer-pierce")
            channel.onReady = { [weak self, weak channel] in
                guard let self, let channel else { return }
                var payload = MockWriter()
                payload.u32(token)
                channel.send(initCode: 0, payload: payload.data)
                channel.setMode(.peer)
                self.wirePeer(channel, username: self.username)
            }
            channel.start()
        }
    }

    /// Dials the client and asks it to upload `virtualPath` to us.
    func requestUpload(virtualPath: String) {        queue.async { [weak self] in
            guard let self, let port = self.clientPort() else { return }
            let channel = self.dial(port: port, label: "peer-out-p")
            channel.onReady = { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.sendPeerInit(on: channel)
                channel.setMode(.peer)
                self.wirePeer(channel, username: self.username)

                var payload = MockWriter()
                payload.string(virtualPath)
                channel.send(code: 43, payload: payload.data)
            }
            channel.start()
        }
    }

    /// Dials the client and sends a `UserInfoRequest`, which a working client answers with 16.
    func requestUserInfo() {
        queue.async { [weak self] in
            guard let self, let port = self.clientPort() else { return }
            let channel = self.dial(port: port, label: "peer-userinfo")
            channel.onReady = { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.sendPeerInit(on: channel)
                channel.setMode(.peer)
                self.wirePeer(channel, username: self.username)
                channel.send(code: 15, payload: Data())
            }
            channel.start()
        }
    }

    // MARK: Inbound

    private func accept(_ connection: NWConnection) {
        let channel = MockChannel(connection: connection, mode: .initChannel,
                                  label: "peer-inbound", queue: queue)
        channels.append(channel)
        channel.onInit = { [weak self, weak channel] code, payload in
            guard let self, let channel else { return }
            self.handleInit(code: code, payload: payload, channel: channel)
        }
        channel.onClosed = { [weak self, weak channel] _ in
            guard let self, let channel else { return }
            self.channels.removeAll { $0 === channel }
        }
        channel.start()
    }

    private func handleInit(code: UInt8, payload: Data, channel: MockChannel) {
        var reader = MockReader(payload)
        switch code {
        case 1: // PeerInit
            guard let username = try? reader.string(), let type = try? reader.string() else {
                channel.cancel()
                return
            }
            _ = try? reader.u32() // token
            recordedPeerInitTypes.append(type)
            recordedPeerInitUsernames.append(username)
            switch type {
            case "P":
                channel.setMode(.peer)
                wirePeer(channel, username: username)
            case "F":
                beginReceiveUpload(channel)
            default:
                channel.cancel()
            }

        case 0: // PierceFireWall
            _ = try? reader.u32()
            channel.setMode(.peer)
            wirePeer(channel, username: nil)

        default:
            channel.cancel()
        }
    }

    private func wirePeer(_ channel: MockChannel, username: String?) {
        channel.onMessage = { [weak self, weak channel] code, payload in
            guard let self, let channel else { return }
            self.handlePeerMessage(code: code, payload: payload, channel: channel, username: username)
        }
    }

    private func handlePeerMessage(code: UInt32, payload: Data, channel: MockChannel, username: String?) {
        var reader = MockReader(payload)
        switch code {
        case 4: // GetShareFileList
            var body = MockWriter()
            body.raw(encode(folders: shareFolders))
            body.u32(0)
            channel.send(code: 5, payload: (try? Zlib.compress(body.data)) ?? Data())

        case 43: // QueueUpload
            guard let filename = try? reader.string() else { return }
            recordedQueueUploads.append(filename)
            var request = MockWriter()
            request.u32(1) // direction = upload
            request.u32(downloadToken)
            request.string(filename)
            request.u64(UInt64(downloadPayload.count))
            channel.send(code: 40, payload: request.data)

        case 40: // TransferRequest (client is the uploader)
            guard let direction = try? reader.u32(),
                  let token = try? reader.u32(),
                  let filename = try? reader.string() else { return }
            let size: UInt64? = direction == 1 ? (try? reader.u64()) : nil
            recordedTransferRequests.append(TransferRequestInfo(
                direction: TransferDirection(rawValue: direction) ?? .download,
                token: token, filename: filename, size: size))
            var response = MockWriter()
            response.u32(token)
            response.bool(true)
            channel.send(code: 41, payload: response.data)

        case 41: // TransferResponse (client accepted our download offer)
            guard let token = try? reader.u32(), let allowed = try? reader.bool() else { return }
            var reason: String?
            if !allowed { reason = try? reader.string() }
            recordedTransferResponses.append((token, allowed, reason))
            if allowed { openFileConnectionForUpload(token: token) }

        case 51: // PlaceInQueueRequest
            guard let filename = try? reader.string() else { return }
            recordedPlaceRequests.append(filename)
            var response = MockWriter()
            response.string(filename)
            response.u32(placeInQueueAnswer)
            channel.send(code: 44, payload: response.data)

        case 50: // UploadDenied
            let filename = (try? reader.string()) ?? ""
            let reason = (try? reader.string()) ?? ""
            recordedUploadDenied.append((filename, reason))

        case 16: // UserInfoResponse
            recordedUserInfoResponses += 1

        default:
            break
        }
    }

    /// We are the uploader: dial the client's `F` listener, send the token, read the offset, stream.
    private func openFileConnectionForUpload(token: UInt32) {
        guard let port = clientPort() else { return }
        let channel = dial(port: port, label: "peer-f")
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel else { return }
            var initPayload = MockWriter()
            initPayload.string(self.username)
            initPayload.string("F")
            initPayload.u32(0)
            channel.send(initCode: 1, payload: initPayload.data)
            channel.setMode(.raw)

            var tokenBytes = MockWriter()
            tokenBytes.u32(token)
            channel.sendRaw(tokenBytes.data)

            var header = Data()
            var offsetDelivered = false
            channel.onRaw = { [weak self, weak channel] data in
                guard let self, let channel, !offsetDelivered else { return }
                header.append(data)
                guard header.count >= 8 else { return }
                var reader = MockReader(header)
                let offset = (try? reader.u64()) ?? 0
                self._downloadAskedOffset = offset
                offsetDelivered = true

                let total = UInt64(self.downloadPayload.count)
                let start = Int(min(offset, total))
                let remaining = self.downloadPayload.subdata(in: start..<self.downloadPayload.count)
                channel.sendRaw(remaining)
            }
        }
        channel.start()
    }

    /// We are the downloader: the client dialled our `F` listener to upload to us.
    private func beginReceiveUpload(_ channel: MockChannel) {
        var tokenSeen = false
        var buffer = Data()
        channel.onRaw = { [weak self, weak channel] data in
            guard let self, let channel else { return }
            if !tokenSeen {
                buffer.append(data)
                guard buffer.count >= 4 else { return }
                var reader = MockReader(buffer)
                _ = try? reader.u32() // transfer token
                tokenSeen = true
                var offset = MockWriter()
                offset.u64(0)
                channel.sendRaw(offset.data)
                return
            }
            self._receivedUploadBytes.append(data)
        }
        // Set `onRaw` before switching so bytes coalesced with the PeerInit frame are not lost.
        channel.setMode(.raw)
    }

    // MARK: Helpers

    private func clientPort() -> UInt16? {
        guard let server else { return nil }
        let port = server.clientListeningPort
        return port > 0 ? port : nil
    }

    private func dial(port: UInt16, label: String) -> MockChannel {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        let channel = MockChannel(connection: connection, mode: .initChannel, label: label, queue: queue)
        channels.append(channel)
        return channel
    }

    private func sendPeerInit(on channel: MockChannel) {
        var payload = MockWriter()
        payload.string(username)
        payload.string("P")
        payload.u32(0)
        channel.send(initCode: 1, payload: payload.data)
    }

    private func encode(folders: [ShareFolder]) -> Data {
        var writer = MockWriter()
        writer.u32(UInt32(folders.count))
        for folder in folders {
            writer.string(folder.path)
            writer.u32(UInt32(folder.files.count))
            for file in folder.files { writer.raw(encode(file: file)) }
        }
        return writer.data
    }

    private func encode(file: ShareFile) -> Data {
        var writer = MockWriter()
        writer.u8(1)
        writer.string(file.name)
        writer.u64(file.size)
        writer.string(file.fileExtension)
        let attributes = file.attributes.sorted { $0.key < $1.key }
        writer.u32(UInt32(attributes.count))
        for (code, value) in attributes {
            writer.u32(code)
            writer.u32(value)
        }
        return writer.data
    }
}
