# C3 report: owner items 6 and 7 (round 15)

Branch `c3-library-finds` (from `v0.0.1-custom` 25bed51). Commits:
- `1f689a7` item 7 alone: a rejected find leaves your playlists (D137, D138).
- `cb5aa84` item 6, runner: Try / Add to library intents, Magpie Lossless Preferred, library trials marked, target preview.
- `b5d118c` item 6, app: menus, confirmations, singles switch, keep on arrival, status, gating, check-writes pins.
- (one more: report + Release UI result.)

`c3-wip-all` is a scratch branch from the split. It can be deleted.

## Item 7: a rejected find leaves your playlists (D137, D138)

**Design:**
- `notForMe(confirm)` first proves the Not for me again with `runner.notForMeCheck`, which only reads.
- Then `cleanUpAfterLetGo`:
  - The pending playlist adds linked to the find are dropped.
  - A `FindCleanup` job is saved (`find-cleanups-<instance>.json`).
  - Each of the user's own playlists (`editablePlaylists`) goes through `removeEverywhere`, in AppModel+Playlists.swift. That function:
    - reads the playlist fresh through `ownPlaylist`, under the playlist lock;
    - refuses a playlist whose listing doesn't match its `songCount`;
    - removes every position holding the find's songs (duplicates too), highest first, in one `updatePlaylist`, sent once.
- Only after that does the runner delete the files. Its scan follows the delete.
- **Why the order matters:** after the scan, entries for deleted songs would dangle, and positions could no longer be trusted.

**Retry and notification:**
- The job is saved per playlist as it goes. An unfinished job is finished from a fresh read on every requests update.
- In-app message: e.g. "Gone from your Finds. Removed “Song” from 2 playlists: Chill, Road Trip."
- When the clean-up finishes in the background with notifications on, a local notification "Let go from your Finds" is also posted. With notifications off it is in-app only.
- **History:** Finds › Recently let go shows the latest 5 of 20.

**Pins:** check-writes pins the shape of `removeEverywhere` and that only AppModel+FindCleanup.swift calls it.

**Tests:**
- Package `FindCleanupTests`: 4 tests.
  - Positions highest first, duplicates included.
  - Message text.
  - Store, and its erase on sign-out.
  - History trim.
- Hosted `FindCleanupAppTests`: 9 tests, against a mock Navidrome with owners and counts.
  - Two playlists with duplicates: everything removed, the other entries untouched, one write per playlist with indexes 4, 3, 1.
  - A playlist the user doesn't own: untouched.
  - A count mismatch: the playlist is left alone and named.
  - A pending add is cleared, and saved without it.
  - An interrupted clean-up is finished later and is safe to repeat.
  - The background notification text, and nothing posted in the foreground.
  - Notifications off: in-app only.
  - Not in any playlist: no message.
  - The words name no service.
- **RED evidence:** the tests didn't compile before the types and API existed. No behavioural RED run was recorded.
- Regressions passed: Round14ActionsTests, FindsShelfTests, and the Requests package suite (386 tests).

**Release UI check: PASSED.**
- `Round15LetGoUITests.testARejectedFindLeavesItsPlaylistAndMagpieSaysSo` ran on scheme MagpieUIOnly, Release, the "Magpie Tests" simulator, against the dev Navidrome. It took 17.6 s.
- The dev stack can't make a real find without the internet. So `-MagpieUITesting YES -MagpieUITestLetGo <song id>` runs the exact clean-up a confirmed Not for me runs. This hook is UI-tests only, like `-MagpieSearchPageSize`.
- Setup: a playlist [a, X, b, X], made through the Subsonic API.
- Result: the message names X, and the playlist is [a, b].
- **Not covered by a UI test:** the runner's Lidarr delete half. Hosted and package tests cover it.

## Item 6: Try and Add to library (the coordinator's approved spec)

