import XCTest
@testable import iSoulseek

final class ByteCodecTests: XCTestCase {

    // MARK: Little-endian encoding

    func testIntegersAreLittleEndian() {
        var writer = ByteWriter()
        writer.write(UInt16(0x0201))
        writer.write(UInt32(0x04030201))
        writer.write(UInt64(0x0807060504030201))
        XCTAssertEqual(Array(writer.data),
                       [0x01, 0x02,
                        0x01, 0x02, 0x03, 0x04,
                        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    func testIPIsPackedLittleEndian() {
        var writer = ByteWriter()
        writer.write(ip: "1.2.3.4")
        XCTAssertEqual(Array(writer.data), [0x04, 0x03, 0x02, 0x01])
    }

    func testMalformedIPFallsBackToZeros() {
        var writer = ByteWriter()
        writer.write(ip: "not.an.ip")
        XCTAssertEqual(Array(writer.data), [0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Round-trips

    func testRoundTripPrimitives() throws {
        var writer = ByteWriter()
        writer.write(UInt8(0xFE))
        writer.write(UInt16(0xBEEF))
        writer.write(UInt32(0xDEADBEEF))
        writer.write(UInt64(0x1122334455667788))
        writer.write(true)
        writer.write(false)
        writer.write(string: "héllo")
        writer.write(ip: "10.20.30.40")

        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readUInt8(), 0xFE)
        XCTAssertEqual(try reader.readUInt16(), 0xBEEF)
        XCTAssertEqual(try reader.readUInt32(), 0xDEADBEEF)
        XCTAssertEqual(try reader.readUInt64(), 0x1122334455667788)
        XCTAssertEqual(try reader.readBool(), true)
        XCTAssertEqual(try reader.readBool(), false)
        XCTAssertEqual(try reader.readString(), "héllo")
        XCTAssertEqual(try reader.readIP(), "10.20.30.40")
        XCTAssertEqual(reader.remaining, 0)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testStringLengthPrefixCountsUTF8Bytes() {
        var writer = ByteWriter()
        writer.write(string: "é")
        XCTAssertEqual(Array(writer.data), [0x02, 0x00, 0x00, 0x00, 0xC3, 0xA9])
    }

    func testReadStringFallsBackToLatin1() throws {
        var writer = ByteWriter()
        writer.write(UInt32(1))
        writer.write(raw: Data([0xFF])) // invalid UTF-8
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readString(), "ÿ")
    }

    func testEmptyStringRoundTrips() throws {
        var writer = ByteWriter()
        writer.write(string: "")
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readString(), "")
    }

    // MARK: Truncation

    func testTruncatedReadsThrow() {
        let cases: [(String, (inout ByteReader) throws -> Void)] = [
            ("u8", { _ = try $0.readUInt8() }),
            ("u16", { _ = try $0.readUInt16() }),
            ("u32", { _ = try $0.readUInt32() }),
            ("u64", { _ = try $0.readUInt64() }),
            ("ip", { _ = try $0.readIP() }),
            ("string length", { _ = try $0.readString() })
        ]
        for (name, read) in cases {
            var reader = ByteReader(Data())
            XCTAssertThrowsError(try read(&reader), name) { error in
                XCTAssertEqual(error as? ProtocolError, .truncated, name)
            }
        }
    }

    func testStringWithDeclaredLengthLongerThanBufferThrows() {
        var writer = ByteWriter()
        writer.write(UInt32(10))
        writer.write(raw: Data("abc".utf8))
        var reader = ByteReader(writer.data)
        XCTAssertThrowsError(try reader.readString()) { error in
            XCTAssertEqual(error as? ProtocolError, .truncated)
        }
    }

    func testSkipBeyondEndThrows() {
        var reader = ByteReader(Data([0x01, 0x02]))
        XCTAssertThrowsError(try reader.skip(3)) { error in
            XCTAssertEqual(error as? ProtocolError, .truncated)
        }
        XCTAssertThrowsError(try reader.skip(-1)) { error in
            XCTAssertEqual(error as? ProtocolError, .truncated)
        }
    }

    // MARK: Bounded counts

    func testReadCountRejectsAbsurdCounts() {
        var writer = ByteWriter()
        writer.write(UInt32(1_000_000))
        var reader = ByteReader(writer.data)
        XCTAssertThrowsError(try reader.readCount(minimumBytesPerItem: 14)) { error in
            guard case .invalidValue = (error as? ProtocolError) else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testReadCountAcceptsCountThatFits() throws {
        var writer = ByteWriter()
        writer.write(UInt32(3))
        writer.write(raw: Data(repeating: 0, count: 42))
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readCount(minimumBytesPerItem: 14), 3)
    }

    func testReadCountWithZeroMinimumDoesNotBound() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0xFFFF_FFFF))
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readCount(minimumBytesPerItem: 0), 0xFFFF_FFFF)
    }

    func testPeekDoesNotAdvance() throws {
        var writer = ByteWriter()
        writer.write(UInt32(0x0A0B0C0D))
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.peekUInt32(), 0x0A0B0C0D)
        XCTAssertEqual(reader.offset, 0)
        XCTAssertEqual(try reader.readUInt32(), 0x0A0B0C0D)
    }

    func testReadBytesAcrossOffsetBoundaries() throws {
        // Exercise a non-zero-offset slice: Data from a range keeps a startIndex that is not 0.
        let backing = Data([0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04, 0xCC])
        let slice = backing[2..<6]
        var reader = ByteReader(slice)
        XCTAssertEqual(try reader.readUInt32(), 0x04030201)
        XCTAssertEqual(reader.remaining, 0)
    }
}
