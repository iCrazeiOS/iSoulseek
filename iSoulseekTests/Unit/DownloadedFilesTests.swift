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

    private func file(_ path: String, size: UInt64, modified: TimeInterval) -> DownloadedFile {
        DownloadedFile(url: URL(fileURLWithPath: "/" + path), relativePath: path,
                       name: URL(fileURLWithPath: path).lastPathComponent, size: size,
                       modified: Date(timeIntervalSince1970: modified))
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

    func testTreeGroupsFilesByFolder() {
        let files = [
            file("Artist/Album/b.mp3", size: 2, modified: 100),
            file("Artist/Album/a.mp3", size: 3, modified: 300),
            file("Artist/loose.mp3", size: 4, modified: 200),
            file("Zeta/z.flac", size: 5, modified: 400),
            file("root.flac", size: 6, modified: 500),
        ]
        let root = DownloadTree.build(from: files, sortOrder: .oldest)

        XCTAssertEqual(root.name, "Downloads")
        XCTAssertEqual(root.folders.map(\.name), ["Artist", "Zeta"])
        XCTAssertEqual(root.files.map(\.name), ["root.flac"])
        XCTAssertEqual(root.fileCount, 5)
        XCTAssertEqual(root.totalSize, 20)

        let artist = root.folders[0]
        XCTAssertEqual(artist.path, "Artist")
        XCTAssertEqual(artist.folders.map(\.name), ["Album"])
        XCTAssertEqual(artist.files.map(\.name), ["loose.mp3"])
        XCTAssertEqual(artist.folders[0].path, "Artist/Album")
        XCTAssertEqual(artist.folders[0].files.map(\.name), ["b.mp3", "a.mp3"])
    }

    func testTreeCollapsesIntermediateFolders() {
        let files = [
            file("user/Music/Artist/Album/song.mp3", size: 1, modified: 200),
            file("user/Music/Other/Album/other.mp3", size: 2, modified: 100),
            file("user/top.mp3", size: 3, modified: 300),
        ]
        let root = DownloadTree.build(from: files, sortOrder: .oldest)

        XCTAssertEqual(root.folders.map(\.name), ["user"])
        let user = root.folders[0]
        XCTAssertEqual(user.path, "user")
        XCTAssertEqual(user.folders.map(\.name), ["Album"])
        XCTAssertEqual(user.folders[0].path, "user/Album")
        XCTAssertEqual(user.folders[0].files.map(\.name), ["other.mp3", "song.mp3"])
        XCTAssertEqual(user.files.map(\.name), ["top.mp3"])
        XCTAssertEqual(user.fileCount, 3)
        XCTAssertEqual(user.allFiles.map(\.name).sorted(), ["other.mp3", "song.mp3", "top.mp3"])
    }

    func testLayoutPreferenceDefaultsToList() {
        let suite = "DownloadedFilesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.downloadLayout, .list)

        store.downloadLayout = .tree
        XCTAssertEqual(defaults.integer(forKey: "downloadLayout"), DownloadLayout.tree.rawValue)
        XCTAssertEqual(store.downloadLayout, .tree)
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
