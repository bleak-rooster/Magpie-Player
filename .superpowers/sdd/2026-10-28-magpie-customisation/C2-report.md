# C2 report: Trending's chart flows and chart picker (round 15, owner items 5 and 5b)

Branch `c2-trending` (from `v0.0.1-custom` 25bed51). Decisions D130–D134 in docs/decisions.md.

## Research (Aurral 2.13 source)
- `POST /api/discover/editorial/:id/library` (`addEditorialPlaylistToLibrary`) has **no track limit**: it imports
  the whole Deezer playlist as a static playlist with `importSource {syncEnabled: true, keepRemovedTracks: true}`, so
  Aurral re-syncs the whole chart and never drops songs. `normalizeImportSource` has no limit field.
- Static ("shared") playlists, owner-scoped with `requireFlowAccess` (routes/playlists/handlers/staticPlaylists.ts):
  `POST /api/playlists/shared-playlists {name, sourceName, tracks}` creates one with an explicit song list;
  `PUT …/:id {tracks}` replaces the list (`updateStaticPlaylistLocked`: songs still in keep their jobs, the rest leave
  the playlist, new ones are queued through Aurral's own download sources); `DELETE …/:id` removes it (files no other
  playlist uses are deleted); `POST …/:id/sync` only re-reads an import source. A duplicate name answers 400.
- Charts: `findChartPlaylist` looks up Deezer user 637006841's "Top <Country>" playlists (falls back to "Top
  Worldwide"); genre charts are Deezer `/chart/<genre>/tracks` (not playlists), served by
  `GET /api/discover/trending/genres/:id`. `GET /api/discover/editorial/:id` reads any Deezer playlist id, so the
  worldwide chart (bundled `ChartPlaylists.json` `worldwide` = 3155776842) is reachable through Aurral.

## Design chosen (D130)
Option (a) through Aurral only: a chart flow is the user's own Aurral static playlist holding the chart's top N.
Create = POST with the top N; Songs: N (shorten/extend) and Refresh now = PUT with the new list; Remove = DELETE.
Aurral downloads/matches/publishes as for Add flow; Magpie follows the state with A4's phases. Option (b) rejected:
Lidarr would need a whole artist per chart song (up to 100 adds) or Tubifarry + per-song MusicBrainz matching, and the
charts exist only with Aurral anyway. Without Aurral Trending stays hidden (as today); without accessFlow the controls
are hidden; refresh is on tap only (no automatic Aurral writes, D82/D118).

## What changed
- MagpieCore: `TrendingChart` (worldwide / country / genre, keyed "worldwide", "country:AU", "genre:132");
  `ChartsCountry` gains `.worldwide`, `.genre(id)` and `chart(phoneRegion:serverRegion:countriesWithCharts:)` (the
  default chart).
- AurralKit: three routes (`chartFlowCreate` POST, `chartFlowUpdate` PUT, `chartFlowDelete` DELETE), `nameTaken`
  error, `ChartFlows.swift` (`ChartFlowTrack`, `ChartFlowPlan`, `ChartFlow`, `ChartFlowBook`, the three client calls).
- App: `AppModel+ChartFlows.swift` (read any chart through Aurral, chart pages, make default, create/resize/refresh/
  remove); `loadTrending` follows the default chart (worldwide/genre too); `TrendingSnapshot.chart`; `AurralFeeds`
  keeps `chartFlows` in the per-account/Aurral-user file (cleared on sign-out) and session chart pages; chart flow
  playlists count as Discover's; `ChartFlowViews.swift` (ChartFlowControl, ChartFlowSheet, ChartPickerSheet);
  TrendingView gets the chart bar (Chart: <name>, Make default / Default) and the flow control; Settings › Charts
  country lists Worldwide.
- Stubs: `StubAurral` serves the three routes (+ `sharedPlaylistSongs`), a 30-song worldwide chart;
  `dev/aurral-stub/server.py` likewise, lists them in `sharedPlaylists`, serves their jobs, and adds `GET /__stub/shared`.
- check-writes: routes pinned (30), method block, constants, one send each in ChartFlows.swift, bodies/guards;
  allow-list entries for the stub's verbs and the UI test's stub reset.

## Hooks in TrendingView (C3 boundary)
TrendingView's song rows are untouched (`ChartSongList` as before); no change to `OutsideSongMenu` or action sheets.

