# Y3 report: Home fixes and main-library scoping (item 5), pull to refresh (item 4), Now Playing transcoding label (item 11)

Branch `y3-home-pages`, off `v0.0.1-custom`. Commits are prefixed "Y3:".

## What was built

### Item 5: main library everywhere (Y3 owns library scoping)
- **The client.** `NavidromeClient.setLibraryScope(_:)` / `libraryScope` hold the main library. Every list and search call then carries it:
  - Subsonic `musicFolderId`: getAlbumList2 (all types, byGenre too), getSongsByGenre, getGenres, getStarred2, getArtists, search3, and the new `randomSongs(size:)` (getRandomSongs);
  - native `library_id`: the `/api/song` pages (Library › Songs and the A–Z seek) and `/api/artist` (Album artists only off).
  - Probed on the dev Navidrome 0.64.2: the filters work. getGenres and getStarred2 ignore the parameter, which does no harm.
- **Never scoped:** lookups by id, getPlaylists, the Finds library's own read, recording lookups, and the match index (`songsPage(…, wholeServer: true)`).
- **`musicFolders()` (getMusicFolders):** any account can read it, unlike `/api/library`, which needs an admin.
- **`App/AppModel+LibraryScope.swift`** works out `mainLibraryId`:
  - the R18 choice (`findsSetup.mainLibrary`), when the server still lists it and it isn't kept apart;
  - otherwise the one library left once Finds and Discover's libraries are set aside (Discover's come from the Y6 hook `discoverLibraryIds`, empty for now);
  - nil with a single library or no obvious choice, so nothing is sent.
- **When the scope is applied.** `syncLibraryScope()` runs on every session change (sign-in, reconnect, failover, so a rebuilt client is rescoped) and on every Finds setup change.
  - The folders are read through `request`: awaited at sign-in, and after a resumed launch's login. They are saved per account and cleared on sign-out. Nothing is asked offline.
  - When the scope changes, Home reads everything again silently (`HomeFeed.libraryChanged()`).
- **No caller changed.** Home, Library, Search and CarPlay all reach the server through the client. Y1's search and Y2's CarPlay calls inherit the scope without changes.

### Item 5: Home shelves
- **Playlists shelf** (`AppModel.homePlaylists`): the user's own playlists first, then most recently changed first (undated last), then by name.
  - Y6 hook: `isDiscoverPlaylist(_:)`, false for now.
- **Distinct playlist tile** (`Screens/Home/PlaylistTile.swift`): a stacked frame, a `music.note.list` badge, and "Playlist · N songs".
- **"Recently downloaded"**: the `.downloaded` section's title changes; its case name is unchanged, so saved layouts still decode.
  - `OfflineCatalog.recentlyDownloaded()` orders by `downloadedAt`, newest first.
  - A downloaded playlist is one tile and opens the phone's copy.
  - A song held only by playlists makes no partial album.
  - "See all" opens Downloads.
- **Stale-cache guard:** `HomeShelf.fits(_:in:)`. `HomeShelfCache.load` drops any saved shelf that holds a tile kind its section never shows.

### Item 4: pull to refresh (`App/AppModel+PageRefresh.swift`)
- `.refreshable` on the Artist, Album and Playlist pages. It:
  - forgets the artist's saved Popular, and the cover's palette and in-memory image;
  - asks for a quick `startScan` (`fullScan=false`);
  - reloads at once (which re-runs Popular, the Lidarr line and "Not in your library");
  - polls `getScanStatus` every 1 s for up to 20 s, then reloads again.
