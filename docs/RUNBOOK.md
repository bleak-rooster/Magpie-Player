# Magpie Runbook

## Toolchain
Every shell: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points to CLT). The scripts do this for you. Requires XcodeGen (`brew install xcodegen`).

## Scripts
- `scripts/test-packages.sh` runs `swift test` in `Packages/MagpieKit`.
- `scripts/test-app.sh` runs `xcodegen generate`, then unit and UI tests on the "iPhone 18 Pro" simulator (iOS 27.0 runtime).
- `scripts/test-all.sh` runs both.
- `scripts/it.sh` runs server integration tests (`MAGPIE_IT=1`, dev stack only).
- `scripts/build.sh` generates the project and builds the app.

`Magpie.xcodeproj` and `App/Info.plist` are generated from `project.yml` and are git-ignored.

## What works
- M2: search, queue, lyrics. Search tab searches the library as you type (250 ms pause, in-flight searches cancelled): Top result (best name match, else the first song), Songs, Artists, Albums, with All/Songs/Artists/Albums scopes and Recent searches (kept on the device, Clear). Tap a song to play the results from there; long-press for Play Next / Add to Queue. Queue sheet (from Now Playing): Now playing, Shuffle and Repeat (off / all / one) toggles, Up Next, Playing next; Edit gives drag handles, swipe removes, Clear drops everything after the current song. Lyrics sheet appears only when the server advertises `songLyrics`; synced lines follow the playback position (tap a line to jump), unsynced lyrics are plain text, empty state "No lyrics for this song". Network sessions are ephemeral with no URLCache, so Subsonic auth URLs never reach disk. External ("Not in your library") search results arrive with M4.
- M1: sign in, browse, play. Connect (one or more addresses, first answering wins; credentials and addresses in the Keychain, restored on launch; Sign-out clears them), tabs Home · Library · Search, Home shelves (Jump back in / Recently added / Most played) and a "Finish setting up" card, Library (Playlists, Artists, Albums, Recently added), Album, Artist (Popular hidden when the server has no top songs), Playlist, mini player and Now Playing (scrubber, star, Lossless hallmark, lyrics and up-next panels). Address failover mid-session: a connection error re-probes the addresses, rebuilds the client and the player's stream URLs. Signature and Classic looks (`-MagpieCharacter classic` launch argument).
  - Against the dev stack: `dev/` stack running (`http://127.0.0.1:4533`), then `MAGPIE_IT=1 scripts/test-app.sh` runs `BrowseFlowTests` (signs in, opens the first album, plays track 1, checks the mini player). The script reads the URL and admin credentials from `dev/.env.local` (dev marker and localhost required, G0) and passes them as `TEST_RUNNER_MAGPIE_IT_*`; nothing is committed. By hand: run the app in the simulator and sign in with `http://127.0.0.1:4533` and the `NAVIDROME_ADMIN_*` values from `dev/.env.local`.
- M0 — app launches to Connect: package skeleton, XcodeGen app shell, placeholder Connect screen, CarPlay scene delegate stub. Nothing else yet.
- MagpieCore primitives: `ServerEndpoint` (base-path-preserving URLs, failover), `HTTPTransport` / `URLSessionTransport`, `MockTransport` (in `MagpieTestSupport`), `Redactor`, `Log`, `KeychainStore`, `AtomicFile`.

## Connecting to a real server
- Self-signed HTTPS (B3): Magpie does not override certificate trust (AVPlayer would ignore it). Install your CA into the simulator with `xcrun simctl keychain booted add-root-cert <ca.pem>` (on a device, install and trust a profile). Connect says so when it sees an untrusted certificate.
- LAN address times out (B4) but opens in Safari on the Mac: check System Settings › Privacy & Security › Local Network for Xcode/Simulator. `localhost` in the simulator is the Mac.
- Plain HTTP outside the home network works only in Debug builds (B2); Release asks for HTTPS.