**Where the actions appear:**
- Song menus (`OutsideSongMenu`): Trending, genre charts, Discover playlists, top songs, and Search's outside songs.
- Album menus: Trending Top albums (long press), outside artist page album rows, and the outside album page bar.
- Recommended shows artists, so its actions are on the artist pages.

**Exactly what was touched in TrendingView:** in `albums(_:region:)` only. The ForEach's `_` became `index`, and a `.contextMenu { OutsideAlbumMenu(…) }` plus `accessibilityIdentifier("trending-album-\(index)")` were added. The chart picker and flow code weren't touched. **RecommendedView was not touched.**

**What exists:**
- **Runner** (package):
  - `RequestRunner.Intent` (`.plain` / `.trial` / `.library`), with request marks `addToLibrary` and `askedAsTry`.
  - A new artist added to the library goes to the main root, tag `magpie`, with "Magpie Lossless Preferred". Lidarr is told `monitor: all` and `searchForMissingAlbums: false`. The runner then sends AlbumSearch for the target, then ArtistSearch.
  - A find artist gets a find, which is kept on arrival.
  - A library artist gets monitor + search of that release only; nothing about the artist changes.
  - `isLibraryTrial` marks Try on a library artist; `trialKept` clears it.
  - `targetPreview`: the release a song brings in, using reads only.
  - `ArtistLidarr.listSingles`: the singles switch, for Magpie's own artists that follow no new releases.
  - `Provisioner.ensureLosslessPreferred`.
- **App:**
  - The menus.
  - "This song comes with the album X" and "Include singles" confirmations.
  - Keep on arrival, then Bring in more Everything in lossless-preferred.
  - Status lines: In your library / On trial · until / Coming · N% / Couldn't bring it in, with Retry.
  - Gating: hidden without Lidarr. Otherwise explained, and a tap reads nothing.
  - Add to library never lands in the queue.

**Tests:**
- Package `LibraryFindsTests`, 15 tests. Every row of the matrix:
  - a new artist: Try, and Add to library (the body, then AlbumSearch, then ArtistSearch);
  - a find artist;
  - a library artist: Add, and Try as a trial;
  - previews: an album said first, not listed, a new artist;
  - singles: lists them and monitors nothing; the owner's artist is refused; changes off sends nothing;
  - persistence, steps and status.
- `LosslessPreferredTests`, 3 tests: made once through the gate; a conflict is never changed; changes off makes nothing.
- Hosted `LibraryFindsAppTests`, 7 tests: gating (hidden / explained, a tap says why, nothing written); quality profile not made with changes off; Try on an album → trial Try sheet; unmatched album; keep on arrival; row status words; copy never says Lidarr or Aurral.
- check-writes and its selftest pass. RefreshArtist and ArtistSearch callers are pinned.

**Release UI check:** see the bottom of this file.

**Not done (item 6):**
1. **Reject for a library trial.** It would delete that release's track files. It needs a new gate confinement rule that also proves the album had no files before Magpie monitored it. That means recording the track-file count at monitor time in the ledger, and a check-writes pin for a third track-file-delete caller. Keep (clearing the mark) exists in the model; there is no UI for it yet.
2. **Library trials in the Finds lists.** FindsShelf reads the Finds library only.
3. **The singles switch covers only artists Magpie added that don't follow new releases.** An owner-added artist would need a new gate rule. The owner-data rule forbids changing it, so it is explained instead.
4. **The Release UI check exercises gating only, with Allow changes off.** A real Try or Add needs MusicBrainz, which is public internet, so it isn't run against the dev stack.

**Release UI check (item 6): PASSED.**
- `Round15LibraryActionsUITests.testATrendingSongOffersTryAndAddToLibraryAndSaysWhyWithChangesOff` ran in Release on the dev stack, the stub Aurral and the dev Lidarr. It took 67.9 s.
- The Trending song's ⋯ menu shows Try and Add to library.
- Each tap shows "…switched off…", and nothing is read or written.

**Checks:** check-writes passes, the selftest passes (42 planted violations and 26 allow-list weakenings caught), and check-release says OK.
