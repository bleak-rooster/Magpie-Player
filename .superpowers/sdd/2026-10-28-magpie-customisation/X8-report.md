# X8 report: search results open pages; outside artist and album pages (R19, with R20)

Status: DONE. Branch `x8-outside-pages` (off v0.0.1-custom). Worktree: `.claude/worktrees/agent-a9f27e7093076f40e`.

## Commits
- 9528d88 MusicBrainz browse (official releases), outside sections and release pick, session catalog, Try this album (release-group target, dedupe by release group)
- c7994c0 Search Artists/Albums results open their pages (phone UI test)
- 0a4667a The car's search lists artists, each opening the artist page
- a9b8c4b Outside artist and album pages, wired from search and the library artist page's "Not in your library"
- 47d4140 Comments name the outside pages as MusicBrainz callers

## What was built
- **Search bug.** Root cause: `.simultaneousGesture(TapGesture())` on the NavigationLink rows took the tap (R20 asked for it to go). Removed it. The search is now remembered when the tab's stack gets deeper (`depth` onChange). Rows got the ids `search-artist-N` and `search-album-N`.
- **CarPlay.** Search dropped artists entirely. `CarPlayRows.searchItems` now lists Songs, Artists, Albums, and `searchResults` has an "Artists" section. An artist row opens `.artist`, which sits at depth 3 and whose albums play (D12 holds).
- **MusicBrainz** (`MusicBrainzClient+Browse.swift`). `officialReleaseGroups(artist:)` browses `release?artist=…&status=official&type=album|ep|single&inc=release-groups`, up to 2 pages of 100, one entry per release group. `officialReleases(releaseGroup:)` browses with `inc=recordings`. Both use the same client, so the same 1 req/s and app UA.
- **Search package** (`OutsidePages.swift`):
  - `OutsideArtistSections`: Albums/EPs/Singles hold the studio releases; anything with a secondary type goes under More, labelled with that type. Newest first, undated last.
  - `OutsideReleasePick`: official first, then the earliest dated release, never one without tracks.
  - `OutsideCatalog`: an actor cache in memory per session. Failures aren't kept.
- **Requests.**
  - `MagpieRequest.albumTarget`.
  - `tryRecording(_:tier:album:releaseGroup:)`: `album` is the Try this album target, and `releaseGroup` dedupes a per-track Try against a live request for that release group.
  - In resolve, a target the catalogue doesn't allow is never swapped for another release group. An owner's artist needs the album in Lidarr; a new artist needs the album to fit the Finds profile.
  - `RequestLinks.request(releaseGroup:)` also matches `albumTarget`, so it works before resolve.
