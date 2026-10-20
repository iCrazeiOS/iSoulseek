import XCTest
@testable import iSoulseek

/// Ordering of the files inside a browsed folder.
final class ShareFolderTests: XCTestCase {

    private func file(_ name: String) -> ShareFile {
        ShareFile(name: name, size: 1)
    }

    func testFilesInNaturalOrderSortsTracksNumerically() {
        let folder = ShareFolder(path: "Music\\The Eminem Show", files: [
            file("10. Without Me.flac"),
            file("2. White America.flac"),
            file("album.nfo"),
            file("12. Sing for the Moment.flac"),
            file("5. Square Dance.flac"),
            file("cover.jpg"),
            file("01 - Intro.flac"),
        ])

        XCTAssertEqual(folder.filesInNaturalOrder.map(\.displayName), [
            "01 - Intro.flac",
            "2. White America.flac",
            "5. Square Dance.flac",
            "10. Without Me.flac",
            "12. Sing for the Moment.flac",
            "album.nfo",
            "cover.jpg",
        ], "tracks must read in numeric order, with artwork and metadata after them")
    }

    func testFilesInNaturalOrderIsCaseInsensitiveForUnnumberedNames() {
        let folder = ShareFolder(path: "Books", files: [
            file("gamma.pdf"),
            file("Alpha.pdf"),
            file("beta.pdf"),
        ])

        XCTAssertEqual(folder.filesInNaturalOrder.map(\.name),
                       ["Alpha.pdf", "beta.pdf", "gamma.pdf"])
    }

    func testNaturalOrderDoesNotChangeTheFolder() {
        let files = [file("10.flac"), file("2.flac")]
        let folder = ShareFolder(path: "Music", files: files)

        XCTAssertEqual(folder.filesInNaturalOrder.map(\.name), ["2.flac", "10.flac"])
        XCTAssertEqual(folder.files.map(\.name), ["10.flac", "2.flac"],
                       "the stored order is untouched; only the presentation is sorted")
    }
}
