# Z2 report — round 13 items 5, 2, 13 (branch `z2-home`)

Status: DONE. Branch `z2-home` (merged with v0.0.1-custom, clean): 4a26685 RED, 62e4f2d Home fix, 91cb8b3 refresh,
611c997 reorder buttons, b7b1e99 decisions, then the merge.

Final run (own simulator "Magpie Z2", app uninstalled first, MAGPIE_IT=1 against the dev stack):
- app: 998 Swift Testing tests in 109 suites passed; XCTest/UI 31 executed, 0 failures, 3 skipped (the existing skips).
- packages (`scripts/test-packages.sh`): exit 0, all suites passed.
- `scripts/check-writes.sh` exit 0 (no new write shapes); `scripts/check-release.sh` OK.

Process note: the session scratchpad turned out to be shared with other implementers, and my first full run's helper
script (`scratchpad/apptest.sh`) was overwritten by another agent mid-round, so that run went to another worktree's
build and simulator and its log is not mine (discarded). Re-ran from a private `scratchpad/z2-a30a/run.sh` pinned to
this worktree and "Magpie Z2". Earlier focused RED/GREEN runs named Round13* tests that exist only in this worktree.

## Root causes

### Item 5 — Home still shows the wrong things
Diagnosed on hosted tests with the stub Aurral + mock Navidrome, plus read-only GETs against the owner's Navidrome
(`getMusicFolders`, `getPlaylists`, `getPlaylist` for the two flow playlists; nothing else, nothing printed).
Owner's server: libraries 1 Music Library / 2 Aurral Playlists / 3 Finds; "Discover Weekly" and "Trending Mix" are
owned by the owner's account, public, and the most recently changed playlists (2026-10-30), their songs Aurral copies.

1. **Discover ↔ Playlists flip (symptoms 1 and 3).** `refreshDiscover` replaced the Discover set (and saved it) with
   whatever one read of Aurral confirmed. When the confirmation couldn't be made — Aurral's job list unreadable or
   slow (`try?` → nil, and at a fresh launch the session's jobs are empty), or a flow run under way with the jobs
   cleared while Navidrome still holds the last run's songs, i.e. every Friday — the flow playlists dropped out of
   Discover. Discover vanished (the next shelf, e.g. Random albums, moved into its place) and the flow playlists went
   to the **top** of Playlists (most recently changed first), where their covers are 2×2 grids of album covers.
   RED: `flowRanAndJobsUnreadable`, `flowRunningJobsCleared` — Discover `nil`, Playlists
   `["playlist-pl-dw", "playlist-pl-mine", …]`. The race the plan suspected is real too: the Playlists read uses the
   Discover ids at read time, so the first read after the flip still hid pl-dw and the *next* one showed it.
2. **Home waited for Aurral (symptom 2).** `homeRead` joins every section; Discover's read did status + jobs + each
   flow playlist + Aurral's library pages. With Aurral slow, every shelf not saved on the phone stayed hidden (60 s in
   `aurralSlow` with a 30 s-per-request stub) — "the Playlists section disappears".
3. **Discover's saved shelf was thrown away at every launch**: `HomeShelf.fits` had no `(.discover, .playlist)`, so
   Home opened without Discover until Aurral answered. RED: `build12CacheShowsDiscover`,
   `feedFromBuild12CacheWithAurralSlow` (a build-12 cache file).

Aurral down and Aurral signed out (401) already fell back to the saved ids correctly (tests pass; kept as regressions).
The section→loader table and position-keyed cache suspicions were checked and are fine.

### Item 2 — pull to refresh shows "Couldn't load this"
Not reproducible on the plain dev stack (localhost is too fast). Through `dev/netem/badnet.py` (+1.5 s on every
request, as over Tailscale) `Round13UITests.testPullToRefreshKeepsThePage` failed: "artist, pull 1: the page said it
couldn't load". The proxy log shows the reload's `getArtist` closed by the client ("Connection lost") while the page's
own first load was still filling in (Popular, Lidarr line): SwiftUI cancelled the `.refreshable` action, the request
ended in `URLError(.cancelled)`, and Album/Artist replaced their content with `.failed`. A second pull, with the page
settled, wasn't cancelled. Also checked on the dev stack: a quick scan never makes getAlbum/getArtist fail (not a
scan race).

## What was built
- `App/AppModel+DiscoverHome.swift` (new): `keptFlowPlaylists` (a confirmed playlist stays Discover's while still named
  after its flow and no other is confirmed for it); `refreshDiscover(waitingAtMost:)` — one shared read of Aurral,
  waited for at most `discoverWait` = 3 s (continuation-based: leaving a task group waits for its children).
- `AppModel+Discover.swift`: uses both; when the Discover set changes, `homeFeedSlot?.sectionsChanged([.discover, .playlists])`.
- `AurralConnectionStore.swift`: one stored property, `DiscoverState.refreshTask`.
- `HomeFeed.sectionsChanged` + `HomeLoad.forget`: the two sections are read again silently; a read under way is
  followed by one more (its answer may predate the change).
