# v1 decision review: adversarial pass on D1–D17 and the v1 build design

Date: 2026-10-26 (night) · Reviewer: independent principal-engineer / product reviewer agent
Reviewed: `docs/decisions.md` (D1–D17), `docs/superpowers/specs/2026-10-27-magpie-v1-build-design.md` ("v1"), `docs/superpowers/specs/2026-10-26-serverless-architecture-design.md` ("parent"), all five `docs/reviews/design-critique-*.md`, `docs/research/lidarr-navidrome.md`.
Verified live where possible against the running dev stack (Navidrome 0.64.2, Lidarr 3.2.0.5144) and upstream source (Lidarr `ArtistEditorController.cs` / `ArtistEditorResource.cs`, ListenBrainz metadata API docs).

**Bottom line.** The triage holds up. No Critical finding was dropped without a reason. Most were deferred along with the mailbox, which is legitimate because v1 has no mailbox. The v1 design does have problems:

- **Lidarr facts.** Three are wrong in ways that will cause bugs: the Finds metadata profile, album tagging, and treating the Keep move as synchronous.
- **Safety.** The design lets Magpie delete or move files in folders it didn't create. The "root folder whose path contains `samples`" auto-detect is the worst case.
- **Completion bar.** "Done" is a single all-or-nothing state, so a night that ends early leaves nothing finished. The build needs milestones, each one shippable.
- **Environment.** The build machine's `xcode-select` points at Command Line Tools. Every `xcodebuild` will fail until agents set `DEVELOPER_DIR`.

---

## 1. Verdict per decision

