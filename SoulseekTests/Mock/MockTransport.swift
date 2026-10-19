import Foundation
import Network

// MARK: - Independent little-endian codec for the mock

/// The mock deliberately does not reuse the app's `ByteReader`/`ByteWriter`/`FrameDecoder`, so a
/// mistake in the app's framing code shows up as a failure rather than cancelling itself out.
struct MockWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        u32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func ip(_ value: String) {
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        for octet in octets.reversed() { data.append(octet) }
    }

    mutating func raw(_ value: Data) { data.append(value) }
}

enum MockTransportError: Error {
    case truncated
}

struct MockReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    private mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw MockTransportError.truncated }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<(start + count)])
    }

    mutating func u8() throws -> UInt8 {
        try bytes(1)[data.startIndex]
    }

    mutating func bool() throws -> Bool { try u8() != 0 }

    mutating func u32() throws -> UInt32 {
        let raw = try bytes(4)
        var value: UInt32 = 0
        for index in stride(from: 3, through: 0, by: -1) {
            value = (value << 8) | UInt32(raw[raw.startIndex + index])
        }
        return value
    }

    mutating func u64() throws -> UInt64 {
        let raw = try bytes(8)
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(raw[raw.startIndex + index])
        }
        return value
    }

    mutating func string() throws -> String {
        let length = Int(try u32())
        let raw = try bytes(length)
        return String(data: raw, encoding: .utf8)
            ?? String(data: raw, encoding: .isoLatin1)
            ?? ""
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }
}

// MARK: - A single framed (or raw) channel

/// Mirrors `SocketConnection` but with its own decoder. All methods must be called on `queue`.
final class MockChannel {
    enum Mode { case server, peer, initChannel, raw }

    let label: String

    var onReady: (() -> Void)?
    var onMessage: ((UInt32, Data) -> Void)?
    var onInit: ((UInt8, Data) -> Void)?
    var onRaw: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var mode: Mode
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, mode: Mode, label: String, queue: DispatchQueue) {
        self.connection = connection
        self.mode = mode
        self.label = label
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let error):
                self.close(error.localizedDescription)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        if mode == .raw { flushRaw() }
    }

    func send(code: UInt32, payload: Data) {
        var writer = MockWriter()
        writer.u32(UInt32(payload.count + 4))
        writer.u32(code)
        writer.raw(payload)
        sendRaw(writer.data)
    }

    func send(initCode: UInt8, payload: Data) {
        var writer = MockWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(initCode)
        writer.raw(payload)
        sendRaw(writer.data)
    }

    func sendRaw(_ data: Data, completion: ((String?) -> Void)? = nil) {
        guard !closed else { completion?("closed"); return }
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error?.localizedDescription)
        })
    }

    func cancel() { close(nil) }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.close(error.localizedDescription)
                return
            }
            if isComplete {
                self.close(nil)
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while true {
            switch mode {
            case .raw:
                flushRaw()
                return

            case .server, .peer:
                guard buffer.count >= 8 else { return }
                let length = Int(readUInt32(at: 0))
                guard length >= 4 else { close("declared length \(length)"); return }
                let total = length + 4
                guard buffer.count >= total else { return }
                let code = readUInt32(at: 4)
                let payload = Data(buffer[(buffer.startIndex + 8)..<(buffer.startIndex + total)])
                buffer.removeFirst(total)
                onMessage?(code, payload)

            case .initChannel:
                guard buffer.count >= 5 else { return }
                let length = Int(readUInt32(at: 0))
                guard length >= 1 else { close("declared length \(length)"); return }
                let total = length + 4
                guard buffer.count >= total else { return }
                let code = buffer[buffer.startIndex + 4]
                let payload = Data(buffer[(buffer.startIndex + 5)..<(buffer.startIndex + total)])
                buffer.removeFirst(total)
                onInit?(code, payload)
            }
        }
    }

    private func flushRaw() {
        guard mode == .raw, !buffer.isEmpty else { return }
        let data = buffer
        buffer.removeAll(keepingCapacity: false)
        onRaw?(data)
    }

    private func readUInt32(at index: Int) -> UInt32 {
        let base = buffer.startIndex + index
        return UInt32(buffer[base])
            | (UInt32(buffer[base + 1]) << 8)
            | (UInt32(buffer[base + 2]) << 16)
            | (UInt32(buffer[base + 3]) << 24)
    }

    private func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason)
    }
}
