import XCTest
@testable import iSoulseek

final class ShareSearchTests: XCTestCase {

    func testAllWordsMustMatch() {
        XCTAssertTrue(ShareSearch.matches(query: "foo", path: "Music\\Foo\\bar.mp3"))
        XCTAssertTrue(ShareSearch.matches(query: "foo bar", path: "Music\\Foo\\bar.mp3"))
        XCTAssertTrue(ShareSearch.matches(query: "bar foo", path: "Music\\Foo\\bar.mp3"))
        XCTAssertTrue(ShareSearch.matches(query: "FOO BAR", path: "music/foo/bar.mp3"))
    }

    func testMissingWordDoesNotMatch() {
        XCTAssertFalse(ShareSearch.matches(query: "foo baz", path: "Music\\Foo\\bar.mp3"))
        XCTAssertFalse(ShareSearch.matches(query: "qux", path: "Music\\Foo\\bar.mp3"))
    }

    func testEmptyQueryNeverMatches() {
        XCTAssertFalse(ShareSearch.matches(query: "", path: "Music\\Foo\\bar.mp3"))
        XCTAssertFalse(ShareSearch.matches(query: "   ", path: "Music\\Foo\\bar.mp3"))
        XCTAssertFalse(ShareSearch.matches(query: "\t", path: "a"))
    }

    func testMultipleWhitespaceSeparators() {
        XCTAssertTrue(ShareSearch.matches(query: "foo\tbar", path: "foo-bar"))
        XCTAssertTrue(ShareSearch.matches(query: "a  b", path: "aXXb"))
    }
}

final class FormattersTests: XCTestCase {

    func testDurationFormatting() {
        XCTAssertEqual(Formatters.duration(0), "0:00")
        XCTAssertEqual(Formatters.duration(5), "0:05")
        XCTAssertEqual(Formatters.duration(125), "2:05")
        XCTAssertEqual(Formatters.duration(3600), "60:00")
    }

    func testSpeedHasPerSecondSuffix() {
        XCTAssertTrue(Formatters.speed(1024).hasSuffix("/s"))
        XCTAssertTrue(Formatters.speed(0).hasSuffix("/s"))
    }

    func testByteFormattingIsNonEmpty() {
        XCTAssertFalse(Formatters.bytes(0).isEmpty)
        XCTAssertFalse(Formatters.bytes(1_000_000).isEmpty)
    }
}

final class ModelTests: XCTestCase {

    func testShareFolderComponents() {
        XCTAssertEqual(ShareFolder.components(of: "Music\\Album\\Disc"), ["Music", "Album", "Disc"])
        XCTAssertEqual(ShareFolder.components(of: "\\Music\\\\Album\\"), ["Music", "Album"])
        XCTAssertEqual(ShareFolder.components(of: ""), [])
    }

    func testShareFileAttributeAccessors() {
        let file = ShareFile(name: "a.mp3", size: 1, fileExtension: "mp3",
                             attributes: [SearchAttribute.bitrate.rawValue: 256,
                                          SearchAttribute.duration.rawValue: 199])
        XCTAssertEqual(file.bitrate, 256)
        XCTAssertEqual(file.duration, 199)
        XCTAssertNil(ShareFile(name: "b", size: 0).bitrate)
    }

    func testTransferLocalFilenameAndProgress() {
        let transfer = Transfer(id: 1, username: "bob", filename: "Music\\Album\\song.mp3",
                                size: 200, isUpload: false)
        XCTAssertEqual(transfer.localFilename, "song.mp3")

        var progress = transfer
        progress.transferred = 50
        XCTAssertEqual(progress.progress, 0.25, accuracy: 0.0001)

        var complete = transfer
        complete.size = 0
        complete.state = .completed
        XCTAssertEqual(complete.progress, 1)
    }

    func testConnectionStateHelpers() {
        XCTAssertTrue(ConnectionState.loggedIn(username: "bob").isLoggedIn)
        XCTAssertFalse(ConnectionState.disconnected.isLoggedIn)
        XCTAssertTrue(ConnectionState.loggedIn(username: "bob").description.contains("bob"))
    }

    func testSearchResultFullPath() {
        let result = SearchResult(username: "bob", token: 1,
                                  file: ShareFile(name: "Music\\a.mp3", size: 1),
                                  isSlotFree: true, averageSpeed: 0, queueLength: 0)
        XCTAssertEqual(result.fullPath, "Music\\a.mp3")
    }
}
