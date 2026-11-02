# Y5 report: Finds status, Add to your library that finishes, rock-solid Find → Add (plan items 8 and 9)

Branch `y5-find-flow` (worktree agent-a911d732dedef4677), from v0.0.1-custom at ea33aad (v0.0.1-custom has since
moved: Y1 is merged; nothing is merged or pushed from here). Design:
docs/superpowers/specs/2026-11-02-magpie-find-flow-design.md (revised per Y5-design-review.md; §13 has the spike
results, §14 the as-built notes).

## What was built

**Gate (LidarrKit)**
- **keptLossyDelete:** a new confinement rule for `DELETE /trackfile/{id|bulk}`. It allows only a kept find's MP3:
  - the artist is Magpie's, with a confirmed Keep and no intent, and strictly inside the main root;
  - the file sits at `<artist path>/<relativePath>` of a `FindFile` recorded at the intent;
  - it is the same track (`foreignTrackId`) and the same size;
  - its quality is on the lossy allowlist (M2), compared loosely (M3).
- **One rule per call (C4):** `Verdict.confined(artists:, rule:)`. Each rule has its own last-moment ledger check.
  A mix of a find's files and a kept find's files refuses.
- **C5:** `LedgerEntry.isKeptOrKeeping` replaces bare `keptAt` in every refusing reader. `isConfirmedKept` is used where
  a confirmed Keep is required (BringInMore, keptLossyDelete).
- **I10:** `Ledger.update(artistId:)` makes one atomic save. New ledger fields: `keepIntentAt`, `findFiles`.
- New reads: `LidarrClient.tracks(albumId:)` and `serverDate()` (the `Date` header; cached answers ignored).

**Runner (Requests)**
- **Keep, item 9.4:**
  - intent (ledger intent plus `findFiles`) → `.queued` → PUT (`sentAt`, I2) → verify → atomic commit.
  - A busy Lidarr queues the Keep (item 9.5). It is dropped after a day.
  - **C1:** a collision refuses (`KeepError.collision`); nothing is written.
- **Lossless watch (§5, RequestRunner+Lossless.swift):**
  - At the commit: a RefreshArtist, then an AlbumSearch, then daily searches for up to 30 days.
  - The watch follows the track files, then relinks to the lossless song.
  - **MP3 rule:** only for a Y5 owner-tapped Keep (C2). Removal (`removeMP3Now`, or the deadline) first does a
    targeted RefreshArtist and waits for it, then re-maps each file by path and track, then deletes through the gate
    (C3). Any change → "needs attention". `removedAt` is set only after a read confirms the delete. The album is
    monitored again if Lidarr unmonitored it (I6).
- **Reconcile (RequestRunner+Reconcile.swift):**
  - fact folding: `.imported` per recording (I8); `stoppedInLidarr` only after the add's RefreshArtist completed and the
    album was listed once (I12);
  - adopted finds: verify, then commit, with no auto-delete;
  - the `y5` migration: I3 legacy locks; a watch without auto-delete for older kept finds; the flag is set last.
- **Leases (RunnerState.swift, I1):**
  - persisted in `runner-state-<instance>.json`, with a heartbeat;
  - a fresh lease of another runner blocks the work;
  - a stale lease (over 2 minutes) is dropped;
  - a retired runner releases its leases.
- **Lidarr's clock (9.7, M4):** history, the search start and the deadline all use it.
- **RefreshArtist completion (9.8):** only a targeted refresh, newer than the baseline, counts. A global or pruned one
  means the state is unknown.
- **Stall (9.6):**
  - status flips no longer restart the clock;
  - a non-Soulseek "warning" waits the limit;
  - the client names are read every pass;
  - the default is 3 minutes, and a saved choice is not migrated (I11).
- **FindState resolver (FindState.swift):**
  - ArtistLidarr gains `.find(lidarrId:, state:)` and `.unmatched`;
  - names alone are never acted on (9.9), except for Magpie's own tagless find, which resolves through its request (I9).
- **Matching without tags (9.2):** a pure `fallbackMatch` (path, else title + artist + duration ±3 s, inside the
  artist folder, exactly one match), plus a new `NavidromeClient.songs(titled:inLibrary:under:)`.

**App**
- `AppModel+FindFlow.swift`: FindCopy (the status lines, no service names) and "Remove the MP3 now". The confirmation
  adds "This can't be undone." when the recycle bin is empty (I7).
