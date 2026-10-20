import Foundation

/// A regular file inside the downloads directory.
struct DownloadedFile: Equatable {
    let url: URL
    let relativePath: String
    let name: String
    let size: UInt64
    let modified: Date

    var folder: String {
        let components = relativePath.split(separator: "/").dropLast()
        return components.isEmpty ? "Downloads" : components.joined(separator: " / ")
    }
}

/// How completed downloads are presented.
enum DownloadLayout: Int {
    case list
    case tree
}

/// A folder in the completed downloads tree, including everything beneath it.
struct DownloadFolder {
    let name: String
    let path: String
    let folders: [DownloadFolder]
    let files: [DownloadedFile]

    var fileCount: Int {
        files.count + folders.reduce(0) { $0 + $1.fileCount }
    }

    var totalSize: UInt64 {
        files.reduce(0) { $0 + $1.size } + folders.reduce(0) { $0 + $1.totalSize }
    }

    var allFiles: [DownloadedFile] {
        files + folders.flatMap(\.allFiles)
    }
}

/// Ordering applied to the completed downloads list.
enum DownloadSortOrder: Int, CaseIterable {
    case oldest
    case newest
    case name

    var displayName: String {
        switch self {
        case .oldest: return "Oldest first"
        case .newest: return "Newest first"
        case .name: return "A-Z"
        }
    }

    func sorted(_ files: [DownloadedFile]) -> [DownloadedFile] {
        files.sorted { lhs, rhs in
            switch self {
            case .oldest:
                if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
            case .newest:
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }
}

/// Builds the completed downloads hierarchy from the flat file list.
enum DownloadTree {

    /// Groups files by the first and last directory only, so shared folder paths stay shallow.
    static func build(from files: [DownloadedFile], sortOrder: DownloadSortOrder) -> DownloadFolder {
        let root = Node()
        for file in files {
            let directories = file.relativePath.split(separator: "/").dropLast()
            guard let first = directories.first else {
                root.files.append(file)
                continue
            }

            var node = root.folder(named: String(first))
            if directories.count > 1, let last = directories.last {
                node = node.folder(named: String(last))
            }
            node.files.append(file)
        }
        return folder(named: "Downloads", path: "", node: root, sortOrder: sortOrder)
    }

    private static func folder(named name: String, path: String, node: Node,
                               sortOrder: DownloadSortOrder) -> DownloadFolder {
        let folders = node.folders
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { childName, childNode in
                let childPath = path.isEmpty ? childName : path + "/" + childName
                return folder(named: childName, path: childPath, node: childNode, sortOrder: sortOrder)
            }
        return DownloadFolder(name: name, path: path, folders: folders,
                              files: sortOrder.sorted(node.files))
    }

    private final class Node {
        var files: [DownloadedFile] = []
        var folders: [String: Node] = [:]

        func folder(named name: String) -> Node {
            if let folder = folders[name] { return folder }
            let folder = Node()
            folders[name] = folder
            return folder
        }
    }
}

/// Reads and removes files in the downloads folder. The folder is the source of truth for what
/// has been downloaded; no in-memory transfer history is involved.
enum DownloadedFiles {

    static func scan(in root: URL) -> [DownloadedFile] {
        let root = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let rootComponents = root.pathComponents
        var files: [DownloadedFile] = []

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }

            let fileURL = url.standardizedFileURL
            let components = fileURL.pathComponents.dropFirst(rootComponents.count)
            guard let name = components.last else { continue }

            files.append(DownloadedFile(
                url: fileURL,
                relativePath: components.joined(separator: "/"),
                name: name,
                size: UInt64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }

        return files
    }

    /// Deletes a file and any folders it leaves empty, without touching the downloads root.
    static func delete(_ url: URL, upTo root: URL) {
        try? FileManager.default.removeItem(at: url)
        removeEmptyParents(of: url, upTo: root)
    }

    /// Removes folders left empty by a file that was already moved elsewhere.
    static func pruneEmptyParents(of url: URL, upTo root: URL) {
        removeEmptyParents(of: url, upTo: root)
    }

    private static func removeEmptyParents(of url: URL, upTo root: URL) {
        var directory = url.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path

        while directory.path.hasPrefix(rootPath + "/") {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: directory)
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }
}
