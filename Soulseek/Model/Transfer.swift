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
        case .queued(let place): return place > 0 ? "Queued (#\(place))" : "Queued"
        case .negotiating: return "Waiting for peer"
        case .transferring: return "Downloading"
        case .completed: return "Completed"
        case .failed(let reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
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
}
