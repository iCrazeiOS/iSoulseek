# Soulseek wire protocol reference

Reference for the subset of the Soulseek protocol this client implements. Compiled from the
Nicotine+, Soulseek.NET (slskd) and aioslsk implementations plus the community `SLSKPROTOCOL`
document. Facts only; no third-party code is copied into this repository.

## 1. Primitives

- **All integers little-endian.**
- `bool` = 1 byte, `0`/non-zero.
- `string` = `u32 byteCount` + `byteCount` bytes of UTF-8 (decoders fall back to Latin-1). No NUL.
- `ip` = `u32`, i.e. the dotted quad packed little-endian: `1.2.3.4` → bytes `04 03 02 01`.
- Paths use `\` as the separator and are relative to a share root ("virtual" paths).

## 2. Framing (depends on the channel)

| Channel | Header | `length` value |
|---|---|---|
| Server | `u32 length` + `u32 code` | `4 + payload.count` |
| Peer | `u32 length` + `u32 code` | `4 + payload.count` |
| PeerInit / Distributed | `u32 length` + `u8 code` | `1 + payload.count` |
| File transfer | none | — |

`length` **excludes** its own 4 bytes. So a frame is `4 + length` bytes on the wire, and a
server/peer frame header needs 8 bytes before the payload can be sized (5 for peer-init).

A TCP read may split or coalesce frames arbitrarily; decoding must be incremental.

## 3. Server connection

Default endpoint `server.slsknet.org:2242`. Client version used here: major `177`, minor `1`.

### Login (code 1)

Send:

```
string  username
string  password
u32     major
string  md5hex(username + password)   // lowercase hex
u32     minor
```

Reply:

```
bool   success
       // success
string greet
u32    ownIp
string md5hex(password)
bool   isSupporter
       // failure
string reason          // "INVALIDUSERNAME", "EMPTYPASSWORD", "INVALIDPASS",
                       // "INVALIDVERSION", "SVRFULL", "SVRPRIVATE"
