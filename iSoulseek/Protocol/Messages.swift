import CryptoKit
import Foundation

enum MD5Hex {
    static func hash(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ShareCodec {

    /// Attribute order used when writing shares, matching what other clients emit.
    static let attributeOrder: [SearchAttribute] = [.bitrate, .duration, .vbr, .sampleRate, .bitDepth]

    static func encode(folder: ShareFolder) -> Data {
        var writer = ByteWriter()
        writer.write(string: folder.path)
        writer.write(UInt32(folder.files.count))
        for file in folder.files {
            writer.write(raw: encode(file: file, name: file.name))
        }
        return writer.data
    }

    static func encode(folders: [ShareFolder]) -> Data {
        var writer = ByteWriter()
        writer.write(UInt32(folders.count))
        for folder in folders {
            writer.write(string: folder.path)
            writer.write(UInt32(folder.files.count))
            for file in folder.files {
                writer.write(raw: encode(file: file, name: file.name))
            }
        }
        return writer.data
    }

    static func encode(file: ShareFile, name: String) -> Data {
        var writer = ByteWriter()
        writer.write(UInt8(1))
        writer.write(string: name)
        writer.write(file.size)
        writer.write(string: file.fileExtension)

        let present = attributeOrder.compactMap { attribute -> (UInt32, UInt32)? in
            guard let value = file.attributes[attribute.rawValue] else { return nil }
            return (attribute.rawValue, value)
        }
        writer.write(UInt32(present.count))
        for (code, value) in present {
            writer.write(code)
            writer.write(value)
        }
        return writer.data
    }

    static func decodeFolders(_ reader: inout ByteReader) throws -> [ShareFolder] {
        let count = try reader.readCount(minimumBytesPerItem: 8)
        var folders: [ShareFolder] = []
        folders.reserveCapacity(count)
        for _ in 0..<count {
            let path = try reader.readString().replacingOccurrences(of: "/", with: "\\")
            let fileCount = try reader.readCount(minimumBytesPerItem: 14)
            var files: [ShareFile] = []
            files.reserveCapacity(fileCount)
            for _ in 0..<fileCount {
                try reader.skip(1) // record code, always 1 for files
                let name = try reader.readString().replacingOccurrences(of: "/", with: "\\")
                let size = try readFileSize(&reader)
                let fileExtension = try reader.readString()
                let attributes = try decodeAttributes(&reader)
                files.append(ShareFile(name: name, size: size, fileExtension: fileExtension, attributes: attributes))
            }
            folders.append(ShareFolder(path: path, files: files))
        }
        return folders
    }

    static func decodeAttributes(_ reader: inout ByteReader) throws -> [UInt32: UInt32] {
        let count = try reader.readCount(minimumBytesPerItem: 8)
        guard count > 0 else { return [:] }
        var attributes: [UInt32: UInt32] = [:]
        attributes.reserveCapacity(count)
        for _ in 0..<count {
            let code = try reader.readUInt32()
            attributes[code] = try reader.readUInt32()
        }
        return attributes
    }

    /// Works around the legacy client bug that reports files over 2 GiB as ~16 EiB.
    static func readFileSize(_ reader: inout ByteReader) throws -> UInt64 {
        let bytes = try reader.readBytes(8)
        let base = bytes.startIndex
        if bytes[base + 7] == 0xFF {
            var value: UInt32 = 0
            for index in stride(from: 3, through: 0, by: -1) {
                value = (value << 8) | UInt32(bytes[base + index])
            }
            return UInt64(value)
        }
        var value: UInt64 = 0
        for index in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[base + index])
        }
        return value
    }
}

// MARK: - Server

struct LoginResult {
    var isSuccess: Bool
    var greeting: String
    var ownIP: String
    var isSupporter: Bool
    var rejectionReason: String
    var rejectionDetail: String
}

struct PeerAddress {
    var username: String
    var ip: String
    var port: UInt16
}

struct ConnectToPeerInfo {
    var username: String
    var connectionType: String
    var ip: String
    var port: UInt16
    var token: UInt32
    var isPrivileged: Bool
}

