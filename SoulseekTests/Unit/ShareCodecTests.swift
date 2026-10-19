import XCTest
@testable import Soulseek

final class ShareCodecTests: XCTestCase {

    func testFolderRoundTripWithAttributes() throws {
        let folders = [
            ShareFolder(path: "Music\\Album", files: [
                ShareFile(name: "Music\\Album\\a.mp3", size: 1_234_567, fileExtension: "mp3",
                          attributes: [0: 320, 1: 210, 2: 0]),
                ShareFile(name: "Music\\Album\\b.flac", size: 42, fileExtension: "flac",
                          attributes: [4: 44_100])
            ]),
            ShareFolder(path: "Books", files: [
                ShareFile(name: "Books\\c.epub", size: 9, fileExtension: "epub")
            ])
        ]

        let encoded = ShareCodec.encode(folders: folders)
        var reader = ByteReader(encoded)
        let decoded = try ShareCodec.decodeFolders(&reader)

        // decodeFolders normalises paths from "/" to "\".
        XCTAssertEqual(decoded, folders)
    }

    func testEncodeFileLayoutIsExact() {
        let file = ShareFile(name: "x.mp3", size: 0x0102030405060708, fileExtension: "mp3",
                             attributes: [0: 128])
        let encoded = ShareCodec.encode(file: file, name: file.name)

        var expected = ByteWriter()
        expected.write(UInt8(1))                                  // record code = file
        expected.write(string: "x.mp3")
        expected.write(UInt64(0x0102030405060708))
        expected.write(string: "mp3")
        expected.write(UInt32(1))                                 // one attribute
        expected.write(UInt32(0))                                 // code: bitrate
        expected.write(UInt32(128))                               // value
        XCTAssertEqual(Array(encoded), Array(expected.data))
    }

    func testAttributeOrderIsStable() {
        let file = ShareFile(name: "x", size: 1, fileExtension: "",
                             attributes: [5: 16, 0: 320, 4: 44_100, 1: 100])
        let encoded = ShareCodec.encode(file: file, name: file.name)

        var reader = ByteReader(encoded)
        try? reader.skip(1)
        _ = try? reader.readString()
        _ = try? reader.readUInt64()
        _ = try? reader.readString()
        XCTAssertEqual(try reader.readUInt32(), 4)
        XCTAssertEqual(try reader.readUInt32(), 0)      // bitrate first
        XCTAssertEqual(try reader.readUInt32(), 320)
        XCTAssertEqual(try reader.readUInt32(), 1)      // duration
        XCTAssertEqual(try reader.readUInt32(), 100)
        XCTAssertEqual(try reader.readUInt32(), 4)      // sample rate
        XCTAssertEqual(try reader.readUInt32(), 44_100)
        XCTAssertEqual(try reader.readUInt32(), 5)      // bit depth
        XCTAssertEqual(try reader.readUInt32(), 16)
    }

    func testUnknownAttributeCodesArePreservedOnDecode() throws {
        // The encoder only emits known attributes in a fixed order, but the decoder must keep
        // whatever a remote peer sends, including codes this client does not understand.
        var writer = ByteWriter()
        writer.write(UInt32(1))
        writer.write(UInt32(99))
        writer.write(UInt32(7))
        var reader = ByteReader(writer.data)
        XCTAssertEqual(try ShareCodec.decodeAttributes(&reader), [99: 7])
    }

    func testDecodeNormalisesForwardSlashes() throws {
        var body = ByteWriter()
        body.write(UInt32(1))
        body.write(string: "Music/Album")       // forward slash on the wire
        body.write(UInt32(1))
        body.write(raw: ShareCodec.encode(file: ShareFile(name: "Music/Album/a.mp3", size: 5),
                                          name: "Music/Album/a.mp3"))
        var reader = ByteReader(body.data)
        let folders = try ShareCodec.decodeFolders(&reader)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].path, "Music\\Album")
        XCTAssertEqual(folders[0].files[0].name, "Music\\Album\\a.mp3")
    }

    // MARK: Legacy >2 GiB quirk

    func testLegacyHighByteBugUsesLowFourBytes() throws {
        // Byte 7 == 0xFF means an ancient client corrupted the high half; only the low u32 is real.
        let bytes = Data([0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        var reader = ByteReader(bytes)
        XCTAssertEqual(try ShareCodec.readFileSize(&reader), 10)
    }

    func testLegacyQuirkNotTriggeredForNormalSizes() throws {
        let bytes = Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]) // 4 GiB
        var reader = ByteReader(bytes)
        XCTAssertEqual(try ShareCodec.readFileSize(&reader), 4 * 1024 * 1024 * 1024)
    }

    func testMaximumSizeRoundTrips() throws {
        let bytes = Data(repeating: 0xFF, count: 8)
        var reader = ByteReader(bytes)
        // 0xFF in the top byte triggers the legacy path, so the value is the low u32.
        XCTAssertEqual(try ShareCodec.readFileSize(&reader), 0xFFFF_FFFF)
    }
}
