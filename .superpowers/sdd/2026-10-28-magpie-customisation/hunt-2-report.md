# Hunt 2: downloads, storage and offline

Branch `worktree-agent-a2c5bed2fd02d1a76`, based on 7f93d25 (TestFlight 0.0.1 build 9). Simulator "Magpie Hunt 2" (iPhone 17 Pro, iOS 27.0), deleted at the end. No server was contacted: fakes and stubs only.

Area covered: AudioStore, DownloadManager (+Removal), the pre-download plan, cache upkeep, the scrobble queue file, the preferences store, the offline catalog and protected-data handling.

## What was swept (all seeded and deterministic; each test runs in under 5 s)

Package, in `Packages/MagpieKit/Tests/PlaybackTests/StoreFuzzTests.swift`:

| Test | Cases |
|---|---|
| `damagedFilesNeverTrapNorLoseDownloads` | 60 seeded stores, 6 songs and a playlist each, with about a third of the files damaged: emptied, truncated, random bytes, hostile JSON numbers (`Int64.max`, `.min`, `-1`, `1<<62`), empty reasons, wrong kinds, 10k-deep nesting, deleted, a directory in place of the file, a dangling symlink, or a symlink outside the store. Also AtomicFile temp leftovers (kill mid-write) and an injected reader that fails about 1 file in 5 with EPERM, EACCES, EIO or ENOSPC, with protected data available or not. Then evict, promote and add (limits 0, 1, nil, `Int64.max`), markPlayed and removeCache, and a clean reload. |
| `hugeClaimedSizesDoNotOverflow`, `hugeIndexSizesBeforeFirstUnlockDoNotOverflow` | Directed overflow cases. |
| `downloadWithNoReasonDecodesAsUnknown` | Directed case: a download decoded with no reason. |
| `writeFailuresNeverTrapNorLoseDownloads` | 30 seeds × 12 operations against a read-only store directory: every write fails. |
| `directoryReplacedByFileOrSymlink` | 3 variants: a file, a dangling symlink, or a symlink to a file. |
| `concurrencyStorm` | 15 seeds × 120 concurrent add, promote, removeReason, evict, removeCache, markPlayed, replace, removeAll, eraseScope and load calls. Afterwards, a reload must agree with memory. |
| `quotaEdges` | 6 limits (0, 1, 999, 5000, `.max-1`, `.max`) × 30 add and promote rounds. Downloads never exceed the limit. |
| `scrobbleQueueFileFuzz` | 80 queue files (corrupt, truncated, empty, 1500 entries), with the first 0 to 3 reads failing. An unread file is never written. The 500 limit holds. |
| `preferencesDecodeFuzz` | 750 hostile stored areas across all 5 preference areas. Decoding never traps, is always normalised and round-trips. |
| `offlineCatalogFuzz` | 300 catalogs: NaN, ±infinity and 1e300 durations, `Int.min`/`.max` track and disc numbers, empty, combining and 300-character names, duplicate ids. |
| `preDownloadPlanFuzz` | 1000 plans, with counts including `Int.min`, `Int.max`, 0 and negatives. |

App, in `Tests/MagpieTests/Hunt2DownloadTests.swift`:

- `seededStorms`: 60 seeds × 80 steps (4,800 steps), each seed with a random concurrency and limit (nil, 0, 2,500, 6,000 or `.max`). The steps mix:
  - downloads with every reason, playlist saves, covers and pre-downloads at three qualities;
  - removals by reason, by songs, by song and Remove all, plus Clear cache;
  - retries, Wi-Fi, cellular and no-network flips, offline toggles, re-downloads, `serverAnswered`, `dropBadFile`, `cancelAll`, and relaunches on the same store.

  After every step, no download is left without a reason and downloads stay within the limit. At the end, no download the user didn't remove has gone, and nothing is left running.
- `unreadablePendingIsNeverWrittenOver`, `removalWhileUnreadHoldsAfterTheMerge`, `listenDurationNeverTraps`.