enum ServerRequest {
    case login(username: String, password: String, major: UInt32, minor: UInt32)
    case setWaitPort(UInt16)
    case getPeerAddress(String)
    case watchUser(String)
    case connectToPeer(token: UInt32, username: String, type: ConnectionType)
    case fileSearch(token: UInt32, query: String)
    case setStatus(UserStatus)
    case serverPing
    case checkPrivileges
    case sharedFoldersFiles(directories: UInt32, files: UInt32)
    case getUserStats(String)
    case haveNoParent(Bool)
    case sendUploadSpeed(UInt32)
    case cantConnectToPeer(token: UInt32, username: String)

    var code: ServerCode {
        switch self {
        case .login: return .login
        case .setWaitPort: return .setWaitPort
        case .getPeerAddress: return .getPeerAddress
        case .watchUser: return .watchUser
        case .connectToPeer: return .connectToPeer
        case .fileSearch: return .fileSearch
        case .setStatus: return .setStatus
        case .serverPing: return .serverPing
        case .checkPrivileges: return .checkPrivileges
        case .sharedFoldersFiles: return .sharedFoldersFiles
        case .getUserStats: return .getUserStats
        case .haveNoParent: return .haveNoParent
        case .sendUploadSpeed: return .sendUploadSpeed
        case .cantConnectToPeer: return .cantConnectToPeer
        }
    }

    func payload() -> Data {
        var writer = ByteWriter()
        switch self {
        case .login(let username, let password, let major, let minor):
            writer.write(string: username)
            writer.write(string: password)
            writer.write(major)
            writer.write(string: MD5Hex.hash(username + password))
            writer.write(minor)
        case .setWaitPort(let port):
            writer.write(UInt32(port))
        case .getPeerAddress(let username), .watchUser(let username), .getUserStats(let username):
            writer.write(string: username)
        case .connectToPeer(let token, let username, let type):
            writer.write(token)
            writer.write(string: username)
            writer.write(string: type.rawValue)
        case .fileSearch(let token, let query):
            writer.write(token)
            writer.write(string: query)
        case .setStatus(let status):
            writer.write(status.rawValue)
        case .serverPing:
            break
        case .checkPrivileges:
            break
        case .sharedFoldersFiles(let directories, let files):
            writer.write(directories)
            writer.write(files)
        case .haveNoParent(let noParent):
            writer.write(noParent)
        case .sendUploadSpeed(let speed):
            writer.write(speed)
        case .cantConnectToPeer(let token, let username):
            writer.write(token)
            writer.write(string: username)
        }
        return writer.data
    }
}

enum ServerMessage {
    case login(LoginResult)
    case peerAddress(PeerAddress)
    case connectToPeer(ConnectToPeerInfo)
    case userStatus(UserStatusInfo)
    case userStats(username: String, averageSpeed: UInt32, uploads: UInt32, files: UInt32, directories: UInt32)
    case privilegesRemaining(UInt32)
    case excludedSearchPhrases([String])
    case parentSpeed(ratio: UInt32)
    case relogged
    case ping
    case unhandled(code: UInt32)

    static func decode(code: UInt32, payload: Data) throws -> ServerMessage {
        var reader = ByteReader(payload)
        switch ServerCode(rawValue: code) {
        case .login:
            let isSuccess = try reader.readBool()
            guard isSuccess else {
                let reason = try reader.readString()
                let detail = reader.isAtEnd ? "" : (try reader.readString())
                return .login(LoginResult(isSuccess: false, greeting: "", ownIP: "",
                                          isSupporter: false, rejectionReason: reason,
                                          rejectionDetail: detail))
            }
            let greeting = try reader.readString()
            let ownIP = try reader.readIP()
            _ = try reader.readString() // md5 of the password we sent
            let isSupporter = try reader.readBool()
            return .login(LoginResult(isSuccess: true, greeting: greeting, ownIP: ownIP,
                                      isSupporter: isSupporter, rejectionReason: "",
                                      rejectionDetail: ""))

        case .getPeerAddress:
            let username = try reader.readString()
            let ip = try reader.readIP()
            let port = UInt16(truncatingIfNeeded: try reader.readUInt32())
            return .peerAddress(PeerAddress(username: username, ip: ip, port: port))

        case .connectToPeer:
            let username = try reader.readString()
            let type = try reader.readString()
            let ip = try reader.readIP()
            let port = UInt16(truncatingIfNeeded: try reader.readUInt32())
            let token = try reader.readUInt32()
            let isPrivileged = reader.isAtEnd ? false : (try reader.readBool())
            return .connectToPeer(ConnectToPeerInfo(username: username, connectionType: type,
                                                    ip: ip, port: port, token: token,
                                                    isPrivileged: isPrivileged))

        case .getUserStatus:
            let username = try reader.readString()
            let raw = try reader.readUInt32()
            let isPrivileged = reader.isAtEnd ? false : (try reader.readBool())
            return .userStatus(UserStatusInfo(username: username,
                                              status: UserStatus(rawValue: raw) ?? .offline,
                                              isPrivileged: isPrivileged))

        case .getUserStats:
            let username = try reader.readString()
            let averageSpeed = try reader.readUInt32()
            let uploads = try reader.readUInt32()
            _ = try reader.readUInt32()
            let files = try reader.readUInt32()
            let directories = try reader.readUInt32()
            return .userStats(username: username, averageSpeed: averageSpeed, uploads: uploads,
                              files: files, directories: directories)

        case .checkPrivileges:
            return .privilegesRemaining(try reader.readUInt32())

        case .excludedSearchPhrases:
            let count = try reader.readCount(minimumBytesPerItem: 4)
            var phrases: [String] = []
            phrases.reserveCapacity(count)
            for _ in 0..<count {
                phrases.append(try reader.readString())
            }
            return .excludedSearchPhrases(phrases)

        case .parentSpeedRatio:
            return .parentSpeed(ratio: try reader.readUInt32())

        case .relogged:
            return .relogged

        case .serverPing:
            return .ping

        default:
            return .unhandled(code: code)
        }
    }
}

