import XCTest
@testable import iSoulseek

final class ZlibTests: XCTestCase {

    func testRoundTripKnownData() throws {
        let original = Data("The quick brown fox jumps over the lazy dog".utf8)
        let compressed = try Zlib.compress(original)
        XCTAssertNotEqual(compressed, original)
        // zlib streams start with the 0x78 marker byte (CMF: deflate, 32K window).
        XCTAssertEqual(compressed.first, 0x78)
        XCTAssertEqual(try Zlib.decompress(compressed, limit: 1 << 20), original)
    }

    func testRoundTripEmptyData() throws {
        let compressed = try Zlib.compress(Data())
        XCTAssertEqual(try Zlib.decompress(compressed, limit: 1024), Data())
    }

    func testRoundTripBinaryData() throws {
        var original = Data()
        for index in 0..<4096 { original.append(UInt8(index & 0xFF)) }
        let compressed = try Zlib.compress(original)
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(try Zlib.decompress(compressed, limit: 1 << 20), original)
    }

    func testDecompressEmptyInputThrows() {
        XCTAssertThrowsError(try Zlib.decompress(Data(), limit: 1024)) { error in
            XCTAssertEqual(error as? ProtocolError, .compressionFailed)
        }
    }

    func testDecompressWithNonPositiveLimitThrows() {
        let compressed = try! Zlib.compress(Data("x".utf8))
        XCTAssertThrowsError(try Zlib.decompress(compressed, limit: 0)) { error in
            XCTAssertEqual(error as? ProtocolError, .compressionFailed)
        }
    }

    func testDecompressTruncatedStreamThrows() {
        let compressed = try! Zlib.compress(Data(repeating: 0x41, count: 1000))
        let truncated = compressed.prefix(compressed.count / 2)
        XCTAssertThrowsError(try Zlib.decompress(Data(truncated), limit: 1 << 20)) { error in
            XCTAssertEqual(error as? ProtocolError, .compressionFailed)
        }
    }

    func testDecompressGarbageThrows() {
        XCTAssertThrowsError(try Zlib.decompress(Data([0x00, 0x11, 0x22, 0x33]), limit: 1024)) { error in
            XCTAssertEqual(error as? ProtocolError, .compressionFailed)
        }
    }

    func testDecompressionBombIsRejected() throws {
        // A highly compressible payload: 4 MiB of zeros compresses to a few KiB.
        let bomb = try Zlib.compress(Data(repeating: 0, count: 4 << 20))
        XCTAssertLessThan(bomb.count, 64 << 10)

        XCTAssertThrowsError(try Zlib.decompress(bomb, limit: 4 * 1024)) { error in
            guard case .decompressedTooLarge(let limit) = (error as? ProtocolError) else {
                return XCTFail("expected decompressedTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 4 * 1024)
        }
    }

    func testExactLimitBoundaryIsAccepted() throws {
        let original = Data(repeating: 0x5A, count: 1000)
        let compressed = try Zlib.compress(original)
        XCTAssertEqual(try Zlib.decompress(compressed, limit: 1000), original)
    }
}
