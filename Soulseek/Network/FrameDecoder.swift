import Foundation

/// How bytes on a connection are delimited. Soulseek uses different framing per channel.
enum FrameMode: Equatable {
    /// `u32 length | u32 code | payload` — server and established peer connections.
    case server
    /// `u32 length | u32 code | payload` — established peer connections.
    case peer
    /// `u32 length | u8 code | payload` — peer-init and distributed connections.
    case initChannel
    /// Undelimited stream — file transfers.
    case raw
}

enum Frame: Equatable {
    case message(code: UInt32, payload: Data)
    case initMessage(code: UInt8, payload: Data)
}

/// Incremental framing for one channel. TCP may split or coalesce frames arbitrarily, so bytes are
/// accumulated until a complete frame is available.
struct FrameDecoder {

    static let maximumServerFrame = 1 << 20          // 1 MiB
    static let maximumPeerFrame = 16 << 20           // 16 MiB
    static let maximumInitFrame = 1 << 20            // 1 MiB

    var mode: FrameMode
    private var buffer = Data()

    init(mode: FrameMode) {
        self.mode = mode
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Removes and returns everything buffered, used when switching to raw mode.
    mutating func takeBuffered() -> Data {
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }

    var bufferedCount: Int { buffer.count }

    mutating func next() throws -> Frame? {
        let headerSize: Int
        let codeSize: Int
        let limit: Int

        switch mode {
        case .server:
            headerSize = 8; codeSize = 4; limit = Self.maximumServerFrame
        case .peer:
            headerSize = 8; codeSize = 4; limit = Self.maximumPeerFrame
        case .initChannel:
            headerSize = 5; codeSize = 1; limit = Self.maximumInitFrame
        case .raw:
            return nil
        }

        guard buffer.count >= headerSize else { return nil }

        let length = Int(uint32(at: 0))
        guard length >= codeSize else {
            throw ProtocolError.rejectedFrame("declared length \(length)")
        }
        let total = length + 4
        guard total <= limit else {
            throw ProtocolError.frameTooLarge(UInt32(clamping: length))
        }
        guard buffer.count >= total else { return nil }

        defer { buffer.removeFirst(total) }

        if codeSize == 4 {
            return .message(code: uint32(at: 4), payload: slice(from: 8, to: total))
        }
        return .initMessage(code: buffer[buffer.startIndex + 4], payload: slice(from: 5, to: total))
    }

    private func uint32(at index: Int) -> UInt32 {
        let base = buffer.startIndex + index
        return UInt32(buffer[base])
            | (UInt32(buffer[base + 1]) << 8)
            | (UInt32(buffer[base + 2]) << 16)
            | (UInt32(buffer[base + 3]) << 24)
    }

    private func slice(from start: Int, to end: Int) -> Data {
        let base = buffer.startIndex
        return Data(buffer[(base + start)..<(base + end)])
    }
}