| # | Verdict | Notes |
|---|---|---|
| D1 Owner-only Curator v1 | **Agree** | Correct cut. It makes Feasibility C1–C4 (mailbox, household, lease) moot for v1. |
| D2 Character dial in v1 | **Change:** build **Signature only** through milestone M5. Classic and Immersive-lite come in M7 as token swaps. | Theming is cheap only once the components exist. Three themes × light/dark × the a11y contrast tests (D15) is about 6× the visual QA surface on the night. The owner said the look is "perfect", which refers to Signature. The dial must never change state meaning (UX H2.4): Classic uses the same text + symbol status. |
| D3 Round record, text + symbol always | **Agree** | Rejecting "finds as square sleeves" is defensible: UX H2 is High, not Critical, and A11y C2's real ask (never shape-only) is met. Add the CarPlay depth consequence from D12 (below). Artists: plain circle + caption, no groove ring at 44 pt in the car. Drop the groove ring for not-yet artists everywhere; UX H2.2 is right that it's invisible at small sizes. |
| D4 Library-first search | **Agree, extend:** also take UX H3.2 (two bands: library rows, then a "Not in your library yet" sub-header, never interleaved) and H3.3 (collapse LB duplicates to one row per artist+normalised title). | The two bands are easier to build than a mixed ranker, and the collapse prevents five "Try" rows for one song. |
| D5 Keep = release; optional "Bring in more" | **Change:** (a) Keep moves the **whole artist** in Lidarr (`artist/editor` is artist-level). The copy must say so when the artist has other finds. (b) The "approximate size from Lidarr album statistics" doesn't exist: `statistics.sizeOnDisk` only counts downloaded files. Estimate from album `duration` × codec bitrate (FLAC ≈ 900 kbps), or show no number (Feasibility M1). (c) Ship the follow-up sheet in M7. For M6, Keep = release only. | See API corrections A3 and A5. |
| D6 One landing rule | **Agree** | The CarPlay bridge mix must be library songs only, with the audio session activated only when real audio starts (CarPlay H3). |
| D7 Honest progress | **Agree** | |
| D8 Patient tier → "Ask for it" | **Agree, specify:** v1 tier = **Standard** if Tubifarry is detected (`/system/plugins` lists it, or an indexer/download client `implementation` contains "Tubifarry"), else **Patient**. | With plain Lidarr, every Try is "Ask for it" with no wait screen. That is honest. Test that path first, because it's the likely one tomorrow. |
| D9 Start listening first; nothing written without a tap | **Agree, strengthen:** add a single **"Allow Magpie to change Lidarr"** master switch (off until the owner flips it in the setup card). It also gates provisioning, Try, Keep and Not for me. Tags can't apply to albums (A2), so "everything tagged `magpie`" needs a **local ledger** of every Lidarr object Magpie created. | |
| D10 Finds lifecycle, no auto-expiry | **Agree**, with the guards in §3. | |
| D11 Mailbox v2 spec | **Agree** (spec only). | |
| D12 CarPlay list roots, ≤2 pushes | **Agree, close a gap:** the path Library › Artists › Artist › Album is 4 deep, which already breaks "tab root + 2 pushes". Adopt CarPlay H1.2: on the Artist template, tapping an album **plays** it and doesn't push a tracklist. Tracklists are reachable only from Albums, Playlists and Home. Assert `templates.count ≤ 3` before any browse push. | |
| D13 App Store posture | **Agree, plus:** add the Devil's cheap probe to the owner's list: an external-TestFlight review of a minimal Try build **before** investing in v2 household work. D13 dropped this without comment. | It isn't relevant to tonight, but the probe is the only way to get an early verdict. |
| D14 Keep "Bringing it home" | **Agree** (owner's voice; disclosure fixes concealment). Low cost to revisit. | |
| D15 A11y baseline | **Agree**, but bind it to milestones: labels, values, actions and Dynamic Type ship with each screen in the milestone that builds it, not as a final pass. The contrast unit test runs against Signature tokens from M1. | |
| D16 Cut "Top this week in your house" | **Agree** | |
| D17 Account deletion before invites | **Agree** | |

### Did the lead water down any Critical?
- **Feasibility C1–C4, UX C4, Devil C2 (Listener pickup):** deferred with the mailbox and household features. Legitimate.
- **Feasibility C2 (expiry deletes):** no expiry job in v1, but **Not for me** inherits the same risk. v1 has a path-prefix check. It lacks the "re-GET before delete" check, ledger ownership, recycle-bin awareness, and a ban on artist `deleteFiles=true`. Fix this (see §3).
- **UX C2 (Keep downloads six releases):** accepted on the phone, with Albums+EPs still preselected on the follow-up. That's acceptable because it's a separate explicit tap. Fix the size claim (D5b).
- **UX H4 (no terminal failure):** High, not Critical, but v1 has `failed` with **no Cancel / Stop asking action and no retry bound**. A Patient-tier request on the owner's real Lidarr will sit forever. Add **Cancel**: unmonitor the album; if Magpie created the artist and it has no files, delete the artist with `deleteFiles=false`. Also add a bound: Standard 24 h, Patient 7 d → "Couldn't find it · Ask again".
- **Devil C1 / CarPlay C1–C2:** correctly marked "owner to confirm". The TestFlight probe was dropped (see D13).
- Nothing else was watered down.

---

## 2. API corrections (v1 design text → what to build)

**A1. Wrong Finds metadata profile (bug).** v1 §2.2 provisions *Magpie Albums+EPs*, and §2.5 picks the "smallest release group containing the recording (Single → EP → Album)". If the Finds artist is added with a profile that excludes Singles, the single's release group never exists in Lidarr, so `albumsToMonitor` silently monitors nothing. The parent spec said "our metadata profile (includes Singles/EPs)".
**Build:**
- Provision **two** metadata profiles:
  - *Magpie Finds*: Album + EP + Single, Official, no secondary types. Used for Try.
  - *Magpie Albums+EPs*: used only for the optional "bring in more".
- Don't switch the metadata profile on Keep. A profile change makes Lidarr drop albums outside the profile on the next refresh, and whether it keeps ones with files is unverified. Test it on the dev stack before ever doing it.

**A2. Lidarr tags are artist-level only.** Albums have no tags, so "every artist/album Magpie adds is tagged `magpie`" is impossible for the "artist already in library → album request in place" branch.
**Build:**
- Never add tags to an artist Magpie didn't create.
- Track album requests in a local **ledger**: `{lidarrArtistId, albumId, rgMbid, createdByMagpie: Bool, rootAtCreate}`, persisted next to the request store.

**A3. Keep's move is asynchronous.** `PUT /api/v1/artist/editor` with `rootFolderPath` queues a `BulkMoveArtistCommand` (verified in `ArtistEditorController.cs`) and returns the artist list, not a command id. If `startScan` fires right after the PUT, Navidrome scans before the files move: the song disappears from Finds and doesn't appear in the main library.
**Build:**
- Poll `GET /command` for `name == "BulkMoveArtist"` covering that artist until `completed` (or `failed`), and confirm `GET /artist/{id}.path` is under the main root.
- Then call `startScan?target=` for **both** libraries: the source so the old entry goes missing, the destination so the new one appears.
- Re-resolve song IDs by MBID afterwards. Navidrome IDs across a cross-library move are unverified, and queue items holding the old ID will 404.

**A4. `artist/editor` field semantics.**
- Send `applyTags: "remove"` with `tags: [<magpie-find id>]`. `replace` would wipe tags; `add` is the enum default.
- Send only the fields you intend to change. Nullable fields are ignored.
- `moveFiles: true` is a real field (verified).
- Never call `DELETE /artist/editor`: it bulk-deletes.

**A5. No pre-download size.** Covered under D5. `statistics.sizeOnDisk` and `trackFileCount` only describe files that exist.

**A6. Finds artist add.**
- Use **one** `POST /api/v1/artist` built from `GET /artist/lookup?term=lidarr:<artistMbid>`, overriding:
  - `rootFolderPath` = Finds root
  - `qualityProfileId` = Fast Start
  - `metadataProfileId` = Magpie Finds
  - `monitored: true`
  - `monitorNewItems: "none"` (otherwise new releases auto-download into Finds)
  - `tags` = [magpie, magpie-find]
  - `addOptions: {monitor: "none", albumsToMonitor: [rgMbid], searchForMissingAlbums: true}`
- `albumsToMonitor` overrides `monitor` and avoids racing the async `RefreshArtist` (research §"one call and atomic").
- v1 §2.5's "monitor none and monitor that one album" reads like the racy 3-step version. Don't build that.

**A7. Existing-artist branch.**
- The wanted release group may not exist under the artist's existing metadata profile; the owner's "Standard" profile typically excludes Singles.
- Pick the smallest release group that **is present** in `GET /album?artistId=` and contains the recording. Then `PUT /album/monitor {albumIds:[id], monitored:true}` + `POST /command {name:"AlbumSearch", albumIds:[id]}`.
- Never change the owner's artist profiles to make it fit. If no such album exists → `failed("not in this artist's catalogue on your server")`.

**A8. Choosing the smallest release group needs MusicBrainz, not ListenBrainz.**
- `/1/metadata/recording` takes `recording_mbids` (plural) and `inc` ∈ `artist tag release`. It returns **one** canonical release with `release_group_mbid` and **no ISRC** (verified in the LB docs).
- For Single → EP → Album selection and for ISRC, call MB WS/2 `GET /ws/2/recording/<mbid>?inc=releases+release-groups+isrcs&fmt=json`, with a real `User-Agent` (`Magpie/0.1 ( jordan@… )`), ≤1 req/s, and only on **Try tap**, never per search row.
- The match ladder runs fine without ISRC on external rows (MBID → artist+title+duration).

**A9. LB labs search.** `GET https://labs.api.listenbrainz.org/recording-search/json?query=…` is unauthenticated and has no SLA. Keep the 5 s timeout and silent degradation (already in v1). Pass the LB token only to `api.listenbrainz.org`, never to labs.

**A10. Lidarr `/search?term=`.** This is SkyHook text search, which is known to be flaky (#5498). Use it for artist and album rows only. When LB gives an artist MBID, prefer `artist/lookup?term=lidarr:<mbid>` (reliable ID lookup). Check `GET /health` before showing any tier estimate (Feasibility H7).

**A11. Navidrome native API (verified on 0.64.2).**
- `POST /auth/login` returns `{id, isAdmin, name, subsonicSalt, subsonicToken, token, username}`, so the admin check uses `isAdmin`.
- Send `X-ND-Authorization: Bearer <jwt>`. Every response carries a refreshed JWT in `X-Nd-Authorization`, so store the latest one.
- `/api/song?_start=&_end=&_sort=&_order=` returns `X-Total-Count`. Song fields include `libraryId`, `libraryPath`, `path`, `mbzRecordingID` (capital **ID**), `mbzReleaseGroupId`, `missing`, `tags`. ISRC, when present, is under `tags.isrc` (array), not a top-level field.
- Use `libraryId` for the "is a find" scrobble check and filter `missing == true` out of the match index.
- Page size 500–1000; sort by `id` for stable paging during a scan.

**A12. `startScan?target=` works on 0.64.2** (verified: `target=2:` → `scanType: "quick-selective"`).
- Format: `<libraryId>:<path relative to that library's root>`.
- The Lidarr path (container A) must be mapped to the Navidrome library path (container B). They are identical on the dev stack and **often differ in real setups** (`/music` vs `/data/music`).
- Build an explicit path-mapping step. If no mapping is known, call plain `startScan` (no target, `fullScan=false`). Poll `getScanStatus`.
- Debounce: one scan per library per 10 s.

**A13. OpenSubsonic `apiKeyAuthentication` is not advertised on 0.64.2** (`getOpenSubsonicExtensions` lists `transcodeOffset, formPost, songLyrics v1/2, indexBasedQueue, transcoding, playbackReport, topSongsByArtistId`). Token + salt is the v1 path. The design already says "if advertised"; just don't build the apiKey path tonight.
- `getLyricsBySongId` is gated on `songLyrics`.
- `getTopSongs` needs the Last.fm agent. It returns empty on the dev stack (`ND_LASTFM_ENABLED=false`) and possibly for the owner. Hide the shelf when empty.

**A14. Lidarr progress.**
- `GET /queue/details?albumIds=` → progress = `1 − sizeleft/size`, plus `status`, `trackedDownloadState`, `statusMessages`, `timeleft`.
- `history/since?date=` events: `grabbed, trackFileImported, downloadImported, downloadFailed, albumImportIncomplete, downloadIgnored`. Treat `downloadFailed` / `albumImportIncomplete` as `waiting`, not `failed`, because Lidarr retries.
- "Nothing found" = `AlbumSearch` command completed + empty queue + no `grabbed` within N min → `waiting("still looking")`.

**A15. Provisioning bodies.** Build quality and metadata profiles from `GET /qualityprofile/schema` and `GET /metadataprofile/schema` (full `items` / type lists are required) and look up by name first. On Lidarr 3.2.0, `/system/plugins` returns 200. On older or plugin-less builds expect 404 → "not detected".

**A16. Not for me endpoint.**
- Use `DELETE /api/v1/trackfile/bulk {trackFileIds:[…]}`. Verify the exact route against the dev stack's OpenAPI; fall back to per-id `DELETE /trackfile/{id}`.
- Then `PUT /album/monitor {monitored:false}`.
- Only after re-GET shows zero files across the artist: `DELETE /artist/{id}?deleteFiles=false&addImportListExclusion=false`, and only if the ledger says Magpie created it.

**A17. URL base paths.** Owners often run `https://host/navidrome` and `/lidarr`. Build every URL by appending path components to the stored base. `URL(string: "/rest/ping", relativeTo: base)` drops the base path. Add a unit test.

---

## 3. Required safety guards (owner's real Lidarr and Navidrome)

Writes in v1: profile/tag creation, artist add, album monitor + search, artist move (Keep), track-file delete (Not for me), artist delete (Not for me / Cancel), Navidrome `startScan`, `scrobble`.

**G0. Overnight agents never touch real servers.**
- Integration tests and smoke scripts run only against a host allowlist (`127.0.0.1`, `localhost`).
- Every write-path test first checks that `system/status.instanceName` (Lidarr) / the Navidrome library names match the dev stack (e.g. a `magpie-dev` marker set by `bootstrap.sh`), and aborts otherwise.
- No real credentials exist in the repo or env tonight. Keep it that way.

**G1. Master switch.** "Allow Magpie to change Lidarr" defaults to off. All Lidarr writes go through one `LidarrWriteGate` that checks the switch and logs each write, method + path + body sans secrets, to an on-device **Lidarr change log** viewable in Settings. The log is the owner's undo map.

**G2. Finds root must be explicitly confirmed, never inferred from a name.**
- Delete the "existing root folder whose path contains `samples`" auto-pick. Owners who make music commonly have a real `Samples` folder, and this rule would make it deletable.
- Setup shows candidate root folders and the owner confirms: "Use `/music/samples` for Finds? Magpie will only delete files it brought in here."
- Store the confirmed path and the Navidrome library id.
- Reject a Finds root that equals, contains, or is contained by any other Lidarr root folder or the main Navidrome library path. Nested roots are double-scanned and break path confinement.
- Without confirmation → fallback mode (main root, no Not for me).

**G3. Delete preconditions (Not for me, Cancel).** All must hold, each re-checked by a fresh GET immediately before the call:
1. The ledger says Magpie created this album request; for artist deletes, Magpie created the artist.
2. The artist has tag `magpie-find`.
3. `artist.path` and every `trackFile.path` start with `findsRoot + "/"`, after normalising (`standardizedFileURL`, resolve `..`, strip trailing `/`, case-insensitive compare only if the volume is case-insensitive). A bare `hasPrefix` lets `/music/samples-old` pass.
4. The album isn't kept (no Keep in the ledger) and has no Keep in flight.
5. Explicit confirm in the UI.

Never `DELETE /artist?deleteFiles=true` (it removes untracked files in the folder too). Never `addImportListExclusion=true`. Never call bulk `DELETE /artist/editor`. Never `DELETE /api/missing` in v1. Check `GET /config/mediamanagement.recycleBin`. If it's empty, the confirm copy says "This deletes the files permanently". Don't change the setting.

**G4. Keep (move) preconditions.**
- Exactly one `artistIds` element, from the ledger, with `magpie-find` present and `path` under `findsRoot`.
- Destination check: `GET /filesystem?path=<mainRoot>/<artist folder>` must not exist. The owner may already have an unmanaged folder for that artist; Lidarr would move into it and its rescan could import or rename the owner's files.
- If the destination exists → don't move. Untag `magpie-find` and say "Kept. It'll stay in your Finds folder for now."
- Body = `{artistIds:[id], rootFolderPath: mainRoot, moveFiles: true, qualityProfileId: lossless, tags:[findTagId], applyTags:"remove"}` only. Wait for `BulkMoveArtist` to complete (A3).

**G5. Never modify the owner's existing configuration.**
- No `PUT` to `/config/mediamanagement`, `/config/naming`, `/config/metadataprovider`, `/qualityprofile/{id}`, `/metadataprofile/{id}`, `/rootfolder`, `/indexer`, `/downloadclient`, `/notification`, or to any artist Magpie didn't create. Turning on renaming or tag-writing (parent §13 step 2) would rewrite the owner's whole library, so it's **advice text only** in v1.
- Provisioning is create-if-absent by exact name. A name collision with different content → stop and report; never overwrite.

**G6. Existing-artist branch is additive only:** monitor + `AlbumSearch` on one album. No tags, no profile change. Not for me is hidden for these rows, and so is everything in fallback mode. Cancel only unmonitors the album, and only if Magpie monitored it (ledger records `wasMonitoredBefore`).

**G7. Rate and blast-radius limits.** Max 5 active Lidarr requests. Batch Try is not in v1. Dedupe by rgMbid against the ledger and Lidarr before any add (v1 §5 already says this). `startScan` always `fullScan=false`.

**G8. Scrobbling.** Against the real server, scrobbles go to the owner's ListenBrainz/Last.fm. Add a Settings toggle "Count plays" (default on), so the owner can switch it off while poking at the app tomorrow.

**G9. Tests for G2–G6** (unit + dev-stack integration): sibling-prefix path, nested root, symlinked root, destination-exists Keep, non-ledger artist, kept album, `BulkMoveArtist` failure, recycle bin off.

---

## 4. Scope realism and milestone build order

v1 §2 lists 11 workstreams and §7 defines "Done" as all of them green. For one night that's not realistic: three themes, a full CarPlay tree, merged search + match index, a request machine with real Lidarr side effects, Keep/Not-for-me, Activity, lyrics and LB shelves. Worse, the design has **no ordering**, so parallel agents could all be 70% done at 7 am with nothing runnable.

**Rule:** each milestone ends with `xcodebuild build test` green on the iOS 27.1 simulator, a tagged commit, and **RUNBOOK.md updated to say exactly what works**. Agents never start M(n+1) integration work until M(n) is tagged. Package work for later milestones can run in parallel only if it doesn't block the tag.

| M | Ships | Contents | Risk to owner data |
|---|---|---|---|
| **M0 Foundations** (≈1 h) | App launches to the Connect screen | XcodeGen project; MagpieKit package skeletons; `DEVELOPER_DIR` set in all scripts; Keychain wrapper (no custom access group); redacting Logger; base-path-safe URL builder (A17); ATS config (§5); RUNBOOK v0. | none |
| **M1 Player** | **Useful app**: connect to Navidrome, browse, play | `/auth/login` + token/salt, JWT refresh single-flight, multi-address; Home (Jump back in), Library (Artists/Albums/Playlists), Album, Artist (library only), Playlist; `AVQueuePlayer` engine + Queue model; mini player; Now Playing (Signature); `MPNowPlayingInfoCenter`/remote commands; scrobble (G8). A11y labels per screen. | scrobble only |
| **M2 Library search + Queue view** | Owner can find and play anything | `search3`, debounced; Up Next view. | none |
| **M3 CarPlay (library only)** | Testable in the CarPlay simulator | `CPTabBarTemplate` Home · Library · Search (list root → push `CPSearchTemplate`, library results only); Now Playing with real cover; depth assert; item limits; no-rebuild diffing; describe-not-instruct empty states. | none |
| **M4 Lidarr read-only + merged search** | Owner sees not-yet results, nothing written | Lidarr connect + audit (version, auth, roots, profiles, health, Tubifarry); match index from `/api/song` paging + snapshot; LB labs + Lidarr `/search` merged as two bands (D4); not-yet rows with status text; Try button visible but routed to "Turn on changes in Settings" while G1 is off. | none |
| **M5 Try (fallback mode) + Activity** | First real request end-to-end | G1 switch; provisioning (A15, create-if-absent); ledger; RequestMachine + Runner; MB release-group pick (A8); existing-artist branch (A7) and new-artist-into-main-root branch with Fast Start; Ready = Navidrome lists it; Activity with real %, **Cancel**, retry bound; D8 "Ask for it" on Patient. **This is the path the owner most likely tests tomorrow** (no confirmed Finds root). | additive writes only |
| **M6 Finds mode: Finds shelf, Keep, Not for me** | Full loop on the dev stack | G2 confirmation UI + path mapping; Try into Finds root (A1, A6); Finds shelf with days-left; Keep (G4, A3) without the "more" sheet; Not for me (G3). Ship **behind a second switch** "Use a Finds folder", default off, until the owner has run the pre-flight. | destructive, fully guarded |
| **M7 Polish** | Nice-to-haves | Classic + Immersive-lite; lyrics; LB "Made for you"; Artist page not-yet albums; "Bring in more" sheet (D5); CarPlay Finds tab + "Try it next" with library bridge (D6); landing rule banner. | additive |
| **M8 Hardening** | Morning hand-off | Security review fixes, edge-case suite, RUNBOOK final, change-log screen. | n/a |

Testing and the security reviewer run **per milestone** (fast pass), not only at M8. If the night ends after M3, the owner still has a working player in the phone and car simulators, and the morning brief says so.

Also amend v1 §7 "Done means" to: "Done = highest milestone tagged green; RUNBOOK states which."

Smaller scope cuts:
- `swift test` can only cover platform-neutral modules (Core, NavidromeKit, LidarrKit, ListenBrainzKit, MatchIndex, Requests, Queue model). DesignSystem, CarPlayUI and the Playback engine must be tested via `xcodebuild test -destination 'platform=iOS Simulator,…'`. Declare `.macOS(.v27)` in the package platforms so `swift test` builds.
- The JSON snapshot for the match index is fine for ≤100k songs. Write it off the main actor, atomically.

---

## 5. Blockers for the owner testing tomorrow

**B1. The build toolchain isn't selected.** `xcode-select -p` = `/Library/Developer/CommandLineTools`, so `xcodebuild` and `simctl` fail. Xcode 27.1 (27A9275) with iOS 27.1 runtimes is installed at `/Applications/Xcode.app`.
- Every agent script must `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `sudo xcode-select -s` needs the owner's password.
- First launch may also need `xcodebuild -runFirstLaunch` and license acceptance. Check now, not at 5 am.

**B2. Plain HTTP beyond the LAN.**
- `NSAllowsLocalNetworking` covers IP literals (incl. Tailscale 100.x), `.local` and single-label names.
- It does **not** cover `http://host.tailnet.ts.net:4533` or `http://music.example.com`.
- For tonight: the **Debug** configuration gets `NSAllowsArbitraryLoads = YES` via a per-configuration Info.plist key (`INFOPLIST_KEY_…` / build-setting substitution). Release keeps local-networking only and shows "Use HTTPS for addresses outside your home network".
- Add `NSLocalNetworkUsageDescription` (needed on device, harmless in the simulator).

**B3. Self-signed HTTPS (not covered by v1).**
- `URLSession` can trust a certificate via a delegate, but **`AVPlayer` streaming ignores your URLSession delegate**, so a TOFU pin would make browsing work while playback fails.
- v1 answer: no in-app trust override. RUNBOOK documents installing the owner's CA into the simulator with `xcrun simctl keychain booted add-root-cert <ca.pem>` (and a device profile later).
- The Connect screen detects `NSURLErrorServerCertificateUntrusted` and shows that instruction instead of a generic failure.

**B4. Reaching the owner's servers from the simulator.**
- The simulator uses the Mac's network: LAN IPs and Tailscale work if the Mac can reach them.
- On recent macOS the Mac-side Local Network privacy permission can block LAN access for Simulator-hosted apps. RUNBOOK: if a LAN IP times out but works in Safari on the Mac, check System Settings › Privacy & Security › Local Network for Simulator/Xcode.
- `localhost` in the simulator = the Mac, so the dev stack works as is.

**B5. Lidarr behind auth or a reverse-proxy base path.** API key header works in all v3 auth modes. A base path (`/lidarr`) needs A17. If Lidarr has "Authentication Required: Enabled" with forms, the API key is still fine.

**B6. Path mapping (A12).** If Lidarr and Navidrome see different paths, Ready detection still works through the match index, but targeted scans and the Finds root check don't. RUNBOOK pre-flight: compare Lidarr `rootfolder.path` with Navidrome `/api/library` paths. Setup asks for a prefix mapping when they differ.

**B7. CarPlay simulator.**
- Use Simulator › I/O › External Displays › CarPlay with the `com.apple.developer.carplay-audio` key in the entitlements file. Simulator builds are signed to run locally, so Apple's approval isn't needed there.
- Don't add a custom `keychain-access-groups` entitlement. Ad-hoc simulator signing can return `errSecMissingEntitlement (-34018)`; use the default app keychain.
- A physical-device build needs the approved entitlement in the provisioning profile. If the owner doesn't have it yet, a device build must strip the CarPlay entitlement (separate configuration).
- "Cold launch with phone locked" can't be meaningfully tested in the simulator. Mark it as a device test.

**B8. Likely first-run state.** The owner probably has no confirmed Finds root and maybe no Tubifarry. M5's fallback + Patient "Ask for it" path is therefore what they'll see first. Make sure it's polished and the copy is honest ("Finds aren't set up, so this goes straight into your library").

**B9. Scrobble pollution while testing** (G8) and **Lidarr real downloads**: the RUNBOOK warns that Try on the real Lidarr triggers real indexer searches.

**B10. Pre-flight additions to v1 §7:**
- (a) Is the Lidarr recycle bin set?
- (b) Path mapping (B6).
- (c) `getOpenSubsonicExtensions` has `songLyrics`.
- (d) Last.fm agent present (top songs).
- (e) Does the destination artist folder exist for any artist you'll test Keep on (G4)?
