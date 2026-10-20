import Foundation

enum TransferState: Equatable {
    case queued(place: UInt32)
    case negotiating
    case transferring
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .negotiating, .transferring: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    var description: String {
        switch self {
        case .queued(let place): return place > 0 ? "Queued (#\(place))" : "Queued by peer"
        case .negotiating: return "Waiting for peer slot"
        case .transferring: return "Downloading"
        case .completed: return "Completed"
        case .failed(let reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Which section of the Transfers screen is showing.
enum TransferTab: Int {
    case downloading
    case downloaded
    case uploading
}

/// A download we asked for, or an upload a peer asked us for.
struct Transfer: Identifiable, Equatable {
    let id: UInt32
    let username: String
    let filename: String
    var size: UInt64
    let isUpload: Bool
    var transferred: UInt64 = 0
    var state: TransferState = .queued(place: 0)
    var averageSpeed: UInt64 = 0

    var progress: Float {
        guard size > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Float(Double(transferred) / Double(size)))
    }

    var localFilename: String {
        filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? filename
    }

    /// The state in the direction of the transfer, for display in the Transfers screen.
    var stateDescription: String {
        state == .transferring && isUpload ? "Uploading" : state.description
    }

    /// Whether this is a download that ended in failure, as opposed to a failed upload.
    var isFailedDownload: Bool {
        guard !isUpload else { return false }
        if case .failed = state { return true }
        return false
    }
}

/// Outcome of asking to download a file.
enum DownloadStartResult: Equatable {
    case added(Transfer)
    case alreadyDownloading(Transfer)
    case alreadyDownloaded(Transfer)
}
