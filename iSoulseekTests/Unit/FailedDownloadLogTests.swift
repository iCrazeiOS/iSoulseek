import XCTest
@testable import iSoulseek

/// Failure surfacing on the Downloading tab.
final class FailedDownloadLogTests: XCTestCase {

    private func failedTransfer(_ id: UInt32, reason: String = "Peer died") -> Transfer {
        var transfer = Transfer(id: id, username: "alice", filename: "Music\\song.flac",
                                size: 100, isUpload: false)
        transfer.state = .failed(reason)
        return transfer
    }

    func testRecordKeepsFailedDownloadsNewestFirst() {
        var log = FailedDownloadLog()
        XCTAssertTrue(log.record(failedTransfer(1)), "a new failure must be reported as new")
        XCTAssertTrue(log.record(failedTransfer(2)), "a second failure of a different transfer is new too")

        XCTAssertEqual(log.transfers.map(\.id), [2, 1])
    }

    /// The same transfer may report its failure more than once; replacing the entry must not
    /// surface the failure (and its toast) again.
    func testRecordingSameTransferAgainReplacesWithoutReportingNew() {
        var log = FailedDownloadLog()
        XCTAssertTrue(log.record(failedTransfer(1, reason: "First")))
        XCTAssertFalse(log.record(failedTransfer(1, reason: "Second")),
                       "a repeat of a known failure is not new")

        XCTAssertEqual(log.transfers.map(\.state), [.failed("Second")],
                       "the row must show the most recent reason")
    }

    func testCompletedDownloadsAndUploadsAreNotRecorded() {
        var log = FailedDownloadLog()

        var completed = Transfer(id: 1, username: "alice", filename: "a.flac",
                                 size: 10, isUpload: false)
        completed.state = .completed
        XCTAssertFalse(log.record(completed), "completed downloads stay in the Downloaded tab")

        var cancelled = Transfer(id: 2, username: "alice", filename: "b.flac",
                                 size: 10, isUpload: false)
        cancelled.state = .cancelled
        XCTAssertFalse(log.record(cancelled))

        var uploadFailure = Transfer(id: 3, username: "alice", filename: "c.flac",
                                     size: 10, isUpload: true)
        uploadFailure.state = .failed("Peer died")
        XCTAssertFalse(log.record(uploadFailure), "upload failures belong to the Uploading tab")

        XCTAssertTrue(log.transfers.isEmpty)
    }

    func testLogKeepsOnlyTheMostRecentFailures() {
        var log = FailedDownloadLog()
        let lastID = FailedDownloadLog.capacity + 10
        for id in UInt32(1)...UInt32(lastID) {
            log.record(failedTransfer(id))
        }

        XCTAssertEqual(log.transfers.count, FailedDownloadLog.capacity)
        XCTAssertEqual(log.transfers.first?.id, UInt32(lastID))
        XCTAssertEqual(log.transfers.last?.id, UInt32(lastID - FailedDownloadLog.capacity + 1),
                       "the oldest failures are dropped first")
    }

    /// Queueing the same file again must retire its stale failure row, so the live transfer
    /// replaces it instead of both showing on the Downloading tab.
    func testDropRetiresAFailureWhenItsFileIsQueuedAgain() {
        var log = FailedDownloadLog()
        log.record(failedTransfer(1, reason: "Could not connect to alice"))
        var other = failedTransfer(2)
        other = Transfer(id: 2, username: "BOB", filename: "Music\\other.flac",
                         size: 100, isUpload: false)
        other.state = .failed("Peer died")
        log.record(other)

        log.drop(username: "ALICE", filename: "music\\SONG.flac")

        XCTAssertEqual(log.transfers.map(\.id), [2],
                       "matching is case-insensitive; other failures stay")
    }

    func testRemoveReturnsTheDismissedFailures() {
        var log = FailedDownloadLog()
        log.record(failedTransfer(1))
        log.record(failedTransfer(2))
        log.record(failedTransfer(3))

        let removed = log.remove(ids: [1, 3])

        XCTAssertEqual(Set(removed.map(\.id)), [1, 3])
        XCTAssertEqual(log.transfers.map(\.id), [2])
        XCTAssertTrue(log.remove(ids: [99]).isEmpty, "unknown ids are a no-op")
    }
}
