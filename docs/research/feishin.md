# Feishin: engineering research for our Navidrome player

Source studied: `github.com/jeffvli/feishin` @ `8d12eae` (v1.17.0, 2026-10-25), shallow clone, plus GitHub issues via `gh`.
All paths below are relative to the Feishin repo root.

Our target: native Apple apps (SwiftUI + CarPlay) and a Docker-hosted web app, Navidrome-first, with Lidarr + ListenBrainz integration. The notes below say for each area what to **copy**, **adapt**, or **avoid**.

---

## 0. TL;DR

| Area | Feishin approach | Verdict for us |
|---|---|---|
| Stack | Electron 43 + React 19 (React Compiler) + Vite 7 (`electron-vite`), Mantine 9, CSS Modules, Zustand + immer, TanStack Query 5, ts-rest + zod, axios | Web app: same family (React + Vite + TanStack Query + Zustand) is a sound choice |
| API layer | One domain model (`src/shared/types/domain-types.ts`) + per-backend controller + per-backend normalizer; a facade picks the backend by `ServerType` | **Copy the pattern**, but we only need Navidrome (+ OpenSubsonic fallback). Share the domain model between Swift and TS conceptually |
| Navidrome | Hybrid: native `/api/*` (JWT, `x-nd-authorization`) for lists/sorting/filtering/playlists/queue; Subsonic `/rest/*` for stream, cover art, star, scrobble, lyrics, similar songs, artist info, search | **Copy exactly** - this is the right split |
| Web playback | Two `<audio>` elements (via react-player), each piped through `MediaElementAudioSourceNode -> GainNode` (ReplayGain). "Gapless" = start next element ~116 ms before end; crossfade = volume ramps driven by 10 ms progress polling | **Avoid as the gapless solution**. Maintainer says it is "not truly gapless". Use Web Audio scheduled buffers / MSE or accept "near-gapless" on web |
| Desktop playback | mpv over IPC, 2-item mpv playlist (current + next), `--gapless-audio=weak --prefetch-playlist=yes`, mpv's own ReplayGain | **Mirror this on Apple**: `AVQueuePlayer` with current + next item = same model, real gapless |
| Queue | `songs: Record<uniqueId, QueueSong>`, `default: string[]` order, `shuffled: number[]` permutation of indexes, `priority: string[]` ("Up Next") | **Copy** (with a cleaner shuffle model, see 2.6) |
| Scrobble | Accumulated *listened* time (not playhead) vs. threshold (default 75% OR 240 s); `scrobble submission=false` at start = now playing; OpenSubsonic `reportPlayback` for live state | **Copy**, but use Last.fm/ListenBrainz rule (50% or 4 min) |
| Docker web | Static Vite build in `nginx-unprivileged`; runtime config via an envsubst-rendered `settings.js` (`SERVER_URL`, `SERVER_LOCK`, `FS_*` defaults); **no proxy**, browser hits Navidrome directly (needs CORS) | **Adapt**: keep runtime `settings.js` idea, but add a same-origin reverse proxy (also needed for Lidarr/ListenBrainz keys) |
| UI | 3-row grid (title bar / main / 90 px player bar), sidebar, right-side queue/drawer, full-screen player with blurred art + `fast-average-color` tinted background, motion crossfades, virtualized tables/grids with sparse page loader | **Copy** the look; implement natively in SwiftUI |

---

## 1. Architecture

### 1.1 Framework and process layout
- `package.json`: Electron 43, React 19.2, Vite 7, `electron-vite`, `babel-plugin-react-compiler` (`vite.react-plugin.ts`), Mantine 9 for components, `motion` (Framer Motion) for animation, `react-window` v1 (grids) + v2 (tables), `overlayscrollbars`, `cmdk` (command palette), `@atlaskit/pragmatic-drag-and-drop`, `wavesurfer.js`, `audiomotion-analyzer` + `butterchurn` (visualizers), `idb-keyval`, `fuse.js`.
- `docs/agents/architecture.md` describes trees: `src/main` (Electron main: mpv, MPRIS, Discord RPC, DLNA, lyrics scrapers, remote-control server), `src/preload` (`window.api` bridge), `src/renderer` (the whole UI; *also the web build root*), `src/remote` (small remote-control SPA), `src/shared` (types, normalizers, themes, UI primitives).
- Three builds: `electron.vite.config.ts` (desktop), `web.vite.config.ts` (web/Docker, with `vite-plugin-pwa`), `remote.vite.config.ts`.
- Desktop-only features are gated with `isElectron()` and null-checks on `window.api` - meaning the web build silently loses mpv, external lyric providers (lrclib/netease/genius/simpmusic live in `src/main/features/core/lyrics/`), custom themes, Discord. Lesson: **decide on day one which features need a server-side component in the web build**; for us the Docker container should include a small backend (proxy + lyrics + Lidarr + ListenBrainz) so web isn't a second-class client.

