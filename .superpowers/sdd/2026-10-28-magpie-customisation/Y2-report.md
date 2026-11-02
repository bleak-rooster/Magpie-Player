# Y2 report: CarPlay A–Z groups and a Favourite button instead of Sleep (round 12 items 2 and 2b)

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
  - Tapping a group pushes its list (`CPDestination.letterGroup`, rows built in advance, so nothing is fetched). That list keeps its letter sections and scrubber.
- **Albums past 500.** The car read only the first 500 albums, and 500 is also this simulator's item limit, so later albums never appeared and Albums could never reach the letters screen. It now reads pages of 500 (`albumsAZ(offset:size:)`, up to 5000 albums). Offline, the albums come from the phone.

### Item 2b: Favourite instead of Sleep
- `sleepButton()`, `watchSleepTimer()`, `sleepTimerMessage` and the adapter's `sleepTimerActive` / `toggleSleepTimer` are gone from the car. The phone's sleep timer is unchanged.
- **The new button.** A `CPNowPlayingImageButton` shows star or star.fill, with `isSelected` set and the label "Favourite" or "Unfavourite" (the phone's `FavouriteCopy` words). It follows the current song through the existing `PlayerModes` watch, which now includes `favourite`, read through `isFavourite(songId:)` → `AppModel.isFavourite(.song)`. That read is observable: this session's change, else what the server said, else the queue's copy.
- **A tap.** It goes through X3's `setFavourite(.song, on)`, which is optimistic and rolls back to the real state on a refusal. The button is disabled while the change is with the server.
- **What the car says.** Nothing on success, because the star shows it. On a failure: "Couldn't add to your favourites" or "Couldn't remove from your favourites". Offline, nothing is sent and the car says "You're offline". The car speaks only in answer to the tap (critique M3), and the copy describes rather than instructs (D12).
- With nothing playing, the star is shown but disabled.

## Tests (TDD)
- **Package `CarPlayUITests/LetterGroupsTests`** (new target, macOS, 12 tests): sectioning and index titles, articles, "#", empty lists, range merging, paging, the letters screen never overflowing, the letters screen itself, details for paged groups, the section limit, album and playlist group rows that play, and clamp/needsRebuild keeping index titles.
  - RED: `value of type 'CPSectionModel' has no member 'indexTitle'`, `type 'CarPlayRows' has no member 'letterGroups'`.
  - GREEN: `Test run with 12 tests in 1 suite passed`.
- **App `CarPlayControllerTests`:**
  - Favourite: `favouriteButtonFollowsTheSong`, `favouriteTapStarsTheSongPlaying` (`/rest/star` and `/rest/unstar` with the song's id), `favouriteFailureRollsBack` (refused → star off, `isFavourite` false, alert, button enabled again), `favouriteOfflineSaysSo`.
  - A–Z: `libraryListsShowTheLetterScrubber`, `aLetterGroupOpensAListThatPlays`, `albumsPastTheFirstPageReachTheLettersScreen` (1200 albums → "A (1 of 3)"…, last group ends at "Album 1199"), `listLimitsAreReadable`.
  - RED: `value of type 'CarPlayController' has no member 'favouriteTapped'`, `type 'CarPlayRows' has no member 'favouriteMessage'`, plus the albums test failing three expectations before paging.
  - GREEN: `Test run with 14 tests in 1 suite passed`.
- **Updated tests.**
  - `CarPlayModelTests.depthNeverExceeds` now walks each A–Z list both under and over the limits, including `.letterGroup`.
  - `CarPlayCustomisationTests`: the two adapter sleep-toggle tests are replaced by `carFavouriteMessages`. `carReadsAreObservable` checks `isFavourite` instead of `sleepTimerActive`.
  - The phone's `SleepTimerTests` are untouched.
- **Final runs** (once, at the end):
  - `swift test` (all package suites): 10 test runs, all passed.
  - Full app scheme on "Magpie Y2" (app uninstalled first): 897 tests in 99 suites, 1 issue, in `CarPlayEdgeCaseTests.longAndUnicodeTitles`. That test assumed the first album row was the long title, but rows are now sorted A–Z. I changed it to check that the long title is present and uncut. The suite then passed (4/4). Everything else passed; UI tests skipped their dev-stack parts as usual without `MAGPIE_IT`.
  - `check-writes.sh` and `check-release.sh`: OK.
- **Limits read on the iOS 27.0 simulator:** `CPListTemplate.maximumItemCount = 500`, `maximumSectionCount = 200`.

## Decisions
1. **D12 depth budget kept.** A group's list is a third screen, so its rows play and never push:
   - an artist row shuffles the artist ("Shuffle · 3 albums");
   - an album plays from its start;
   - a playlist plays from its start (new `CPPlayRequest.playlist(id:)`).

   Under the limit, nothing changes: rows open the artist, album or playlist page as before. The alternative was to swap the list's content in place, so pages stayed one level up. I didn't take it, because the brief says "pushes" and Back would skip the letters screen.
2. **Merging only when needed.** Merging only when the screen wouldn't otherwise fit keeps letters as fine-grained as possible. With the 500 limit, letters rarely merge. When the car limits lists (for example a 12-item limit while driving), small neighbours merge first.
3. **Order follows the phone's index.** "#" comes first. Other scripts file under "#", so they are grouped into that one section rather than placed after Z.
4. **Detecting a failed favourite.** The adapter reads the phone's state back after `setFavourite`. A mismatch means the server refused, because X3 has already rolled the state back.

## Files
- New: `Packages/MagpieKit/Sources/CarPlayUI/LetterGroups.swift`, `Packages/MagpieKit/Tests/CarPlayUITests/LetterGroupsTests.swift`.
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
- **Behaviour change for big libraries.** Once a list is over the limit, artists in a group list shuffle instead of opening their page (decision 1). Worth an owner look on the car.
- **Not checked in a real car.** Whether CarPlay draws a scrubber for `sectionIndexTitle` on every head unit, and how it styles a disabled `CPNowPlayingImageButton`, is only verifiable on the CarPlay simulator or a car. This was not done here.
