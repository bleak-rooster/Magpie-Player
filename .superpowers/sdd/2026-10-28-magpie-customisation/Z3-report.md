# Z3 report: round 13 items 3, 4, 9, 10, 11 (CarPlay)

Branch `z3-carplay`, off v0.0.1-custom, with the latest v0.0.1-custom merged in (d5f01e7). Written in the worktree copy because the main path is blocked for this agent.

## What was built
- **Item 3: letter groups.** Artists, Songs and Albums always open on five rows: A–E, F–J, K–O, P–T and U–Z & #.
  - Each row shows its count. An empty group shows "No artists" and is disabled.
  - A group opens its list in letter sections, so CarPlay's scrubber still works. "#" comes last in U–Z & #.
  - A group over the car's item limit is split into pages on the same screen ("A–E (1 of 3)", detail "Abba to Cure"). The page size grows until the group screen itself fits.
  - Depth: tab → groups → group → page → Now Playing (5).
  - Playlists keep Y2's letters screen.
  - Code: `CarPlayUI/LetterBands.swift`.
- **Songs in the car (new).** The car's Library now shows Songs.
  - The group boundaries come from six single-row seeks, run in parallel, over `/api/song?_sort=title`: A, F, K, P, U and past Z. `LetterIndex.seekPastZ` was added and `LetterIndex.rank` made public.
  - When the count header is missing, the end is also found by seeks.
  - A group reads its songs by offset when it opens, capped at the list limit; past that the list says "Showing N of M".
  - Offline, the phone's songs are put in the server's order (`CPSongIndex.titleOrder`).
- **Item 4: Newest.** The Albums group screen starts with Newest.
  - Order: year (newest first), then `created`, then name. An album without a year goes last.
  - Newest is paged like a group when it is over the limit.
  - Inside each group, each letter's albums are newest first.
  - `Album.created` was added; Subsonic `created` is now decoded.
- **Item 9: Up Next.** The Up Next button is on (`isUpNextButtonEnabled`) while there is a queue.
  - The list has a "Now playing" row, then "Up next". The playing mark moves in place when the song changes. A long queue ends with "Showing N of M".
  - A tap calls `Player.jump(to:)` (the songs before it count as played) and goes back to Now Playing.
  - When Now Playing is already at depth 5, Up Next opens from the tab bar instead (Now Playing, then Up Next).
  - Code: `UpNext.swift`, `CarPlayController+UpNext.swift`, `CPNavigator.upNextFits`.
- **Item 10: the third tab.** The Finds tab is gone; Finds is now a Library row.
  - Tabs: Home · Library · chosen tab · Search.
  - The choice is stored in a new preference area, `CarPlayPreferences` (`magpie.prefs.carplay`).
  - Choices: Playlists (default), Artists, Albums, Songs, Genres, Favourites, Discover or Downloads. Discover is offered only while Aurral is set up; a saved Discover shows Playlists otherwise.
  - Changing it rebuilds the car's tabs at once.
- **Item 11: the car's Home.** The car has its own ordered list of the plan's nine shelves (no Genres).
  - Until it is changed, it follows the phone's Home.
  - The editor is the shared layout editor plus a "Same as iPhone" toggle.

## Tests (RED → GREEN)
- **Package:** `CarPlayPreferencesTests` (6), `LetterBandsTests` (13), `UpNextRowsTests` (5), `PlayerJumpTests` (3).
  - RED each time was the compile failure on the missing symbols: `Preferences.carPlay`, `CarPlayRows.artistBands`, `Album(created:)`, `CarPlayRows.upNext`, `CPNavigator.upNextFits` and `.queueEntry`.
- **App:** new `CarPlayRound13Tests` (7 tests).
  - They cover:
    - choosing the third tab, including the Discover fallback;
    - the Artists, Songs and Albums groups through the controller and adapter;
    - playing from a song group;
    - the Up Next jump and its depth re-root;
    - the car's own Home against the phone's.
  - First run: 5 failures, all from the tests reading lists that load asynchronously. Fixed in the tests (waits); the code didn't change.
  - The depth-walk test in `CarPlayModelTests` now also walks the groups, the song pages and every third-tab root.
- **Existing tests updated for the new behaviour:**
  - the car's Library shows Songs;
  - Finds is a Library row;
  - the car's Home has no Genres shelf;
  - the Y2 albums-paging test now goes through the A–E pages;
  - `libraryRoot(_:)` lost its `hasFindsTab` parameter.
- **Final full runs** (on simulator "Magpie Z3", app uninstalled first):
  - package suite: 1087 tests passed;
  - app suite: 993 Swift Testing tests passed, `** TEST SUCCEEDED **`;
  - XCUITests: 0 failures; the dev-stack ones were skipped because MAGPIE_IT was not set.
- `check-writes.sh` OK (no new writes; GETs only). `check-release.sh` OK.

## Decisions
D63–D68 are in docs/decisions.md; renumber them at merge if another stream took the same numbers. D12 is annotated, and docs/storyboard/carplay.md has a round-13 note.

## Concerns
1. **Settings placement.** As a top-level row, CarPlay made the Settings list overflow 375 × 667: 578 pt of content in 535 pt with Lidarr connected (`topLevelFitsSmallestPhone`).
   - So for now it opens from **Settings › Home & Library › CarPlay**.
   - `SettingsPage.carPlay` (row, destination and identifier `settings-carplay`) already exists. Z1 can promote it to the top level by adding it to `topLevel`.
2. **No Genres shelf on the car's Home,** following the plan's list of nine. Before this change, the car showed a Genres shelf whenever the phone did.
3. **Song offsets.** `songTitle(at:)` counts missing files but `songsPage` skips them, so a page can come up a song short when files are missing.
4. **Up Next doesn't reshape while on screen** (the existing never-reshape rule). Songs added meanwhile show the next time it is opened.
5. **No XCUITest for the new Settings page.** It is covered only by the summary check and the build.