// MARK: - Peer

struct FileSearchResults {
    var username: String
    var token: UInt32
    var files: [ShareFile]
    var isSlotFree: Bool
    var averageSpeed: UInt32
    var queueLength: UInt32
}

struct TransferRequestInfo {
    var direction: TransferDirection
    var token: UInt32
    var filename: String
    var size: UInt64?
}

struct TransferResponseInfo {
    var token: UInt32
    var isAllowed: Bool
    var size: UInt64?
    var reason: String?
}

enum InitMessage {
    case pierceFireWall(token: UInt32)
    case peerInit(username: String, connectionType: String, token: UInt32)

    static func decode(code: UInt8, payload: Data) throws -> InitMessage {
        var reader = ByteReader(payload)
        switch InitCode(rawValue: code) {
        case .pierceFireWall:
            return .pierceFireWall(token: try reader.readUInt32())
        case .peerInit:
            let username = try reader.readString()
            let connectionType = try reader.readString()
            let token = reader.isAtEnd ? 0 : (try reader.readUInt32())
            return .peerInit(username: username, connectionType: connectionType, token: token)
        case .none:
            throw ProtocolError.unsupportedMessage("init code \(code)")
        }
    }
}

enum PeerRequest {
    case pierceFireWall(token: UInt32)
    case peerInit(username: String, connectionType: ConnectionType, token: UInt32)
    case getShareFileList
    case sharedFileList([ShareFolder])
    case userInfo(UserInfo)
    case folderContentsRequest(token: UInt32, folder: String)
    case folderContentsResponse(token: UInt32, folder: String, folders: [ShareFolder])
    case fileSearchResponse(FileSearchResults)
    case queueUpload(filename: String)
    case transferRequest(TransferRequestInfo)
    case transferResponse(TransferResponseInfo)
    case uploadDenied(filename: String, reason: String)
    case placeInQueueRequest(filename: String)
    case placeInQueueResponse(filename: String, place: UInt32)

    var usesInitChannel: Bool {
        switch self {
        case .pierceFireWall, .peerInit: return true
        default: return false
        }
    }

    var code: UInt32 {
        switch self {
        case .pierceFireWall: return UInt32(InitCode.pierceFireWall.rawValue)
        case .peerInit: return UInt32(InitCode.peerInit.rawValue)
        case .getShareFileList: return PeerCode.getShareFileList.rawValue
        case .sharedFileList: return PeerCode.sharedFileListResponse.rawValue
        case .userInfo: return PeerCode.userInfoResponse.rawValue
        case .folderContentsRequest: return PeerCode.folderContentsRequest.rawValue
        case .folderContentsResponse: return PeerCode.folderContentsResponse.rawValue
        case .fileSearchResponse: return PeerCode.fileSearchResponse.rawValue
        case .queueUpload: return PeerCode.queueUpload.rawValue
        case .transferRequest: return PeerCode.transferRequest.rawValue
        case .transferResponse: return PeerCode.transferResponse.rawValue
        case .placeInQueueResponse: return PeerCode.placeInQueueResponse.rawValue
        case .placeInQueueRequest: return PeerCode.placeInQueueRequest.rawValue
        case .uploadDenied: return PeerCode.uploadDenied.rawValue
        }
    }