- M1: when the MP3 is removed its queue entries go. Phone downloads, stars and plays are documented (decision Y5-6).
- Tagless lookup for the runner.
- Artist line: find states and "Couldn't match this artist". The artist page's button reads "Add <artist> to your
  library".
- Activity: the queued, collision and lossless lines, and a "Remove the MP3 now" swipe and accessibility action.
- The CarPlay adapter maps queued and collision (AppModel+CarPlay.swift only; no CarPlay files touched).

**Checks and docs**
- check-writes.sh pins track file deletes to NotForMe and Lossless only, and flags any bare `.keptAt` read outside
  the allowlist. A planted violation was caught.
- decisions.md: Y5-1 to Y5-6, labelled `Y5-n` to avoid numbering clashes with parallel streams; renumber at merge.

## Step 0 spike (dev Lidarr, own artist created and removed)

- **(6) RefreshArtist:** after `POST /artist` it carries `body.artistIds == [id]` and completes in about 4 s. A sent
  `{RefreshArtist, artistId}` shows the same ids.
- **(3) MP3 → FLAC:** with the artist on the FLAC-only profile, the FLAC import replaced the MP3, the MP3 left the disk,
  and the album stayed monitored.
  - `wanted/cutoff` does **not** list the album, so Lidarr's own cutoff search won't look for the FLAC. Magpie's daily
    AlbumSearch is required.
- **I6:** deleting a track file didn't unmonitor the album on the dev stack (that is an owner setting). The re-monitor
  stays.

## Tests (TDD; RED → GREEN)

- **RED evidence:**
  - `KeptLossyDeleteTests` first failed with 2 issues ("not a file Magpie's find brought in": the loose compare of
    relative paths), and the race tests hung until that was fixed.
  - The `RequestsTests` run after the runner rework showed the expected REDs: collision instead of untag-only, intent
    instead of `keptAt`, the 3-minute default and status flips. One hang was caused by a retired runner's lease; fixed
    by `stop()` releasing its leases.
  - `FindFlowTests`: 20 REDs at first (harness), then 3, then green.
  - `FindFlowIT`: 4 REDs that found two real bugs:
    - the state file collided with a requests file named `requests.json` (fixed, with a unit test);
    - after the move, stale track file paths blocked Lidarr's upgrade (fixed by the rescan before the search).
