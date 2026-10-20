import Combine
import XCTest
@testable import iSoulseek

/// A diagnostic probe that replays the reported download flows against the real network and
/// records exactly where a queued download goes missing: a single search-result download, then
/// a browse followed by single-file and whole-folder downloads. Skipped unless `SOULSEEK_LIVE=1`
/// with credentials, so it never runs in CI. Produces a machine-readable verdict at the end; the
/// transfer-level detail is in the unified log (subsystem `com.icraze.iSoulseek`) and in the
/// printed event timeline.
final class LiveDownloadProbeTests: XCTestCase {

    func testLiveSearchDownloadAndFolderDownloadProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULSEEK_LIVE"] == "1",
                          "Set SOULSEEK_LIVE=1 to run the live download probe")

        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["SOULSEEK_LIVE_USER"], !username.isEmpty,
              let password = environment["SOULSEEK_LIVE_PASS"], !password.isEmpty else {
            throw XCTSkip("SOULSEEK_LIVE_USER and SOULSEEK_LIVE_PASS must both be set")
        }

        let suiteName = "iSoulseekLiveProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let documents = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iSoulseekLiveProbe-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(defaults: defaults,
                                 keychainService: "com.icraze.liveprobe.\(UUID().uuidString)",
                                 documentsDirectory: documents)
        store.username = username
        store.password = password
        store.serverHost = "server.slsknet.org"
        store.serverPort = 2242
        store.preferredListeningPort = 0
        store.status = .online

        let client = SoulseekClient(store: store)
        defer {
            client.disconnect()
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: documents)
        }

        // Every transfer event, timestamped, matching what the Transfers screen subscribed to.
        let timeline = Locked<[String]>([])
        let start = Date()
        let stamp: () -> String = { String(format: "+%.1f", Date().timeIntervalSince(start)) }
        let transferCancellable = client.transferChanges.sink { transfer in
            timeline.mutate {
                $0.append("[\(stamp())] #\(transfer.id) \(transfer.username) \\\(transfer.localFilename) -> \(transfer.state.description) (\(transfer.transferred)/\(transfer.size))")
            }
        }
        defer { transferCancellable.cancel() }

        client.connect()
        let loggedIn = waitUntil(60) { client.stateChanges.value.isLoggedIn }
        guard loggedIn else {
            XCTFail("did not log in to the real server")
            return
        }
        print("PROBE login ok")

        // MARK: Flow 1 — download a single search result

        let searchResults = Locked<[SearchResult]>([])
        let resultCancellable = client.searchResults.sink { result in
            searchResults.mutate { $0.append(result) }
        }
        defer { resultCancellable.cancel() }
        _ = client.search("mp3")
        XCTAssertTrue(waitUntil(60) { searchResults.value.count >= 10 },
                      "too few search results arrived to probe with")

        let pick = searchResults.value.first {
            $0.file.size > 0 && $0.file.size < 15_000_000 && $0.isSlotFree
        } ?? searchResults.value.first { $0.file.size > 0 && $0.file.size < 15_000_000 }
        guard let pick else {
            XCTFail("no small downloadable search result arrived")
            return
        }
        print("PROBE picking search result: \(pick.username) \(pick.file.name) (\(pick.file.size) bytes, slotFree \(pick.isSlotFree))")

        let singleOutcome = Locked<String>("none")
        client.download(username: pick.username, filename: pick.file.name,
                        size: pick.file.size) { result in
            singleOutcome.value = String(describing: result)
        }
        let singleTerminated = waitUntil(120) { client.transfers().allSatisfy { !$0.state.isActive } }
        let singleEnd = client.transfers()
        print("PROBE single enqueue outcome: \(singleOutcome.value)")
        print("PROBE after single download: transfers()=\(singleEnd.map { "\($0.id):\(String(describing: $0.state))" }) terminatedOnTime=\(singleTerminated)")
        print("PROBE files on disk after single download scan: \(DownloadedFiles.scan(in: client.store.downloadsDirectory).count)")

        // MARK: Flow 2 — browse then download files and a whole folder (the reported flows)

        let browseUser = searchResults.value
            .first(where: { $0.username != pick.username })?.username ?? pick.username
        let browseFolders = Locked<[ShareFolder]>([])
        client.browse(username: browseUser) { result in
            switch result {
            case .success(let folders):
                browseFolders.value = folders
                print("PROBE browse \(browseUser): \(folders.count) folders, \(folders.reduce(0) { $0 + $1.files.count }) files")
            case .failure(let error):
                print("PROBE browse \(browseUser) FAILED: \(error)")
            }
        }
        let browsed = waitUntil(90) { !browseFolders.value.isEmpty }
        guard browsed else {
            XCTFail("browse of \(browseUser) produced no folders")
            return
        }
        let folders = browseFolders.value

        // The app's folder picker: every file in one folder, enqueued one by one.
        guard let folder = folders
            .filter({ !$0.files.isEmpty && $0.files.allSatisfy({ $0.size > 0 }) })
            .min(by: { $0.files.count < $1.files.count }) else {
            XCTFail("no folder with files came back from the browse")
            return
        }
        let folderFiles = Array(folder.files.prefix(5))
        print("PROBE downloading \(folderFiles.count)/\(folder.files.count) files of \(folder.path): \(folderFiles.map { "\($0.name) (\($0.size))" })")

        let outcomes = Locked<(added: Int, duplicates: Int, onDisk: Int, rejected: Int)>((0, 0, 0, 0))
        for file in folderFiles {
            client.download(username: browseUser, filename: folder.path + "\\" + file.name,
                            size: file.size) { outcome in
                outcomes.mutate { counts in
                    switch outcome {
                    case .added: counts.added += 1
                    case .alreadyDownloading: counts.duplicates += 1
                    case .alreadyDownloaded: counts.onDisk += 1
                    case nil: counts.rejected += 1
                    }
                }
            }
        }
        waitUntil(10) { outcomes.value.added + outcomes.value.duplicates
            + outcomes.value.onDisk + outcomes.value.rejected == folderFiles.count }
        let folderTerminated = waitUntil(180) { client.transfers().allSatisfy { !$0.state.isActive } }
        let folderEnd = client.transfers()
        let counts = outcomes.value
        print("PROBE folder enqueue outcomes: added=\(counts.added) duplicates=\(counts.duplicates) alreadyOnDisk=\(counts.onDisk) rejected=\(counts.rejected)")
        print("PROBE after folder download: transfers()=\(folderEnd.map { "\($0.id):\(String(describing: $0.state))" }) terminatedOnTime=\(folderTerminated)")
        print("PROBE files on disk after folder download scan: \(DownloadedFiles.scan(in: client.store.downloadsDirectory).count)")

        for line in timeline.value { print("PROBE.EVENTS \(line)") }
        let summary: ([Transfer]) -> String = { list in
            let completed = list.filter { $0.state == .completed }.count
            let failed = list.filter { if case .failed = $0.state { return true } else { return false } }.count
            let cancelled = list.filter { $0.state == .cancelled }.count
            return "completed=\(completed) failed=\(failed) cancelled=\(cancelled) other=\(list.count - completed - failed - cancelled)"
        }
        print("PROBE VERDICT single: \(summary(singleEnd))")
        print("PROBE VERDICT folder: added=\(counts.added) duplicates=\(counts.duplicates) alreadyOnDisk=\(counts.onDisk) rejected=\(counts.rejected) | \(summary(folderEnd.filter { !$0.isUpload }))")
    }
}
