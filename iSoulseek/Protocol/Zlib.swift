import Foundation
import zlib

/// Soulseek compresses whole message payloads with plain zlib (RFC 1950).
enum Zlib {

    static func compress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var capacity = uLong(compressBound(uLong(input.count)))
        var output = [UInt8](repeating: 0, count: Int(capacity))
        var status: Int32 = Z_OK

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                status = compress2(destination.baseAddress, &capacity,
                                   source.baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }

        guard status == Z_OK else { throw ProtocolError.compressionFailed }
        return Data(output[0..<Int(capacity)])
    }

    /// Inflates `data`, refusing to produce more than `limit` bytes unless `allowingPartial` is
    /// set, in which case the prefix that fits is returned instead of throwing.
    static func decompress(_ data: Data, limit: Int, allowingPartial: Bool = false) throws -> Data {
        guard !data.isEmpty, limit > 0 else { throw ProtocolError.compressionFailed }

        var stream = z_stream()
        let initStatus = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw ProtocolError.compressionFailed }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()
        var status: Int32 = Z_OK
        let input = [UInt8](data)

        try input.withUnsafeBufferPointer { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            stream.avail_in = uInt(input.count)

            while true {
                let produced = buffer.withUnsafeMutableBufferPointer { destination -> Int in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }

                if produced > 0 {
                    let room = limit - output.count
                    guard produced <= room else {
                        guard allowingPartial else {
                            throw ProtocolError.decompressedTooLarge(limit: limit)
                        }
                        if room > 0 { output.append(contentsOf: buffer[0..<room]) }
                        return
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }

                if status == Z_STREAM_END { return }
                guard status == Z_OK else { throw ProtocolError.compressionFailed }
                if produced == 0 && stream.avail_in == 0 { throw ProtocolError.compressionFailed }
            }
        }

        return output
    }
}
