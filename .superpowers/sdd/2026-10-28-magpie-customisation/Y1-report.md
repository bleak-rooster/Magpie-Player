# Y1 report: search that understands "song + artist", and load more (plan items 1 and 3)

Branch `y1-search` (off v0.0.1-custom). Commits: 524eeda (package), 6748bef (app + UI tests), plus a final commit with the CarPlay test update and this report.

## What was built

**Item 1: song + artist in one query**
- `SearchRanker` (Packages/MagpieKit/Sources/Search/SearchRanker.swift), pure:
  - Scores by query words covered across title, artist and album. A whole word scores 3, a prefix 2 and a near-miss 1; title or name matches count double.
  - Near-miss means one edit, or two for words of 8+ letters, using OSA distance with adjacent swaps. Words under 4 letters never count as near-misses.
  - Folds case, diacritics, width and œ/æ/ß/ø/ł/đ/þ. Punctuation inside a word is dropped as well as split on, so "AC/DC" matches both "acdc" and "ac dc".
  - Unspaced scripts (CJK, kana, Hangul, Thai) match as substrings. Cyrillic and other spaced scripts match by word.
  - Articles (the, a, an, le, la, les, l, el, los, las, die, der, das) are optional in the query and in names, unless the query is nothing but articles ("the the").
  - Order of comparison: words covered, then main name matched in full, then how many of name and artist are matched in full, then quality.
  - Ties go artist, then album, then song, then server order, which keeps the old exact-name rule. When no hit covers any word, the Top result falls back to the server's first song, as before.
- One scorer drives the Top result, the order within every library section, and the outside band (ListenBrainz/Lidarr). The band is ranked before the 10/8/5 limits are applied, and ties keep source order.
- `SearchPlan`:
  - Runs the whole query plus at most 4 splits. The artist part is tried as the last word, the first word, the last two words, then the first two.
  - A part that is only an article is skipped.
  - " - ", "–" and "—" parse into both orders, and the dash is dropped from the whole query. " by " gives one split (title by artist), and the whole query stays as typed, so "Stand by Me" still works.
- `LibraryPager.first`:
  - Runs the plan at most 3 requests at a time: the whole query and 4 splits make 5 requests per debounced query.
  - Splits ask for songs and albums only (`artistCount` 0). A split keeps only rows whose artist matches its artist part (`SearchRanker.nameMatches`, which allows typos).
  - Rows are de-duplicated by id. A failed split adds nothing. Search fails only when the whole query failed and the splits found nothing.
- Item 1.3: when the Top result is a song matched by both title and artist, its artist (cover `ar-<id>`) and album are inserted as the first rows if they aren't already there. The artist row reads just "Artist" because no album count comes with it.
- The 250 ms debounce and cancel-on-new-query were already in SearchModel and are unchanged.

**Item 3: load more**
- `NavidromeClient.search` takes `songOffset`/`albumOffset`/`artistOffset`, with defaults of 0. A zero offset is left out of the URL.
- `LibraryQuery` carries the text, counts and offsets, so Y3 can add `musicFolderId` in one place. AppModel's `mergedSearch()` call site maps it onto `client.search`. **No musicFolderId added.**
- Batch sizes are 20 songs, 10 albums and 10 artists; the first batch of artists rose from 5 to 10.
- `SearchPaging`:
  - Lives on `SearchSections.paging`; it is nil offline, so offline never pages.
  - Holds, per section, each plan query's offset and done flag plus the ids shown, so sections page on their own and two can load at once.
  - A batch shorter than asked for ends that query's section. The splits page too.
- `LibraryPager.more`:
  - Asks only for the one section (other counts 0) from every query that still has more.
  - If a split's artist filter drops a whole batch, it keeps going for up to 5 rounds, then gives up on the section, so the spinner never hangs.
  - A partial failure stops that query. When every query fails it throws, and the footer offers to try again.
- `SearchSections.append`:
  - Adds new rows at the end, ranked among themselves, so nothing on screen moves.
  - De-duplicates and leaves the Top result and other sections alone.
- `SearchModel.loadMore(kind)`:
  - Runs only when the phase is `.done`, the results have paging and the section has more. One load runs per section at a time.
  - A new query cancels every load-more, and a stale result never lands.
- SearchView: each library section ends with a footer.
  - While the section has more, a spinner that loads as it appears (`search-more-<kind>`). Its identity includes the row count, so it fires again if it is still on screen after a small batch.
  - After a failure, "Couldn't load more. Try again".
  - At the end, "No more results" (`search-end-<kind>`). In the All scope it shows only after something more has loaded, so short lists don't end every section with it. In the Songs, Artists and Albums scopes it always shows.
- UI tests only: `-MagpieUITesting YES -MagpieSearchPageSize 5` (App/Screens/Search/SearchPageSize.swift) shrinks the batches, because no dev-library query has more than 17 songs.

## Tests (RED, then GREEN)

