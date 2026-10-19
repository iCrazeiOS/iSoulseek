import Foundation

enum ServerCode: UInt32 {
    case login = 1
    case setWaitPort = 2
    case getPeerAddress = 3
    case watchUser = 5
    case unwatchUser = 6
    case getUserStatus = 7
    case connectToPeer = 18
    case fileSearch = 26
    case setStatus = 28
    case serverPing = 32
    case sharedFoldersFiles = 35
    case getUserStats = 36
    case relogged = 41
    case userSearch = 42
    case privilegedUsers = 69
    case haveNoParent = 71
    case parentMinSpeed = 83
    case parentSpeedRatio = 84
    case checkPrivileges = 92
    case acceptChildren = 100
    case possibleParents = 102
    case wishlistInterval = 104
    case sendUploadSpeed = 121
    case branchLevel = 126
    case branchRoot = 127
    case excludedSearchPhrases = 160
    case cantConnectToPeer = 1001
}

enum PeerCode: UInt32 {
    case getShareFileList = 4
    case sharedFileListResponse = 5
    case fileSearchResponse = 9
    case userInfoRequest = 15
    case userInfoResponse = 16
    case folderContentsRequest = 36
    case folderContentsResponse = 37
    case transferRequest = 40
    case transferResponse = 41
    case queueUpload = 43
    case placeInQueueResponse = 44
    case uploadFailed = 46
    case uploadDenied = 50
    case placeInQueueRequest = 51
}

/// The first message on a fresh inbound connection uses one-byte codes.
enum InitCode: UInt8 {
    case pierceFireWall = 0
    case peerInit = 1
}

enum ConnectionType: String {
    case peer = "P"
    case fileTransfer = "F"
    case distributed = "D"
}

enum TransferDirection: UInt32 {
    case download = 0
    case upload = 1
}

/// Transfer denial reasons understood by other clients.
enum TransferDenialReason {
    static let queued = "Queued"
    static let fileNotShared = "File not shared."
    static let banned = "Banned"
    static let cancelled = "Cancelled"
    static let complete = "Complete"
    static let tooManyFiles = "Too many files"
    static let tooManyMegabytes = "Too many megabytes"
    static let pendingShutdown = "Pending shutdown."
}
