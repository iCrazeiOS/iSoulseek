import XCTest
@testable import iSoulseek

final class FrameDecoderTests: XCTestCase {

    // MARK: Helpers

    private func serverFrame(code: UInt32, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.write(UInt32(payload.count + 4))
        writer.write(code)
        writer.write(raw: payload)
        return writer.data
    }

    private func initFrame(code: UInt8, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.write(UInt32(payload.count + 1))
        writer.write(code)
        writer.write(raw: payload)
        return writer.data
    }

    // MARK: Basic framing

    func testSingleFrameDeliveredInOneByteFragments() throws {
        let frame = serverFrame(code: 26, payload: Data("hi".utf8))
        var decoder = FrameDecoder(mode: .server)

        for byte in frame.dropLast() {
            decoder.append(Data([byte]))
            XCTAssertNil(try decoder.next(), "no frame should be complete yet")
        }
        decoder.append(Data([frame.last!]))

        guard case .message(let code, let payload)? = try decoder.next() else {
            return XCTFail("expected a complete frame")
        }
        XCTAssertEqual(code, 26)
        XCTAssertEqual(payload, Data("hi".utf8))
        XCTAssertNil(try decoder.next())
    }

    func testSeveralFramesCoalescedIntoOneChunk() throws {
        var chunk = serverFrame(code: 1, payload: Data("a".utf8))
        chunk.append(serverFrame(code: 2, payload: Data()))
        chunk.append(serverFrame(code: 3, payload: Data("ccc".utf8)))

        var decoder = FrameDecoder(mode: .server)
        decoder.append(chunk)

        guard case .message(let c1, let p1)? = try decoder.next() else { return XCTFail() }
        guard case .message(let c2, let p2)? = try decoder.next() else { return XCTFail() }
        guard case .message(let c3, let p3)? = try decoder.next() else { return XCTFail() }

        XCTAssertEqual(c1, 1); XCTAssertEqual(p1, Data("a".utf8))
        XCTAssertEqual(c2, 2); XCTAssertEqual(p2, Data())
        XCTAssertEqual(c3, 3); XCTAssertEqual(p3, Data("ccc".utf8))
        XCTAssertNil(try decoder.next())
    }

    func testPartialTrailingFrameIsRetained() throws {
        let complete = serverFrame(code: 1, payload: Data("one".utf8))
        let partial = serverFrame(code: 2, payload: Data("two".utf8)).prefix(5)

        var decoder = FrameDecoder(mode: .server)
        decoder.append(complete)
        decoder.append(Data(partial))

        guard case .message(let code, let payload)? = try decoder.next() else { return XCTFail() }
        XCTAssertEqual(code, 1)
        XCTAssertEqual(payload, Data("one".utf8))
        XCTAssertNil(try decoder.next())
        XCTAssertGreaterThan(decoder.bufferedCount, 0)
    }

    func testZeroLengthPayloadIsValidOnServerChannel() throws {
        var decoder = FrameDecoder(mode: .server)
        decoder.append(serverFrame(code: 32, payload: Data()))
        guard case .message(let code, let payload)? = try decoder.next() else { return XCTFail() }
        XCTAssertEqual(code, 32)
        XCTAssertEqual(payload, Data())
    }

    // MARK: Init channel

    func testInitChannelUsesOneByteCode() throws {
        var decoder = FrameDecoder(mode: .initChannel)
        decoder.append(initFrame(code: 1, payload: Data("xyz".utf8)))
        guard case .initMessage(let code, let payload)? = try decoder.next() else { return XCTFail() }
        XCTAssertEqual(code, 1)
        XCTAssertEqual(payload, Data("xyz".utf8))
    }

