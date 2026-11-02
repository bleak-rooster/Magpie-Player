# Y6 report: Aurral integration, Discover (plan item 7)

Branch `y6-aurral` (worktree agent-a03ea724f2a094644), off v0.0.1-custom (Y1–Y5 merged). Commits:
`09ec1f6` AurralKit · `be98d76` layout + car hooks · `52e8f07` app · `7ab0a0d` album page + copy · `c0b7865` D56–D61 ·
this report. Never contacted the owner's Aurral, Navidrome or Lidarr: every test uses `StubAurral` (in process, answers
only its own host) and a mock Navidrome. No Lidarr writes were needed.

## What was built

**AurralKit (new package module, depends on MagpieCore only)**
- `AurralClient`: base + `X-Api-Key`. `AurralRoute` allow-list: exactly `GET api/health`, `GET api/playlists/status`,
  `GET api/playlists/jobs`, `GET api/library/lookup/<MBID>`, `POST api/playlists/start/<plain id>` (body `{}`). Anything
  else (verb, path, encoding, traversal, query, absolute URL) is refused before a request is built. Key: header only,
  logged via `Log.describe` (redacted), hidden from `debugDescription`/`customMirror`.
- Lenient 2.10 models (`AurralStatus` with flows, flowStats, worker, operationQueue, hint; `AurralJob`; health with
  `AurralVersion.compatibility` supported/newer/older/unknown; lookup; start result). 404 on jobs/lookup tolerated.
- `DiscoverRules` (pure): flow↔playlist matching; `mainCopy` (MBID first, else artist+title+duration ±3 s exactly one,
  never name-only, never a Discover copy/Finds/unlisted library); `swapped` (same position); `discoverLibraries` (from job
  `_flows` paths via recording rows); artists in a playlist with Aurral's artist MBIDs.
- `MagpieTestSupport/StubAurral`: the five routes with state (flows, jobs, a run made active by a start), 401 on a wrong
  key, 404 elsewhere, every request recorded.

**Layout and car (small hooks)**: `HomeSection.discover` / `LibraryRow.discover` (on by default, shown only while Aurral
is set up, never offline). Car: `CPDestination.discover`, `libraryRoot` mapping, `customFetcher` case, protocol
requirement `discoverPlaylists()` with a default (new file `CarPlayDiscover.swift`); adapter: Playlists without Discover's,
Discover's list, and `playlist(id:)` returns the swapped songs for a Discover playlist.

**App**
- `AurralConnectionStore` (Keychain `aurral.connection`), `DiscoverState` (`AppModel.discover`), `AppModel+Discover.swift`
  (connect/test/disconnect with ATS + plain-http consent like Lidarr; refresh; matching; ids saved per account; page with
  swap; library learning; Refresh Flow; artists; artist/album page hooks), `AppModel+DiscoverSwap.swift` ("Use your
  library's copy" through X3's `ownPlaylist` + `sendOnce` + read-back, one whole-list send, at most 500 songs).
