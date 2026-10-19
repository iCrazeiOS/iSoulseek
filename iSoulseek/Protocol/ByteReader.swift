import Foundation

enum ProtocolError: Error, Equatable {
    case truncated
    case invalidValue(String)
    case unsupportedMessage(String)
    case compressionFailed
    case decompressedTooLarge(limit: Int)
    case frameTooLarge(UInt32)
    case rejectedFrame(String)
}

/// Cursor over a message payload. Every read is bounds-checked and throws instead of trapping,
/// because the data always originates from a remote peer.
struct ByteReader {

    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw ProtocolError.truncated }
        offset += count
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ProtocolError.truncated }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start..<(start + count)])
    }

    mutating func readUInt8() throws -> UInt8 {
        guard let byte = try readBytes(1).first else { throw ProtocolError.truncated }
        return byte
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(2)
        return UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        var value: UInt32 = 0
        for index in stride(from: 3, through: 0, by: -1) {
            value = (value << 8) | UInt32(bytes[bytes.startIndex + index])
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(8)
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[bytes.startIndex + index])
        }
        return value
    }

    /// `u32` length prefix followed by UTF-8 (Latin-1 as a fallback, matching other clients).
    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let bytes = try readBytes(length)
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    /// A count that will be used to size a loop must not exceed what the buffer can hold.
    mutating func readCount(minimumBytesPerItem: Int) throws -> Int {
        let raw = try readUInt32()
        let count = Int(raw)
        if minimumBytesPerItem > 0, count > remaining / minimumBytesPerItem {
            throw ProtocolError.invalidValue("count \(count) with \(remaining) bytes left")
        }
        return count
    }

    /// Four bytes holding a dotted quad in little-endian order (`1.2.3.4` is `04 03 02 01`).
    mutating func readIP() throws -> String {
        let bytes = try readBytes(4)
        let octets = [bytes[bytes.startIndex + 3], bytes[bytes.startIndex + 2],
                      bytes[bytes.startIndex + 1], bytes[bytes.startIndex]]
        return octets.map(String.init).joined(separator: ".")
    }

    func peekUInt32() throws -> UInt32 {
        var copy = self
        return try copy.readUInt32()
    }
}