    func payload() throws -> Data {
        var writer = ByteWriter()
        switch self {
        case .pierceFireWall(let token):
            writer.write(token)
        case .peerInit(let username, let type, let token):
            writer.write(string: username)
            writer.write(string: type.rawValue)
            writer.write(token)
        case .getShareFileList:
            break
        case .sharedFileList(let folders):
            var body = ByteWriter()
            body.write(raw: ShareCodec.encode(folders: folders))
            body.write(UInt32(0)) // trailing field official clients always send as zero
            writer.write(raw: try Zlib.compress(body.data))
        case .userInfo(let info):
            writer.write(string: info.description)
            writer.write(info.hasPicture)
            if let picture = info.picture, info.hasPicture {
                writer.write(raw: picture)
            }
            writer.write(info.totalUploads)
            writer.write(info.queueSize)
            writer.write(info.slotsFree)
        case .folderContentsRequest(let token, let folder):
            writer.write(token)
            writer.write(string: folder)
        case .folderContentsResponse(let token, let folder, let folders):
            var body = ByteWriter()
            body.write(token)
            body.write(string: folder)
            body.write(raw: ShareCodec.encode(folders: folders))
            writer.write(raw: try Zlib.compress(body.data))
        case .fileSearchResponse(let results):
            var body = ByteWriter()
            body.write(string: results.username)
            body.write(results.token)
            body.write(UInt32(results.files.count))
            for file in results.files {
                body.write(raw: ShareCodec.encode(file: file, name: file.name))
            }
            body.write(results.isSlotFree)
            body.write(results.averageSpeed)
            body.write(results.queueLength)
            body.write(UInt32(0))
            writer.write(raw: try Zlib.compress(body.data))
        case .queueUpload(let filename):
            writer.write(string: filename)
        case .transferRequest(let request):
            writer.write(request.direction.rawValue)
            writer.write(request.token)
            writer.write(string: request.filename)
            if request.direction == .upload {
                writer.write(request.size ?? 0)
            }
        case .transferResponse(let response):
            writer.write(response.token)
            writer.write(response.isAllowed)
            if response.isAllowed {
                if let size = response.size {
                    writer.write(size)
                }
            } else {
                writer.write(string: response.reason ?? TransferDenialReason.queued)
            }
        case .placeInQueueRequest(let filename):
            writer.write(string: filename)
        case .placeInQueueResponse(let filename, let place):
            writer.write(string: filename)
            writer.write(place)
        case .uploadDenied(let filename, let reason):
            writer.write(string: filename)
            writer.write(string: reason)
        }
        return writer.data
    }
}

enum PeerMessage {

    /// Caps that bound a compressed payload before it is trusted (zlib-bomb defence).
    static let maximumSearchResponseBytes = 8 << 20
    static let maximumBrowseResponseBytes = 64 << 20

    case getShareFileList
    case sharedFileList([ShareFolder])
    case userInfoRequest
    case userInfoResponse(UserInfo)
    case folderContentsRequest(token: UInt32, folder: String)
    case folderContentsResponse(token: UInt32, folder: String, folders: [ShareFolder])
    case fileSearchResponse(FileSearchResults)
    case queueUpload(filename: String)
    case placeInQueueRequest(filename: String)
    case placeInQueueResponse(filename: String, place: UInt32)
    case transferRequest(TransferRequestInfo)
    case transferResponse(TransferResponseInfo)
    case uploadFailed(filename: String)
    case uploadDenied(filename: String, reason: String)
    case unhandled(code: UInt32)