## Tests
- Package (RED first: `swift build --build-tests` failed "cannot find type 'ChartFlowTrack' in scope"; then GREEN):
  `AurralKitTests/ChartFlowTests` (routes, create/resize/remove against StubAurral, name taken, no accessFlow, odd ids,
  the top-N plan, presets, per-chart book), `MagpieCoreTests/TrendingChartTests`. `Round14AllowListTests` updated for
  the 30 routes (it failed on the new routes as expected). AurralKitTests 137 and MagpieCoreTests 153 pass.
- Hosted: `MagpieTests/ChartFlowAppTests` (7: default chart incl. worldwide and a genre, create 10 → 5 → 20 →
  refresh → remove with exactly those writes, each chart its own flow surviving a re-follow and cleared on sign-out,
  name taken → "2", removed on the server → Create again, no accessFlow → nothing sent, the words). Written after the
  app code (RED evidence is the package layer's). Also `Round14DiscoverTests` (29) and `AurralStubServerTests` (Python
  stub parity) pass.
- **Release UI check** (`MagpieUIOnly` scheme, `-configuration Release`, "Magpie Tests" simulator, dev stack + stub on
  port 3911): `MagpieUITests/ChartFlowUITests/testWorldwideAsDefaultThenAFlowOfTenShortenedToFive` **passed** (92 s):
  pick Worldwide, Make default, relaunch → opens on Worldwide, Create flow with Songs: 10 → stub playlist holds 10,
  Edit flow shows 10, stepper to 5 + Save → stub playlist holds 5, no "Aurral" on screen.
- `scripts/check-writes.sh` OK; `scripts/check-release.sh` OK.

## Not done / notes
- A chart flow made on another phone isn't recognised here (no import source to tell it by): D133 known limit.
- Chart flows are not re-synced automatically (owner taps Refresh now); stated in D130.
- The stub was run on port 3911 to avoid restarting other worktrees' stubs on 3901; start.sh reported a stub already on
  3911 running other code and restarted it (if another workstream also used 3911, its stub was restarted).

## Fix round (C2 review: I1, I2, M1–M7)

