# Magpie v1 — build design

Status: approved for overnight build under the owner's standing authorisation (see `docs/decisions.md` D1–D17) · 2026-10-27
Parents: `2026-10-26-serverless-architecture-design.md` (architecture, still authoritative where not narrowed here), `docs/storyboard/*` (design language, flows, CarPlay), `docs/reviews/design-critique-*.md` (critiques this design answers).

## 1. Goal

By morning the owner can run Magpie in the iOS 27.1 simulator (and CarPlay simulator), sign in to **their real Navidrome**, play their library, search across library + not-yet, **Try** a song through **their real Lidarr**, watch it arrive in **Finds**, and **Keep** it. Everything also passes against the local dev stack in `dev/` (Docker Navidrome + Lidarr + fixture library).

The owner is the only user and a Curator. No backend. Nothing is written to Lidarr without an explicit tap; every artist/album Magpie adds is tagged `magpie`.

## 2. In scope

1. **Connect** (one screen, then "Start listening"): Navidrome URL(s) (ordered list: first that answers wins), username + password → `/auth/login` (JWT for native API) + Subsonic token/salt (or OpenSubsonic `apiKey` if advertised). Admin check. Credentials in Keychain (`AfterFirstUnlockThisDeviceOnly`).
2. **Finish setting up card** on Home: Lidarr (URL + API key) with a read-only audit (version, auth on, root folders, quality + metadata profiles, Tubifarry detect via `/system/plugins` / `/indexer`), and an explicit **"Set up Magpie in Lidarr"** button that creates profiles *Magpie Fast Start* (MP3 320/V0) and *Magpie Lossless* (FLAC, upgrades on), metadata profile *Magpie Albums+EPs*, and tag `magpie`. Finds root: use an existing root folder whose path contains `samples` (case-insensitive) **and** a Navidrome library on the same path; otherwise Try falls back to a normal request into the main root with Fast Start (shown honestly: "Finds aren't set up, so tries go straight into your library"). ListenBrainz token optional.
3. **Library playback**: Home (Jump back in = `getAlbumList2` recent / newest / frequent; Made for you = LB created-for playlists when token set; New finds shelf), Library (Artists, Albums, Playlists, Finds, Requests), Album, Artist (library albums + `getTopSongs` + not-yet albums from Lidarr lookup when connected), Playlist, Now Playing (Classic / Signature / Immersive-lite), Queue (Up Next priority list + rest), Lyrics (`getLyricsBySongId`, fallback `getLyrics`). Engine: `AVQueuePlayer` behind a `PlaybackEngine` protocol; prefetch next item ~20 s before end; Subsonic `scrobble` (submission at 50%/4 min rule; never for finds' trial plays? — see §5); `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (play/pause/next/prev/seek/like). Streaming only (no downloads in v1).
4. **Merged search**: debounced 250 ms; parallel `search3` ‖ Lidarr `/search?term=` ‖ ListenBrainz labs `recording-search` (+ `/1/metadata/recording` for ISRC/release) with per-source timeouts (Navidrome 3 s, others 5 s), silent degradation. Match index (in-memory, built from native `/api/song` paging in the background and persisted as a JSON snapshot in Application Support) merges external hits into library items by recording MBID → ISRC → artist+title+|Δdur|≤3 s → normalised artist+title. **Library first** (D4). Not-yet rows: round record art + text "Not in your library" + Try button.
5. **Try** (Curator-direct): pure, deterministic `RequestMachine` (states: `pending → resolving → adding → searching → downloading(p) → importing → ready → kept | dismissed`, plus `waiting(reason, retryAt)` and `failed(reason)`); side effects in a `RequestRunner` actor that polls Lidarr (`/command/{id}`, `/queue/details`, `/history/since`, `/track?albumId=` hasFile) every 5 s while foreground, 30 s otherwise, then **ready only when Navidrome lists the song** (match index by MBID/ISRC/title after `startScan?target=` since the owner is admin). Smallest release group containing the recording (Single → EP → Album). Artist not in Lidarr → add to Finds root (tag `magpie` + `magpie-find`, Fast Start, monitor none) and monitor that one album; artist already in main library → normal album request in place (row explains "Coming straight into your library"). Persisted (JSON in Application Support) so requests survive relaunch. Wait screen per D6/D7/D8: foreground shows real % and steps; Patient tier → "Ask for it", no spinner screen.
6. **Finds shelf**: songs in the Finds library (or Magpie-tagged requests in fallback mode) with days-left from created date (7-day window, display only), Keep and **Not for me** (confirm → delete that album's track files + unmonitor; artist removed only if it has no other files, no import-list exclusion). No automatic expiry in v1.
7. **Keep** (D5): keep the find's release = `artist/editor` move from Finds root → main root (`moveFiles: true`), switch to Magpie Lossless, remove `magpie-find` tag → `startScan`. Then optional sheet "Bring in more from <artist>?" (Albums+EPs preselected; This album only; Everything; + toggle Follow new releases) with approximate size from Lidarr album statistics when available. Lossless upgrade is silent; the hallmark shows "Lossless soon" until the file's suffix/bitrate says lossless.
8. **Activity**: list of requests with real state, %, elapsed; tap → wait screen; failure shows calm copy + Details (Curator) with the raw Lidarr message.
9. **CarPlay** (D12): `CPTabBarTemplate` with list roots Home · Library · Finds · Search. Search root = list with "Type a search" (disabled when `CPSessionConfiguration.limitedUserInterfaces` contains keyboard) + recents → pushes `CPSearchTemplate`. Not-yet results use pre-rendered round artwork + detail text "Not in your library · Try". Try in car = `CPActionSheetTemplate` "Try it next" / "Cancel" (D6). Now Playing via `CPNowPlayingTemplate.shared` with album cover; custom buttons: add-to-library (Keep, only when the item is a find), shuffle, repeat. Depth ≤ 2 pushes below a tab. Lists honour `CPListTemplate.maximumItemCount` / `maximumSectionCount`. Template updates never rebuild a visible list mid-browse (diff + `updateSections` only when the user isn't scrolling — Amperfy #647 lesson). Works when cold-launched in the car with the phone locked (Keychain + files `completeUntilFirstUserAuthentication`).
10. **Design system** (`DesignSystem` package): tokens for the three Characters × light/dark from `docs/storyboard/design-language.md` (Sheen accent default; Tangerine, Ultramarine alternates), type styles mapped to Dynamic Type text styles (New York via `.fontDesign(.serif)` for display in Signature/Immersive, `.rounded` for numerals), components: SleeveArt / RecordArt (round, grooves, spindle hole, spin while on its way, saturation by days-left), StatusLine (text + SF Symbol for every state — D3), Hallmark, CapsuleButton (≥44 pt hit area), SongRow, AlbumTile, ShelfSection, MiniPlayer (`tabViewBottomAccessory`), WaitView (grooves ripple, honest copy). Accessibility per D15.
11. **Settings** (minimal): Appearance (Character dial, accent, Reduce-Motion-aware toggles), Servers (addresses, versions, sign out), Lidarr (audit status, re-run setup), ListenBrainz (token), About. Household shows "Just you".

## 3. Out of scope (v1)

Mailbox / Listener role / invites / household playlist / leader lease (D11 spec only); Mac helper + Quick fetch (never in App Store binaries); automatic expiry, caps, disk quota; downloads/offline; Live Activities, widgets, App Intents/Siri; Immersive particles + visualizers; crossfade; open previews (provider ladder behind a flag, off); iPad/Mac/tvOS/web.

## 4. Architecture

```
Magpie.xcodeproj (XcodeGen: project.yml)
App/                      iOS 27 app target "Magpie" (SwiftUI, @Observable), CarPlay scene delegate, Info.plist, entitlements (carplay-audio, keychain group)
Packages/MagpieKit/       one Swift package, multiple library products:
  MagpieCore              domain models (Song, Album, Artist, Playlist, Find, Request, Quality), IDs (MBID, ISRC), Clock, Logger with credential redaction
  NavidromeKit            Subsonic (/rest) + native (/api) client, auth (JWT + token/salt/apiKey), multi-address failover, contract-tested DTO → domain mappers
  LidarrKit               /api/v1 client (X-Api-Key), audit, provisioning, request ops, polling
  ListenBrainzKit         recording search, metadata, created-for playlists (token)
  MatchIndex              normalisation + ladder, snapshot persistence
  Requests                RequestMachine (pure) + RequestRunner (actor) + persistence
  Playback                PlaybackEngine protocol, AVQueuePlayer engine, Queue model (pure), NowPlaying bridge
  DesignSystem            tokens + components (SwiftUI)
  CarPlayUI               template builders + diffing (UIKit/CarPlay), no business logic
Tests: Packages/MagpieKit/Tests/<Module>Tests (Swift Testing), fixtures as JSON captured from the dev stack; integration tests gated by MAGPIE_IT=1 reading dev/.env.local.
dev/                      Docker Navidrome + Lidarr stack, fixture library, smoke script (exists)
```

Concurrency: Swift 6 strict; app target default MainActor; packages nonisolated with explicit actors (`RequestRunner`, `MatchIndexStore`, network clients are `Sendable` structs over `URLSession`). Networking: `URLSession` with per-request timeouts, `ATS: NSAllowsLocalNetworking`, plus a documented `NSAllowsArbitraryLoads` **debug-only** build setting so the owner can test a plain-HTTP server over the internet (release builds require HTTPS or local network).

## 5. Rules that bite

- Never scrobble a find's trial plays; scrobble library songs only (check: song's library is not the Finds library and request state ≠ ready-unkept).
- Credentials never logged: Logger redacts `u t s p apiKey X-Api-Key token password` query items/headers; URLs printed via a sanitiser.
- All external strings (Lidarr messages, LB metadata, tags) are display-only, length-capped, never interpolated into URLs without encoding.
- Lidarr calls are idempotent by MBID: before add, look up existing artist/album; joining an existing in-flight item instead of duplicating.
- Not for me never touches anything outside the Finds root (path-prefix check on every track file before delete) and never runs on a kept album.
- Durations: trust API duration until the decoder knows (transcodes may lack Content-Length); stream with `estimateContentLength=true`.

## 6. Testing & verification

- Unit (Swift Testing): mappers (fixture JSON), match ladder, RequestMachine transition table (exhaustive), Queue model, redaction, address failover, CarPlay list diffing/limits, design tokens contrast (assert ≥ 4.5:1 for text pairs).
- Integration (dev stack, `MAGPIE_IT=1`): login, search3, album list, stream byte-range, cover art, Lidarr audit, provisioning on a scratch Lidarr, Try against a fixture-backed flow where possible (Lidarr can't download offline — use manual import of a fixture file into the Finds root to simulate arrival), Keep move + rescan, Not for me path confinement.
- App: `xcodebuild build` + `test` for the iOS simulator; UI smoke test (launch with `-MagpieDemo` pointing at dev stack, sign in, play, search, open Finds); CarPlay: build + template unit tests; manual CarPlay simulator run documented.
- Edge cases (test designer agent): huge library paging, unicode, missing MBIDs, server down mid-play, token expiry → silent re-login single-flight, Lidarr outage → waiting state, duplicate tries, kill/relaunch during request.
- Security review (security agents): Keychain classes, log redaction, ATS, TLS handling, input validation, path confinement, no secrets in UserDefaults/plist/logs, dependency audit (target: zero third-party dependencies in v1 except none — use Foundation only).

## 7. Done means

`xcodebuild test` green on iOS 27.1 simulator; `swift test` green for packages; integration suite green on the dev stack; security review findings Critical/High fixed; `docs/RUNBOOK.md` tells the owner how to run it against their own Navidrome + Lidarr in 5 steps, including the pre-flight checks (Navidrome ≥ 0.64 + admin, Lidarr 3.x reachable, samples root present or fallback, Subsonic connection, import-to-visible delay, song-ID stability across upgrade).
