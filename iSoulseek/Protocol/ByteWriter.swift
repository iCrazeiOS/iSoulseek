import Foundation

/// Little-endian payload builder.
struct ByteWriter {

    private(set) var data = Data()

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    mutating func write(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func write(_ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func write(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func write(_ value: Int32) {
        write(UInt32(bitPattern: value))
    }

    mutating func write(string: String) {
        let bytes = Data(string.utf8)
        write(UInt32(bytes.count))
        data.append(bytes)
    }

    /// Writes a dotted quad in the little-endian order the protocol expects.
    mutating func write(ip: String) {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        let padded = octets.count == 4 ? octets : [0, 0, 0, 0]
        for octet in padded.reversed() {
            data.append(octet)
        }
    }

    mutating func write(raw: Data) {
        data.append(raw)
    }
}
