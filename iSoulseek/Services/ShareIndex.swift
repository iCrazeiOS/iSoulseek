import Foundation

/// A read-only snapshot of the shared folder, safe to hand between queues.
struct ShareSnapshot {

    static let empty = ShareSnapshot(folders: [], fileCount: 0, urls: [:])

    let folders: [ShareFolder]
    let fileCount: Int
    private let urls: [String: URL]

    init(folders: [ShareFolder], fileCount: Int, urls: [String: URL]) {
        self.folders = folders
        self.fileCount = fileCount
        self.urls = urls
    }

    var folderCount: Int { folders.count }

    /// Virtual paths are matched case-insensitively; the protocol has no canonical casing.
    func localURL(forVirtualPath path: String) -> URL? {
        urls[Self.normalise(path)]
    }

    /// The folder with exactly this path, used to answer incremental browse requests.
    func folders(matching folder: String) -> [ShareFolder] {
        let wanted = Self.normalise(folder)
        return folders.filter { Self.normalise($0.path) == wanted }
    }

    func contains(virtualPath: String) -> Bool {
        urls[Self.normalise(virtualPath)] != nil
    }

    private static func normalise(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\").lowercased()
    }
}

enum ShareIndex {

    static let rootFolderName = "Shared"
    static let maximumFiles = 100_000

    /// Walks `root` on a background queue and calls back with an immutable snapshot.
    static func scan(root: URL, queue: DispatchQueue, completion: @escaping (ShareSnapshot) -> Void) {
        queue.async {
            let snapshot = build(root: root)
            completion(snapshot)
        }
    }

    private static func build(root: URL) -> ShareSnapshot {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

        var folders: [ShareFolder] = []
        var urls: [String: URL] = [:]
        var stack: [(url: URL, path: String)] = [(root, rootFolderName)]
        var fileCount = 0

        while let current = stack.popLast() {
            let entries = (try? fileManager.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []

            var files: [ShareFile] = []

            for entry in entries {
                guard fileCount < maximumFiles else { break }
                guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
                // Never follow links: they could point outside the sandbox.
                if values.isSymbolicLink == true { continue }

                let name = entry.lastPathComponent
                guard isSafeComponent(name) else { continue }

                if values.isDirectory == true {
                    stack.append((entry, current.path + "\\" + name))
                } else if values.isRegularFile == true {
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    files.append(ShareFile(name: name, size: size, fileExtension: entry.pathExtension))
                    urls[(current.path + "\\" + name).lowercased()] = entry
                    fileCount += 1
                }
            }

            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            folders.append(ShareFolder(path: current.path, files: files))
        }

        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return ShareSnapshot(folders: folders, fileCount: fileCount, urls: urls)
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("\\"), !name.contains("/") else { return false }
        return name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}
