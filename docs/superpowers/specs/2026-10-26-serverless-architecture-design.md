# Serverless architecture & build plan

Status: revised after owner feedback (no MusicKit; open sources only; fast MP3 → lossless) · awaiting approval · 2026-10-26
Supersedes the "hub" recommendation in `docs/research/00-synthesis.md` §6.
Evidence: `docs/research/serverless-feasibility.md`, `tubifarry.md`, `open-previews.md`, `sandbox-samples.md`, `slskd-direct.md`, plus the earlier research files.

Working name in this doc: **the app**. (Name and brand come in the storyboard/design-language phase.)

---

## 1. Intent

A Spotify-grade music app for people who self-host Navidrome. The user never sees "Navidrome", "Lidarr", "ListenBrainz" or "slskd": they see one music service where some songs are *in your library* and some are *not yet*. Searching finds both. Tapping a song that isn't in the library gets it playing as fast as the owner's setup allows — often within a minute — as a real file in a holding area. If they like it, **Add** keeps it, upgrades it to lossless, and brings in the artist's discography according to their default. If they don't, it quietly disappears.

Platforms: iPhone (with CarPlay — the priority), iPhone Duo, iPad, Mac, Apple TV, and a web app shipped as a Docker image.

Primarily personal use; commercial model is a one-time purchase.

### Why no server

General users won't trust (or run) a new Docker backend. So **everything we ship is a client**: UI, UX, and all request/download logic live inside the apps. The apps talk directly to services the owner already runs.

### Services the app talks to

| Service | Required? | Used for |
|---|---|---|
| Navidrome | Required | Library, streaming, playlists, scrobbling (Navidrome forwards to ListenBrainz), the request mailbox |
| Lidarr | Required for requesting | Adding artists/albums, downloading, tagging, upgrading |
| ListenBrainz (+ labs API) | Recommended | Discovery, recommendations, radio, song search outside the library |
| Tubifarry (Lidarr plugin) | Recommended | Faster downloads, lyrics, auto-retry. Detected, never configured by us |
| slskd | Optional, power users | "Fast lane": single-track fetch in ~20–45 s |
| Open audio catalogues (Internet Archive curated collections, Openverse, Wikimedia Commons) | Built in, keyless | Instant previews for the small share of songs that are openly licensed |

No proprietary or closed preview services (no Apple MusicKit, Spotify, Deezer, YouTube).

## 2. Goals, non-goals, anti-goals

**Goals**
- One login experience; the underlying services are invisible after setup.
- Library playback as good as the best existing clients (gapless, prefetch, offline, transcoding, CarPlay).
- Search that merges library and non-library results into one list.
- "Try it" for any non-library song: real audio, as fast as the setup allows, auto-expiring if not kept.
- "Add": keep → upgrade to lossless → discography per the user's default.
- Three speed tiers detected automatically: **fast lane (slskd)**, **Tubifarry**, **plain Lidarr**.
- Every household member can try and add music to the shared library.

**Non-goals**
- Any backend service we write, host, or ask users to run (beyond the static web-UI container).
- Proprietary preview APIs.
- Social features, podcasts, video.

**Anti-goals (failure even if it "works")**
- The user sees Lidarr/slskd jargon outside the one-time setup screens.
- A household member can wipe the library because the app handed them a key without the owner choosing that.
- Plays counted twice in ListenBrainz, or tried-but-not-kept songs polluting stats, shuffle or mixes.
- "Converting" MP3 to FLAC (fake lossless). Upgrades always replace with a genuine lossless download.
- The app naming or advertising Soulseek, YouTube, or other piracy-adjacent sources.

## 3. Constraints (verified)

| Fact | Consequence |
|---|---|
| Lidarr `/api/v1`, Navidrome, ListenBrainz `/1/*` + labs, slskd API all allow CORS `*` | Browser can call all of them directly. |
| Lidarr SignalR hub has no CORS | Web polls Lidarr. |
| Lidarr API key is unscoped and root-equivalent; `/initialize.json` can leak it on LAN | Key distribution is a deliberate owner choice; setup audits Lidarr auth. |
| slskd API keys are effectively full control in 0.26.x (even "readonly" can download/delete) | slskd key lives only on Keeper devices. |
| Navidrome `startScan` is admin-only | Lidarr's built-in Subsonic connection rescans on import; Keepers (Navidrome admins) call `startScan` after moves/deletes. |
| No open source has legal previews of mainstream music (live test: ~2–5% hit rate, ~0% chart music) | Open previews are a bonus; "Try it" via real download is the main path. |
| Lidarr is album-granular; only slskd can fetch one track | Fast lane = slskd single file + Lidarr manual import. |
| No server ⇒ no APNs push | Polling while active, background refresh, optional Lidarr→ntfy. |
| Lidarr metadata server has had long outages | Calm "queued, will retry" state. |
| Lidarr default metadata profile excludes EPs/Singles | Setup provisions our profiles. |
| App Review 5.2.3 forbids facilitating illegal file sharing; no slskd/Soulseek app exists on the App Store | slskd code never ships in App Store binaries (see §9). |

