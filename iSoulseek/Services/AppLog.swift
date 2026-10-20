import os

/// Central logging so download and connection problems can be traced with
/// `Console.app` or `log stream --predicate 'subsystem == "com.icraze.iSoulseek"'`.
/// Privacy note: usernames, ports and transfer outcomes are logged; passwords never are.
enum AppLog {

    static let subsystem = "com.icraze.iSoulseek"

    /// Server connection, login and session lifecycle.
    static let client = Logger(subsystem: subsystem, category: "client")

    /// Download and upload state machine (TransferManager).
    static let transfers = Logger(subsystem: subsystem, category: "transfers")

    /// Peer connections that carry searches, browse lists and file transfers.
    static let peers = Logger(subsystem: subsystem, category: "peers")

    /// User facing views react to the services above.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
