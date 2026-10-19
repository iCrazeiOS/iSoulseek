import XCTest
@testable import iSoulseek

final class DownloadedFilesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadedFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, bytes: Int = 1, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    func testScanListsRegularFilesRecursively() throws {
        _ = try write("single.flac", bytes: 3)
        _ = try write("Artist/Album/song.mp3", bytes: 5)
        _ = try write(".hidden", bytes: 1)

        let files = DownloadedFiles.scan(in: root)
        XCTAssertEqual(files.map(\.relativePath).sorted(),
                       ["Artist/Album/song.mp3", "single.flac"])

        let single = try XCTUnwrap(files.first { $0.relativePath == "single.flac" })
        XCTAssertEqual(single.name, "single.flac")
        XCTAssertEqual(single.folder, "Downloads")
        XCTAssertEqual(single.size, 3)

        let song = try XCTUnwrap(files.first { $0.relativePath == "Artist/Album/song.mp3" })
        XCTAssertEqual(song.name, "song.mp3")
        XCTAssertEqual(song.folder, "Artist / Album")
        XCTAssertEqual(song.size, 5)
    }

    func testScanSkipsInProgressDownloads() throws {
        _ = try write(".partials/Artist/Album/song.mp3", bytes: 5)
        _ = try write("complete.flac", bytes: 3)

        XCTAssertEqual(DownloadedFiles.scan(in: root).map(\.relativePath), ["complete.flac"])
    }

    func testSortOrders() {
        let newest = DownloadedFile(url: URL(fileURLWithPath: "/A.flac"), relativePath: "A.flac",
                                    name: "A.flac", size: 1,
                                    modified: Date(timeIntervalSince1970: 300))
        let oldest = DownloadedFile(url: URL(fileURLWithPath: "/B.flac"), relativePath: "B.flac",
                                    name: "B.flac", size: 2,
                                    modified: Date(timeIntervalSince1970: 100))
        let middle = DownloadedFile(url: URL(fileURLWithPath: "/C.flac"), relativePath: "C.flac",
                                    name: "C.flac", size: 3,
                                    modified: Date(timeIntervalSince1970: 200))
        let files = [newest, oldest, middle]

        XCTAssertEqual(DownloadSortOrder.oldest.sorted(files).map(\.name),
                       ["B.flac", "C.flac", "A.flac"])
        XCTAssertEqual(DownloadSortOrder.newest.sorted(files).map(\.name),
                       ["A.flac", "C.flac", "B.flac"])
        XCTAssertEqual(DownloadSortOrder.name.sorted(files).map(\.name),
                       ["A.flac", "B.flac", "C.flac"])
    }

    func testDeleteRemovesFileAndEmptyParents() throws {
        let nested = try write("Artist/Album/song.mp3")
        let rootFile = try write("keep.flac")

        DownloadedFiles.delete(nested, upTo: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Artist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootFile.path))

        DownloadedFiles.delete(rootFile, upTo: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the downloads root must be kept")
    }

    func testPruneEmptyParentsNeverRemovesFiles() throws {
        let nested = try write("Artist/Album/song.mp3")

        DownloadedFiles.pruneEmptyParents(of: nested, upTo: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))

        try FileManager.default.removeItem(at: nested)
        DownloadedFiles.pruneEmptyParents(of: nested, upTo: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Artist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