### 1.2 API abstraction layer (worth copying)
Documented in `docs/agents/api.md`:

| Layer | Path |
|---|---|
| Feature queries/mutations (`queryOptions`, `useMutation`) | `src/renderer/features/<feature>/api/` |
| Facade: pick backend by current server type | `src/renderer/api/controller.ts` (`endpoints = { jellyfin, navidrome, subsonic }`) |
| Per-backend HTTP client + controller | `src/renderer/api/{navidrome,subsonic,jellyfin}/*-api.ts`, `*-controller.ts` |
| Zod schemas + normalizers -> domain | `src/shared/api/{navidrome,subsonic,jellyfin}/*-types.ts`, `*-normalize.ts` |
| Domain contract | `src/shared/types/domain-types.ts` (`Song`, `Album`, `QueueSong`, `ControllerEndpoint`) |
| Query keys | `src/renderer/api/query-keys.ts` - always `[serverId, resource, ...]` |

Key details:
- HTTP clients are `ts-rest` contracts with zod response schemas (`navidrome-api.ts` `contract = c.router({...})`). Response validation can be toggled (`VITE_VALIDATE_API_RESPONSES`, `src/renderer/api/response-validation.ts`) - nice for catching server-version drift without crashing prod.
- `NavidromeController` composes: methods either hit `ndApiClient` (native) or delegate straight to `SubsonicController.xxx` (e.g. `getStreamUrl: SubsonicController.getStreamUrl`). This "Navidrome = OpenSubsonic + extras" inheritance is the right mental model.
- The domain `Song` (`domain-types.ts:397`) is rich: `albumArtists[]`, `artists[]`, `participants` (role -> artists), `gain`/`peak` (ReplayGain track/album), `bitDepth`, `sampleRate`, `codec`, `container`, MBIDs (`mbzRecordingId`, `mbzTrackId`, `mbzAlbumId`, `mbzReleaseGroupId`), `tags`, `explicitStatus`, `blurHash`/`thumbHash`, `_serverId`, `_serverType`, `_itemType`. **We should keep MBIDs first-class** - they are the join key to Lidarr and ListenBrainz.
- Normalizers handle quirks (e.g. Navidrome playlist tracks have `mediaFileId` vs `id` -> `playlistItemId`, `navidrome-normalize.ts:226`; partial ISO dates; release vs original date).
- Server capability detection: `src/shared/types/features-types.ts` `ServerFeature` enum; `getServerInfo` pings, reads `serverVersion`, merges a Navidrome version table (`navidrome-controller.ts:41` `VERSION_INFO`: smart playlists >=0.48, sharing >=0.49.3, tags/BFR >=0.55, native queue >=0.57, image upload >=0.61) with OpenSubsonic `getOpenSubsonicExtensions`. UI gates on `hasFeature(server, ...)`. **Copy this: a capability set, not version checks scattered in UI.**

### 1.3 Data fetching and caching
- TanStack Query (`src/renderer/lib/react-query.ts`): `staleTime` 10 s, `gcTime` 20 s, no refetch on focus, `throwOnError` only for 5xx, toast on background-refetch errors. Very short caching - they rely on the server being fast.
- Persisted state uses Zustand `persist` with IndexedDB (`idb-keyval`, `src/renderer/store/utils.ts`) - queue can be large, so not localStorage.
- **Big lists**: count-first + sparse page cache. `src/renderer/components/item-list/helpers/item-list-infinite-loader.ts`: suspense query for total count (Navidrome native API returns `x-total-count` header), then a `dataMap: Map<index, item>` filled page-by-page (`itemsPerPage` 100) as the virtual window scrolls, with `fetchThreshold`. This gives correct scrollbar size instantly for 100k+ songs. Copy this for web; on iOS use the same "count + windowed page fetch" behind a `LazyVStack`/`List` data source.
- Separate high-frequency store for playhead: `src/renderer/store/timestamp.store.ts` - so 4 Hz time updates don't re-render the app. Lyrics use `requestAnimationFrame` reading the store directly (`synchronized-lyrics.tsx:134`). Copy: on Swift, keep the playback clock out of the main `@Observable` model (separate object or `TimelineView`).