Thread Sanitizer: `swift test --sanitize=thread` ran over PlaybackTests, MagpieCoreTests and SubmitListensTests (146 tests, including the concurrency storm), both before and after the fixes. **No races reported (0 warnings).**

## Crashes and invariant breaks found

### 1. Arithmetic-overflow trap in `AudioStore.usage()` (crash)
- **Where:** `Packages/MagpieKit/Sources/Playback/Storage/AudioStore.swift:139` (`usage.downloadBytes += entry.size`); the same pattern was in `checkLimit` at :403 and `evictCache` at :344. lldb: "Swift runtime failure: arithmetic overflow" in `AudioStore.usage()` at AudioStore.swift:139.
- **Root cause:** reconcile only re-sizes an entry from its file when the file can be sized. Before first unlock the store serves the index as read, unchecked. When a directory stands where the audio should be, the sidecar's size stands too. A damaged record claiming `Int64.max` therefore reached a trapping sum. Settings' storage line calls `usage()`.
- **Fix:** `AudioStore.sum`: negative sizes count as 0 and a sum that would overflow saturates at `Int64.max`, which is over any real limit. `evictCache` subtracts clamped sizes.
- **Tests:** `hugeIndexSizesBeforeFirstUnlockDoNotOverflow` and `hugeClaimedSizesDoNotOverflow`. Both trapped with signal 5 before the fix and pass after it.
- **Commit:** c168b48

### 2. A download kept with no reason (orphan; the user can't remove it)
- **Where:** the tolerant decoder in `Packages/MagpieKit/Sources/Playback/Storage/AudioEntry.swift:102-103`.
- **Root cause:** `reasons: []` with `kind: download` (or a cache record whose kind was damaged to download) decoded to a download with an empty reason set. `removeReason` can never match it, and "Remove from this phone" finds no reason to drop, so only Remove all could clear it.
- **Fix:** a download decoded with no reason gets `.unknown`, as a missing list already did.
- **Tests:** found by `damagedFilesNeverTrapNorLoseDownloads` (10 failures before the fix). `downloadWithNoReasonDecodesAsUnknown` was RED without the fix and is GREEN with it.
- **Commit:** c168b48

### 3. An unread `pending.json` was written over or removed (data loss; breaks "nothing is written to an unread file")
- **Where:** `App/Downloads/DownloadManager.swift:155`, in `start()`: `try? AtomicFile.read(...)`.
- **Root cause:** a file that exists but can't be read yet (protected data before first unlock, or EIO) looked the same as no file. The next `savePending()` replaced it with only the in-memory jobs, or removed it when they were none. The queued manual downloads were lost.
- **Fix:**
  - `loadPending()` tells a failed read apart from a failed decode.
  - While the file is unread (`pendingUnread`), `savePending` reads it again first and never writes or removes it.
  - `resumeStoreWork` (on unlock, or on the store retry) triggers the read.
  - Once it reads, its jobs join the ones asked for meanwhile, minus those a removal took in between (`removalsWhileUnread`).
  - Remove all and sign-out (`cancelAll`) still discard it.
- **Tests:** `unreadablePendingIsNeverWrittenOver` was RED (s1 and s2 lost) and is now GREEN. `removalWhileUnreadHoldsAfterTheMerge` was RED and is now GREEN.
- **Commit:** f8d696d

### 4. Trap replaying a queued play with an out-of-range time (crash)
- **Where:**
  - `Packages/MagpieKit/Sources/NavidromeKit/NavidromeClient.swift:308`: `Int64(at.timeIntervalSince1970 * 1000)`;
  - `Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift:64`: `Int(at.timeIntervalSince1970)`.
- **Root cause:** queued plays come back from `scrobble-queue.json` with whatever `Date` the file holds. 1e300, ±infinity or NaN trap: "Double value cannot be converted to Int64 because the result would be greater than Int64.max".
- **Fix:** a time out of range is left out. Navidrome then uses "now"; ListenBrainz refuses the listen.
- **Tests:** `BrowseMappingTests.scrobbleTimeOutOfRangeSendsNoTime` and `SubmitListensTests.listenedAtOutOfRangeIsLeftOut`. Both trapped before the fix and pass after it.
- **Commit:** a24c097

