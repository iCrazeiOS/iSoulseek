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
        let components = path.split(separator: "/")
        return DownloadedFile(
            url: URL(fileURLWithPath: "/" + path),
            name: String(components.last ?? ""),
            size: size,
            modified: Date(timeIntervalSince1970: modified),
            username: components.count > 1 ? String(components[0]) : nil,
            album: components.count > 2 ? String(components[components.count - 2]) : nil
        )
    }

    func testScanListsRegularFilesRecursively() throws {
        _ = try write("single.flac", bytes: 3)
        _ = try write("Artist/Album/song.mp3", bytes: 5)
        _ = try write(".hidden", bytes: 1)

        let files = DownloadedFiles.scan(in: root)
        XCTAssertEqual(files.map(\.name).sorted(), ["single.flac", "song.mp3"])

        let single = try XCTUnwrap(files.first { $0.name == "single.flac" })
        XCTAssertNil(single.username, "files at the downloads root have no uploader")
        XCTAssertNil(single.album)
        XCTAssertEqual(single.location, "Downloads")
        XCTAssertEqual(single.size, 3)

        let song = try XCTUnwrap(files.first { $0.name == "song.mp3" })
        XCTAssertEqual(song.username, "Artist")
        XCTAssertEqual(song.album, "Album")
        XCTAssertEqual(song.location, "Artist · Album")
        XCTAssertEqual(song.size, 5)
    }

    func testScanSkipsInProgressDownloads() throws {
        _ = try write(".partials/Artist/Album/song.mp3", bytes: 5)
        _ = try write("complete.flac", bytes: 3)

        XCTAssertEqual(DownloadedFiles.scan(in: root).map(\.name), ["complete.flac"])
    }

    func testSortOrders() {
        let newest = DownloadedFile(url: URL(fileURLWithPath: "/A.flac"), name: "A.flac", size: 1,
                                    modified: Date(timeIntervalSince1970: 300),
                                    username: nil, album: nil)
        let oldest = DownloadedFile(url: URL(fileURLWithPath: "/B.flac"), name: "B.flac", size: 2,
                                    modified: Date(timeIntervalSince1970: 100),
                                    username: nil, album: nil)
        let middle = DownloadedFile(url: URL(fileURLWithPath: "/C.flac"), name: "C.flac", size: 3,
                                    modified: Date(timeIntervalSince1970: 200),
                                    username: nil, album: nil)
        let files = [newest, oldest, middle]

        XCTAssertEqual(DownloadSortOrder.oldest.sorted(files).map(\.name),
                       ["B.flac", "C.flac", "A.flac"])
        XCTAssertEqual(DownloadSortOrder.newest.sorted(files).map(\.name),
                       ["A.flac", "C.flac", "B.flac"])
        XCTAssertEqual(DownloadSortOrder.name.sorted(files).map(\.name),
                       ["A.flac", "B.flac", "C.flac"])
    }

    func testTreeGroupsFilesByUsernameAndFolder() {
        let files = [
            file("alice/Music/Album/b.mp3", size: 2, modified: 100),
            file("alice/Music/Album/a.mp3", size: 3, modified: 300),
            file("alice/loose.mp3", size: 4, modified: 200),
            file("bob/z.flac", size: 5, modified: 400),
            file("root.flac", size: 6, modified: 500),
        ]
        let root = DownloadTree.build(from: files, sortOrder: .oldest)

        XCTAssertEqual(root.name, "Downloads")
        XCTAssertEqual(root.folders.map(\.name), ["alice", "bob"])
        XCTAssertEqual(root.files.map(\.name), ["root.flac"])
        XCTAssertEqual(root.fileCount, 5)
        XCTAssertEqual(root.totalSize, 20)

        let alice = root.folders[0]
        XCTAssertEqual(alice.path, "alice")
        XCTAssertEqual(alice.folders.map(\.name), ["Album"])
        XCTAssertEqual(alice.files.map(\.name), ["loose.mp3"])
        XCTAssertEqual(alice.folders[0].path, "alice/Album")
        XCTAssertEqual(alice.folders[0].files.map(\.name), ["b.mp3", "a.mp3"])

        let bob = root.folders[1]
        XCTAssertTrue(bob.folders.isEmpty)
        XCTAssertEqual(bob.files.map(\.name), ["z.flac"])
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

    func testTransferTabPreferenceRoundTrips() {
        let suite = "DownloadedFilesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let store = SessionStore(defaults: defaults, keychainService: "test.\(suite)")
        XCTAssertEqual(store.transferTab, .downloading)

        store.transferTab = .uploading
        XCTAssertEqual(defaults.integer(forKey: "transferTab"), TransferTab.uploading.rawValue)
        XCTAssertEqual(store.transferTab, .uploading)

        store.transferTab = .downloaded
        XCTAssertEqual(store.transferTab, .downloaded)
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
