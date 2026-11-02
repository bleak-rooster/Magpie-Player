# Y2 report: CarPlay A–Z groups, Favourite instead of Sleep, Play/Shuffle rows, Now Playing album/artist (round 12 items 2, 2b, 2c, 2d)

Branch `y2-carplay` (off `v0.0.1-custom`). Commits are prefixed "Y2:".

## What was built

### Item 2: A–Z in the car's long lists
- **Letter sections.** Library › Artists, Albums and Playlists are now one section per letter ("#", then A–Z). Each section has a header and a `sectionIndexTitle`, so CarPlay shows its letter scrubber. `CPSectionModel.indexTitle` is new; `rebuild` passes it to `CPListSection`, `clamp` keeps it, and `needsRebuild` treats a change to it as a reshape.
- **Articles, as on the phone (W3).** Artists and albums drop Navidrome's default articles (`LetterIndex.navidromeArticles`), so "The Beatles" files under B. Playlists keep their articles, as the phone's Playlists do. The folding is `LetterIndex` itself (CarPlayUI now depends on `Search`), so diacritics, ligatures, digits, symbols, other scripts and blank names behave the same as on the phone. Every "#" item goes in one "#" section, first, matching the phone's index order.
- **Letters screen.** When a list has more items than `CPListTemplate.maximumItemCount`, or more letters than `maximumSectionCount`, it opens on a letters screen instead (`CarPlayRows.lettered` / `letterGroups`):
  - One row per letter, with the count in the detail ("12 artists").
  - Letters stay separate while the screen fits. When it doesn't, the smallest neighbouring pair merges first (leftmost on a tie) into a range such as "X–Z", and a merge never goes past one page.
  - A letter with more items than the limit is split into pages, "S (1 of 3)", with "Sabbath to Scorpions" as the detail.
  - If pages alone would overflow the letters screen, the page size grows until the screen fits. The car then clamps each group list with its usual "Showing N of M" row. This can't happen at the limit this simulator reports.
  - Tapping a group pushes its list (`CPDestination.letterGroup`, rows built in advance, so nothing is fetched). That list keeps its letter sections and scrubber, and its rows open their artist, album or playlist page, the same as on a list under the limit (owner ruling, see Decisions).
- **Albums past 500.** The car read only the first 500 albums, and 500 is also this simulator's item limit, so later albums never appeared and Albums could never reach the letters screen. It now reads pages of 500 (`albumsAZ(offset:size:)`, up to 5000 albums). Offline, the albums come from the phone.