## 4. Roles and how requesting works without a server

- **Keepers** (the owner, plus anyone the owner trusts): their app holds the Lidarr (and optional slskd) credentials in Keychain and is a **Navidrome admin**, because only admins can read other users' private mailbox playlists. Keeper devices perform work directly.
- **Listeners** (everyone else): no keys. They try and add music the same way; their app writes into a **mailbox** that Keepers process.

### The mailbox

Each user has a private Navidrome playlist (hidden from all UI) whose `comment` field holds a small JSON document. Verified end-to-end: readable/writable by its owner and Navidrome admins only; the Keeper writes status back; the Listener reads it.

```
{ "v":1, "requests":[ { "id":"uuid", "kind":"try|song|album|artist",
  "mbid":"…", "isrc":"…", "title":"…", "artist":"…",
  "discography":"albums+eps", "at":"2026-10-26T…",
  "status":"pending|accepted|searching|downloading|importing|ready|kept|expired|failed",
  "progress":0.42, "tier":"fast|tubifarry|lidarr", "note":"…" } ] }
```

Read-modify-write with optimistic retry; per-user cap on open items (default 25). Mailbox JSON from Listeners is untrusted input: schema-validated, size-limited, status fields ignored when written by the Listener.

### Who processes the mailbox

- **The Mac helper** (menu-bar app, approved by owner): sweeps mailboxes every few seconds while anyone is active, every minute otherwise. This is what makes requests feel instant, and it is the **only Apple-platform place the fast lane runs** (§9).
- Keeper iPhones/iPads: sweep when foregrounded, during playback, and on background refresh.
- Web app (Keeper mode): sweeps while open.

Keepers' own actions also go through their own mailbox, so history and "who added what" look the same for everyone. De-duplication: the processor checks Lidarr and joins an existing item rather than creating a new one; a per-artist lock prevents races.

### Invites

The owner adds people from the app: **Listener** (default) or **Keeper**. Invites can create a new Navidrome account (via the native user API) or attach to an existing one; the invitee sets their own password. The app produces a QR code / deep link carrying server addresses (home and away) and, for Keepers, the keys — encrypted with a one-time code shown on the owner's screen. Nobody but the owner ever types a key.

## 5. Identity and matching

MusicBrainz IDs are the spine. Navidrome exposes recording MBID + ISRC on songs, release MBID on albums (Subsonic) and release-group MBID via native `/api/album` (`mbzReleaseGroupId`). Lidarr albums are release groups. ListenBrainz is recording-MBID native.

Each client keeps a local **match index** (GRDB on Apple, IndexedDB on web) built from Navidrome's native API. Match ladder: recording MBID 1.0 → ISRC 0.95 → artist MBID + title + |Δduration| ≤ 3 s 0.9 → normalized artist+title (+duration) 0.8/0.6.

Navidrome's native API is undocumented: behind an adapter with contract tests pinned to supported versions; Subsonic-only fallback if it breaks.

## 6. Search

One query fans out in parallel and merges into one ranked list (Top result, Songs, Artists, Albums, Playlists):

| Source | Gives | Notes |
|---|---|---|
| Navidrome `search3` | Library songs/albums/artists | Instant; always outranks; excludes the Samples library |
| ListenBrainz labs `recording-search` + `/1/metadata/recording` | Non-library songs (album, artist, ISRC) | Keyless |
| Lidarr `/search`, `/artist/lookup`, `/album/lookup` | Non-library artists/albums, artwork, bios | Keeper only; degrade silently on outage |
| ListenBrainz/MusicBrainz metadata | Non-library artists/albums for Listeners | Same data LB's own site uses |
| ListenBrainz popularity | Ranking signal | Re-ranks fuzzy matches |
| Tubifarry similar-artist search | "Similar to…" | When detected |

External results that match a library item merge into it (no duplicates). Songs in the Samples library show as "trying" rather than as library items.