    func testServerAndInitFramingDifferForSameBytes() throws {
        // A 6-byte init frame has a 5-byte header and one payload byte. The same bytes are not
        // long enough to satisfy the 8-byte server/peer header.
        var initDecoder = FrameDecoder(mode: .initChannel)
        initDecoder.append(initFrame(code: 9, payload: Data([1])))
        guard case .initMessage(let initCode, let payload)? = try initDecoder.next() else {
            return XCTFail("expected an init frame")
        }
        XCTAssertEqual(initCode, 9)
        XCTAssertEqual(payload, Data([1]))

        var server = FrameDecoder(mode: .server)
        server.append(initFrame(code: 9, payload: Data([1])))
        XCTAssertNil(try server.next(), "the same bytes cannot satisfy a 4-byte code header")
    }

    func testDeclaredLengthBelowCodeSizeIsRejected() {
        // Server: length must be >= 4 (one u32 code).
        var server = FrameDecoder(mode: .server)
        var writer = ByteWriter()
        writer.write(UInt32(3))   // < 4
        writer.write(UInt32(0))
        server.append(writer.data)
        XCTAssertThrowsError(try server.next()) { error in
            guard case .rejectedFrame = (error as? ProtocolError) else {
                return XCTFail("expected rejectedFrame, got \(error)")
            }
        }

        // Init channel: length must be >= 1 (one u8 code).
        var initDecoder = FrameDecoder(mode: .initChannel)
        var initWriter = ByteWriter()
        initWriter.write(UInt32(0))
        initWriter.write(UInt8(0))
        initDecoder.append(initWriter.data)
        XCTAssertThrowsError(try initDecoder.next()) { error in
            guard case .rejectedFrame = (error as? ProtocolError) else {
                return XCTFail("expected rejectedFrame, got \(error)")
            }
        }
    }

    // MARK: Size caps

    func testFrameAboveServerCapIsRejected() {
        var decoder = FrameDecoder(mode: .server)
        var writer = ByteWriter()
        writer.write(UInt32(FrameDecoder.maximumServerFrame)) // total = cap + 4
        writer.write(UInt32(1))
        decoder.append(writer.data)
        XCTAssertThrowsError(try decoder.next()) { error in
            guard case .frameTooLarge = (error as? ProtocolError) else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    func testFrameAbovePeerCapIsRejected() {
        var decoder = FrameDecoder(mode: .peer)
        var writer = ByteWriter()
        writer.write(UInt32(FrameDecoder.maximumPeerFrame + 1))
        writer.write(UInt32(1))
        decoder.append(writer.data)
        XCTAssertThrowsError(try decoder.next()) { error in
            guard case .frameTooLarge = (error as? ProtocolError) else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }

    func testServerCapIsLowerThanPeerCap() {
        XCTAssertLessThan(FrameDecoder.maximumServerFrame, FrameDecoder.maximumPeerFrame)
    }

    // MARK: takeBuffered / raw mode

    func testTakeBufferedReturnsAndClears() {
        var decoder = FrameDecoder(mode: .peer)
        decoder.append(Data([1, 2, 3, 4]))
        XCTAssertEqual(decoder.takeBuffered(), Data([1, 2, 3, 4]))
        XCTAssertEqual(decoder.bufferedCount, 0)
        XCTAssertEqual(decoder.takeBuffered(), Data())
    }

    func testRawModeYieldsNoFramesAndKeepsBufferedBytes() throws {
        var decoder = FrameDecoder(mode: .initChannel)
        decoder.append(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        decoder.mode = .raw
        XCTAssertNil(try decoder.next())
        XCTAssertEqual(decoder.bufferedCount, 4)
        XCTAssertEqual(decoder.takeBuffered(), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testSwitchingFromRawBackToFramed() throws {
        var decoder = FrameDecoder(mode: .raw)
        decoder.append(serverFrame(code: 7, payload: Data()))
        XCTAssertNil(try decoder.next())
        decoder.mode = .server
        guard case .message(let code, _)? = try decoder.next() else { return XCTFail() }
        XCTAssertEqual(code, 7)
    }
}