- **A refused scan** (an account that isn't an admin): the page reloads only, without waiting.
- **Offline:** it re-reads the phone and sends nothing.

### Item 11: what you hear (`Screens/NowPlaying/HearingLabel.swift`)
- **The line under the scrubber:**
  - "Lossless · FLAC 24/96" for a lossless original;
  - "MP3 320" for a lossy original;
  - "Transcoded · Opus 160 kbps (from FLAC)";
  - "On this iPhone · …" for stored songs.
  - A file already in the target format, at no more than the target bit rate, counts as the original.
- **Hallmark:** it follows what plays. A transcode gets none. The original, and the fallback to the original, keep it ("Lossless soon" included). The fallback hint stays.
- **Where the source comes from:** `playingSource(_:)` uses the same rule as Song info, answered at once. It reads a new `DownloadManager.localQualities` mirror.
- **The details on the label:** `Song` gained `samplingRate` and `bitDepth`. `AudioMetadata` now keeps `bitRate`, `samplingRate` and `bitDepth`, with tolerant decoding so older files still read.
- **Fit:** the line sits inside the scrubber part, so the measured layout makes room. There is still no scroll.

## Tests

**RED**
- **Package:** `swift test --filter "LibraryScopeTests|RecentDownloadsTests"` failed to compile: "no member 'setLibraryScope' / 'randomSongs' / 'musicFolders'", "extra argument 'wholeServer'".
- **App:** `Round12HomePagesTests.swift`, built against an exported copy of `v0.0.1-custom`, gave `** TEST BUILD FAILED **`: "no member 'mainLibraryId' / 'libraryScope' / 'refreshMusicFolders' / 'homePlaylists' / 'refreshPage' / 'scanWait'", "'HomeShelf' has no member 'fits'".
- **Gap:** for the app, the implementation came before this RED build, so its RED is a compile failure against base rather than a strictly test-first run.

**GREEN**
- **Package `LibraryScopeTests` (5):**
  - all 11 list calls name the main library;
  - nothing is sent when unscoped;
  - lookups, playlists and Finds are never scoped;
  - the match index stays whole-server;
  - getMusicFolders is read.
- **Package `RecentDownloadsTests` (3):** date order; playlists as themselves; ties by name.
- **App `Round12HomePagesTests` (13):**
  - R18 main-library picking;
  - Aurral and Finds albums never reach Home, Library › Albums or Search, and every list request carries `musicFolderId=1` (fake server with 3 libraries);
  - automatic pick when obvious; a single library sends nothing;
  - playlist order and the Discover hook;
  - Recently downloaded order, with the playlist as one tile;
  - the stale-cache guard;
  - refresh: scans, 3 polls, then a second reload; gives up at 20 s; a refused scan still reloads; caches cleared, and nothing sent offline;
  - the label for each source (lossless and lossy originals, transcoded, passthrough, fallback, downloaded, unknown);
  - `playingSource` follows what plays.
- **App `NowPlayingSmallPhoneTests.smallestPhoneFitsWithHearingLineHintAndError`:** fits 375 × 667 without scrolling, with the line, hint and error all showing.
- **Updated:** `OfflineAppTests`, where the car header is now "Recently downloaded".
- **Bug the suite caught:** the folder read had skipped the forced-offline guard. It now goes through `request`.

**Full runs (once, at the end)**
- `scripts/test-packages.sh`: exit 0.
- Full app suite on my own "Magpie Y3" simulator, with the app uninstalled first: `✔ Test run with 905 tests in 100 suites passed`, `** TEST SUCCEEDED **`. The UI tests ran without MAGPIE_IT, so their dev-stack tests were skipped.
- `check-writes.sh` and `check-release.sh`: OK. There are no new write shapes (all new calls are GETs).

## Decisions
- **Scope on the client, not per caller.** It covers every current and future list call, and none of Y1's or Y2's files are touched.
- **The match index stays whole-server.** It decides "already yours" for outside results; scoping it belongs with Y5 and Y6.
- **Downloaded playlists reuse `HomeShelf.Item.playlist`.** No new case, so the CarPlay adapter (Y2's file) needed no change.
- **The shelf is now titled "Recently downloaded"** on the phone and in the car.
- **The refresh spinner stays up while the scan runs** (at most 20 s). The page reloads once before the wait.
- **Refresh clears the in-memory artwork only.** The disk copy stays; Reload artwork is the way to fetch it again.

## Concerns
- **The owner's server has three libraries:** Music (1), Aurral (2) and Finds (3). Until the owner picks "Main library" in Settings, or Y6 fills `discoverLibraryIds`, no main library is obvious and nothing is scoped. Settings already prompts for the pick.
- **Aurral flows still show under Playlists.** getPlaylists can't be filtered by library, so they stay there until Y6's `isDiscoverPlaylist`.
- **Library › Songs labels lack "24/96".** Songs read from the native API carry no sample rate or bit depth, so the line shows "Lossless · FLAC".
- **"Transcoded" is inferred.** It comes from the quality settings plus the passthrough rule (the same approach as Song info), not from what the server reports.

## Fix round 1 (review Y3-review.md: 0C/2I)

The first round's Concerns about the unscoped owner layout, the missing "24/96" in Library › Songs and the inferred "Transcoded" are resolved by I1 and minors 5 and 6 below.

### Important
- **I1: the main library is picked without the owner** (`AppModel+LibraryScope.swift`, `autoPickMainLibrary`). It runs after the folders are read, but only when more than one library is left besides the separate ones and none is chosen.
  - It picks the Navidrome library that holds Lidarr's main root folder (`lidarrSetup.rootFolderPath`), mapped through the Finds `PathMapping` with the existing `keptLocation` (`libraryHolding(root:)`).
  - With no Lidarr main root, it picks the library with the most albums (new `NavidromeClient.albumCount(inLibrary:)`), leaving Finds out. A tie means no pick.
  - It never goes by a library's name.
  - The pick is saved to `findsSetup.mainLibrary`, so Settings shows it and the owner can change it. It is also saved per account as `magpie.autoMainLibrary.<scope>`, which also covers the case with no Finds setup.
  - `mainLibraryPickedAutomatically` is there for a Settings note. Choosing a library by hand clears the auto pick.
- **I2: the car's Recently downloaded playlists open the phone's copy.** One `where section == .downloaded` case in `CarPlayRows.homeRow` (`CustomisationRows.swift`, Y2's file) gives `.open(.downloadedPlaylist(id:title:))`.

### Minors
- **Refresh:**
  - it asks `getScanStatus` first; while a scan is running it reloads once and never starts a second scan or waits;
  - the quick scan targets the main library and Finds (`"1:"`, `"3:"`) once they are known;
  - the second reload happens only after a scan that started and finished.
- **Match index:** it reads `.only([main, finds])` explicitly (new `NavidromeClient.LibraryFilter`; Navidrome reads a repeated `library_id` as "any of", probed on dev). It reads every library while no main library is known. `MatchIndexStore.refresh(using:)` passes `.all` instead of relying on the scoped default.
- **Favourites:** when scoped, `starred()` keeps only the songs, albums and artists that the native API lists as `starred=true` in the main library. getStarred2 ignores `musicFolderId`, which is why this filter is needed.
- **Label:** `playingSource` reads the playing entry's own URL (new `Player.currentURL`):
  - a file means on the phone;
  - otherwise the `format` and `maxBitRate` of the stream it plays.
  - It falls back to the setting only before anything has loaded.
- **Sample rate and bit depth:** native `/api/song` rows now map `sampleRate` and `bitDepth`.
- **Finds library:** `rememberFindsLibrary` rescopes when it first learns the Finds library.
- **Sign-in folder read:** I tried making it non-blocking (review minor 9), but `SecurityAppTests.plainHTTPLidarrNeedsConsent` caught a background request interleaving with the caller's next step. The read is awaited again.

### Tests
- **RED:**
  - Package: compile errors, "no member 'albumCount'", "extra argument 'libraries'".
  - App: after stubbing the two new properties, 10 tests failed (`mainLibraryIsTheOneHoldingLidarrsRootFolder`, `mainLibraryPickNeverGoesByName`, `withoutLidarrTheLibraryWithMostAlbums`, `carRecentlyDownloadedPlaylistOpensThePhonesCopy`, `refreshDuringARunningScanJustReloads`, `refreshScansTheMainLibraryAndFinds`, `matchIndexCoversMainAndFinds`, `hearingFollowsThePlayingStreamNotTheSetting`, and the two existing refresh tests whose scripted scan answers changed).
- **GREEN:**
  - `LibraryScopeTests`: 8 tests.
  - `Round12HomePagesTests`: 21 tests. The owner's shape is covered: Music Library /music, Aurral Playlists /aurral, Finds /finds, with Lidarr root /music → library 1, and with the names swapped → still 1.
  - Not added: an offline car test that opens a downloaded playlist end to end. Only the row action is tested.
- **Full runs:**
  - `scripts/test-packages.sh`: exit 0.
  - `check-writes.sh` and `check-release.sh`: OK.
  - App suite, first run: 912/913; the one failure was the race above. Rerun after the fix: see the line below.
  - App suite, rerun after the fix: `✔ Test run with 913 tests in 100 suites passed`, `** TEST SUCCEEDED **`.