## 7. Hearing music that isn't in the library

Tap a non-library song → the app picks the best available path, in this order:

1. **Open preview (instant, rare).** Provider ladder (all keyless, commercial-safe allow-list): MusicBrainz free-download/streaming URL relationships → Internet Archive curated collections (78rpm, netlabels, Jamendo mirror, Musopen; Live Music Archive only if the owner enables non-commercial sources) → Openverse with commercial-licence filter → Wikidata/Commons → ListenBrainz's IA lookup. Anonymous/unlicensed uploads are filtered out. If found, it plays immediately (labelled with its licence/source in the info sheet), and **Try the real thing** is offered alongside.
2. **Try it (real file, auto-expiring).** The default when no open preview exists (~95% of the time). The song is fetched into the **Samples** library at the fastest tier available (§9), plays as soon as it lands, and is removed after N days (default 7) unless the user taps **Add**.

The "Try it" wait is a designed moment, not a spinner: the art comes forward, the tier's honest estimate is shown ("about a minute", "a few minutes", "usually within the hour"), and if the user leaves, a notification/Live Activity tells them it's ready. If the user starts something else meanwhile, the tried song lands in a "Ready to try" shelf instead of interrupting.

Tried songs never scrobble (the app doesn't call `scrobble`, and a per-user Navidrome scrobble filter on the Samples library is the backstop) and are excluded from shuffle, smart mixes, random and stats.

## 8. Samples library, Add, and expiry

Setup (owner, one-time): create a `samples` folder visible to Lidarr and Navidrome; the app creates the Lidarr root folder and the Navidrome library (`POST /api/library`) and grants every user access (`PUT /api/user/{id}/library`). If the owner skips this, "Try it" degrades to a song-level request into the main library (no auto-expiry).

**Try** (artist not in Lidarr): add artist with root folder = Samples, tag `sample`, **Fast Start** quality profile (MP3 320/V0 only), our metadata profile (includes Singles/EPs), monitor none — then explicitly re-monitor the artist (Lidarr leaves it unmonitored otherwise, hiding albums from later searches). Fetch per tier (§9).
**Try** (artist already in Samples): reuse it. **Try** (artist already in main library): skip Samples — it's a normal song request into the main library, with "Remove" offered later.

**Add**: one `PUT /artist/editor` moving the artist to the main root folder (`moveFiles:true`), switching to the **Lossless** profile (FLAC, upgrades allowed, cutoff FLAC), removing the `sample` tag → Keeper calls `startScan` → then the discography expansion by the user's default (Nothing more · This album · Albums · Albums + EPs (default) · Everything incl. singles · Future releases only) via `PUT /album/monitor`, `monitorNewItems`, `ArtistSearch`. Song IDs, likes and play counts survive the move (verified). Lidarr then replaces the MP3 with a genuine FLAC; the UI shows a quiet quality badge change.

**Guard**: any Add/album/artist request for an artist still in Samples performs the move first, so discographies never land in Samples.

**Expiry**: any Keeper device deletes artists tagged `sample` older than N days with no Add (`DELETE /artist?deleteFiles=true&addImportListExclusion=true`), calls `startScan`, clears Navidrome missing entries (`DELETE /api/missing`). Limits: per-user and household sample caps; disk quota from Lidarr's size stats; ask first when the only release containing the song is a full album.

## 9. Speed tiers

Detected on connect and re-checked daily: Lidarr `/system/plugins`, `/indexer`, `/downloadclient`, `/metadata`, `/notification` for Tubifarry; slskd reachability + login state + a shared-folder check (Lidarr can see slskd's downloads path) for the fast lane.

| Tier | Needs | First-song path | Typical wait |
|---|---|---|---|
| **Fast lane** | slskd configured by owner, folder check passes; runs on Mac helper or web (Keeper) | slskd search (cancel at ~6 s, rank: title/artist match, 320/V0, duration ±3 s, free slot, speed) → download one file into a per-request folder → Lidarr `ManualImport` into the artist/album (tags written, file renamed) → rescan → play. Lidarr's smallest-release search starts **in parallel**, so fallback costs nothing | ~20–45 s |
| **Tubifarry** | Tubifarry detected with a working source | Smallest release group containing the recording (Single → EP → Album) via Fast Start profile | ~1.5–5 min |
| **Plain Lidarr** | Always | Same, with the owner's indexers | 10 min – hours |

Fast lane falls back automatically when nothing good is found, three peers fail, or 60 s pass.

**Fast-lane traps handled in code** (from live tests): `replaceExistingFiles=true` only when the album has no files (otherwise `false` + explicit `startScan`); setup enables Lidarr track renaming and audio-tag writing; check Tubifarry's slskd "Inclusive" option to avoid it grabbing our files; don't rely on slskd transfer records (Tubifarry clears them); search one at a time (slskd returns 429), polite pacing.

**Where the fast lane code lives** *(recommended — your call, §13)*: only in the **Mac helper** (distributed as a notarized direct download, outside the Mac App Store) and the **self-hosted web app**. The App Store iPhone/iPad/TV apps contain no slskd code: their "Try it" writes to the mailbox and the Mac helper runs the fast lane, so an iPhone user with the Mac helper still gets ~30–60 s. Without a Mac helper, iPhone gets the Tubifarry or plain-Lidarr tier.

**Feature differences by setup** (missing features are absent, never greyed out):

| Capability | Plain Lidarr | + Tubifarry | + Fast lane |
|---|---|---|---|
| Try / Add / discography | ✓ | ✓ | ✓ |
| First song | slow | minutes | under a minute |
| Synced lyrics for new music | if in files | ✓ | ✓ (with Tubifarry) |
| Similar-artist search extras | LB only | ✓ | ✓ |
| Auto-retry stuck downloads | app retries | ✓ | ✓ |

The app only **detects** Tubifarry and never writes its settings. Settings → Library carries one neutral line recommending it for faster arrivals. The fast lane appears in setup under a neutral name ("Quick fetch"), off by default, Keeper-only, never described with Soulseek/P2P wording, and absent from App Review demo setups.

## 10. Request pipeline (state machine)

A pure, deterministic state machine in a shared core (Swift package; TypeScript port for web; shared test vectors). Same path for Keeper actions and mailbox items.

```
pending → resolving → adding → searching ─┬─ fast lane: fetching → importing ─┐
                                          └─ lidarr: downloading(n%) → importing ┴→ ready → (kept | expired)
                     ↘ waiting (metadata outage / nothing yet; backoff)   ↘ failed (human sentence + admin detail)
```

Progress (polling): `/queue/status` every 5–10 s while visible → `/queue` → `/history/since` → `/track?albumId=` `hasFile` → match index finds the song in Navidrome → `ready`. Slskd transfer progress drives the fast-lane bar.

## 11. Discovery (ListenBrainz)

- Home shelves: Daily Jams, Weekly Jams, Weekly Exploration, Top Discoveries/Missed; "Because you listened to…" from CF recommendations; New releases from followed artists (fresh releases ∩ (starred ∪ Lidarr-monitored ∪ top-stats)); "Ready to try".
- Radio / smart mixes: LB Radio prompts — library tracks play; non-library tracks show with Try.
- Artist pages: popular tracks (LB popularity), similar artists (labs).
- Scrobbling: **Navidrome does it**; app only calls Subsonic `scrobble`. Never for open previews or tried songs.
- Each user's ListenBrainz token stored in Keychain (or delivered via invite).

## 12. Platform architecture

**Apple** (Xcode 27, Swift 6, iOS/macOS/tvOS 27 SDKs, Liquid Glass):
- One multiplatform SwiftUI target (iPhone / Duo / iPad / Mac) + tvOS target + CarPlay scene. Separate **Mac helper** target (menu bar, Developer ID distribution).
- Swift packages: `Domain`, `NavidromeKit`, `LidarrKit`, `ListenBrainzKit`, `OpenPreviews` (provider ladder), `MatchIndex` (GRDB), `Requests` (state machine, mailbox, sweeper, samples lifecycle), `QuickFetch` (slskd — linked only into the Mac helper), `Queue` (pure), `PlaybackEngine` (protocol; v1 dual `AVQueuePlayer` decks; v2 sample-buffer renderer), `Downloads` (background URLSession, 3-tier cache), `Visuals`, `DesignSystem`, `CarPlayUI`.
- Background: `BGAppRefreshTask`, local notifications, Live Activity while the app is alive.
- Secrets: Keychain, after-first-unlock (CarPlay works locked). ATS: `NSAllowsLocalNetworking`; trust-on-first-use pinning for self-signed certs.

**Web** (static Docker image, no logic server-side, no secrets server-side): SvelteKit 5 SPA/PWA served by nginx; `settings.js` from env vars; optional pure pass-through locations for mixed-content/LAN access (off by default); TypeScript port of the state machine incl. Quick fetch; Web Audio chain, pre-decoded gapless with dual-`<audio>` fallback; Media Session API. Keys in browser storage only when the owner opts into Keeper mode.

**Reaching servers from anywhere**: each service has an ordered list of addresses (LAN, public, Tailscale); the app probes on network change and uses the first that answers; offline mode when none do.

## 13. Setup flow (owner, once)

1. Navidrome URL + login → version, capabilities, admin status.
2. Lidarr URL + key → auth audit, Tubifarry detection, metadata profiles (Albums+EPs, Everything), quality profiles (**Fast Start** MP3 320/V0; **Lossless** FLAC with upgrades), enable track renaming + tag writing, Subsonic connection → Navidrome, root-folder ↔ library path check.
3. Samples: guided one-time folder creation; app creates Lidarr root folder + Navidrome library + user access.
4. Optional Quick fetch (Mac helper / web only): slskd URL + key, shared-folder check.
5. ListenBrainz token; confirm Navidrome's LB scrobbling is on.
6. Household defaults: discography preference, sample expiry, caps.
7. Invite people.

## 14. Decisions

**Owner (2026-10-26)**
1. No custom server; apps talk only to the owner's services.
2. Lidarr with and without Tubifarry (recommended); fast first song is a priority.
3. Every user can request into the shared library.
4. Commercial model: one-time purchase (universal), web image free.
5. First release: iPhone + CarPlay (+ Mac helper).
6. Mac helper approved as the request processor.
7. No Apple MusicKit — open sources only for previews.
8. Fast MP3 first, genuine lossless later; direct slskd connection allowed as an option.

**Still yours**
- **Where Quick fetch runs** (§9): my recommendation is Mac helper (direct download) + web only, never in App Store binaries.

**My calls (check these)**
- Keeper = Lidarr key holder + Navidrome admin; Listener mailbox in a private playlist comment.
- "Try it" via a Samples library with 7-day expiry; Add moves + upgrades + expands.
- Open-preview provider ladder with commercial-safe allow-list; non-commercial sources off by default.
- Default discography: Albums + EPs. Listener requests run without approval, capped.
- Multiple addresses per server with automatic switching.
- GRDB not SwiftData; native SwiftUI Mac not Catalyst.

## 15. Build plan (phases)

Each phase ends with a working, tested slice. Testing and security run inside every phase.

0. **Foundations** — Xcode 27 + CarPlay entitlement (owner). Dev-only docker-compose: Navidrome + Lidarr (+ Tubifarry variant) + slskd (offline, API-shape only) + fixture library (gapless albums, MP3 w/o LAME tags, transcoding cases, huge-library generator). Repo, CI, package skeletons.
1. **Storyboard & design language** — journeys, screen map, the "Try it" wait choreography, request states, native vs immersive modes, motion and type. Approved before UI code.
2. **Core playback (iPhone)** — login, browse, library search, queue, dual-deck gapless, prefetch, downloads, Now Playing.
3. **CarPlay** — tabs, browse, iOS 27 search, now playing, locked-phone tests.
4. **Requests & Try it** — LidarrKit, state machine, setup flow, Samples lifecycle, tier detection, mailbox, invites, merged search, notifications, **Mac helper with Quick fetch**.
5. **Discovery & open previews** — ListenBrainz shelves, radio, OpenPreviews ladder.
6. **Immersive player** — art-centric mode, particles, envelope-driven visualizer, Reduce Motion/Low Power budgets.
7. **Platforms** — iPad, Duo, full Mac app, tvOS, web app + Docker image.
8. **Engine v2** — true crossfade, live FFT visualizer.

**Agent team**: architect/integrator; playback engineer; library & data engineer; requests engineer (Lidarr, Samples, mailbox); quick-fetch engineer (slskd, Mac helper); CarPlay engineer; UI engineers (native, immersive/visuals); web engineer; test designer (edge-case scenarios, fixtures, contract tests against pinned versions); security reviewer. Every merge passes tests + a reviewer agent.

**Security test themes**: keys never leave Keychain/never logged; invite encryption and replay; malicious mailbox JSON from a Listener (oversized, forged status, injection); Listener attempting Keeper actions; credential stripping in logs (`u`,`t`,`s`,`p`,`apiKey`, `X-API-Key`); slskd search results as untrusted input (filenames, path traversal in download paths); manual-import path confinement to the per-request folder; Samples expiry never touching the main library; TLS downgrade and pin changes; web XSS via metadata; CarPlay locked-device access; App Store binaries contain no QuickFetch symbols (build check).
