import XCTest
@testable import Soulseek

final class ShareIndexTests: XCTestCase {

    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShareIndexTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shared", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("album1"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("album2"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        try Data(repeating: 0x41, count: 100).write(to: root.appendingPathComponent("album1/song.mp3"))
        try Data(repeating: 0x42, count: 50).write(to: root.appendingPathComponent("album1/notes.txt"))
        try Data(repeating: 0x43, count: 200).write(to: root.appendingPathComponent("album2/other.flac"))
        try Data(repeating: 0x44, count: 10).write(to: root.appendingPathComponent(".hidden.mp3"))
        try Data(repeating: 0x45, count: 10).write(to: outside.appendingPathComponent("secret.bin"))

        // A symlink that must never be followed.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                                   withDestinationURL: outside)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func scan() -> ShareSnapshot {
        let queue = DispatchQueue(label: "share-index-test")
        let box = Locked<ShareSnapshot?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        ShareIndex.scan(root: root, queue: queue) { snapshot in
            box.value = snapshot
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)
        return box.value ?? .empty
    }

    func testScanCountsFoldersAndFiles() {
        let snapshot = scan()
        // Root ("Shared") plus album1 and album2.
        XCTAssertEqual(snapshot.folderCount, 3)
        XCTAssertEqual(snapshot.fileCount, 3)

        let paths = Set(snapshot.folders.map(\.path))
        XCTAssertEqual(paths, ["Shared", "Shared\\album1", "Shared\\album2"])
    }

    func testScanSkipsHiddenFilesAndSymlinks() {
        let snapshot = scan()
        XCTAssertNil(snapshot.localURL(forVirtualPath: "Shared\\.hidden.mp3"))
        XCTAssertNil(snapshot.localURL(forVirtualPath: "Shared\\escape\\secret.bin"))
        XCTAssertFalse(snapshot.folders.contains { $0.path.contains("escape") })
        XCTAssertFalse(snapshot.contains(virtualPath: "Shared\\album1\\.hidden.mp3"))
    }

    func testLocalURLResolvesSharedFiles() {
        let snapshot = scan()
        let url = snapshot.localURL(forVirtualPath: "Shared\\album1\\song.mp3")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "song.mp3")
        // Backslashes and forward slashes are interchangeable, and matching is case-insensitive.
        XCTAssertNotNil(snapshot.localURL(forVirtualPath: "shared/album1/SONG.MP3"))
    }

    func testFoldersMatchingReturnsExactFolder() {
        let snapshot = scan()
        let album1 = snapshot.folders(matching: "Shared\\album1")
        XCTAssertEqual(album1.count, 1)
        XCTAssertEqual(album1[0].files.map(\.name), ["notes.txt", "song.mp3"])

        XCTAssertTrue(snapshot.folders(matching: "Shared\\nope").isEmpty)
    }

    func testFileSizesAreCaptured() {
        let snapshot = scan()
        guard let url = snapshot.localURL(forVirtualPath: "Shared\\album2\\other.flac") else {
            return XCTFail("missing file")
        }
        let folder = snapshot.folders.first { $0.path == "Shared\\album2" }
        XCTAssertEqual(folder?.files.first?.size, 200)
        XCTAssertEqual((try? Data(contentsOf: url))?.count, 200)
    }

    func testEmptyRootProducesOnlyRootFolder() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let queue = DispatchQueue(label: "share-index-empty")
        let box = Locked<ShareSnapshot?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        ShareIndex.scan(root: empty, queue: queue) { box.value = $0; semaphore.signal() }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)

        let snapshot = box.value ?? .empty
        XCTAssertEqual(snapshot.folderCount, 1)
        XCTAssertEqual(snapshot.fileCount, 0)
        XCTAssertEqual(snapshot.folders.first?.path, ShareIndex.rootFolderName)
    }
}