- Package tests (SearchTests):
  - `SearchRankerTests`: a ranking table of 40 queries, including "hey jude beatles", "beatles hey jude", "the national bloodbuzz", typos ("beatels", "jued", "rapsody", "quen"), articles, diacritics, Cyrillic, CJK, AC/DC and "the the". Plus ordering, score, nameMatches and outside-row tests.
  - `SearchPlanTests`: 7 tests.
  - `LibraryPagerTests`: 14 tests against `FakeNavidrome`, which applies Navidrome's AND-of-word-prefixes rule, CJK substring matching, counts/offsets and count 0 → none. Its semantics were checked against the dev server. Covers splits, the concurrency cap (peak ≤ 3, ≥ 2), failures, offsets, stopping on a short batch, de-duplication across queries and batches, split paging, cancellation, filtered-out batches and page size.
  - `MergedSearchPagingTests`: 6 tests.
  - NavidromeKit: `searchSendsOffsets`.
- RED: `error: cannot find type 'LibraryQuery' in scope` (package) and `extra arguments at positions #5, #6, #7` (client).
- GREEN: `Test run with 93 tests in 13 suites passed`.
- App: `SearchLoadMoreTests` covers loading then "no more", a new query cancelling the load, a failed load that can be tried again, and no load without paging.
  - RED: built against the old SearchModel, `error: value of type 'SearchModel' has no member 'loadMore'`, `extra argument 'more' in call`.
  - GREEN: 44 tests in 5 search, offline and cancellation suites passed.
- UI on the dev stack (own simulator "Magpie Y1"):
  - `SearchUITests.testSongAndArtistInOneQuery`: "dead reckoning cartografers" puts Dead Reckoning as the Top result and The Midnight Cartographers in the artist row.
  - `testSongsLoadMoreAtTheEnd`: "aurora" with batches of 5 loads 13 songs in 3 batches, then shows "No more results", with no 14th row.
  - RED by construction: before this change, a GET probe of the dev server returned nothing for "dead reckoning cartografers", and no load-more footer existed.
  - Both pass, along with BrowseFlowTests' search and queue tests (testSearchAndPlay, testSearchArtistAndAlbumResultsOpenTheirPages, testQueueAfterPlayNextAndModes, testQueueStaysUpThroughSongChangesAndEdits).
- Final runs:
  - Full package suite: every target passes.
  - Full app suite: 895 tests. The first run had 1 issue, fixed below, and its suite was then re-run green.
  - `check-writes.sh` and `check-release.sh` are OK. There are no new write shapes: search3 is a GET.

## Decisions
- On an exact-name tie, album beats song: "hey jude" and "hey jude wilson pickett" give his album "Hey Jude". This keeps the earlier exact-name rule.
- `CarPlayFindsAppTests.carSearchDoesNotWaitForOutsideSources` asserted the server's order ["jt-1","jt-2","other-1"] for "Judie". Ranking now puts the song titled "Judie" first. The test is about timing, so its order assertion was updated.
- Scope: the old string-only `MergedSearch(library:)` init (tests) keeps one batch, no splits and no paging. The app uses the new `MergedSearch(libraryPage:pageSize:...)`. CarPlay goes through `mergedSearch()`, so it gets ranking and splits without paging; no CarPlay files were touched.
- Offline search ranks too, through `SearchSections.library`. It does not add a song's artist or album rows (`withSongsArtist` defaults to false) and does not page.

## Concerns
- The plan says each keystroke burst stays "under 6 requests". The whole query plus 4 splits makes 5 on the first batch. Each load-more makes up to 5 per round, and up to 5 rounds when a split's filter keeps dropping everything.
- Splits find a misspelt word only next to a correct title part. A long title plus a 3-word artist ("sweet child o mine guns n roses") relies on the whole query, which works whenever the words are spelt right.
- The FakeNavidrome ordering is library order, but real Navidrome orders hits its own way. The ranker re-sorts the first batch, but later batches are only ranked among themselves.
- Y3: add `musicFolderId` to `LibraryQuery` (or at the AppModel `libraryPage` closure) and to `client.search`.

## Files
- New: Packages/MagpieKit/Sources/Search/{SearchRanker,SearchPlan,LibraryPager}.swift; App/Screens/Search/SearchPageSize.swift; Packages/MagpieKit/Tests/SearchTests/{SearchFixtures,SearchRankerTests,SearchPlanTests,LibraryPagerTests,MergedSearchPagingTests}.swift; Tests/MagpieTests/SearchLoadMoreTests.swift; Tests/MagpieUITests/SearchUITests.swift.
- Changed: Search/{SearchSections,MergedSearch}.swift; NavidromeKit/NavidromeClient.swift (search offsets); App/AppModel.swift (the `mergedSearch()` library closure only); App/Screens/Search/{SearchModel,SearchView}.swift; Tests/NavidromeKitTests/BrowseMappingTests.swift; Tests/MagpieTests/CarPlayFindsAppTests.swift (one expectation).

## Fix round 1 (review Y1-review.md: 0C/3I)