### 5. Trap building a listen with an out-of-range duration (crash)
- **Where:** `App/Playback/ScrobbleRouter.swift:316`: `Int(song.duration * 1000)`, guarded only by `> 0`.
- **Root cause:** an infinite or huge duration (from a damaged queue snapshot, or a server's float `duration`) traps.
- **Fix:** no duration is sent unless it is between 0 and 1e12 seconds.
- **Test:** `Hunt2DownloadTests.listenDurationNeverTraps`. This is the same trap class as #4, whose package tests were confirmed RED. This app test was run only after the fix and passes.
- **Commit:** d0b764f

### 6. A re-download could take downloads past their limit (quota invariant)
- **Where:** `Packages/MagpieKit/Sources/Playback/Storage/AudioStore.swift`, in `replace(songId:with:quality:fileExtension:)` (line 193 at base): there was no limit check.
- **How found:** `Hunt2DownloadTests.seededStorms`, seed 35 step 39, failed only under full-suite load, because the timing decided which fetch size the re-download got. "Re-download in this format" to a bigger file pushed `usage().downloadBytes` over the limit.
- **Root cause:** `add` and `promote` check the limit, but `replace` swapped in a file of any size. (`addReason` doesn't check either, but nothing calls it.)
- **Fix:** a download's bigger new file must fit the limit in place of the old one. Otherwise `downloadsFull` is thrown before anything changes on disk, the old file stays, and DownloadManager stops the job like any full download. DownloadManager now passes `limitBytes(prefs)`. A cached song's re-download isn't held to the downloads limit.
- **Test:** `StoreFuzzTests.redownloadRespectsTheLimit` was RED (3 issues: 1,500 bytes against a 1,000 limit) and is now GREEN.
- **Commit:** 1343687

## Suspected issues not fixed (no crash reproduced, or outside this area)
- **Store directory replaced by a file** (or a dangling symlink): no trap. The store stays read-only (`notReady`) indefinitely, so downloads show "Downloading" and never move until sign-out erases the scope. This is a product decision, not a crash.
- **ScrobbleQueue:** a file that reads but doesn't decode counts as empty and is overwritten by the next play. This is documented behaviour; only an *unreadable* file is protected, and the fuzz confirms that.
- **Outside this area (same `Int(Double)` class, not reproduced here):**
  - `App/AppModel+BringInMore.swift:32` guards `isFinite` but not size, so `Int((1e300/3600).rounded())` would trap;
  - `App/Screens/Finds/FindsShelf.swift:71` would trap on a far-off `created` date.

  These are worth a look by the owning hunter.
- On macOS, `AtomicFile` can't replace a mode-000 file (the write fails and is logged). On iOS a protected file can still be replaced, which is why fix #3 is needed on the device.

## Final runs
- Package (`swift test`, after every fix): 652 tests, all passed.
- App tests on "Magpie Hunt 2" (scripts/test-app.sh logic, own UDID and DerivedData, no `MAGPIE_IT`), run after fix #6: **TEST SUCCEEDED**. 694 tests: 680 passed, 14 skipped (they need the dev stack), 0 failed. The run before fix #6 failed only `seededStorms` (finding #6).
- TSan: 0 warnings, before and after the fixes.

## Commits
- c168b48 Hunt 2: store sizes can't overflow; a download never decodes with no reason
- a24c097 Hunt 2: a queued play's time out of range sends no time instead of trapping
- f8d696d Hunt 2: an unread pending.json is never written over
- d0b764f Hunt 2: a listen's duration out of range sends no duration instead of trapping
- ee23d64 Hunt 2: fuzz the stored preference areas
- 1343687 Hunt 2: a re-download that would go past the downloads limit is refused