- **App.**
  - `AppModel+Outside.swift` adds `outsideCatalog`, `tryAlbum` and `tryTrack`, plus `librarySong(for:)` through the match index. `AppModel.swift` got one stored-property hook line.
  - `Screens/Outside/` has `OutsideArtistModel/View` and `OutsideAlbumModel/View`, and `Route.outsideArtist/outsideAlbum`.
  - The pages reuse `OutsideArtLoader`, `ArtistLidarrModel`/`ArtistLidarrLine` (W3 line plus X7's Add flow), `RequestedItemRow`/`RequestRow` and `TrySheet`.
  - TrySheet gained an album mode ("Try this album") and dedupes per-track Tries by release group.
  - `ArtistLidarrLine` takes an optional `addTitle`, so the album page can say "Add <artist> to your library".
  - Offline, both pages show `OfflineNotice` ("You're offline") and send no request.
  - Not-yet artist and album rows in search, and the library artist page's not-yet albums, open the outside pages when they have an MBID.

## Decisions
- **Popular songs omitted** (spec call): the app has no top-recordings source.
- **How an album Try is represented:** the request carries the album's first track as its recording and the release group as its target. It lands when the album does, and the request rows show that track.
- **Which release the album page lists:** official, then earliest dated. The aim is the original issue rather than a later deluxe edition.
- **Source on tracks:** MusicBrainz tracks use `ExternalSource.lidarr`, to avoid adding a Codable enum case.
- **Simulator:** "Magpie X8" is iPhone 18 Pro on iOS 27.0. The 27.1 runtime rejected iPhone 17/18 device types. It was deleted at the end.
- **Where Try this album appears:** a capsule on the album page, and a long-press item on album rows of the artist page. A tap on an album row opens its page.

## Tests (RED → GREEN)
- **Package, RED** was compile-level (missing symbols), then GREEN:
  - `MusicBrainzBrowseTests` (3)
  - `OutsidePagesTests` (4): sections, release pick, catalog cache, tracks as recordings
  - `TryAlbumTests` (5): the target release group, the owner's artist monitors only that album, a target outside the Finds profile writes nothing, two Try this album taps make one request, a per-track Try joins the live album request
- **Phone UI test** `BrowseFlowTests.testSearchArtistAndAlbumResultsOpenTheirPages`: RED with the ids added but before the fix ("the album result opened nothing"), then GREEN.
- **CarPlay** `CarPlaySearchArtistsTests` (2): RED (no Artists section, index crash), then GREEN.
- **App tests** `OutsidePagesAppTests` (5): sections, picked release, offline, per-track dedupe, lands in place. Plus `ArtistLidarrAppTests.outsidePagesAddThroughTheGateAndRefuseTheOwnersArtist`.
  - These were written right after the models, so they had no separate RED run.
  - A mutation run stood in for it: undoing the albumTarget match and the landing refresh failed the dedupe and lands-in-place tests. Restoring the code made them pass.
- **Full runs:**
  - Packages: all green.
  - App suite with the UI tests (`MAGPIE_IT=1`, app uninstalled first): 1077 passed, 3 skipped, 1 failed. The failure was `AppIconUITests.testPickerSwitchesTheIconAndBack`, which is unrelated and passed when re-run alone (flake).
  - `check-writes.sh` and `check-release.sh`: OK.

## Concerns
- **Album rows when Ready:** on the outside artist page, a Ready album row stays a request row; its request page offers Play. Only the album page turns its tracks into library songs in place.
- **New artists and More albums:** Try this album on a More album (Live and so on) for a new artist fails with "no release", because the Finds profile excludes it. The option is still offered.
- **Not exercised end-to-end:** no UI test opens an outside page, since that would reach musicbrainz.org (G0).
- **Large catalogues:** artists with more than 200 official releases list only the first 200.
- **Scope:** CarPlay has no outside pages; R19 asked only for the search check there.

## Fix round (review 0C/2I + polish), after merging v0.0.1-custom (X1)
- I1 (9a2347e): Try this album now dedupes only against a live request for its release group, in both the runner (`liveTry`) and `TrySheet.existingPhase(album:)`.
  - A single-song request for track 1 no longer stands for the album.
  - RED: `TryAlbumTests.anEarlierSongTryOfTrackOneIsNotTheAlbum` failed with 4 issues before the fix.
  - Also added: `OutsidePagesAppTests.trySheetForTheAlbumIgnoresASongRequestOfTrackOne`.
- I2: each outside page now builds and loads its model in one task, `OutsideArtistModel.open` / `OutsideAlbumModel.open`, so the order SwiftUI runs tasks in no longer matters.
  - RED: compile-level (missing symbols).
  - Test: `thePageTaskBuildsAndLoadsTheModel`.
- Try this album is hidden where it can't work: an album with a secondary type (Live, Compilation…) by an artist not known to be in Lidarr.
  - The rule is `OutsideAlbumModel.canTryAlbum`, tested.
- Review Minors:
  - A Magpie-added artist's target must now fit the Finds profile.
  - The `rgNone` sentinel is gone.
  - The `OutsideCatalog.reset` comment no longer claims sign-out clears it.
- Polish (a) and (b) (44756bc), tested in QueueActionsTests (RED was compile-level):
  - The queue toasts last 1.5 s (`LibraryNotice.shown`).
  - Offline, Play next or Add to queue on an album or playlist with nothing downloaded says "Nothing downloaded" instead of asking.
- Polish (c), deflaked tests (cb4ecca, abab9cc); no assertion was weakened:
  - The remove test starts the second remove only once the first is under way.
  - The probe test counts requests by when they were sent.
  - The icon picker answers the system alert wherever it shows, until the icon is chosen.
  - The layout editor test waits until both drag handles can be tapped.
  - A new UI-testing-only `-MagpieResetLayouts` resets layouts on every BrowseFlow launch, and on failure through a teardown relaunch.
  - The DownloadingNow test first clears any download an earlier test left. It failed in the full run for that reason, and passed once fixed and re-run with the leftover state in place.
- Final runs:
  - Packages: green.
  - App suite (app uninstalled first): 1108 passed, 1 failed (DownloadingNow, fixed above).
  - UI target re-run: 23 passed, 3 skipped.
  - check-writes.sh and check-release.sh: OK.
