# iSoulseek

A native iOS client for the [Soulseek](https://www.slsknet.org/) peer-to-peer network: sign in,
search, browse shares, download, and serve a share folder of your own. Swift/UIKit, no third-party
dependencies.

## Requirements

- Xcode 27 or newer (iOS 27 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 15.0 or newer

## Using the app

- **Sign in.** New usernames register automatically; there is no password reset. Credentials live in
  the Keychain, so the login form only reappears after a rejection, a session takeover, or sign out.
- **Search.** Results group by user and sort by size, bitrate or duration. Tap or swipe a result to
  download or browse. Filters (type, excluded words, size, bitrate, lossless, free slots) apply
  locally, so changing them doesn't need a new search.
- **Browse.** Expand folders, filter by name, and download files or whole folders. Natural track
  order, with artwork and metadata files last.
- **Transfers.** *Downloading* shows progress, speed and cancel, and keeps failures with their reason
  for the session. *Downloaded* has sorting, list/tree views, Quick Look, swipe delete, Show in
  Files and share. *Uploading* lists what others are taking from your share. *Select* does bulk
  cancel/delete, with *Select All* per tab.
- **Files.** Downloads land in `On My iPhone ▸ iSoulseek ▸ Downloads` under `<uploader>/<album>`.
  Partials stay hidden in `.partials` and resume on retry.
- **Shares.** Everything in `On My iPhone ▸ iSoulseek ▸ Shared` is served to other users.
- **Settings.** Server and ports, status, share counts and rescan, search sort and filters, activity
  log, sign out.

## Build and run

```sh
xcodegen generate
open iSoulseek.xcodeproj

xcodebuild -project iSoulseek.xcodeproj -scheme iSoulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`./build_ipa.sh` produces an unsigned `iSoulseek.ipa` in the repository root. `iSoulseek.xcodeproj`
is generated; `project.yml` is the source of truth.

## Tests

```sh
xcodebuild -project iSoulseek.xcodeproj -scheme iSoulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

About 180 unit and integration tests, including an in-process mock Soulseek server and peer that
speak the real wire protocol. Live tests are skipped unless you set
`SOULSEEK_LIVE=1 SOULSEEK_LIVE_USER=<user> SOULSEEK_LIVE_PASS=<pass>` (use `TEST_RUNNER_`-prefixed
names for the UI test). Use a throwaway account — unused names are registered.

## Limitations

- **Foreground only.** iOS suspends raw TCP sockets in the background, so transfers stop when you
  leave the app.
- **Inbound connections.** A reachable listening port is needed; carrier-grade NAT can block
  transfers. `ConnectToPeer` helps, but there is no UPnP/NAT-PMP.
- **No distributed network participation.** The client sends `HaveNoParent` and never accepts
  children, so it neither receives nor answers other users' global searches.
- **No obfuscated peer connections** (type 1 / RC4).
- **No chat, rooms, wishlists, user pictures or recommendations.**
- Unlikely to pass App Store review (guideline 5.2.3); build and sideload it yourself.

## Architecture

```
iSoulseek/
  App/         AppDelegate, SceneDelegate, Info.plist, assets
  Model/       share, search, transfer and connection types
  Protocol/    byte reader/writer, message codes and types, zlib
  Network/     FrameDecoder, SocketConnection, PeerListener
  Services/    SoulseekClient, TransferManager, PeerSession, ShareIndex,
               DownloadedFiles, SessionStore, Keychain
  UI/          Root, Login, MainTabBar, Search, SearchOptions, Browse, Transfers, Settings,
               FloatingSheet, Theme
iSoulseekTests/     Unit, Integration, Mock server/peer, Support, Live
iSoulseekUITests/   opt-in live UI flow
docs/PROTOCOL.md    wire-format reference
```

Protocol work runs on one serial queue owned by `SoulseekClient`; file I/O uses a separate queue and
UI state is published through Combine on the main queue. Wire format details are in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Security

- Peer-supplied paths are sanitised, and downloads are confined to the downloads directory.
- Parsing is bounds-checked with capped frame and decompressed sizes.
- Search responses are accepted only for our tokens; file connections only for known transfer tokens.
- Credentials stay in the Keychain and are never logged. No third-party code, web views or App
  Transport Security exceptions.
