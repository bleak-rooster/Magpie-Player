# Research synthesis & build recommendation

Date: 2026-10-26. Detailed sources:
- [feishin.md](feishin.md) — Feishin v1.17.0 source + issues
- [ios-clients.md](ios-clients.md) — Arpeggi, Narjo, NaviBeat, Minidisc, Amperfy, Cassette, play:Sub, substreamer
- [lidarr-navidrome.md](lidarr-navidrome.md) — Lidarr v3.2 / Navidrome v0.64.2 source-level API notes
- [listenbrainz-discovery-previews.md](listenbrainz-discovery-previews.md) — LB discovery APIs, MusicBrainz, Deezer/iTunes previews (live-tested)
- [apple-platform-architecture.md](apple-platform-architecture.md) — iOS/macOS/tvOS 27, CarPlay, audio engine, visuals, security, web stack

## 1. The landscape in one paragraph

Every existing client is either a good *player* (Amperfy, NaviBeat, Narjo, Feishin) or a good *requester* (Aurral, Minidisc's Lidarr screens) — none fuse the two invisibly, and none of the iOS ones pair that with reliable CarPlay. Minidisc (open source, SwiftUI, MPL-2.0) is the closest prior art: it has ListenBrainz and a Lidarr UI, but no CarPlay and it exposes Lidarr as Lidarr. The gap we fill: **Spotify-grade experience where "not in your library yet" is just another state of a song.**

## 2. Solved problems we copy, not reinvent

| Problem | Proven approach | Source |
|---|---|---|
| Model normalization | One domain model; per-backend client → normalizer; capability flags computed once from server version + OpenSubsonic extensions | Feishin `domain-types.ts` |
| Navidrome API split | Native `/api` for paged/sorted/filtered library browsing (`X-Total-Count`); Subsonic `/rest` for stream, art, star, scrobble, lyrics, similar, search. `/auth/login` yields both JWT and subsonic token | Feishin |
| Big libraries | Count first, then 100-item pages into virtualized lists; playback time in its own store | Feishin |
| Queue | Per-entry unique IDs (dupes allowed); separate "Up Next" priority list; play order by ID not index; server sync via `savePlayQueue`/`getPlayQueue` | Feishin (+ its bugs) |
| Gapless (Apple, v1) | Dual `AVQueuePlayer` "decks" behind a `PlaybackEngine` protocol with a load token; gapless via native queue, crossfade via second deck | Minidisc |
| Prefetch | Enqueue next track 15–20 s before end; precache next 3 into an LRU auto-cache kept on skip | Amperfy / Minidisc |
| Transcoding | OpenSubsonic transcode decision where available; otherwise `format`+`maxBitRate`; `estimateContentLength=true`; `timeOffset` seek; prefer AAC over Opus on cellular; trust server duration until decoder knows | Feishin, Amperfy issues |
| Storage | 3 tiers: stream buffer / capped auto-cache / pinned downloads. Background `URLSession` per server, Low Data Mode aware, write-through cache to avoid double fetch | Amperfy, Minidisc |
| Scrobbling | **Navidrome scrobbles to ListenBrainz** — client only calls Subsonic `scrobble` (with `time=` for offline). Never submit to LB directly. Never scrobble previews | LB research |
| Auth | Silent re-login with single-flight on 401 (Feishin's logout-on-401 is a known pain); strip creds from every logged URL | Feishin, Amperfy `cleanse(url:)` |
| CarPlay | ≤4 tabs, ≤5 deep, read list limits at runtime, never mutate the visible list during sync, data off main thread, identical playback/auth/cache path as phone; iOS 27 allows search for audio apps | Amperfy + Apple guide 2026-10-13 |
| Reverse proxy | `proxy_buffering off` for streams | Feishin #681 |

## 3. Known traps to avoid

- Web "gapless" via two `<audio>` elements is not gapless (Feishin #1576) and double-plays after sleep (#2290).
- Index-array shuffle + 2,600-line queue store → shuffle/crossfade bugs. Keep queue a pure, unit-tested model.
- Non-virtualized sidebars (4,500 playlists → 3 s freezes). Navidrome auto-imports per-album `.m3u` as playlists — filter them.
- Rebuilding CarPlay lists during background sync → focus jumps / wrong item plays.
- Transcoded streams lacking content length → unknown duration, restarts.
- Fetching every song twice (stream + cache).
- MTAudioProcessingTap on streams for FFT — unreliable.
- SwiftData for a large library cache — use GRDB.
- Wrong file-protection / Keychain accessibility class → CarPlay breaks with phone locked.

## 4. The Lidarr ⇄ Navidrome ⇄ ListenBrainz fusion

**Identity spine = MusicBrainz IDs.** Navidrome exposes recording MBID + ISRC on songs; release-group MBID only via native `/api/album` (`mbzReleaseGroupId`). Lidarr album = MB release group. LB everything = recording MBID.

**Match ladder** (library ⇄ external): recording MBID 1.0 → ISRC 0.95 → artist MBID+title+|Δdur|≤3s 0.9 → normalized artist+title (+dur) 0.8 / 0.6.

**Request flow ("get this song")**: ISRC/recording → release group → `POST /api/v1/artist` with `addOptions.monitor=none`, `albumsToMonitor=[rg]`, `searchForMissingAlbums=true` (atomic, avoids refresh race). Existing artist → `POST /album` or `PUT /album/monitor` + `AlbumSearch`. Prefer smallest release containing the recording. Then "whole discography" = compute album set from user's default monitoring preference → `PUT /album/monitor` + `monitorNewItems` + `ArtistSearch`.

**Completion**: Lidarr webhook `Download` → backend → Navidrome `startScan target=<lib>:<folder>` → poll `getScanStatus` → locate by MBID/ISRC → push "available". `/queue` polling for progress; reconciliation sweep every 1–5 min.

**Previews**: Deezer `/track/isrc:` → `/album/upc:` → scored Deezer search → LB labs Apple ID → iTunes. Deezer URLs expire ~15 min: resolve just-in-time. Never proxy/cache audio; JSON only.

**Discovery**: LB created-for-you playlists (Daily/Weekly Jams, Weekly Exploration), CF recommendations, LB Radio prompts, labs similar artists/recordings, popularity, fresh releases. "Following" = Lidarr-monitored ∪ starred ∪ top-stats artists. LB token required on all calls; ~1 rps.

## 5. Hard constraints / risks

1. **Lidarr downloads whole albums** — first-song latency is minutes, not seconds. UX must make waiting feel intentional (and the preview bridges it).
2. **Lidarr metadata server** (api.lidarr.audio) has had multi-month outages → retry/backoff, "queued" state, ID-only lookups.
3. **Metadata profiles** default to albums only → we provision our own profiles at setup.
4. **Deezer ToS: strictly non-commercial**; Apple previews require "Listen on Apple Music" badge + attribution. Fine for a personal/self-hosted free app; blocks monetisation.
5. **Navidrome native API is undocumented** → isolate behind an adapter, contract-test against pinned versions.
6. **CarPlay entitlement lead time** → apply immediately.
7. **Toolchain**: this Mac has only CLT (SDK 26.5). Need Xcode 27.x for iOS 27 / iPhone Duo / CarPlay search.
8. **Phase-2 custom audio engine** (AVSampleBufferAudioRenderer) for true crossfade + live FFT is the largest single engineering item.

## 6. Recommended architecture

```
                ┌──────────────── Docker: "the hub" ────────────────┐
 iPhone/CarPlay │  Go service                                        │
 iPad / Duo     │   • auth (validates against Navidrome, issues own  │──► Navidrome  (/api, /rest)
 Mac / tvOS ───►│     session; per-user request permissions)         │──► Lidarr     (API key never leaves hub)
 Web (PWA) ────►│   • /rest + stream reverse-proxy (single URL)      │──► ListenBrainz (per-user token)
                │   • unified search + match index (SQLite)          │──► MusicBrainz / CAA (cached, 1 rps)
                │   • request orchestrator (state machine)           │──► Deezer/iTunes JSON (cached)
                │   • Lidarr webhook → targeted Navidrome scan       │
                │   • discovery aggregator, SSE/WebSocket events     │
                │   • serves SvelteKit web app                       │
                └────────────────────────────────────────────────────┘
```

Clients see **one server URL and one login**. Previews stream straight from provider CDNs.

**Apple**: one multiplatform SwiftUI target (iPhone/iPad/Duo/Mac native) + tvOS target, Swift 6, `@Observable`. Shared Swift packages: `Domain`, `HubClient`, `LibraryStore` (GRDB), `Queue` (pure), `PlaybackEngine` (protocol; v1 dual AVQueuePlayer, v2 sample-buffer renderer), `Downloads`, `Visuals` (SwiftUI shaders + Metal), `DesignSystem`, `CarPlayUI`.

**Web**: SvelteKit 5 SPA/PWA, Web Audio chain (ReplayGain, crossfade, analyser), pre-decoded gapless with dual-`<audio>` fallback on iOS Safari, Media Session API.

## 7. Phasing

0. Foundations — Xcode 27, CarPlay entitlement request, docker-compose dev stack (Navidrome + Lidarr + fixture library incl. gapless test albums), design language, storyboard.
1. Hub core + iPhone library playback (browse, search, queue, gapless, downloads).
2. CarPlay.
3. Discovery + previews + invisible requests.
4. Immersive player (art-centric, particles, envelope-driven visualizer).
5. iPad / Duo / Mac / tvOS / web parity.
6. Engine v2 (true crossfade, live FFT), polish.
Testing + security run continuously from phase 1, not at the end.
