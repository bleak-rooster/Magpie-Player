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