    static func decode(code: UInt32, payload: Data) throws -> PeerMessage {
        switch PeerCode(rawValue: code) {
        case .sharedFileListResponse:
            var reader = ByteReader(try Zlib.decompress(payload, limit: maximumBrowseResponseBytes))
            let folders = try ShareCodec.decodeFolders(&reader)
            return .sharedFileList(folders)

        case .folderContentsResponse:
            var reader = ByteReader(try Zlib.decompress(payload, limit: maximumBrowseResponseBytes))
            let token = try reader.readUInt32()
            let folder = try reader.readString()
            let folders = try ShareCodec.decodeFolders(&reader)
            return .folderContentsResponse(token: token, folder: folder, folders: folders)

        case .fileSearchResponse:
            var reader = ByteReader(try Zlib.decompress(payload, limit: maximumSearchResponseBytes))
            let username = try reader.readString()
            let token = try reader.readUInt32()
            let count = try reader.readCount(minimumBytesPerItem: 14)
            var files: [ShareFile] = []
            files.reserveCapacity(count)
            for _ in 0..<count {
                try reader.skip(1)
                let name = try reader.readString().replacingOccurrences(of: "/", with: "\\")
                let size = try ShareCodec.readFileSize(&reader)
                let fileExtension = try reader.readString()
                let attributes = try ShareCodec.decodeAttributes(&reader)
                files.append(ShareFile(name: name, size: size, fileExtension: fileExtension,
                                       attributes: attributes))
            }
            let isSlotFree = reader.isAtEnd ? false : (try reader.readBool())
            let averageSpeed = reader.isAtEnd ? 0 : (try reader.readUInt32())
            let queueLength = reader.isAtEnd ? 0 : (try reader.readUInt32())
            return .fileSearchResponse(FileSearchResults(username: username, token: token,
                                                         files: files, isSlotFree: isSlotFree,
                                                         averageSpeed: averageSpeed,
                                                         queueLength: queueLength))

        case .getShareFileList:
            return .getShareFileList

        case .userInfoRequest:
            return .userInfoRequest

        case .userInfoResponse:
            var reader = ByteReader(payload)
            let description = try reader.readString()
            let hasPicture = try reader.readBool()
            var picture: Data?
            if hasPicture {
                picture = try reader.readBytes(reader.remaining)
            }
            let totalUploads = reader.isAtEnd ? 0 : (try reader.readUInt32())
            let queueSize = reader.isAtEnd ? 0 : (try reader.readUInt32())
            let slotsFree = reader.isAtEnd ? false : (try reader.readBool())
            return .userInfoResponse(UserInfo(description: description, hasPicture: hasPicture,
                                              picture: picture, totalUploads: totalUploads,
                                              queueSize: queueSize, slotsFree: slotsFree))

        case .folderContentsRequest:
            var reader = ByteReader(payload)
            let token = try reader.readUInt32()
            let folder = try reader.readString()
            return .folderContentsRequest(token: token, folder: folder)

        case .queueUpload:
            var reader = ByteReader(payload)
            return .queueUpload(filename: try reader.readString())

        case .placeInQueueRequest:
            var reader = ByteReader(payload)
            return .placeInQueueRequest(filename: try reader.readString())

        case .placeInQueueResponse:
            var reader = ByteReader(payload)
            let filename = try reader.readString()
            let place = try reader.readUInt32()
            return .placeInQueueResponse(filename: filename, place: place)

        case .uploadFailed:
            var reader = ByteReader(payload)
            return .uploadFailed(filename: try reader.readString())

        case .uploadDenied:
            var reader = ByteReader(payload)
            let filename = try reader.readString()
            let reason = reader.isAtEnd ? "" : (try reader.readString())
            return .uploadDenied(filename: filename, reason: reason)

        case .transferRequest:
            var reader = ByteReader(payload)
            let rawDirection = try reader.readUInt32()
            let direction = TransferDirection(rawValue: rawDirection) ?? .download
            let token = try reader.readUInt32()
            let filename = try reader.readString()
            let size: UInt64? = (direction == .upload && !reader.isAtEnd) ? try reader.readUInt64() : nil
            return .transferRequest(TransferRequestInfo(direction: direction, token: token,
                                                        filename: filename, size: size))

        case .transferResponse:
            var reader = ByteReader(payload)
            let token = try reader.readUInt32()
            let isAllowed = try reader.readBool()
            if isAllowed {
                let size: UInt64? = reader.isAtEnd ? nil : try reader.readUInt64()
                return .transferResponse(TransferResponseInfo(token: token, isAllowed: true,
                                                              size: size, reason: nil))
            }
            let reason = reader.isAtEnd ? nil : try reader.readString()
            return .transferResponse(TransferResponseInfo(token: token, isAllowed: false,
                                                          size: nil, reason: reason))

        case .none:
            return .unhandled(code: code)
        }
    }
}