### Item 2b: Favourite instead of Sleep
- `sleepButton()`, `watchSleepTimer()`, `sleepTimerMessage` and the adapter's `sleepTimerActive` / `toggleSleepTimer` are gone from the car. The phone's sleep timer is unchanged.
- **The new button.** A `CPNowPlayingImageButton` shows star or star.fill, with `isSelected` set and the label "Favourite" or "Unfavourite" (the phone's `FavouriteCopy` words). It follows the current song through the existing `PlayerModes` watch, which now includes `favourite`, read through `isFavourite(songId:)` → `AppModel.isFavourite(.song)`. That read is observable: this session's change, else what the server said, else the queue's copy.
- **A tap.** It goes through X3's `setFavourite(.song, on)`, which is optimistic and rolls back to the real state on a refusal. The button is disabled while the change is with the server.
- **What the car says.** Nothing on success, because the star shows it. On a failure: "Couldn't add to your favourites" or "Couldn't remove from your favourites". Offline, nothing is sent and the car says "You're offline". The car speaks only in answer to the tap (critique M3), and the copy describes rather than instructs (D12).
- With nothing playing, the star is shown but disabled.

### Item 2c: Play and Shuffle (owner addition)
- Every album, artist and playlist page in the car now starts with **Play**, then **Shuffle**. That includes the downloaded album, artist and playlist pages. It's built by `CarPlayRows.playShuffle`.
  - Play starts from the first song, in order. For an artist, that's all their songs album by album, in the order the artist page lists them (new `CPPlayRequest.artistInOrder`).
  - Shuffle shuffles the same songs.
- Both replace the queue through `player.play`, which also resets shuffle. The car never asks before replacing, even with "Ask before replacing" on (R12).

### Item 2d: Now Playing's album and artist (owner addition)
- `isAlbumArtistButtonEnabled` is now driven by the song playing. A watch on (song, offline) works out the song's pages with `CarPlayRows.nowPlayingLinks`.
  - Online: the album and artist pages, when the song has an albumId or artistId.
  - Offline (R10): only the downloaded album or artist page, if it's on the phone. With neither, the button is off.
- **A tap** (`CPNowPlayingTemplateObserver`): with both pages known, an action sheet offers "Go to album", "Go to artist" and "Cancel". With only one, it goes straight there.
- **Going to a page.** `go(to:)` pops back to the tab bar and pushes the page from there, so the page gets the whole depth budget. The browse stack under Now Playing goes.

## Tests (TDD)
- **Package `CarPlayUITests/LetterGroupsTests`** (new target, macOS, 12 tests): sectioning and index titles, articles, "#", empty lists, range merging, paging, the letters screen never overflowing, the letters screen itself, details for paged groups, the section limit, album and playlist group rows that play, and clamp/needsRebuild keeping index titles.
  - RED: `value of type 'CPSectionModel' has no member 'indexTitle'`, `type 'CarPlayRows' has no member 'letterGroups'`.
  - GREEN: `Test run with 12 tests in 1 suite passed`.
- **App `CarPlayControllerTests`:**
  - Favourite: `favouriteButtonFollowsTheSong`, `favouriteTapStarsTheSongPlaying` (`/rest/star` and `/rest/unstar` with the song's id), `favouriteFailureRollsBack` (refused → star off, `isFavourite` false, alert, button enabled again), `favouriteOfflineSaysSo`.
  - A–Z: `libraryListsShowTheLetterScrubber`, `aLetterGroupOpensAListThatPlays`, `albumsPastTheFirstPageReachTheLettersScreen` (1200 albums → "A (1 of 3)"…, last group ends at "Album 1199"), `listLimitsAreReadable`.
  - RED: `value of type 'CarPlayController' has no member 'favouriteTapped'`, `type 'CarPlayRows' has no member 'favouriteMessage'`, plus the albums test failing three expectations before paging.
  - GREEN: `Test run with 14 tests in 1 suite passed`.
- **2c, 2d and the ruling.**
  - Package `PlayShuffleAndLinksTests` (6 tests):
    - Play and Shuffle rows on album, playlist and artist pages, online and downloaded, with their actions;
    - `theDeepestPathStaysWithinFive` (tab → letters → group → page = 4, nothing deeper, plus Now Playing ≤ 5);
    - the link rules online and offline.
  - App tests:
    - `playAndShuffleReplaceTheQueue`: album Play gives the queue in order with shuffle off and no question asked, even with "Ask before replacing" on; Shuffle shuffles; artist Play gives al1 then al2 in order.
    - `albumArtistButtonOffersBothPages`: the button turns on, the sheet offers both, and each choice pushes the right page from the tab bar.
    - `albumArtistButtonGoesStraightToTheOnlyPage`.
    - `albumArtistButtonOffline`: off when the song isn't on the phone; the downloaded page when it is.
    - `aLetterGroupOpensAListOfPages`: a row opens the playlist page, then Play.
  - RED: `type 'CPPlayRequest' has no member 'artistInOrder'`, `CPNavigator has no member 'carPlayTemplateDepthLimit'`, `CarPlayRows has no member 'nowPlayingLinks'`. The first app run then failed 7 expectations (offline order and the old depth tests), fixed after.
  - GREEN: the package's CarPlayUI suites ran 18 tests; the app's CarPlay suites ran 52.
- **Updated tests.**
  - `CarPlayModelTests.depthNeverExceeds` now walks each A–Z list both under and over the limits, including `.letterGroup`.
  - `CarPlayCustomisationTests`: the two adapter sleep-toggle tests are replaced by `carFavouriteMessages`. `carReadsAreObservable` checks `isFavourite` instead of `sleepTimerActive`.
  - The phone's `SleepTimerTests` are untouched.
- **Final runs after 2c/2d** (once): `swift test` all 10 runs passed; full app scheme on a fresh "Magpie Y2" (app uninstalled first): `Test run with 901 tests in 99 suites passed` / `TEST SUCCEEDED`; check-writes and check-release OK.
- **Earlier final runs** (before 2c/2d):
  - `swift test` (all package suites): 10 test runs, all passed.
  - Full app scheme on "Magpie Y2" (app uninstalled first): 897 tests in 99 suites, 1 issue, in `CarPlayEdgeCaseTests.longAndUnicodeTitles`. That test assumed the first album row was the long title, but rows are now sorted A–Z. I changed it to check that the long title is present and uncut. The suite then passed (4/4). Everything else passed; UI tests skipped their dev-stack parts as usual without `MAGPIE_IT`.
  - `check-writes.sh` and `check-release.sh`: OK.
- **Limits read on the iOS 27.0 simulator:** `CPListTemplate.maximumItemCount = 500`, `maximumSectionCount = 200`.

## Decisions
1. **D12 revised (owner ruling, 2026-11-02).** The depth limit is now CarPlay's own: 5 templates, Now Playing included.
   - `CPNavigator.maxBrowseDepth` is 4 and `carPlayTemplateDepthLimit` is 5 (tab → letters → group → page, then Now Playing). `docs/decisions.md` D12 is updated to match.
   - A letter group's rows now open their page. My first version had them play, to keep within the old limit of two pushes, but that is gone.
   - Pages are still leaves: an artist page's albums still play rather than open, so the path is the same whatever list it was reached from.
2. **Merging only when needed.** Merging only when the screen wouldn't otherwise fit keeps letters as fine-grained as possible. With the 500 limit, letters rarely merge. When the car limits lists (for example a 12-item limit while driving), small neighbours merge first.
3. **Order follows the phone's index.** "#" comes first. Other scripts file under "#", so they are grouped into that one section rather than placed after Z.
4. **Detecting a failed favourite.** The adapter reads the phone's state back after `setFavourite`. A mismatch means the server refused, because X3 has already rolled the state back.

## Files
- New: `Packages/MagpieKit/Sources/CarPlayUI/LetterGroups.swift`, `CarPlayUI/NowPlayingLinks.swift`, `Packages/MagpieKit/Tests/CarPlayUITests/LetterGroupsTests.swift`, `PlayShuffleAndLinksTests.swift`; `docs/decisions.md` (D12).
- Changed:
  - `Packages/MagpieKit/Package.swift`: CarPlayUI → Search, and the new test target.
  - `CarPlayUI/TemplateModels.swift`: `indexTitle`, `.letterGroup`, `.playlist`, and the lettered builders.
  - `CarPlayUI/ListDiff.swift`
  - `CarPlayUI/CarPlayController.swift`: fetchers with limits, album paging, index titles, playlist play, the star in the buttons and the modes watch.
  - `CarPlayUI/CarPlayController+Customisation.swift`: the protocol and the favourite button.
  - `CarPlayUI/CustomisationRows.swift`: `favouriteMessage`, `CPFavouriteResult`.
  - `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift`
  - Tests: `CarPlayControllerTests`, `CarPlayCustomisationTests`, `CarPlayModelTests`.

## Concerns / for the merger
- **Y3 (library scoping) must scope the new car call.** The adapter's `albumsAZ(offset:size:)` in `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift` calls `albumList(.alphabeticalByName, size:offset:)` and needs `musicFolderId` like the other car list calls. I added none, per the ownership rule. The old `albumList(_:size:)` is still on the protocol and in `CarPlaySceneDelegate`, but the car's Albums no longer uses it.
- **2d clears the browse stack.** "Go to album" / "Go to artist" pops back to the tab bar before pushing the page, so the driver's place in the lists is lost. This was the only way to keep the page and Now Playing within 5 templates.
- **Not checked in a real car.** Whether CarPlay draws a scrubber for `sectionIndexTitle` on every head unit, and how it styles a disabled `CPNowPlayingImageButton`, is only verifiable on the CarPlay simulator or a car. This was not done here.

## Fix round 1 (review Y2-review.md: 0C/2I)
- **I1:** the controller-side work moved into two new files, so `CarPlayController.swift` is back to 894 lines (its pre-Y2 size).
  - `CarPlayUI/CarPlayController+AZ.swift`: `azFetcher`, `readAlbums` (paging plus counting), `reloadAZLists` and `artistSongs`.
  - `CarPlayUI/CarPlayController+NowPlayingLinks.swift`: the 2d observer, `watchNowPlayingLinks` and `go(to:)`.
  - The controller keeps one-line hooks only.
- **I2:** on the artist and downloaded-artist pages, `albumsOpen` decides what an album row does.
  - The controller sets it to `CPNavigator.allowsPush(atDepth:)` for the page's own depth.
  - At depth ≤ 3 an album row opens the album page, which has Play/Shuffle and its tracks. At depth 4 it plays, so Now Playing stays the 5th template.
  - `depthNeverExceeds` now builds each screen for the depth it sits at.
- **Made for you:** now starts with Play and Shuffle over its library songs. A page with no library songs has neither.
- **Minors:**
  - M1: each A–Z list is laid out once per read, off the main thread, not on every song change.
  - M3: the A–Z lists are read again when `limitedUserInterfacesChanged` fires.
  - M4: past 5000 albums, the count is found with at most 40 single-row reads (gallop, then halve), and the list ends with "Showing 5000 of N". That row takes one of the car's slots.
  - M6: offline, the phone's albums come in one catalog read.
  - M9: the star's task is `[weak self]`, held in `favouriteTask`, and cancelled on disconnect.
  - M12: the sheet's real path is tested (`CPAlertAction.handler` → dismiss → `go`). The offline test waits for the links of the song in question (`nowPlayingLinks.songId`) instead of a fixed sleep.
  - Not done: M2 (smarter `go(to:)`), M5, M7, M8 and M10. None was asked for.
- **Tests:**
  - Package `FixRound1Tests` (3 tests): `albumsOpen` both ways (online and downloaded), Made for you's Play and Shuffle, and the "Showing 4 of 9" note in both layouts within `maxItems`.
    - RED: extra-argument compile errors (no `albumsOpen` or `total` parameters existed yet).
    - GREEN: the three CarPlayUI suites ran 21 tests.
  - App tests:
    - `artistAlbumsOpenWhenTheDepthAllows`: two routes. Artist page at depth 3: album opens. At depth 4: album plays, and Now Playing is the 5th template.
    - `albumsPastTheCapSayHowManyShow`: 5200 albums give "Showing 5000 of 5200".
    - `favouriteAfterDisconnectSaysNothing`.
    - Updated: the sheet tap path, the offline wait and the Made for you rows.
    - These were written with the code, so I have no RED run for them.
  - `CarPlayControllerTests`: 21 passed.
  - Final runs: `swift test` (10 runs) passed; check-writes and check-release OK; full app scheme on a fresh "Magpie Y2" (app uninstalled first): `Test run with 904 tests in 99 suites passed`, TEST SUCCEEDED.