string detail          // optional
```

A `success` field of `0` means the server closed the connection (ban) before sending anything.

### Order used by this client

1. Connect TCP, start the listener.
2. `Login` → on success: `HaveNoParent(true)`, `CheckPrivileges`, `SetStatus(2 or 1)`,
   `WatchUser(self)`, `SharedFoldersFiles(dirCount, fileCount)`.
3. `SetWaitPort(listenPort)`.
4. `ServerPing` at most once a minute (TCP keepalive is also enabled).

### Messages used

| Code | Name | Payload |
|---|---|---|
| 1 | Login | above |
| 2 | SetWaitPort | `u32 port` |
| 3 | GetPeerAddress | send `string user`; recv `string user, u32 ip, u32 port, u32 obfType, u16 obfPort` |
| 5 / 6 | WatchUser / UnwatchUser | `string user` |
| 7 | GetUserStatus | send `string user`; recv `string user, u32 status, bool privileged` (0 offline, 1 away, 2 online) |
| 18 | ConnectToPeer | send `u32 token, string user, string type`; recv `string user, string type, u32 ip, u32 port, u32 token, bool privileged, u32 obfType, u32 obfPort` |
| 26 | FileSearch | send `u32 token, string query` |
| 28 | SetStatus | `u32 status` |
| 32 | ServerPing | empty |
| 35 | SharedFoldersFiles | `u32 dirs, u32 files` |
| 36 | GetUserStats | send `string user`; recv `string user, u32 avgSpeed, u32 uploads, u32 unknown, u32 files, u32 dirs` |
| 41 | Relogged | stop the session |
| 69 | PrivilegedUsers | `u32 count, string[count]` — ignore |
| 71 | HaveNoParent | `bool noParent` |
| 83 / 84 | ParentMinSpeed / ParentSpeedRatio | `u32` — informational |
| 92 | CheckPrivileges | empty → `u32 secondsLeft` |
| 1001 | CantConnectToPeer | send `u32 token, string user`; recv `u32 token` |
| 160 | ExcludedSearchPhrases | `u32 count, string[count]` — must filter outgoing result paths |

Unrecognised server codes are ignored (the payload is known from the frame header).

## 4. Peer connections

The first message on a *new inbound* connection is on the peer-init channel and is either
`PeerInit` or `PierceFireWall`; after that the connection switches to peer framing.

| Init code | Name | Payload |
|---|---|---|
| 0 | PierceFireWall | `u32 token` |
| 1 | PeerInit | `string ourUsername, string type, u32 token` |

`type` is `P` (peer), `F` (file transfer) or `D` (distributed). Only `P` and `F` are used here.

Outbound peer setup (what this client does):

1. Resolve address: cached, else `GetPeerAddress` and wait for the server reply.
2. Send `u32 token`-bearing `ConnectToPeer(token, user, "P")` to the server **and** dial the peer
   directly with `PeerInit`. Whichever path completes first wins; the server forwards `ConnectToPeer`
   to the peer so it can dial back with `PierceFireWall(token)` if our outbound dial fails.
3. Keep `token → pending connection` so an inbound `PierceFireWall` can be matched and adopted.

An inbound `ConnectToPeer` of type `F` means an uploader cannot reach our listening port; we dial the
address the server gives and open with `PierceFireWall(token)` instead of `PeerInit`. See §6.

### Peer messages

| Code | Name | Payload |
|---|---|---|
| 4 | GetShareFileList | empty |
| 5 | SharedFileListResponse | **zlib** of: `u32 dirCount, dir[dirCount], u32 unknown, [u32 privateCount, dir[privateCount]]` |
| 9 | FileSearchResponse | **zlib** of: `string user, u32 token, u32 count, file[count], bool slotFree, u32 avgSpeed, u32 queueLength, u32 unknown, [u32 privateCount, file[privateCount]]` |
| 15 / 16 | UserInfoRequest / UserInfoResponse | request empty; response `string description, bool hasPicture, [bytes picture], u32 totalUploads, u32 queueSize, bool slotsFree, [u32 uploadPermissions]` |
| 26 | FileSearch | `string user, u32 token, string query` (this is an inbound search request) |
| 36 / 37 | FolderContentsRequest / FolderContentsResponse | request `u32 token, string folder`; response **zlib** of `u32 token, string folder, u32 dirCount, dir[dirCount]` |
| 40 | TransferRequest | `u32 direction (0=download,1=upload), u32 token, string filename, [u64 size when direction==1]` |
| 41 | TransferResponse | `u32 token, bool allowed, [u64 size when allowed on a download response]`, else `string reason` |
| 43 | QueueUpload | `string filename` |
| 44 | PlaceInQueueResponse | `string filename, u32 place` |
| 46 | UploadFailed | `string filename` |
| 50 | UploadDenied | `string filename, string reason` |
| 51 | PlaceInQueueRequest | `string filename` |
| 121 | *(server code)* SendUploadSpeed | `u32 speed` — sent to the server after an upload |

`file` record:

```
u8     code (1 = file, 2 = directory)
string name            // basename in a share list; full virtual path in a search result
u64    size
string extension       // usually empty
u32    attrCount
u32    attrCode, u32 value   // repeated
```

Attribute codes: `0` bitrate kbps, `1` duration seconds, `2` VBR flag, `4` sample rate Hz,
`5` bit depth.

`dir` record: `string path, u32 fileCount, file[fileCount]`.

Defensive notes:
- Only parse `u32 unknown` and the private-results block if bytes remain.
- Very old clients with files > 2 GiB corrupt the size high half; if byte 7 of the size is `0xFF`,
  use only the low 4 bytes.

## 5. Searches

- The client picks a random `u32` token and sends `FileSearch(token, query)` to the server.
- Responding peers dial the searcher and send `(9) FileSearchResponse` with our token. The response
  is compressed as a whole, so the token cannot be validated without inflating at least 8 bytes;
  inflate the prefix, check the token, and drop the connection if it is unknown.
- There is no cancel message: stop tracking the token locally and discard late results.
- Responding to other people's searches: on inbound `(26) FileSearch`, look the query up in the local
  share index and, if there are hits, dial the requester (type `P`) and send `(9)` with **their**
  token. Filter results against the server's excluded phrases.

## 6. Transfers

### Downloading (we are the downloader)

1. `QueueUpload(filename)` over a peer connection (legacy peers accept
   `TransferRequest(direction=0, token, filename)`; answer that with `TransferResponse(token, true)`).
2. The uploader sends `TransferRequest(direction=1, token, filename, size)` → we reply
   `TransferResponse(token, true)`.
3. The **uploader** opens a new connection to our listening port with `PeerInit(ourUsername, "F", 0)`
   and sends a bare `u32 token`.
4. We reply with `u64 offset` (bytes already downloaded, `0` if none) and the uploader streams raw
   bytes from that offset.
5. The downloader closes the connection to signal completion. The uploader must not close first.
6. `(51) PlaceInQueueRequest(filename)` → `(44) PlaceInQueueResponse(filename, place)` while queued.

If the uploader cannot reach our listening port it sends `ConnectToPeer(token', us, "F")` to the
server instead. The server forwards `ConnectToPeer(them, "F", token', ip, port)` to us; we dial that
address, open with `PierceFireWall(token')`, and the uploader sends the bare `u32 token` just as in
step 3. `token'` is a fresh indirect token, not the transfer token.

### Uploading (we are the uploader)

1. Inbound `QueueUpload(filename)` (or legacy `TransferRequest(direction=0)`): if the file is in the
   share index, enqueue and reply `TransferRequest(direction=1, token, filename, size)` when a slot is
   free, otherwise `TransferResponse(token, false, "Queued")`.
2. On `TransferResponse(token, true)` dial the requester with `PeerInit(ourUsername, "F", 0)`, send
   `u32 token`, read `u64 offset`, stream the file, then wait for the peer to close.
3. In parallel send `ConnectToPeer(token', requester, "F")` so a blocked direct route can still
   complete: the downloader answers by dialling us with `PierceFireWall(token')`, after which we send
   `u32 token` and continue as above. Whichever route connects first is used; the other is dropped.
4. Send `SendUploadSpeed(speed)` on the server connection afterwards.
5. Denials/reasons: `Banned`, `Cancelled`, `Complete`, `File not shared.`, `File read error.`,
   `Pending shutdown.`, `Queued`, `Too many files`, `Too many megabytes`.

### File channel

No framing whatsoever: `u32 token`, then `u64 offset`, then raw bytes until close. There is no
hashing; size is the only integrity check.

## 7. Distributed network (not implemented)

Codes on the `D` channel: `0` ping, `3` search, `4` branch level, `5` branch root, `93` embedded
message. A client that does not want to be a branch parent sends `HaveNoParent(true)` and never
accepts children. Own searches still work: the server injects them into the distributed network.
The cost is that the client does not receive other users' global searches.

## 8. Politeness rules observed by this client

- `ServerPing` at most once per minute; TCP keepalive enabled.
- Never auto-repeat searches; enforce a short cooldown between global searches.
- Cap concurrent peer connections and inbound uploads.
- Filter outgoing search results with the server's `ExcludedSearchPhrases`.
- Report real share counts via `SharedFoldersFiles`.
