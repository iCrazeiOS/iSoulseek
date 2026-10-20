# iSoulseek

A native iOS client for the [Soulseek](https://www.slsknet.org/) peer-to-peer network: sign in,
search, browse shares, download, and serve a share folder of your own. Swift/UIKit, no third-party
dependencies.

## Requirements

- Xcode 27 or newer (iOS 27 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 15.0 or newer

## Using the app

- **Sign in.** New usernames register automatically and there is no password reset. Credentials are
  kept in the Keychain and used to sign in and reconnect automatically; the login form returns only
  after a rejection, a session takeover, or sign out.
- **Search.** Results are grouped by user and can be sorted by size, bitrate or duration. Tap or
  swipe a result to download or browse that user; the navigation bar browses any username. The cog
  opens filters for file types, excluded words, size, bitrate, lossless files and free upload slots;
  Soulseek has no server-side filters, so they are applied locally and can be changed without
  searching again.
- **Browse.** Expand folders, filter by name, and download files or whole folders.
- **Transfers.** *Downloading* shows active downloads with progress, speed and cancel — failed
  downloads stay listed with their reason (with a toast at failure time) for the rest of the
  session, and queueing the same file again retires its failure row; *Downloaded*
  supports sorting, list/tree views, Quick Look, swipe delete, Show in Files, and a long-press share
  sheet; *Uploading* shows files other users are taking from your share. *Select* chooses transfers
  or downloaded files for bulk deletion/cancellation, with *Select All* for clearing everything in a
  tab.
- **Files.** Downloads go to `On My iPhone ▸ iSoulseek ▸ Downloads`, under the uploader's name.
  Partials stay hidden in `.partials` and resume when retried.
- **Shares.** Anything in `On My iPhone ▸ iSoulseek ▸ Shared` is served to other users.
- **Settings.** Server and ports, online/away status, share counts and rescan, search sort order and
  filters, activity log, and sign out.

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
