import Foundation

/// Keeps the most recent failed downloads so the Downloading tab can show why transfers vanished.
///
/// `TransferManager` drops a failed download from its list immediately, which made downloads that
/// failed to start disappear within the same moment the "queued" toast appeared. Failed transfers
/// recorded here stay on the Downloading tab (outside selection mode) until the Transfers screen
/// is left. Completed downloads are unaffected: they still move to the Downloaded tab.
struct FailedDownloadLog {

    /// How many failures are kept before the oldest is dropped.
    static let capacity = 25

    /// Most recent failures first.
    private(set) var transfers: [Transfer] = []

    /// Records a failed download, replacing any earlier entry for the same transfer.
    /// Returns true when the failure is new, so the caller can surface it once.
    @discardableResult
    mutating func record(_ transfer: Transfer) -> Bool {
        guard !transfer.isUpload else { return false }
        guard case .failed = transfer.state else { return false }

        let isNew = !transfers.contains { $0.id == transfer.id }
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
        } else {
            transfers.insert(transfer, at: 0)
        }
        if transfers.count > Self.capacity {
            transfers.removeLast(transfers.count - Self.capacity)
        }
        return isNew
    }

    /// Drops every recorded failure; called when the Transfers screen is left.
    mutating func clear() {
        transfers.removeAll()
    }
}
