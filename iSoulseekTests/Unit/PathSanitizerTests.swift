import XCTest
@testable import iSoulseek

final class PathSanitizerTests: XCTestCase {

    // MARK: components(from:)

    func testNormalisesBothSeparators() {
        XCTAssertEqual(PathSanitizer.components(from: "a\\b/c"), ["a", "b", "c"])
    }

    func testDropsDotAndDotDotComponents() {
        XCTAssertEqual(PathSanitizer.components(from: "a/../../b"), ["a", "b"])
        XCTAssertEqual(PathSanitizer.components(from: "./a/./b"), ["a", "b"])
        XCTAssertEqual(PathSanitizer.components(from: "..\\..\\x"), ["x"])
    }

    func testStripsControlCharactersAndColon() {
        XCTAssertEqual(PathSanitizer.components(from: "a:b\u{01}c"), ["abc"])
        XCTAssertEqual(PathSanitizer.components(from: "ok\u{7F}name"), ["okname"])
        XCTAssertEqual(PathSanitizer.components(from: "C:\\Windows"), ["C", "Windows"])
    }

    func testRejectsEmptyComponentLists() {
        XCTAssertEqual(PathSanitizer.components(from: ""), [])
        XCTAssertEqual(PathSanitizer.components(from: "..."), [])
        XCTAssertEqual(PathSanitizer.components(from: "///"), [])
        XCTAssertEqual(PathSanitizer.components(from: "a"), ["a"])
    }

    func testTrimsWhitespaceAndSurroundingDots() {
        XCTAssertEqual(PathSanitizer.components(from: "  spaced  "), ["spaced"])
        XCTAssertEqual(PathSanitizer.components(from: ".hidden."), ["hidden"])
    }

    func testCapsComponentLength() {
        let long = String(repeating: "x", count: 200)
        let components = PathSanitizer.components(from: long)
        XCTAssertEqual(components, [String(repeating: "x", count: PathSanitizer.maximumComponentLength)])
    }

    func testCapsComponentCountKeepingDeepest() {
        let path = (1...20).map { "c\($0)" }.joined(separator: "/")
        let components = PathSanitizer.components(from: path)
        XCTAssertEqual(components.count, PathSanitizer.maximumComponents)
        XCTAssertEqual(components.first, "c5")
        XCTAssertEqual(components.last, "c20")
    }

    // MARK: destination(in:username:virtualPath:)

    func testDestinationStaysInsideUsernameFolder() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        let destination = PathSanitizer.destination(in: root, username: "alice",
                                                     virtualPath: "music/song.mp3")
        XCTAssertEqual(destination?.path, "/tmp/soulseek-root/alice/music/song.mp3")
    }

    func testDestinationNeverEscapesForTraversalAttempts() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        let attempts = [
            "..\\..\\etc\\passwd",
            "../../../../etc/passwd",
            "a/../../../../b",
            "/etc/passwd",
            "..",
            "./..//..",
            "....//....//etc"
        ]
        for attempt in attempts {
            guard let url = PathSanitizer.destination(in: root, username: "../alice",
                                                       virtualPath: attempt) else { continue }
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix("/tmp/soulseek-root/"),
                          "\(attempt) escaped to \(url.path)")
        }
    }

    func testDestinationSanitisesUsername() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        let destination = PathSanitizer.destination(in: root, username: "../alice",
                                                     virtualPath: "song.mp3")
        XCTAssertEqual(destination?.path, "/tmp/soulseek-root/alice/song.mp3")
    }

    func testDestinationReturnsNilWhenNothingUsableRemains() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        XCTAssertNil(PathSanitizer.destination(in: root, username: "alice", virtualPath: ".."))
        XCTAssertNil(PathSanitizer.destination(in: root, username: "alice", virtualPath: ""))
        XCTAssertNil(PathSanitizer.destination(in: root, username: "alice", virtualPath: "///"))
        XCTAssertNil(PathSanitizer.destination(in: root, username: "..", virtualPath: "song.mp3"))
    }

    func testDestinationSanitisesEachComponent() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        let destination = PathSanitizer.destination(in: root, username: "alice",
                                                     virtualPath: "music/../../etc/pa:sswd")
        XCTAssertEqual(destination?.path, "/tmp/soulseek-root/alice/music/etc/passwd")
    }

    func testDestinationSurvivesVeryLongPaths() {
        let root = URL(fileURLWithPath: "/tmp/soulseek-root")
        let path = (1...40).map { "component\($0)" }.joined(separator: "\\")
        guard let url = PathSanitizer.destination(in: root, username: "alice",
                                                   virtualPath: path) else {
            return XCTFail("expected a destination")
        }
        let components = url.pathComponents.dropFirst(3) // / tmp soulseek-root
        XCTAssertLessThanOrEqual(components.count, PathSanitizer.maximumComponents)
        XCTAssertEqual(components.first, "alice")
        XCTAssertTrue(url.path.hasPrefix("/tmp/soulseek-root/"))
    }
}