- `AppModel+Home.swift`: `HomeShelf.fits` accepts Discover's playlists.
- `App/Screens/Shared/RefreshSafety.swift` (new): `RefreshSafety.run` (the pull's work in its own task) and
  `Loadable.failing(_:)` (a cancellation is never an error; what's shown stays; the error only with nothing to show).
  Applied to Album, Artist, Playlist, Discover playlist + list, Genres, Library, Favourites.
- `App/Screens/Shared/LayoutEditorSheet.swift` (new): the editor sheet with Done, and the toolbar button. Home:
  top-right "Edit Home" (`home-edit-toolbar`); the bottom "Edit Home" now uses the same sheet. Library: "Edit Library"
  (`library-edit-toolbar`) left of Settings.
- `docs/decisions.md`: D63–D66 (renumber at merge if another stream also added D63+).

## Tests (RED → GREEN)
- `Tests/MagpieTests/Round13HomeTests.swift` (new): aurralFine / aurralDown / aurralSignedOut, flowRanAndJobsUnreadable,
  flowRunningJobsCleared, aurralSlow, homeReadsDiscoverAndPlaylistsAgainWhenDiscoverChanges, keptFlowPlaylistsRule,
  build12CacheShowsDiscover, feedFromBuild12CacheWithAurralSlow; `Round13RefreshTests` (a cancellation is never an
  error; the pull's work outlives a cancelled pull).
  - RED at 4a26685: 5 failing (the two flips, with Playlists showing pl-dw on the second read; slow 60 s; cache ×2).
  - GREEN at 62e4f2d: Round13HomeTests + DiscoverAppTests 29/29; HomeFeedTests, HomeSeamlessHostedTests,
    Round12HomePagesTests green.
- `Tests/MagpieUITests/Round13UITests.swift` (new, MAGPIE_IT):
  - testPullToRefreshKeepsThePage — RED via the proxy (artist, pull 1); GREEN via the proxy after 91cb8b3 (two pulls
    each on an album and an artist, each watched 12 s, no "Couldn't load this", content always there).
  - testReorderButtonsOnHomeAndLibrary — RED on the old views ("Home's top-right button"); GREEN after 611c997.
  - To re-run the refresh RED/GREEN with latency: `python3 dev/netem/badnet.py --listen 4613 --upstream 4533 --control
    <file with {"mode":"hdelay","secs":1.5,"all":true}>` and pass MAGPIE_IT_URL=http://127.0.0.1:4613. On the plain
    dev stack the test passes either way (a regression guard there).
- `DiscoverAppTests.swift`: `DiscoverNavidrome.songs` is now `var` (to add a rotated flow's songs).

## Concerns / merge notes
- Z1 changes Aurral to user login: `Round13HomeTests.signedIn` calls `connectAurral(base:apiKey:)` and
  `aurralSignedOut` builds `AurralConnection(base:apiKey:)`; adapt those two lines to Z1's API at merge. My edits to
  `AppModel+Discover.swift` are three small hunks (refreshDiscover's match and notify, discoverPlaylists' wait);
  `AurralConnectionStore.swift` gains one property.
- `testReorderButtonsOnHomeAndLibrary` ends by checking Settings › `settings-home-library` exists; if Z1 moves that row,
  update it.
- Not changed (owned elsewhere): pull to refresh on Requests and Downloads in Lidarr (Settings) and Finds.
- A build-12 cache may hold a Playlists shelf with the flow playlists in it (saved after a flip); it shows until the
  first read replaces it (seconds now).

## Fix round (Z2-review.md: 0C/2I + minors)
- RED 1212a79: statusWithNoFlowsKeepsDiscover, noFlowsDuringARunKeepsDiscover, flowRenamedBeforeItsPlaylist failed
  (Discover nil, pl-dw in Playlists); playlistLeavesDiscoverOnlyOnPositiveEvidence and homeUpdatesWhenSlowAurralAnswers
  (M7, end to end) passed as guards.
- b4ce7a1 fixes:
  - I1 `keptDiscoverPlaylists`: a known Discover playlist that no flow is named as now is read too, and leaves only when
    the status lists flows, its songs read, and they are neither a flow's (jobs) nor Aurral's copies. No flows / renamed
    flow / unread songs change nothing; kept flow = the one its songs belong to, else the one it had, else none
    (`discoverFlow` nil, no Refresh Flow).
  - I2 Downloads in Lidarr: `showsUnreachable(after:before:)` (cancellation keeps the state) + `RefreshSafety.run`.
  - M1 `forgetReads` cancels and clears the shared read. M2 every `refreshDiscover` goes through one shared read
    (`performDiscoverRead` is the body; a forced call follows the running one). M3 the wait polls and stops on
    cancellation, no lingering waiter. M4 `failing(_:noticeTo:)`: "Couldn't refresh this page." notice on a real
    failure with content shown. M5 `HomeFeed.discard([.discover])` from `forgetDiscoverReads` (screen + file).
    M6 noted in D75. M7 tests clear the Aurral delay in defer.
  - Tests for each (Round13HomeTests minors, Round13RefreshTests I2). Note: I2/minor tests were written with the fix,
    not strictly RED first.
- Decisions renumbered D75–D78 (after Z1's D74).
- Merged v0.0.1-custom bb1e2e4 (Z1): kept Z1's account guards and job filter, my `keptDiscoverPlaylists`, dropped Z1's
  `unread`; tests moved to user login (`aurralSignedOut` = changed password + expired sessions). DerivedData had to be
  cleared once (stale AurralKit module after the merge).
- Affected suites after merge: 96 tests in 6 suites passed. check-writes / check-release OK.
- Full suite after merge (own sim, MAGPIE_IT=1, app uninstalled first): 1059 tests in 112 suites passed; UI 32 executed, 0 failures, 3 skipped.