**Root causes (checked in Aurral 2.13 source)**
- **I1:** `POST /shared-playlists` is queued (`enqueuePayload`) and answers 200 with a fresh id whatever the name.
  The duplicate check (`assertUniqueStaticPlaylistName`: the user's playlists and flows, trimmed and lower-cased) runs
  in the worker, which fails the job. The old code relied on a 400 that never comes (both stubs faked it).
- **I2:** the PUT's `updateStaticPlaylistLocked` uses `deleteUnsharedFiles = false`. Dropped songs lost their jobs
  but kept their files, untracked.

**Fixes**
- **Name before sending (I1):** `ChartFlowPlan.freeName` picks the first free name from the names in the status
  (flows, shared playlists and Magpie's own chart flows), then sends once. The `nameTaken` error and the 400 mapping
  are gone.
- **A creation that never appears (I1):** a new flow shows Setting up… until it is listed. If it isn't listed after
  two reads with the server's queue idle, or after 10 minutes, it shows "Couldn't create the flow" with Retry. Retry
  picks a name afresh and sends the same N.
- **Shorten, extend and Refresh now (I2):** these read the flow's jobs, then send `POST …/:id/track-removals {jobIds}`
  for songs that leave and `POST …/:id/tracks {tracks}` for songs that come in. Nothing is sent when nothing changed.
  The PUT is dropped and refused again.
- **Removal file safety (I2):** checked in the 2.13 source (`removePlaylistFileIfUnshared`):
  - only files inside Aurral's own download folder are deleted;
  - library-reused files (`externalPath`) are skipped;
  - a file another Aurral playlist or flow uses is moved to it, not deleted;
  - files a visible Navidrome playlist uses are kept.

  This is recorded in D130.
- **Routes:** 31 now (create, append, track-removals, delete). They are pinned in `AurralRoute` and check-writes, and
  the bodies match the 2.13 valibot schemas.
- **M1:** the Remove confirmation says what goes and what stays, including starred songs.
- **M2:** a flow is `confirmed` once listed. Until then Edit is disabled, and resize, refresh and remove refuse to
  send.
- **M3:** lenient book and snapshot decoding. A lost book is rebuilt from the status (`sourceName` "Charts", named
  after the chart). Such playlists count as Discover's on any phone.
- **M4:** Home's shelf heading is "Trending · <chart>".
- **M5:** Make default from Automatic onto a country shows a note. The Settings label is now "Default chart".
- **M6:** removed the unused `resize`.
- **M7:** the Edit sheet notes that Not for me songs are skipped.
- **Stubs:** both now match 2.13. The create answers 200 and a taken name (playlist or flow) fails silently. The
  Swift stub records deleted files, failed creates, a worker failure switch and a moving worldwide chart. The Python
  stub's `/__stub/shared` reports `deletedFiles` and `failedCreates`.

**Tests**
- **RED:** after the stubs were made to match 2.13, the old `aNameAlreadyTakenIsTold` failed (no error thrown) and
  `resizingReplaces…` failed (`notFound`). The new app code was then missing APIs, so the build failed
  (`nameTaken`, `updateChartFlow`).
- **GREEN, package:** `ChartFlowTests` (free name, taken name accepted then never listed, changes plan, shorten with
  files deleted, extend, remove, odd ids, lenient book), `TrendingChartTests` and the allow-list tests. 140
  AurralKit tests pass.
- **GREEN, hosted:** `ChartFlowAppTests` (11: create 10 → 5 → 20 → refresh after the chart moved → no-op refresh →
  remove, with exact writes and deleted files; free name; couldn't create then Retry; nothing sent until listed;
  lost book rebuilt; Home title and pin note; words), `Round14DiscoverTests` (29) and `AurralStubServerTests`.
- **Release UI check:** `ChartFlowUITests` passed, on stub port 3923. It now also waits for Edit to be enabled and
  checks that the five dropped songs' files were deleted. The first attempt hit an accessibility "Error getting main
  window" during sign-in (the shared simulator); the retry passed.
- check-writes OK; check-release OK.

**Notes**
- New songs from extend or refresh join at the end of the playlist (append), not in chart order.
- The scratchpad is shared with other workstreams: C3's `run-ui.sh` had replaced mine. I briefly edited it, then put
  it back. C2 now uses `c2-run-ui.sh`.

## Second fix round (C2 re-review: I3, M-a to M-d)

**What was wrong, and the fixes**
- **I3, Remove brought the flow back.** 2.13 only queues the delete, so the playlist stays listed for a while. In
  that gap the "Charts" rebuild took it back.
  - Removed, retried-away and server-gone playlist ids are now remembered with the book (`removedPlaylistIds`: newest
    200, per account, cleared on sign-out).
  - The rebuild never takes one of those back.
  - Both stubs now queue the delete. The Swift stub's delay is configurable (`setDeleteDelay(reads:)`, default 1).
- **M-a, upgrade jobs.** `AurralJob.upgradeForJobId` is now decoded, and `ChartFlowPlan.changes` ignores those jobs.
- **M-b, failed songs read.** Now tested: if reading the flow's songs fails, nothing is sent and N is unchanged.
- **M-c, failed names read.** Create reads the status fresh for the names. If that read fails, no create is sent
  (`StubAurral.setStatusFailure`).
- **M-d, retry window.** In 2.13, `retryDecision` retries a failed create every 60 s, up to 3 tries.
  `getHonkerQueueDepth` counts only `run_at <= now`, so a waiting retry doesn't show in the queue. Idle reads therefore
  count only after 150 s (this covers the third try). Recorded in D131.

**Tests**
- **RED:**
  - Package: the build failed, since `upgradeForJobId` and `noteRemoved` didn't exist yet.
  - I3: the new hosted test failed with the adopt guard taken out. It took the removed flow back: `checkChartFlow` not
    nil, and the flow was present. I then put the guard back.
  - First version of that test: it passed even without the guard. Its own extra status read let the one-read delete
    finish, and the app's background refresh after Remove uses up a read too. The test now uses a delete that stays
    listed for 3 reads, closer to 2.13's worker, which deletes files and tells Navidrome first.
  - I wrote the other new hosted tests (M-b, M-c, M-d) before the app code, but didn't capture a RED run for them.
- **GREEN:**
  - Package: `ChartFlowTests` (13, including upgrade jobs, the queued delete and the removed-ids list) and
    AurralKitTests (141).
  - Hosted: `ChartFlowAppTests` (15), `Round14DiscoverTests` (29) and `AurralStubServerTests`.
  - `aFlowRemovedOnTheServerCanBeCreatedAgain` now lets the queued delete run (two status reads) before it expects
    the 404.
- **Release UI check:** `ChartFlowUITests` passed on stub port 3923 (242 s; the shared simulator was slow).
- check-writes OK; check-release OK.
