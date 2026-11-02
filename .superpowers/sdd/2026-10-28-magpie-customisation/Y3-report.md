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
