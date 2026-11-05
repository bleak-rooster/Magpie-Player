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
