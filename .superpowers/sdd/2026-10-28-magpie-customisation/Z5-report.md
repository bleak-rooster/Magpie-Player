# Z5 report: round 13 items 7 and 8 (cache quality, source line)

Branch `z5-playback`, off v0.0.1-custom, with the latest v0.0.1-custom merged in (Z4 and Z6 included; the decisions.md conflict was resolved by keeping Z4's D63). Commits are prefixed "Z5:".

## What was built

### Item 7: replace a cached copy that isn't at the right quality (D64)
- **`AudioStore.replaceCache(songId:from:with:quality:fileExtension:)`** (MagpieKit/Playback). Inside the actor, in one step, it replaces an entry only when it is still a *cache* entry at `from` and `from != quality`. Otherwise it returns nil and discards the incoming file: a download (or a cached song promoted meanwhile), an entry whose quality changed, or one that was evicted. It goes through `replace`, which stores the new file first and deletes the old one after. An extension off the allowlist throws `invalidFile`.
- **`App/Downloads/DownloadManager+CacheQuality.swift`** (new).
  - `refreshCacheQuality(songId:target:)` starts one background fetch. It uses the foreground fetcher, with `allowsCellular = overMobileData`.
  - It fetches only when all of these hold:
    - the song is stored as `.cache` at a quality other than `target`;
    - `manualAllowed` holds (not offline, and not on mobile data with "Download on mobile data" off);
    - downloads aren't paused or held in the background;
    - no job for the song is running;
    - no other replacement is fetching or held;
    - `songId|target` hasn't been tried this session.
  - **Verification** before anything changes:
    - the response is audio;
    - it is in an allowed format (`AudioStore.fileExtension`);
    - it is moved into the temp folder `MagpieCacheSwap/` with its extension, and `isPlayableFile` (AVFoundation, injectable) accepts it.
  - **Never mid-song.** The verified copy is held while `isSongInUse` says playback holds the song (`player.windowSongIds`: the current song plus the engine's window). `applyCacheSwap(target:)` swaps it in on the next queue change. A held copy for a target that is no longer current is dropped.
  - **Stopping.**
    - `cacheTargetChanged(_:)` stops a fetch for another target, and drops a held copy for one.
    - `networkChanged()` stops a fetch the network no longer allows.
    - `clearCache()` and `cancelAll()` drop both.
  - **Retries.** A failed or unusable replacement isn't retried for the same song and target this session, so there's no loop on a song the server can't convert. A fetch that was only stopped may go again.
- **Wiring.** `App/AppModel+CacheQuality.swift` (new), plus one-line hooks:
  - `queueChanged` (PreDownload) applies a held swap, and checks the song that just started against `currentStreamQuality`;
  - the network quality watch and `preferencesDidChange` call `cacheQualityTargetChanged()`, which also re-checks the playing song;
  - `startDownloads` sets `isSongInUse`.
- **Opened for the extension**, marked `(+CacheQuality)` as the file already does for `+Removal`:
  - `fetcher`, `streamURL`, `isLive`, `manualAllowed`;
  - `track`, which now returns its task key;
  - `activeRuns`, read only.
- **Added to `DownloadManager`:** `kind(of:)`, and the stored `cacheRefresh` and `isSongInUse`.

### Item 8: where the song comes from (D65)
- `SongInfo.Source` is now `.downloaded(q)`, `.cached(q)` or `.stream(q)`. It also has `quality`, and `place`: "Downloaded", "From cache" or "Streaming".
- `HearingLabel` puts the place in front of Y3's text, for example:
  - "Streaming · Transcoded · Opus 160 kbps (from FLAC)";
  - "Downloaded · Lossless · FLAC 16/44.1".
- A converted copy on the phone now also says "Transcoded".
- With nothing known about the file, the line is the place alone.
- `playingSource` tells a download from a cached copy via `kind(of:)`.
- Song info's "Playing" row is the same `HearingLabel` text, from `playingSource`. Its old store lookup and `SongInfo.playing` were removed.

## Tests (RED → GREEN)
- **PKG `CacheQualityStoreTests`, 4 tests.**
  - RED: `value of type 'AudioStore' has no member 'replaceCache'`.
  - GREEN: 4 of 4 pass.
- **APP `CacheQualityTests`, 15 tests.**
  - RED: compile errors (`no member 'refreshCacheQuality'`, `'applyCacheSwap'`, `'cacheTargetChanged'`, `'isSongInUse'`).
  - GREEN: 15 of 15 pass.
  - They cover:
    - a mismatch is fetched again and replaced, and the old file goes;
    - a match fetches nothing;
    - a download is never replaced;
    - a song downloaded meanwhile is kept;
    - mobile data with mobile downloads off fetches nothing, and with them on it fetches;
    - offline fetches nothing;
    - a network change stops the fetch;
    - a target change stops the fetch;
    - the swap waits until the song is no longer playing;
    - a held copy for an old target is dropped;
    - one replacement at a time;
    - an unplayable or non-audio copy never replaces the old one;
    - a failed replacement isn't retried this session;
    - Clear cache drops a held copy.
- **APP `CacheQualityAppTests`, 4 tests.**
  - RED: the two positive tests failed (`pendingCacheSwapSongId == "s1"` was never true, and `rawFetches == 0`).
  - GREEN: 4 of 4 pass.
  - They cover:
    - a cached song played at the wrong quality is fetched, held while it plays, and swapped after `next()`;
    - Wi-Fi coming back while a song plays fetches the new target;
    - mobile data with mobile downloads off never fetches;
    - Streaming, From cache and Downloaded each show in Now Playing, and Song info matches.
  - The item 8 test was written after its code, so it was green on its first run. Item 8's RED came from the updated tests below.
- **Item 8, updated tests.**
  - RED: compile errors (`'SongInfo.Source' has no member 'downloaded'/'cached'`).
  - GREEN after the change.
  - Updated: `Round12HomePagesTests.hearingLabelPerSource` (each source plus cache cases), `playingSourceFollowsWhatPlays`, and `NowPlayingMoreTests` (the Song info row equals Now Playing's text).
  - `NowPlayingSmallPhoneTests` checks that the longest line fits with no page scroll view.
- **Never scrolls.** The NowPlayingSmallPhoneTests (3) and NowPlayingLyricsLayoutTests (2) suites pass.
  - `smallestPhoneFitsWithoutScrolling` used songs with no format, so it used to have no line, and it showed Up next.
  - It now always has the "Streaming" line. On 375 × 667, Up next makes way for it (D43).
  - That matches what Y3 already did for every real song, since Navidrome always sends a suffix. The test's order now drops `upNext`, with a comment.
- **Final runs.**
  - **Package suite.** Everything passed except `GenreGroupsTests.twoThousandGenresAreFast`, a 250 ms timing check that ran at 370 ms while the app suite built in parallel. Re-run alone, all 16 GenreGroupsTests pass.
  - **App unit suite (MagpieTests).** 515 of 518 pass. The 3 failures were simulator "signal kill" events: `LayoutSettleSweepTests.nowPlayingHeightsSettle` ×2 and the UI runner never connecting.
    - `LayoutSettleSweepTests` failed twice more in a row on the branch, but also once with item 8's line change reverted, so the line isn't the cause.
    - On the base (`git archive` of v0.0.1-custom) it passed.
    - Re-run on the branch, it passes 2 of 2. It is environmental: other workstreams' simulators were busy at the same time.
  - **UI target (MagpieUITests), re-run alone.** 1 passed and 28 skipped; they need MAGPIE_IT, which wasn't run here.
  - **Checks.** `check-writes.sh` is green and `check-release.sh` says OK. No new Lidarr write shapes.

## Files
- New:
  - Packages/MagpieKit/Tests/PlaybackTests/CacheQualityStoreTests.swift
  - App/Downloads/DownloadManager+CacheQuality.swift
  - App/AppModel+CacheQuality.swift
  - Tests/MagpieTests/CacheQualityTests.swift
  - Tests/MagpieTests/CacheQualityAppTests.swift
- Changed:
  - Packages/MagpieKit/Sources/Playback/Storage/AudioStore.swift
  - App/Downloads/DownloadManager.swift, App/Downloads/DownloadManager+Removal.swift
  - App/AppModel+PreDownload.swift, App/AppModel+Playback.swift, App/AppModel+Preferences.swift, App/AppModel+Downloads.swift
  - App/Screens/NowPlaying/HearingLabel.swift, App/Screens/NowPlaying/SongInfoSheet.swift
  - Tests: Round12HomePagesTests, NowPlayingMoreTests, NowPlayingSmallPhoneTests
  - docs/decisions.md (D64, D65)

## Decisions
- **D64:** the cache-quality replacement, with the rules above.
- **D65:** the source line, and Up next making way on the smallest phone.
- **Calls made within D64:**
  - "One fetch at a time" means at most one replacement fetching *or held*. There is no queue; other mismatches wait for their own next play.
  - "Respects the cellular setting" uses Downloads › "Download on mobile data" (`overMobileData`).
  - On Low Data Mode Wi-Fi the target is the mobile quality, and the fetch is allowed because the connection isn't cellular.
  - A replacement also waits while downloads are paused, or held in the background.

## Concerns
- **A small race at the swap.** The "not in use" check runs on the main actor, and the store write after it on the store actor. A song that starts in between keeps its old URL while the old file is unlinked. AVFoundation normally keeps the open file, so this is low risk.
- **The held copy lives in the temp folder.** If the app is killed it is lost, and the song is fetched again on its next play.
- **Item 8 has no UI test.** It is covered by the hosted layout tests and the model tests. The dev-stack UI tests (MAGPIE_IT) were not run here.
- **Simulator kills while other workstreams run.** Expect "signal kill before establishing connection" flakes under that load; re-run alone.

## Fix round 1 (Z5 review, 0C/1I)
- **I1.** Each replacement `Fetch` has a `token`. `isCurrentCacheRefresh` and the run's `defer` compare tokens, so a stopped fetch that unwinds late never clears a newer one.
  - Test `aStoppedFetchNeverClearsTheNextOne`: A → B → A flip, with the first fetch ignoring cancellation and the second held in its check. The second stays the one under way, a second song can't start, and the second lands.
- **Owner ruling (M4).** On mobile data (or Low Data Mode) a better cached copy is kept: `wantsReplacement(from:target:onMobile:)`. Only a lower bit rate, or a transcode when the target is the original, is replaced. On Wi-Fi the copy matches exactly.
  - Tests: `onMobileDataABetterCopyIsKept` (original, AAC 256, and same rate in another format all kept), `onMobileDataAWorseCopyIsReplaced`, `onWiFiTheTargetIsMatchedExactly`.
  - Recorded in D64.
- **M1.** `AudioStore.replaceCache` now returns a `CacheReplacement` (the entry plus the old file name). It keeps the old audio but removes the old sidecar.
  - The manager removes the old file with `removeUnreferencedAudio` only once `isSongInUse` is false, at the swap or on a later queue change.
  - After a crash, the next load sweeps the orphan.
  - Tests: `theOldFileStaysWhilePlaybackMightHoldIt`, plus the store tests `replacesACacheEntryAtTheExpectedQuality` and `anOldCopyLeftByACrashIsSweptOnLoad`.
- **M2.** The new `isConfirmedPlayable` is strict: an unreadable or empty file, or any thrown error, counts as no.
  - Test: `aCheckThatCannotConfirmKeepsTheOldCopy`.
- **M3.** `bodyFits` refuses a response whose type is another format than the transcode asked for (for example FLAC sent for an Opus request). Octet-stream passes through to the strict check. Pre-downloads are unchanged: they still store what arrives under the asked-for quality.
  - Test: `aBodyInAnotherFormatIsNotKept`.
- **M5.** Held copies now live in `<scope>/swap/`, which is emptied at `start()`.
  - Test: `heldCopiesFromALastRunAreSwept`.
- **M7.** The tautological assertion was removed.
- **Not done (optional):** M6. A fetch started before a pause runs to the end; pausing only stops new ones.
- **RED evidence.**
  - Store tests: `AudioEntry has no member 'entry'/'oldFileName'`, `no member 'removeUnreferencedAudio'`.
  - App: 8 of 23 failed, including `cacheRefreshSongId → nil` and `fetches 5 vs 4` for I1, the better copy replaced on mobile data, and the old file deleted while held.
- **GREEN.** CacheQualityStoreTests and AudioStoreTests: 34 of 34. CacheQualityTests: 23 of 23. CacheQualityAppTests: 4 of 4.
