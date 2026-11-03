# Z4 report: round 13 item 6, Downloads in Lidarr can restart anything

Branch `z4-restart-any`, cut from v0.0.1-custom (47f8f4f) with the latest v0.0.1-custom merged in (f1c1a38; the only incoming change was the plan doc).

## Commits
- 92656e9: gate. `queueRestartAny` now refuses only importing or imported rows. A new `allowForeign` flag, set only by the flagged confirmation, lets a download Lidarr never grabbed through. The search that follows is still limited to the albums its rows name.
- 3ee6dd0: board and restarter can restart anything. A new `Ask` on each row; Restart all now includes couldn't-import copies; `includeForeign` adds another app's; check-writes pins the new flags, and the selftest has 4 new plants.
- c91f33c: screen and copy, plus D63.
- f1c1a38: merge of v0.0.1-custom.
- A final commit adds this report.

## What was built
**Gate** (`LidarrWriteGate.send(_:_:body:confinedAs:allowForeign:)` and `WriteConfinement.queueRestartAny`):
- Unchanged:
  - the exact query;
  - its own fresh read of the whole queue;
  - refuses a row that is gone or has no download id;
  - refuses a row that is importing, imported or complete, or whose download is shared with one that is.
- Changed: queued, paused, delayed and unreachable copies are no longer refused. This supersedes fix round 1 C1's second layer, at the owner's "restart anything".
- Without `allowForeign`, the grab check stands: the "wasn't grabbed" message, then the history read fresh. An unreadable history leaves the write unconfirmed.
- With `allowForeign`, the grab check is skipped.
- The flag is refused with any shape other than `queueRestartAny`.
- `restartSearch` is unchanged: only albums the removed download's rows named, within 10 minutes.

**Board** (`LidarrDownloads`):
- Each row now has:
  - `foreign`;
  - `underlying` (what the row is, whoever started it; never `.notStarted`);
  - `ask`: none, stillGoing, couldntImport or foreign.
- `canRestart` is true when all of these hold:
  - the download has an id;
  - nothing in the download is importing or done;
  - the grab status is known.
- `restartable` is stalled, failed and couldn't-import rows that Lidarr grabbed. `restartableForeign` is another app's rows in those states.
- `attention` is unchanged.
- `GrabCache` now also looks up rows that are still going, after the stuck ones, still at most 10 per refresh.
- The stall clock (`QueueStallWatch`) now follows another app's downloading copies too.

**Restarter** (`LidarrDownloadRestarter`):
- `restart(row, allowForeign:)` and `restartAll(rows, includeForeign:)`.
- Whose download it is gets re-read fresh. A foreign download without the flag gets `.notStartedByLidarr`.
- A foreign download is removed directly, never through the runner's `removeCounting`, so it is never counted against a request's five removals.
- Restart all skips rows that are still going.

**Screen** (`LidarrDownloadsView`):
- Every restartable row has Restart:
  - stalled or failed rows restart at once;
  - rows still going and couldn't-import rows ask first;
  - another app's rows ask the plan's flagged confirmation ("This download wasn't started by your library — it may belong to another app. Restart anyway?", button "Restart anyway"). This is the only place `allowForeign: true` is set.
- Restart all is now "Restart all that need attention". When another app's stalled, failed or couldn't-import rows exist, a second button "Also restart N started by another app" sets `includeForeign`.
- `scripts/check-writes.sh` pins:
  - `allowForeign: true` to the restarter's one send and the screen's flagged confirmation;
  - `includeForeign: true` to Restart all's second button.

## Tests (RED, then GREEN)
- **QueueRestartAnyGateTests** (18 tests):
  - RED: 3 failing tests, 11 issues. Foreign with the flag was refused; waiting and paused copies were refused; the search after a foreign restart was refused.
  - New or changed tests:
    - `foreignDownloadIsSentOnlyWithTheFlag`: without the flag refused, with it sent; history down plus the flag is still sent;
    - `flagStillRefusesImportingOrDone`;
    - `flagOnlyForTheQueueRestart` (tightened before GREEN; it passed vacuously at first);
    - `searchFollowsAForeignRestartOnlyForItsAlbum`;
    - `waitingPausedOrUnreachableCopiesAreRestarted`.
  - GREEN: 18/18.
- **DownloadsInLidarrTests** (23 tests):
  - RED, run against API stubs: 10 failing tests, 33 issues.
  - New tests: `foreignNeedsTheFlag`, `pausedRowIsRestarted` (a row that isn't progressing / still going), `couldntImportJoinsRestartAllButForeignOnlyWhenTurnedOn`, `foreignNeverGoesThroughTheRunner`.
  - Updated tests: `sortsIntoActiveStalledFailed`, `ownersRealShapes`, `ungrabbedOrUnknownIsNeverRestartable`, `waitingCopiesAreNeverStalled`, `grabCacheIsBatchedAndCached`, `sharedWithAnImportIsNotRestartable`, `stillRestartableUsesTheSameRule`.
  - GREEN: 23/23.
- **LidarrDownloadsAppTests.restartAnythingAsksFirst**:
  - RED: the build fails against the old view (`type 'LidarrDownloadsCopy' has no member 'confirmOne'`).
  - GREEN: the suite passes on the "Magpie Z4" simulator.
- **Final runs:**
  - full package suite: 1066 tests in 11 runs, 0 failures;
  - check-writes: OK;
  - check-writes selftest: 20/20 plants caught;
  - check-release: OK;
  - full app suite (unit and UI, without MAGPIE_IT, on "Magpie Z4" with the app uninstalled first): 987 tests, 1 failure, in `DiscoverAppTests.lookupsAreCached`. That suite is outside Z4's files. It passed when re-run on its own, so it is a flake; record it for Z2/Y6.

## Decisions (D63 in docs/decisions.md)
- **Rows still going.** Restart on a row that is downloading, waiting, paused or whose client can't be reached asks "This download is still going. Restart drops it and looks for another copy." The plan names confirmations only for foreign rows; this one guards against a mistaken tap.
- **Rows with no download id stay refused.** The plan says the gate refuses "only importing or imported" rows. Without a download id, the gate can't tell what the delete would take along, nor whether it shares a download with an import.
- **Rows whose grab status isn't known yet** can't be restarted until the lookup comes back (a few seconds at most). Otherwise the screen couldn't tell which confirmation to show.
- **Restart all's opt-in is a second dialog button.** A confirmation dialog can't hold a toggle, so the owner "turns that on" by picking that button.
- **Restart all never includes rows that are still going.**
- **The "Started by another app" section stays.** Another app's stalled, failed or couldn't-import rows are still listed there, now with Restart. Another app's rows that are still going stay in Active.

## Concerns
- **Decision number may clash.** Z1–Z3 may also have added D63 after D62. Renumber when merging (the code comments say "D63").
- **The security panel should re-check the loosened gate:**
  - waiting and paused copies are no longer refused;
  - `allowForeign` skips the grab history check.
- **No dev-stack UI test for the flagged confirmation.** The plan lists package tests only for item 6, and building a foreign download on the dev stack isn't practical.
- **Flaky test:** `DiscoverAppTests.lookupsAreCached`, see above.
