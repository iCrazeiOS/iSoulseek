# Soulseek for iOS

A native iOS client for the [Soulseek](https://www.slsknet.org/) peer-to-peer network: sign in,
search the network, browse other users' shares, and download to the app's Documents folder. It also
publishes a share folder of its own so it behaves like a real client rather than a leech.

Written in Swift with UIKit. No third-party dependencies.

## Requirements

- Xcode 27 or newer (the project targets the iOS 27 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- **iOS 15.0 or newer.** The original brief asked for iOS 13, but the installed toolchain rejects
  anything below 15.0 (`the range of supported deployment target versions is 15.0 to 27.0.x`), so
  15.0 is the floor.

## Build and run

```sh
xcodegen generate                       # writes Soulseek.xcodeproj from project.yml
open Soulseek.xcodeproj                 # then run on a simulator or device
```

Command line:

```sh
xcodebuild -project Soulseek.xcodeproj -scheme Soulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Tests:

```sh
xcodebuild -project Soulseek.xcodeproj -scheme Soulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

This runs 135+ unit and integration tests, including an in-process mock Soulseek server and peer
that speak the real wire protocol. The two live tests are skipped unless you opt in:

```sh
# Unit test bundle
SOULSEEK_LIVE=1 SOULSEEK_LIVE_USER=<user> SOULSEEK_LIVE_PASS=<pass> \
  xcodebuild -project Soulseek.xcodeproj -scheme Soulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SoulseekTests test

# UI flow test (xcodebuild only forwards TEST_RUNNER_-prefixed variables to a UI test runner)
TEST_RUNNER_SOULSEEK_LIVE=1 \
TEST_RUNNER_SOULSEEK_LIVE_USER=<user> TEST_RUNNER_SOULSEEK_LIVE_PASS=<pass> \
  xcodebuild -project Soulseek.xcodeproj -scheme Soulseek \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SoulseekUITests test
```

The live tests sign in to `server.slsknet.org`, run one search, and (in the UI test) drive the whole
app: sign in, search, check the tabs. Use a throwaway account — signing in with an unused name
registers it.

`Soulseek.xcodeproj` is generated and therefore not committed; `project.yml` is the source of truth.

## Using the app

1. Sign in with a Soulseek username and password. A username that does not exist yet is registered
   automatically — there is no password reset, so keep the credentials safe. They are stored in the
   Keychain (`WhenUnlockedThisDeviceOnly`).
2. **Search** — global search across the network. Results arrive as peers reply and are grouped by
   user; a result with a free slot will start downloading immediately, queued ones may wait a while.
3. **Browse** — tap *Browse* on a result's section header, or *Browse user…* in the search screen.
   Download single files or whole folders.
4. **Downloads** — live progress for both directions, swipe to cancel, *Clear finished* to tidy up.
5. **Files** — downloaded files live in `On My iPhone ▸ Soulseek ▸ Downloads` because file sharing is
   enabled for the app, so you can move them out with the Files app.
6. **Shares** — anything you put in `On My iPhone ▸ Soulseek ▸ Shared` is served to other users.

## Limitations

- **Foreground only.** iOS suspends raw TCP sockets shortly after the app is backgrounded, so
  transfers stop when you leave the app. There is no way around this for a peer-to-peer client that
  does not use `URLSession` background transfers.
- **Inbound connections.** Downloads you request are delivered by the uploader dialling *you*, so a
  reachable listening port is needed. On carrier-grade NAT some transfers will not start. The client
  also asks the server to have the peer connect back through `ConnectToPeer`, which helps but is not
  a full NAT traversal implementation (no UPnP/NAT-PMP).
- **No distributed network participation.** The client declares `HaveNoParent` and never accepts
  children, so it does not receive other users' global searches and therefore does not answer them.
  Your own searches, browsing and transfers are unaffected. See `docs/PROTOCOL.md` §7.
- **No obfuscated peer connections** (obfuscation type 1 / RC4).
- **Chat, rooms, wishlists, user pictures and recommendations are not implemented.**
- App Store review is unlikely: guideline 5.2.3 covers apps that facilitate downloading media from
  third-party sources. Expect to build and sideload this yourself.

## Architecture

```
Soulseek/
  App/         AppDelegate, SceneDelegate, Info.plist, assets
  Model/       ShareFile/ShareFolder, SearchResult, Transfer, ConnectionState
  Protocol/    bounds-checked byte reader/writer, message codes, typed messages, zlib
  Network/     FrameDecoder, SocketConnection (NWConnection), PeerListener (NWListener)
  Services/    SoulseekClient, TransferManager, PeerSession, ShareIndex, SessionStore, Keychain
  UI/          Root, Login, Search, Browse, Downloads, Settings
SoulseekTests/ unit tests and an in-process mock server
SoulseekUITests/ opt-in UI flow test that drives the app against the real network
docs/PROTOCOL.md  condensed wire-format reference
PLAN.md           design notes, phases and the security checklist
```

Everything protocol-related runs on one serial `DispatchQueue` owned by `SoulseekClient`, so the
protocol layer needs no locking. File I/O is pushed to a separate queue. UI-facing state is
republished through Combine subjects on the main queue.

Protocol summary (framing, message layouts, transfer flow) is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md), written from the Nicotine+, Soulseek.NET and aioslsk
implementations.

## Security notes

- Credentials are kept in the Keychain and never logged.
- Every path that comes from a peer is sanitised before it is used on disk, and the resolved URL is
  checked to be inside the downloads directory.
- Message parsing is fully bounds-checked; framing, frame size and decompressed size are all capped,
  so a hostile peer cannot make the app allocate unbounded memory.
- Search responses are only accepted for tokens this client issued, checked before the payload is
  inflated.
- Inbound file connections are only served when their transfer token matches a transfer we requested
  or accepted. The reverse indirect route is equally guarded: we dial a `ConnectToPeer` only for a
  transfer we are actively awaiting, and adopt an inbound `PierceFireWall` only for a token we
  registered.
- No third-party code, no web views, no dynamically loaded code, no App Transport Security
  exceptions.