### 1.4 Web / Docker build
- `Dockerfile`: node builder -> `pnpm build:web` -> `nginxinc/nginx-unprivileged:alpine-slim`, port 9180.
- Runtime config without rebuild: `settings.js.template` is rendered by nginx's built-in envsubst (`/etc/nginx/templates`) into `window.SERVER_URL`, `SERVER_TYPE`, `SERVER_NAME`, `SERVER_LOCK`, `LEGACY_AUTHENTICATION`, `REMOTE_URL`, `ANALYTICS_DISABLED` and ~100 `FS_*` default-setting overrides (`docs/ENV_SETTINGS.md`, `src/renderer/store/env-settings-overrides.ts`). Served with `Cache-Control: no-store` (`ng.conf.template`). `PUBLIC_PATH` supports sub-path hosting.
- `SERVER_LOCK=true` + name/type/url preconfigures the server so users only enter username/password.
- **No proxy / CORS**: the browser calls Navidrome directly. Navidrome native API needs CORS for the `x-nd-authorization` header; issue #289 shows users behind auth portals/bot protection break. Maintainer's recommended workaround: host Feishin on a subpath of the Navidrome domain. Also #681: reverse proxy with `proxy_buffering on` caused 30 s stalls on `stream.view` - document `proxy_buffering off` for streaming.
- **For us**: ship the web app with a tiny same-origin backend (`/api/nd/*` -> Navidrome, `/api/lidarr/*`, `/api/lb/*`), so (a) no CORS, (b) Lidarr API key and ListenBrainz token never reach the browser, (c) lyrics providers work on web. Keep the runtime `settings.js`/env pattern and a `SERVER_LOCK` equivalent.

---

## 2. Playback

### 2.1 Engines
`src/renderer/features/player/audio-player/`: `web-player.tsx` + `engine/web-player-engine.tsx` (HTML audio), `mpv-player.tsx` + `engine/mpv-player-engine.tsx` (desktop), `jukebox-player`, `dlna-player` (casting), `wavesurfer-player-engine.tsx`. `engine/player-handoff.ts` carries pending seek across engine switches. The queue store is engine-agnostic; engines only see `player1`/`player2` songs (`getDualPlayerSongs`, `player.store.ts`).

