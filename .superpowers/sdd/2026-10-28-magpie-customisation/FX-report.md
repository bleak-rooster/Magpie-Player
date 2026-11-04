# FX: round 14 final-suite fixer report

Branch `fix-r14suite` (from v0.0.1-custom 6a3e2e9). Commits: 8de2794, 051a3de, 973cc55.

## Root causes
1. **AurralStubServerTests x3 (previewResolvesOnAMixedCaseAddress, imageProxyServesAurralNamedPictures, theRealOpenTransportRefusesRedirectsAndOversizedAnswers).** The cause was a stale stub. The process on 127.0.0.1:3901 (pid 83689) had been started at 16:03 from A1's worktree (agent-aaddb8c72c4341169), before A7 added `?download`, the image proxy and the redirects/oversized scenarios (18:37 and 19:17). `start.sh` reused any stub that answered `/__stub/ping`. Evidence: `/s/redirects/api/health` returned 404 (unknown scenario) on the old process and 200 after the restart.
   - **Fix (8de2794):** `/__stub/ping` now reports the sha256 of the server.py that is running. `start.sh` compares it with its sibling server.py's hash. If they differ, it stops the listener and starts the right code. It only stops a process whose command line is `aurral-stub/server.py`, and refuses anything else holding the port.
   - **Stray stub:** the stub on 127.0.0.1:3978 (pid 81823, from worktree agent-a27212bc370a426e7) was checked to be `dev/aurral-stub/server.py` and stopped.
   - **Side effect:** the 3901 stub now runs from this worktree's server.py. The main repo will restart it automatically once this branch is merged, because the hash will then match.
2. **Round14ActionsUITests Whole artist.** The cause was the S14 M2 fixture, not a code bug. The stub's editorial links always answer ARTIST_A `a74b1b7f-…`, a real MusicBrainz id. The dev Lidarr's `artist/lookup?term=lidarr:a74b…` names it "Radiohead", while the chart song's artist is "Stub Arrows". D116 therefore correctly refused with "Couldn't match this artist", and no Add appeared.
   - **Fix (051a3de):** a new stub scenario, `lidarr-artist`, credits Trending's songs to "Radiohead". The test signs in to `s/lidarr-artist` and fails fast if the unmatched message appears.
   - The name check is unchanged.
   - **Caveat:** the dev Lidarr resolves the lookup through its own metadata service. The test itself still only talks to localhost.
3. **BrowseFlowTests.testHomeLayoutEditor.** This was a flaky drag, not a regression. The `home-editor-changed` screenshot shows Most played still below Favourites after `press(forDuration:thenDragTo:)`, so the List had dropped the drag. X5's report already logged this test as "flaky under load". `OrderedVisibilityEditor`'s `.onMove` is unchanged.
   - **Fix (973cc55):** the drag is now slow, holds at the target, and checks the editor's own order (Most played's handle above Recently added's) before going on. It tries up to 3 times.

## Tests (own simulator "Magpie FX", iOS 27.0, deleted at the end; dev stack + localhost stub only)
- **RED:** the 5 failures in the main repo's run (Test-Magpie-2026.11.04_20-16-26).
- **GREEN, the 5 tests alone:** all passed. testHomeLayoutEditor took 1m28s; Whole artist took 1m05s.
- **GREEN, the suites:** BrowseFlowTests, Round14ActionsUITests, AurralStubUITests and AurralStubServerTests ran 28 tests: 28 passed, 0 skipped.
- **Packages:** `scripts/test-packages.sh` exit 0, all suites passed.
- **Writes checks:** `check-writes.sh` and `check-writes-selftest.sh` both exit 0.

## Files
- dev/aurral-stub/server.py
- dev/aurral-stub/start.sh
- Tests/MagpieUITests/Round14ActionsUITests.swift
- Tests/MagpieUITests/BrowseFlowTests.swift

## Concerns
- The Whole artist UI test needs the dev Lidarr to reach its metadata service for the MBID lookup. If it is offline, the test fails on the "match this artist" assertion, and the failure message says why.
- If two worktrees with different stub code run tests at once, each start restarts the shared stub. Run them one after another.