**I1: no more automatic load-more storms.**
- A split now stops when its artist filter kept nothing from a batch. The count is taken after the filter, before de-duplication. A split also stops on a short batch, as before.
- Only the whole query, and splits that actually found their artist, keep paging.
- A load-more is at most 2 rounds (`LibraryPager.maxRounds` = 2).
- `loadedMore` is set only when rows came. A load that brings nothing ends the section quietly.
- Loading now needs the user's own scroll:
  - `SearchModel.footerAppeared` / `footerDisappeared` / `userScrolled`, fed by `List.onScrollPhaseChange(.interacting)`.
  - Each load needs a fresh scroll. A footer that is on screen when results arrive, or still on screen after a batch, loads nothing by itself. The footer's per-count identity was removed.
  - The list always bounces, so a pull at the end of a short list counts as a scroll.
- Tests:
  - `splitsWhoseFilterKeptNothingStop`: "hey jude beatles" against 123 songs gives 3 matches, `!hasMore` for every section, and exactly 5 requests.
  - `aLoadMoreIsAtMostTwoRounds`.
  - `splitQueriesPage`: a split that kept nothing no longer pages.
  - App `footersLoadOnlyAfterTheUserScrolls`: no scroll means no request; one scroll means one batch; scrolling elsewhere loads nothing.
  - The UI load-more test now asserts nothing loads before a scroll, and dismisses the keyboard before swiping. The keyboard was swallowing the swipes; the old test had passed only because footers loaded on their own.

**I2: an exact-name artist beats their self-titled album again.**
- The artist field counts towards "matched in full" only when a query word went to it.
- An album Top result matched by name + artist now also brings its artist row (plan item 1.3 extended).
- Tests:
  - "weezer" and "metallica" (including a song titled "Metallica") give the artist.
  - "hey jude" still gives the album.
  - "hey jude beatles" with a Beatles "Hey Jude" album gives the album: a deliberate tie, album before song. The Beatles appear as an artist row.
  - The 40-row table is unchanged and green.

**I3: separate deadlines.**
- `LibraryPager.first(_:deadline:sleep:)` gives each request its own deadline: the phone's 3 s, or 60 s in the car.
- The paged MergedSearch no longer puts one deadline round the whole plan.
- A split that runs out of time fails on its own. Only the whole query timing out, with nothing from the splits, is an error.
- Tests:
  - `aSlowSplitNeverHidesTheWholeQuery` (virtual clock): the split "hey" never answers, and the whole query's rows plus the Top result show after one deadline.
  - `aSlowWholeQueryStillTimesOut`.
- Note: a slow request that started in the second wave of 3 can stretch the first answer to about 2 deadlines in the worst case.

**Minors**
- M1 done: split artist filters allow near-misses only on words of 6 letters or more (`nameMatches(strict:)`), so "love" no longer keeps "Live" and "hate" no longer keeps "Kate Bush". "beatels" and "cartografers" still match.
- M3 done: en and em dashes need spaces around them to split a query, so "a–ha take on me" stays whole.
- M5 checked: CarPlay album rows show no song count (only playlist rows do).
- M2 not done: adding word splits after " by " contradicts the plan's "no guessing" for separators.
- M4, M6, M7 noted; no change.

**RED, then GREEN**
- Package RED: 9 issues (maxRounds, loadedMore, weezer/metallica, album-top artist row, `SearchTimedOut` caught for the slow split, split paging, short sections). M3 RED: 2 issues.
- App RED: `value of type 'SearchModel' has no member 'footerAppeared' / 'userScrolled'`.
- GREEN:
  - SearchTests: 99 passed. HostileDataTests and NavidromeKitTests also passed.
  - Affected app suites: 31 passed.
  - UI tests on the dev stack passed: SearchUITests (both) and BrowseFlowTests' two search tests.
  - The full app suite, run once: 896 tests passed.
  - check-writes and check-release OK.

## Fix round 2 (coordinator: the first answer never waits on the splits)

- **Early rows:** `LibraryPager.first(onWhole:)` hands over the whole query's rows the moment they arrive. MergedSearch passes them to `libraryFirst`, so the phone shows them while the splits are still out. Once the splits land, `libraryFirst` gets the full library rows (still ahead of the outside sources), and then the final result follows.
- **No jumps:**
  - Result rows report when they appear and disappear (`SearchModel.rowAppeared` / `rowDisappeared`; no gestures on the rows).
  - When late rows land (`SearchModel.stabilised`), every row above the first one on screen keeps its place in its section, as does the Top result if it is above the screen. The rest take the new order.
  - At the top of the list, the new order applies in full.
- **Merge:** merged v0.0.1-custom (Y2 CarPlay, Y3 library scoping). One conflict, in `NavidromeClient.search`, was resolved by keeping the offsets and adding Y3's `folderItem`.
- **Tests:**
  - RED for `aSlowSplitDoesntDelayTheFirstResults`: no early rows while a split was out. RED for the app: `no member 'rowAppeared'`.
  - GREEN:
    - Package: SearchTests 100, NavidromeKit 113 and HostileData 22 passed, plus 21 tests in the suites matched by "CarPlay".
    - App: `lateRowsNeverMoveRowsAboveTheVisibleArea` and `lateRowsReRankFullyAtTheTop` pass.
    - Full app suite after the merge, run once: 937 tests passed.
    - check-writes OK.