- **GREEN, new suites:**
  - `KeptLossyDeleteTests`: 13 (incl. the race tests both ways, critic 2);
  - `FindFlowTests`: 26 (the critic's 16 are 1, 3–8, 10–16, with 2 in LidarrKit and 9 in the app suite);
  - `FindStateTests`: 3;
  - `FindFlowAppTests`: 5;
  - plus the updated Keep, NotForMe, BringInMore, Stall, ArtistLidarr and RequestLinks tests.
- **Full package:** `scripts/test-packages.sh`, 876 tests, all pass.
- **Full app suite:** on my simulator ("Magpie Y5", app uninstalled first), 896 tests. One failure:
  `OfflineAppTests.fastFailingDownloadsProbeSparingly`, a download-probe timing check unrelated to Y5. It passed on a
  re-run of its suite (24/24), so it is treated as a flake under load.
- **Dev-stack ITs:**
  - `FindFlowIT` (3 tests): the upgrade, with the phone clock 10 minutes off; deadline removal through the gate after a
    relaunch, then the FLAC; the collision refusal. Final run: 3/3 passed in 225 s.
  - An earlier full run failed 2/3 because Navidrome hadn't listed the FLAC within 4.5 minutes. Fixed in product code:
    while a lossless relink waits, the folder scan is asked for again once a minute. After that fix, the targeted
    suites `KeepTests` and `FindFlowTests` were re-run (green); the full package run came before it.
  - `FindsIT|TryIT|ArtistAddIT|DownloadChoicesIT`: 6 tests, pass.
- `check-writes.sh` and `check-release.sh`: OK.

## Concerns

- The E2E releases come from Lidarr's manual import, not a fake indexer plus blackhole client, so search → grab
  isn't exercised. Lidarr re-tags imported files on the dev stack, so the tagless case is covered only by unit tests.
- The I3 legacy-lock clear for a crash that saved no `keep` uses a narrower stand-in rule:
  - the request is still ready and never moved;
  - the artist is tagged and strictly inside the Finds root.

  The critic's `fromPath` rule is used when a Keep was saved.
- Older kept finds get no recorded `findFiles`. "Remove the MP3 now" is not offered for them (no record, no delete).
- After a real crash, the foreign-lease staleness (2 minutes) delays that request or artist on relaunch by up to
  2 minutes. This is by design (I1).
- `NavidromeClient.swift` gained one method next to the existing folder lookup. Y3 also edits this file, so expect a
  small merge.
- `dev/data` (a symlink to the main repo's dev data) and `dev/.env.local` are in the worktree for the ITs. They are
  git-ignored or untracked and not committed. Remove them with the worktree.

## Fix round 1 (review Y5-review.md: 0 Critical, 10 Important)

**RED:** every new test was red before its fix. The gate suite failed to compile until the new gate code existed (that
code was set aside with a reversible patch while the RED run was recorded). The runner suite failed to compile on
`scanFolder`, `FaultPoint` and `hasRecord`.

**Fixes**
- **I1:** the find's file record is stored once per album entry. The gate also matches one *distinct* record and
  refuses copies that disagree. Tests: two-entry artist, at the gate and in the runner.
- **I2:** `recoverOrphanIntents`. An intent that no request follows is either:
  - cleared, with a change-log `NOTE`, when the artist is still a tagged find in the Finds folder; or
  - left in place, with the find marked "needs a look".

  `clearIntent` now reports failure, so the next pass retries.
- **I3:** the lossless watch is saved in the same request change that says kept. The commit then sends its commands;
  a pass re-sends them if a crash came first.
- **I4:**
  - `Ledger.record` merges, so a replacing entry carries over `keptAt`, `keepIntentAt` and `findFiles`;
  - the Try's album entry also inherits them explicitly;
  - the check-writes `.keptAt` pin is now per call site (file plus line text). A planted read in an allowlisted file
    was caught.
- **I5:**
  - `RunnerState.modify` runs under a process-wide lock;
  - `tryAcquireArtist` is one locked check-and-insert;
  - leases are renewed inside the Keep and refresh waits;
  - the removal's RefreshArtist is sent and checked on later passes (its id is kept on the watch), so the tick never
    waits; only the owner's tap waits, up to 3 minutes, renewing its lease.
- **I6:** each migration step reports done or unknown; the flag is set only when every step finished.
- **I7:**
  - one coalesced, targeted scan per artist folder through a new `LibraryAccess.scanFolder` (it never falls back to the
    whole library or a full scan);
  - skipped while Navidrome scans;
  - backs off 1, 2, 4, 8 minutes;
  - bounded to 30 minutes per folder.
- **I8:** "Remove the MP3 now" is offered only with a file record (`LosslessWatch.hasRecord`). The app uses it.
  Decision D50 now matches design §9.
- **I9:** the gate confines `POST /command`:
  - AlbumSearch only for albums the ledger knows;
  - RefreshArtist only for an artist it knows;
  - neither without the ledger.
- **I10:**
  - chaos suite: the app killed at 8 `FaultPoint`s, then relaunched, reaches the end state:
    - Keep: intentSaved, beforePut, afterPut, ledgerCommitted, requestCommitted;
    - removal: refreshSent, beforeDelete, afterDelete;
  - sign-out with an active watch: the watch ends and nothing is deleted; the ledger keeps its record (decision D55);
  - a lease kept fresh across a 3-minute step;
  - a lease that goes stale mid-step: the takeover only follows the saved Keep (one move);
  - critic 1 completed: the queue delete at the gate, plus Stall, Not for me's artist removal and the cleanup unmonitor
    in the runner;
  - two passes over an unchanged server write nothing.
- **Minors done:** Opus counts as lossy; the legacy-lock clear writes a change-log note.
- **Minors not done:** moving runner helpers out of RequestRunner.swift; the "can't be undone" line on the artist page;
  `remonitor` of an owner-unmonitored album; pruning `warningWatch`.

**Merge and decisions**
- v0.0.1-custom (Y1, Y2, Y3) merged with no conflicts.
- The decisions are renumbered D50 to D55 (Y4 has D49).

**Results**
- Package: 970 tests, all pass.
- App suite on a fresh "Magpie Y5" simulator: 943 tests, all pass.
- `check-writes.sh` and `check-release.sh`: OK.
- Dev stack (FindFlowIT and FindsIT): see the final line below.
- Dev stack:
  - `FindsIT` passed.
  - The first `FindFlowIT` run failed 2/3. Its own library hook had no targeted folder scan (the new `scanFolder`), so
    Navidrome never saw the FLAC. The upgrade run also showed the MP3 still in place once; that was not reproduced.
  - With the hook added (artist folder only), `FindFlowIT` passed 3/3 in 309 s.
- The simulator is deleted and the worktree's dev links are removed.