### 2.2 Web engine: dual audio elements + Web Audio gain
- Two `ReactPlayer` instances (`web-player-engine.tsx:327,353`) with `forceAudio: true`, `crossOrigin: 'anonymous'` (required to route into Web Audio without muting). The store alternates `playerNum` 1/2; the inactive slot is preloaded with the next song.
- On first `onStart`, each element is wrapped with `context.createMediaElementSource(el)` and connected to a per-slot `GainNode` (`web-player.tsx:~560`). ReplayGain applied via `gains[i].gain.setValueAtTime(...)` per slot so the pre-started next track already has the right gain.
- **ReplayGain math** (`web-player.tsx:443`): `gain = 10^((rg + preamp)/20)`, mode track/album with fallback to the other, fallback dB when tags missing, optional clip prevention `min(gain, 1/peak)`, NaN guard. Copy verbatim (it's the hydrogenaudio spec).
- **"Gapless"** (`gaplessHandler`, `web-player.tsx:754`): when within 2 s of end, enter transition; poll progress at 10 ms (`progressInterval={isTransitioning ? 10 : 250}`), and call `nextPlayer.play()` when `currentTime + 0.116 s >= duration` (0.065 s for FLAC). This is timer-based overlap, not sample-accurate. Encoder padding (MP3/AAC priming) isn't handled. Maintainer in #1576: "the web player isn't truly 'gapless', it just attempts to mimic it... switch over to mpv."
- **Crossfade** (`crossfadeHandler`, `web-player.tsx:626`): when `currentTime > duration - crossfadeDuration`, start next at volume 0 then drive both volumes per progress tick with selectable curves: equal-power (`sin`/`cos`), linear, exponential (k=5), S-curve (smoothstep). Nice: curve choice is a user setting (`CrossfadeStyle`).
- Play/pause fades: 300 ms volume ramp via `setInterval` (`fadeAndSetStatus`). Better done with `GainNode.linearRampToValueAtTime` - setInterval ramps are jittery under load.
- Repeat-one detection by wraparound heuristic (`handleRepeatOne`: last > 85% and now < 15%).

### 2.3 Desktop engine: mpv
`src/main/features/core/player/index.ts`:
- Spawns mpv with `--idle=yes --no-config --load-scripts=no --prefetch-playlist=yes --network-timeout=10 --stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_at_eof=1,reconnect_delay_max=5` (`DEFAULT_MPV_PARAMETERS`, line ~104).
- Keeps a **2-entry mpv playlist**: index 0 = current, index 1 = next. IPC: `player-set-queue` (replace + append next), `player-set-queue-next` (remove 1, append new next when the queue changes), `player-auto-next` (remove 0, append new next after a natural advance). User options: `gapless-audio` (`weak` default), ReplayGain mode/preamp/clip/fallback (`src/renderer/features/settings/components/playback/mpv-properties.ts`).
- This is exactly `AVQueuePlayer` semantics. **For iOS/macOS: AVQueuePlayer with current + 1-2 preloaded `AVPlayerItem`s; re-sync the "next" item whenever the queue/shuffle/repeat changes.** Note AVPlayer gapless only works for formats that carry gapless metadata (AAC/ALAC with iTunSMPB, MP3 with LAME header); FLAC/Opus via transcode need `format=aac`/`mp3` or our own `AVAudioEngine` scheduler. Consider `AVAudioEngine` + `AVAudioPlayerNode.scheduleSegment` for true gapless+crossfade if we decode locally (downloaded files).
- Known mpv pain (issues #371, #1610, #2322): socket closed / IPC invalid / control lost after suspend. An in-process engine avoids this whole class.

### 2.4 Transcoding and stream URL
`SubsonicController.getStreamUrl` (`subsonic-controller.ts:1973`):
- Base: `/rest/stream.view?id=..&v=1.13.0&c=Feishin&u=..&s=..&t=..`.
- User transcode on: append `&format=<fmt>&maxBitRate=<kbps>` (`appendTranscodeParams`, line 234).
- If server supports OpenSubsonic **`transcodeDecision`** extension (`ServerFeature.OS_TRANSCODE_DECISION`): POST `getTranscodeDecision.view` with client `directPlayProfiles` (built from what the browser `canPlayType`s - `getDirectPlayProfiles()` in `components/audio-players.tsx:92`) and transcoding profiles; if `canDirectPlay` -> raw stream, else use `getTranscodeStream.view?mediaId&mediaType&offset&transcodeParams=...`. Falls back to direct stream on any error. **This is the modern approach - copy it**: send AVFoundation-playable codecs on Apple (aac, alac, mp3, flac, opus on iOS 17+), browser-playable on web; let Navidrome decide.
- mpv path uses `skipAutoTranscode` (mpv plays anything).
- Stream URL is resolved through React Query (`hooks/use-stream-url.tsx`, `staleTime` 60 s) and the current track's URL is pinned so changing transcode settings doesn't restart the current track.
- Pitfalls from issues: `.mka`/ALAC/M4A fail on web without transcode (#1300, #779, #1587); stale "transcode enabled" setting after upgrade caused `ERR_REQUEST_RANGE_NOT_SATISFIABLE`. Make format support detection automatic, not a user toggle.

### 2.5 Prefetching the next track
- Web: the inactive `<audio>` element gets `src = nextSongUrl` as soon as the current track starts (browser preloads per `preload` default). No explicit byte prefetch/cache.
- mpv: `--prefetch-playlist=yes` on the 2-entry playlist.
- Auto DJ (`hooks/use-auto-dj.ts`, `auto-dj/auto-dj-songs.ts`): subscribes to the queue store; when `remaining < settings.timing`, fetches `getSimilarSongs` (Navidrome -> Last.fm/plugins) for the current song, dedupes against queue, appends (`Play.LAST`), falls back to random/genre songs; album mode adds whole similar albums. Settings: `itemCount`, `onlySimilar`, `allowDuplicates`, strategy.

### 2.6 Queue model
`src/renderer/store/player.store.ts` (2,628 lines, Zustand + immer + `subscribeWithSelector` + persist to IndexedDB) and `QueueData` in `domain-types.ts:69`:
```ts
interface QueueData {
  default: string[];          // canonical order of _uniqueId
  priority: string[];         // "Up Next" (Play next), kept directly after current
  shuffled: number[];         // permutation of indexes into default
  songs: Record<string, QueueSong>; // _uniqueId -> song (nanoid per queue entry)
}
```
- Every queue entry gets a `_uniqueId` (`nanoid`) so the same song can appear multiple times - **copy**.
- `Play` enum: `NOW`, `NEXT`, `LAST`, `SHUFFLE`, `NEXT_SHUFFLE`, `LAST_SHUFFLE`, `INDEX`.
- Shuffle = index permutation; `player.index` is a position in `shuffled` when shuffle is on (`mapShuffledToQueueIndex`). Inserting "next" while shuffled requires bumping all indexes >= insert position (`adjustShuffledIndexesForInsertion`) and splicing new shuffled indexes after the current shuffled index. Starting playback on a specific song moves it to shuffled[0]. Fisher-Yates in `src/renderer/utils/shuffle.ts`.
- Spotify-like "Up Next": `priority` list survives `Play.NOW` (carried into the new queue) and `syncUpNext` keeps it contiguous after current.
- **Avoid**: index-permutation shuffle makes every mutation O(n) with index-fixups and is the source of many bugs (e.g. #1381 shuffle+crossfade+repeat-one). Simpler for us: store two ordered arrays of entry IDs (`originalOrder`, `playOrder`); shuffle rebuilds `playOrder` = played-history + current + shuffled(rest); "play next" inserts into `playOrder` after current (and into `originalOrder` after current's original position); unshuffle maps current entry back into `originalOrder`. IDs, not indexes.
- Server queue sync: `savePlayQueue` / `getPlayQueue`. Prefers OpenSubsonic `savePlayQueue`/`savePlayQueueByIndex` ("credentials never expire") and falls back to Navidrome native `POST /api/queue` (`navidrome-controller.ts:1198`). Restored on startup (`hooks/use-queue-restore.ts`), autosaved (`use-autosave.ts`). **We want this for handoff between iPhone/Mac/web.**

### 2.7 Scrobbling
`src/renderer/features/player/hooks/use-scrobble.ts` (big comment block at top explains rules) + `SubsonicController.scrobble` (`subsonic-controller.ts:2326`):
- **Now playing**: on track `start` event call `scrobble.view?id=..&submission=false`.
- **OpenSubsonic `reportPlayback`** (when supported): `starting` then `playing` on start, `paused`, `playing` on unpause, `stopped` on change; with `positionMs`, `playbackRate`, `ignoreScrobble=true`. Must send *both* `starting` and `playing` (#2131). A short debounce on track changes avoids spamming the server.
- **Submission**: `scrobble.view?submission=true` once, when **accumulated listened time** (only while PLAYING, from consecutive timestamp deltas <= 5 s; seeks re-baseline, not counted) reaches `scrobbleAtPercentage` (default 75) OR `scrobbleAtDuration` (default 240 s), mode configurable (both/percentage/seconds). Resets when playhead returns to < 5 s after being > 10 s (restart) or on repeat.
- Private mode disables everything. Defaults are not Last.fm-standard (50% / 4 min); for ListenBrainz we should use 50% or 4 min.
- Navidrome forwards scrobbles to Last.fm/ListenBrainz itself if the user linked accounts there. Decide whether we scrobble to ListenBrainz directly (client token) or only via Navidrome - **don't do both or you'll double-submit**.
- Bug history: final track in queue not scrobbled with mpv (#1274), scrobbling flaky with private mode toggles (#1889). Make scrobble logic a pure state machine fed by engine events and unit test it.

---

## 3. Navidrome specifics

### 3.1 Auth
- Login: `POST {server}/auth/login {username,password}` returns `token` (JWT), `subsonicSalt`, `subsonicToken`, `id`, `isAdmin` (`navidrome-controller.ts:143`). Feishin stores **two credentials**: `ndCredential` (JWT for `/api`) and `credential = u=..&s=<subsonicSalt>&t=<subsonicToken>` for `/rest`. So it never needs to md5 the password itself for Navidrome.
- Native requests send `x-nd-authorization: Bearer <jwt>`; Navidrome returns a refreshed token in the `x-nd-authorization` response header, which the axios interceptor writes back (`navidrome-api.ts`, response interceptor). On 401, if a saved password exists (Electron secure storage), it re-logs in once (with a shared `shouldDelay` gate so concurrent 401s don't stampede; handles 429 rate limit) and retries. Web build cannot save passwords so JWT expiry = logout; README tells users to raise Navidrome `SessionTimeout` (e.g. 72h).
- Generic Subsonic: random 12-char salt + `md5(password+salt)` (`subsonic-controller.ts:316`), or legacy `p=` plaintext flag.
- **For us**: Keychain-store the password (or better, an API key if Navidrome adds one) and implement the same refresh-on-header + single-flight re-login. Prefer Subsonic token auth for anything long-lived (stream URLs, CarPlay) since it doesn't expire.

### 3.2 Native vs Subsonic endpoints used
Native `/api` (`navidrome-api.ts` contract): `auth/login`, `album`, `album/:id`, `artist`, `artist/:id`, `artist/:id/image` (upload/delete), `song`, `song/:id`, `genre`, `tag` (multi-valued tags, BFR >=0.55), `playlist` CRUD, `playlist/:id/tracks` (add/remove/move), `playlist/:id/image`, `queue` (get/save), `radio` CRUD + image, `share`, `user`.
Why native: server-side sorting/filtering/pagination with `_start/_end/_sort/_order` and `x-total-count`, richer fields (participants/roles, tags, library IDs), filters like `starred`, `has_rating`, role-based artist filtering (`NAVIDROME_ROLES`: composer, conductor, producer, remixer...).

Subsonic `/rest` (`subsonic-api.ts`): `stream`, `getCoverArt` (with `size`), `star/unstar`, `setRating`, `scrobble`, `reportPlayback`, `getLyricsBySongId` (OpenSubsonic structured lyrics, v2 "enhanced" = word-level), `getLyrics`, `getSimilarSongs`/`getSimilarSongs2`, `getArtistInfo2`, `getAlbumInfo2`, `getTopSongs`, `search3`, `getRandomSongs`, `getPlayQueue(ByIndex)`/`savePlayQueue(ByIndex)`, `getTranscodeDecision`/`getTranscodeStream`, `getOpenSubsonicExtensions`, `getScanStatus`/`startScan`, `jukeboxControl`, `getMusicDirectory`/`getIndexes` (folder view).

### 3.3 Smart playlists
- Created/updated through native `/api/playlist` with a `rules` JSON (Navidrome NSP format). UI is a query builder (`src/renderer/features/playlists/components/playlist-query-builder.tsx`, `playlist-query-editor.tsx`) with field list `NDSongQueryFields` (`src/shared/api/navidrome/navidrome-types.ts:73`: album, albumartist, dates, play count, rating, loved, genre, year, bpm, etc.) and operators; plus `limit`, `limitPercent`, `sort` (new syntax: `"+album,-year"`). Gated on `PLAYLISTS_SMART` (>= 0.48).
- Lesson: a visual rule builder is a differentiator; keep NSP JSON as the storage format.

### 3.4 Lyrics
- Server: OpenSubsonic `getLyricsBySongId` (structured, synced, multiple languages, `enhanced=true` for word timing when extension v2) then fallback `getLyrics` (plain). `src/renderer/api/subsonic/subsonic-structured-lyrics.ts`.
- External providers only in Electron main: LRCLIB, NetEase, Genius, SimpMusic (`src/main/features/core/lyrics/*.ts`), plus furigana via kuroshiro and optional translation. Issue #523: lyrics missing in Docker because those providers aren't available in web. Our Docker backend should host LRCLIB lookup.
- Rendering: `synchronized-lyrics.tsx` (line-synced, rAF loop, configurable delay/lead time, follow-scroll alignment), `synchronized-karaoke-lyrics.tsx` (word-level), RTL handling, offsets per lyric.

### 3.5 Artist info, similar, radio
- Artist bio/similar artists/images: `getArtistInfo2` (`navidrome-controller.ts:296`) - Navidrome sources from Last.fm/Spotify/Deezer agents.
- Similar songs / "song radio" / "album radio" / "artist radio": all `getSimilarSongs(id, count)` (Navidrome resolves via agents; can return empty if no agents configured -> fallback needed). Top songs: `getTopSongs` (artist name or id if `topSongsByArtistId`).
- Instant mix in Feishin = Auto DJ (2.5). **For us**: ListenBrainz can supply better radio (LB Radio / similar-recording via MBIDs); map MBIDs back to Navidrome IDs via `song?mbz_recording_id=` filter on native API.

---

## 4. UI and aesthetic

### 4.1 Layout
- `src/renderer/layouts/default-layout.tsx` + `.module.css`: CSS grid rows `[window-bar 0/30px] [main calc(100dvh - 90/120px)] [player 90px]`.
- `layouts/default-layout/`: `left-sidebar.tsx` (nav + playlists, collapsible to icons), `main-content.tsx`, `right-sidebar.tsx` (queue / lyrics / visualizer panel), `side-drawer-queue.tsx`, `full-screen-overlay.tsx`, `player-bar.tsx`. Separate `mobile-layout/` and `mobile-fullscreen-player*.tsx` for small screens (`responsive-layout.tsx`).
- Player bar: left (art + title/artist links + favorite), center (transport + seek slider or waveform `playerbar-waveform.tsx`), right (volume, queue toggle, lyrics, sleep timer, DLNA cast). 

### 4.2 Album-art-driven colour and blur
- `src/renderer/hooks/use-fast-average-color.tsx`: `fast-average-color` with `algorithm: 'dominant'`, `mode: 'speed'`, ignoring near-white/near-black/transparent pixels, deferred via `setTimeout`, cancels stale src. Returns `rgb` + `isDark/isLight`.
- Detail pages (`albums/routes/album-detail-route.tsx`, `artists/routes/album-artist-detail-route.tsx`): header background = dominant colour, optional blurred cover image (`albumBackground`, `albumBackgroundBlur` settings), and `library-background-overlay.module.css` gradient from colour to transparent (with optional dither to avoid banding). Sticky header bar (`library-header-bar.tsx`) picks up the colour on scroll.
- Full-screen player (`features/player/components/full-screen-player.tsx`): two stacked `motion.div` background images cross-faded via `AnimatePresence` on track change, CSS blur (`--image-blur` rem), black overlay with user opacity (divided by 120 so it never goes fully black), or dynamic colour background. Tabs for queue / lyrics / similar songs / visualizer.
- Native equivalents: compute dominant colour once per album server-side or with Core Image `CIAreaAverage`/k-means on a 64x64 thumbnail, cache by `coverArtId`; `.blur(radius:)` + material overlays; `matchedGeometryEffect` for mini-player -> full-screen.

### 4.3 Virtualized lists
- `src/renderer/components/item-list/`: `item-table-list` (react-window v2 `Grid`, resizable/reorderable columns, album group headers), `item-grid-list` (react-window v1), `item-detail-list`, plus a paginated mode. Scroll position persisted per route (`use-item-list-scroll-persist.ts`), list hotkeys (`use-list-hotkeys.ts`), multi-select + drag (pragmatic-drag-and-drop).
- Data via the sparse infinite loader (1.3). Images carry `blurHash`/`thumbHash` placeholders when the server provides them.
- **Avoid**: the sidebar playlist list is *not* virtualized - #2611: 4,500 playlists -> 85k DOM nodes, 3 s freeze on every navigation (react-router `<Link>`/`useHref` re-rendering). Navidrome auto-imports per-album `.m3u` files as playlists (users with 23k playlists). Virtualize *every* list including sidebars, and guard against `.m3u` auto-import floods (filter by owner/comment).
- Other perf traps: double-clicking a row on the Songs page queues the *entire library* (#681) - cap "play all" or stream the queue lazily; the `tag` list fetch is unpaginated and can be huge on big libraries (#1593).

### 4.4 Keyboard shortcuts, command palette
- `BindingActionsSchema` (`src/renderer/store/settings.store.ts:141`): play/pause, next/prev (and next/prev *album*), skip fwd/back, volume, mute, shuffle/repeat toggles, rate 0-5, favorite current/previous, global/local search, toggle queue, toggle full-screen player, zoom, list actions (play now/next/last, show playing song). Global media keys on desktop. `cmdk` command palette for search. On Apple: `.keyboardShortcut`, `MPRemoteCommandCenter`, menu bar commands.

### 4.5 Theming
- ~35 built-in themes in `src/shared/themes/*` (default dark/light, catppuccin, nord, rose-pine, tokyo-night, gruvbox, "glassy-dark", high-contrast...), theme = colour tokens + app vars + Mantine overrides; accent colour and primary shade configurable; follow system theme. Desktop supports user JSON themes with `extends`, hot-reloaded (`docs/CUSTOM_THEMES.md`). Plus custom CSS injection (`FS_CSS_*`).
- For a premium Spotify-like product we should ship 1 excellent dark + 1 light theme with accent derived from artwork rather than 35 themes.

### 4.6 What makes it feel premium
1. Colour-tinted headers and blurred-art backgrounds with soft gradients (no hard edges, dithered).
2. Animated cross-fades on art/background changes (`motion`), not instant swaps.
3. Instant-feeling huge lists (count-first virtualized tables, placeholders, scroll restore).
4. Rich now-playing: synced/karaoke lyrics, similar songs, visualizers (audiomotion, butterchurn/Milkdrop), waveform seekbar.
5. Fine control: crossfade curves, ReplayGain, Up Next, play next album, sleep timer, auto DJ.
6. Many OS integrations: MPRIS/Media Session (`hooks/use-media-session.ts`), Discord RPC, DLNA cast, remote-control web page.

---

## 5. Known problems worth avoiding

| Problem | Evidence | Our mitigation |
|---|---|---|
| Web "gapless" is approximate; ReplayGain volume jumps at track starts | #1576 (maintainer: "isn't truly gapless... use mpv"), #1450 | Native: AVQueuePlayer/AVAudioEngine. Web: decode-and-schedule via Web Audio for gapless albums (or MSE), set gain *before* `play()`, use `setTargetAtTime` ramps |
| Two tracks playing at once after tab/display wake (Safari, Firefox) | #2290, #705 (open) | Single source of truth for "which element is active"; on `visibilitychange` reconcile and pause all non-active elements; never auto-`play()` the inactive element outside a transition |
| Crossfade regressions (freeze at 0:02, quieter output, shuffle+repeat-one) | #2466, #1109, #1381, #665, #871 | Treat transitions as an explicit state machine with tests; avoid timer-polled ramps |
| Auto-advance sometimes stops | #550 | Don't rely solely on `ended`; also watch `timeupdate` near duration; recover on `stalled`/`error` |
| mpv IPC fragility | #371, #1610, #2322 | In-process engine on Apple |
| Sidebar not virtualized; huge playlist counts | #2611 | Virtualize everything; filter auto-imported m3u playlists |
| Playing "all songs" queues whole library | #681 | Lazy/streamed queue or cap with "load more" |
| Unpaginated tag fetch on big libraries | #1593 | Paginate or lazy-search tags |
| Reverse proxy buffering stalls streams | #681 | Docs: `proxy_buffering off` for `/rest/stream` |
| CORS/auth-portal breakage in web build | #289 | Same-origin proxy in our container |
| Session expiry logs user out (any 401 -> logout) | #214, README SessionTimeout advice | Silent re-auth with stored secret, single-flight; Subsonic token for media URLs |
| Web build loses lyrics providers, custom themes, password storage | #523, `docs/CUSTOM_THEMES.md` | Server-side companion in Docker |
| Unsupported codecs on web (.mka, ALAC, some M4A) | #1300, #779, #1587 | OpenSubsonic `getTranscodeDecision` with real `canPlayType` profiles |
| Offline / download is the oldest open request | #47 (open since early days) | Plan downloads + offline queue from day one on iOS (CarPlay needs it) |
| No A-Z jump index | #148 (open) | Add section index scrubber (natural on iOS) |
| `player.store.ts` is 2.6k lines; scrobble hook 900 lines | source | Split queue model (pure, testable) from engine adapters and side-effects |

---

## 6. Recommendations for our build

**Copy**
- Domain model + per-backend normalizer + capability flags (`ServerFeature`) + facade. Keep MBIDs first-class.
- Navidrome hybrid API split (native for library browsing with `x-total-count`; Subsonic for stream/art/star/scrobble/lyrics/similar). Store both JWT and subsonic `s/t` from `/auth/login`; refresh JWT from `x-nd-authorization` response header.
- Count-first sparse page loader for big lists; separate high-frequency playhead store.
- Queue entries with unique IDs; Up Next priority lane; server queue sync (OpenSubsonic `savePlayQueueByIndex` preferred).
- ReplayGain math, selectable crossfade curves (equal-power default).
- `getTranscodeDecision` with client codec profiles; fallback `format`+`maxBitRate`.
- Scrobble state machine: accumulated listen time, now-playing at start, `reportPlayback` `starting`+`playing`/`paused`/`stopped`.
- Runtime `settings.js` env injection + `SERVER_LOCK` in Docker; nginx `try_files` SPA + `no-store` for config.
- Visual language: dominant-colour gradients, blurred art, animated background crossfade, synced lyrics with rAF.

**Avoid / do differently**
- Timer-polled dual `<audio>` "gapless" as the only web strategy; setInterval volume fades.
- Index-permutation shuffle with O(n) fix-ups; monolithic stores.
- Browser-direct calls to Navidrome needing CORS; secrets in the browser.
- Non-virtualized sidebars; unbounded "play all"; unpaginated tag fetches.
- 35 themes and every-option-is-a-setting sprawl; pick strong defaults.
- Treating offline/downloads as an afterthought.