- Screens: `DiscoverPlaylistView` (+ `PlaylistRouteView`, `DiscoverListView`), `DiscoverArtistsView` +
  `DiscoverArtistAdder` (Magpie's R18/R20 Add via `ArtistLidarrModel`), `LibraryCopyBanner` (own playlists),
  `AurralSettingsView` + `AurralSettingsSection` (Settings › New music › Discover › Aurral).
- Hooks: Y3's `discoverLibraryIds` / `isDiscoverPlaylist`; Home `.discover` shelf; Library row/route; X3 `ownPlaylist`,
  `canEdit`, `editablePlaylists` refuse Discover playlists; Library › Playlists filter; queue actions; artist page hides an
  Aurral album whose every song has a library copy; album page plays library copies; sign-out forgets Aurral.
- `scripts/check-writes.sh`: allowlists the one POST (marker), pins the five routes, refuses any product mention of
  `/api/settings`, `/api/auth/api-key`, `/api/discover`, `/api/library/tracks|artists`, the import-list route; only the
  Lidarr gate and the Aurral client set an API key; playlist client writes only in X3's file and the swap file, both via
  `ownPlaylist` (which refuses Discover's).

## Tests (RED → GREEN)

- Package `AurralKitTests` (21): RED = target missing (`target 'AurralKit' referenced in product 'AurralKit' is empty`);
  GREEN 21/21. Allow-list refusals (40+ method/path pairs, nothing sent), the five allowed, never settings/auth/discover,
  odd flow ids, key only in the header and never logged (log sink), status/progress/run-active, jobs, version tolerance,
  404 tolerance, lenient decoding, errors; flow matching, swap by MBID / fallback / never name-only / never itself /
  listed libraries only, positions, library from job paths, artists.
- `PreferencesTests.discoverOnlyOnceSetUp`: RED (`type 'HomeSection' has no member 'discover'`) → GREEN; two existing
  expectations updated for the new default entry. `CarPlayUITests.DiscoverRowsTests` (2) green; `CarPlayModelTests`'
  depth walk gained the `.discover` case.
- App `DiscoverAppTests` (14): off until set up; key only in the Keychain store; consent for public plain http (nothing
  sent; the first run also proved the gate: a dotted stub host was refused until made single-label); newer version
  tolerated; Discover hidden from Playlists (Home shelf, editable, car); no playlist writes to Discover
  (add/rename/remove/delete/swap); swap in place (phone and car); library learnt from job paths and scoped out;
  own-playlist swap is one checked send with the exact query, nothing for someone else's; Refresh refused while active,
  then one POST, a second tap refused; artists with MBIDs and no Aurral add; offline asks nothing; copy names no service;
  sign-out forgets.
  Mutation RED: removing `ownPlaylist`'s Discover guard and `refreshFlow`'s run-active guard made
  `noPlaylistWritesToDiscover` (6 issues) and `refreshFlowRefusedWhileActive` (4 issues) fail; restored → green.
- Final: full package suite, every run passed; full app suite on "Magpie Y6" (app uninstalled first): 963 tests in 104
  suites passed, UI tests skipped (no MAGPIE_IT); `check-writes.sh` OK; `check-release.sh` OK. Simulator deleted.

## Decisions

D56–D61 in docs/decisions.md (client allow-list and key; Discover identity and hiding; library from job paths; the swap;
Use your library's copy; Refresh Flow and adding artists).

## Concerns

1. Settings placement: a "Discover" section on the New music page with an "Aurral" page, not a top-level "Services" row
   (the top level must fit 375 × 667, T21b).
2. Flow ids are assumed plain (`[A-Za-z0-9_-]`, ≤ 100); any other id makes Refresh refuse (safe), unverified on 2.10.
3. Search and Library leave out Aurral's whole library (Y3 scope), not only duplicates; that matches item 5's design.
4. Aurral's library is learnt only from a flow entry with a recording MBID whose job file is Aurral's own; an all-untagged
   flow teaches nothing (Discover still works; that library stays listed until one is learnt).
5. A user playlist named exactly like a flow is treated as Discover (hidden from Playlists, protected from edits).
6. Each Discover page view does one recording lookup (or one search3) per flow song, four at a time.
7. An Aurral album's page shows the library's songs under the Aurral album header. `GET /api/library/lookup` is
   allow-listed and tested, but the UI takes artist status from Lidarr's lookup (as the plan says).
8. No new UI tests or screenshots for the Discover screens; coverage is hosted unit tests.

## Fix round 1

Review: 0C/3I (Y6-review.md). Commit `4e85059` (+ decisions/report); v0.0.1-custom already merged (no new commits).
- **I1** `DiscoverRules.confirmedFlowPlaylists`: name match AND > half the entries are the flow's songs (jobs by recording
  id, else artist + title ± 3 s) or known Aurral-library songs; empty never; best per flow. `refreshDiscover` reads each
  candidate; an unreadable one keeps its previous state.
- **I2** `refreshAurralLibrary`: learns the library on the first Discover read, then reads its songs (`library_id`) and
  saves the ids per account (`magpie.aurralSongs.<scope>`); the swap and the candidate exclusion use them.
- **I3** `RefreshLatch` (start time, flow's `lastRunAt`); `noteStatus` lets go when the run shows, `lastRunAt` moves, or
  after 120 s; `isFlowRunActive` honours the limit, so the page's poll loop ends.
- **M1** per-song lookup cache (30 min, hits and misses), `fresh:` on pull to refresh; **M3** job match needs ± 3 s;
  **M5** greps widened; **M6** `AurralConnection`/`LidarrConnection` redact; **M7** sign-out removes the keys;
  **M8** neutral placeholder. Flow ids: UUIDs accepted (test), "/", "?", "%" refused. Not done: M2 (artist-page hiding
  still needs a Discover read this session), M4, M9, M10.
- **Final:** full app suite 968/968 on "Magpie Y6"; AurralKit, CarPlayUI and Preferences package suites green; check-writes OK.
- **Tests (RED → GREEN):** package `FixRound1Tests` (5) RED on missing `confirmedFlowPlaylists`/`jobRecording`/`lastRunAt`
  → GREEN. App: with only the API surface added, 9 tests failed behaviourally (same-named playlist taken over and edits
  refused, rotated copy not found, latch `.runActive`, lookups repeated, keys printed, keys left at sign-out) → GREEN 19/19.
  Stub jobs now cover every flow song (as Aurral's do); `aurralsLibraryLearntFromJobPaths` now learns at connect.
