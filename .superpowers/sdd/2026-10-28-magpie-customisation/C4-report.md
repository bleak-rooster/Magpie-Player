# C4 report: Home's recommended pictures, Genres sort and filter (round 15)

Branch `c4-home-genres` from `v0.0.1-custom` (4bba6a5). Decisions D140–D145 in `docs/decisions.md`.

## 1. Home › Recommended: the artist circles had no pictures (D140)

**Root cause.** `OutsideTile` (HomeSections.swift) asked for a picture only when the tile carried `artworkKey`. Aurral's
recommendations rarely name one, so the D123 fallback inside `HomeAurralShelves.artwork(for:)` was never reached.
Library › Recommended uses `AurralArt`, which falls back to the artist page's picture without that guard.

**Fix.** One shared helper, `AppModel.recommendedArtistPicture(_:artist:side:show:)`, holds AurralArt's chain: the
phone's copy, then the picture the server named (through the image proxy), then the artist page's picture
(`recommendedArt`). `AurralArt` and Home's artist tiles (`AppModel.homeTilePicture`) both call it. While drawing, the
tile reads only memory (`recommendedArt.peek`). `HomeOutsideItem.artistMBID` gives an MBID only for an artist tile whose
key is an MBID; a `name:…` key (from `RecommendedRails.key`) is never looked up. Home's prefetch (`prefetchHomeArtists`)
already covered all five rails and is unchanged. The HomeSections.swift edit is the picture change only, plus a
test-only marker (`home-artist-art-<key>`).

**Tests.**
- Hosted (`OutsideArtAppTests`):
  - `c4HomeRecommendedCircleWithoutAServerPictureShowsTheArtistPagesPicture`
  - `c4HomeRecommendedCircleShowsThePhonesCopyFirst`
  - `c4HomeTileWithoutAnMBIDAsksNothing`
- RED: the first two failed against build 15's behaviour, which I extracted unchanged into `homeTilePicture` first. The
  third passed then, as expected, since it is a guard.
- GREEN: the whole `OutsideArtAppTests` suite passes.
- Release UI (`C4HomeGenresUITests.testHomeRecommendedCircleShowsAPicture`): Home › Recommended chip, and Stub Arrows'
  circle must show `artwork-loaded`.
  - The localhost stack has no public picture host for Lidarr's artist pictures (and the dev Lidarr is empty).
  - So the test launches with `-MagpieUITesting YES -MagpieUITestArtistPicture <MBID>`. That puts a plain picture in the
    app's outside-art folder (`ArtworkTestMarker.seedArtistPicture`, UI-test launch arguments only).
- **RED in Release** with build 15's tile restored: the circle stayed "placeholder". **GREEN** with the fix.

## 2. Genres: albums can be sorted and filtered (D141–D145)

**What was there.**
- A genre page read one `getAlbumList2 byGenre` page of up to 500 albums.
- A group page read up to 500 from each of its genres (thousands in memory for Rock), merged in genre order.
- There was no sort and no filter.

**Design.** The owner delegated it; it is recorded in D141–D145.
- **Sort**, a chip menu: Name, Artist, Newest, Oldest, Recently added, Most played, Random. The last sort is kept per
  kind of page (`GenrePreferences.groupSort` / `genreSort`).
- **Filters:**
  - a group's sub-genres as chips with counts (the 12 biggest, then More genres);
  - Decade (a menu of the decades the page spans);
  - album or artist (the page's search field, debounced);
  - Favourites;
  - Downloaded.
  - Clear sits next to the sort while any filter is on; the count line shows what is left.
- **Paging:** Navidrome's native `/api/album` sorts and filters on the server, 100 albums at a time
  (`GenreAlbumPager`, MagpieCore; `NavidromeClient.albumsPage` / `genreIds`).
- **Verified on the dev Navidrome 0.64.2:**
  - every sort key;
  - repeated `genre_id` means "any of";
  - `name` is a full-text match on album and artist;
  - `starred=true` and `missing=false` work;
  - `random` with a `seed` keeps its order from page to page.
- **Decade:** Navidrome has exact-year filtering only (`min_year`/`max_year` are exact-match; a repeated `year` gives a
  500). So a decade is a window of the year-ordered list, found by binary search.
  - A window of up to 1,000 albums is read whole and sorted on the phone.
  - A larger one is paged in year order, and the page says so.
- **Fallbacks:**
  - No native list (an unsupported 4xx, or an answer that isn't the API): the old Subsonic list (at most 500 a genre),
    sorted and filtered on the phone.
  - Offline, or Downloaded only: the downloaded albums, sorted on the phone.
- **Model change:** `Album.playCount` was added (optional, mapped from both APIs) for Most played on the phone.
- **CarPlay:** out of scope and unchanged. Its genre lists have no room for a sort and filter row.

**Found on the way.** On the dev stack, "The Cat Is Out" (Samples library) is flagged `missing`. Without `missing=false`
the count said 2 albums while 1 showed. The server now leaves missing albums out.

**Tests.**
- Package, `NavidromeKitTests/GenreAlbumPageTests` (6): the query for each sort, the filters, row mapping (cover id
  `al-<id>_<imageHash>`, release group, plays, compilation), the total without the count header, genre ids, a 404.
  - RED: did not compile (no `albumsPage`). GREEN.
- Package, `MagpieCoreTests/GenreAlbumsTests` (11): paging never holds the group, a short list is one page, the sorts on
  the phone, the phone's filter, the filter rules and decades, the decade window and its seeks, an empty decade, a huge
  decade in year order, the year span skipping unknown years, repeats dropped, the kept sort (including old and unknown
  stored values).
  - Written right after the pager, not before it: there is no separate RED run for these (two test-side expectation
    slips were fixed).
- Hosted, `GenresAppTests` (the 15 existing tests plus 4 new `c4…` tests): server pages with sort and filters in the
  query, paging, the kept sort per kind of page across a relaunch, the Subsonic fallback on a 404, and offline /
  Downloaded only sending nothing.
  - Written after the browser code; no separate RED run.
- Release UI, `C4HomeGenresUITests.testGenreGroupSortAndSubGenreFilter` (Library › Genres › Electronic):
  - Name order is Continuum, Late Night Finds, Lowlands.
  - Oldest gives Lowlands, Continuum, Late Night Finds.
  - The Electronic chip leaves Late Night Finds only.
  - Clear brings all three back in Oldest order.
  - The test then puts Name back. **GREEN.**

## Runs

- `swift test --filter "GenreAlbumPageTests|GenreAlbumsTests|Preferences"`, plus NavidromeKitTests and
  HostileDataTests: all pass.
- Hosted `GenresAppTests` and `OutsideArtAppTests`: 43/43 pass.
- Release UI, `-scheme MagpieUIOnly -configuration Release`, both `C4HomeGenresUITests` tests: 2/2 pass.
  - Run on my own simulator "Magpie Tests C4" (iPhone 18 Pro, iOS 27.0, never signed in to real servers), because
    another workstream's UI run was holding "Magpie Tests".
  - The stub Aurral ran on its own port, 3914, so the shared 3901 stub was never restarted.
- `scripts/check-writes.sh`: OK. `scripts/check-release.sh`: OK. No full suite run.

## Not done / notes

- CarPlay's genre lists have no sort or filter (D141).
- I didn't touch Trending, chart flows, `OutsideSongMenu`, Try or Add.
- Nothing on the dev stack has a decade window big enough to page; that case is covered only by the package tests.
- The "Magpie Tests C4" simulator is still there; delete it with `xcrun simctl delete "Magpie Tests C4"` if it isn't
  wanted.
