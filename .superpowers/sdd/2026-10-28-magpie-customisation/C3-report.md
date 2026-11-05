# C3 report: owner items 6 and 7 (round 15)

Branch `c3-library-finds` (from `v0.0.1-custom` 25bed51). Commits:
- `1f689a7` item 7 alone: a rejected find leaves your playlists (D137, D138).
- `cb5aa84` item 6, runner: Try / Add to library intents, Magpie Lossless Preferred, library trials marked, target preview.
- `b5d118c` item 6, app: menus, confirmations, singles switch, keep on arrival, status, gating, check-writes pins.
- (one more: report + Release UI result.)

`c3-wip-all` is a scratch branch from the split. It can be deleted.

## Item 7: a rejected find leaves your playlists (D137, D138)

**Design:**
- `notForMe(confirm)` first proves the Not for me again with `runner.notForMeCheck`, which only reads.
- Then `cleanUpAfterLetGo`:
  - The pending playlist adds linked to the find are dropped.
  - A `FindCleanup` job is saved (`find-cleanups-<instance>.json`).
  - Each of the user's own playlists (`editablePlaylists`) goes through `removeEverywhere`, in AppModel+Playlists.swift. That function:
    - reads the playlist fresh through `ownPlaylist`, under the playlist lock;
    - refuses a playlist whose listing doesn't match its `songCount`;
    - removes every position holding the find's songs (duplicates too), highest first, in one `updatePlaylist`, sent once.
- Only after that does the runner delete the files. Its scan follows the delete.
- **Why the order matters:** after the scan, entries for deleted songs would dangle, and positions could no longer be trusted.

**Retry and notification:**
- The job is saved per playlist as it goes. An unfinished job is finished from a fresh read on every requests update.
- In-app message: e.g. "Gone from your Finds. Removed “Song” from 2 playlists: Chill, Road Trip."
- When the clean-up finishes in the background with notifications on, a local notification "Let go from your Finds" is also posted. With notifications off it is in-app only.
- **History:** Finds › Recently let go shows the latest 5 of 20.

**Pins:** check-writes pins the shape of `removeEverywhere` and that only AppModel+FindCleanup.swift calls it.

**Tests:**
- Package `FindCleanupTests`: 4 tests.
  - Positions highest first, duplicates included.
  - Message text.
  - Store, and its erase on sign-out.
  - History trim.
- Hosted `FindCleanupAppTests`: 9 tests, against a mock Navidrome with owners and counts.
  - Two playlists with duplicates: everything removed, the other entries untouched, one write per playlist with indexes 4, 3, 1.
  - A playlist the user doesn't own: untouched.
  - A count mismatch: the playlist is left alone and named.
  - A pending add is cleared, and saved without it.
  - An interrupted clean-up is finished later and is safe to repeat.
  - The background notification text, and nothing posted in the foreground.
  - Notifications off: in-app only.
  - Not in any playlist: no message.
  - The words name no service.
- **RED evidence:** the tests didn't compile before the types and API existed. No behavioural RED run was recorded.
- Regressions passed: Round14ActionsTests, FindsShelfTests, and the Requests package suite (386 tests).

**Release UI check: PASSED.**
- `Round15LetGoUITests.testARejectedFindLeavesItsPlaylistAndMagpieSaysSo` ran on scheme MagpieUIOnly, Release, the "Magpie Tests" simulator, against the dev Navidrome. It took 17.6 s.
- The dev stack can't make a real find without the internet. So `-MagpieUITesting YES -MagpieUITestLetGo <song id>` runs the exact clean-up a confirmed Not for me runs. This hook is UI-tests only, like `-MagpieSearchPageSize`.
- Setup: a playlist [a, X, b, X], made through the Subsonic API.
- Result: the message names X, and the playlist is [a, b].
- **Not covered by a UI test:** the runner's Lidarr delete half. Hosted and package tests cover it.

## Item 6: Try and Add to library (the coordinator's approved spec)

**Where the actions appear:**
- Song menus (`OutsideSongMenu`): Trending, genre charts, Discover playlists, top songs, and Search's outside songs.
- Album menus: Trending Top albums (long press), outside artist page album rows, and the outside album page bar.
- Recommended shows artists, so its actions are on the artist pages.

**Exactly what was touched in TrendingView:** in `albums(_:region:)` only. The ForEach's `_` became `index`, and a `.contextMenu { OutsideAlbumMenu(…) }` plus `accessibilityIdentifier("trending-album-\(index)")` were added. The chart picker and flow code weren't touched. **RecommendedView was not touched.**

**What exists:**
- **Runner** (package):
  - `RequestRunner.Intent` (`.plain` / `.trial` / `.library`), with request marks `addToLibrary` and `askedAsTry`.
  - A new artist added to the library goes to the main root, tag `magpie`, with "Magpie Lossless Preferred". Lidarr is told `monitor: all` and `searchForMissingAlbums: false`. The runner then sends AlbumSearch for the target, then ArtistSearch.
  - A find artist gets a find, which is kept on arrival.
  - A library artist gets monitor + search of that release only; nothing about the artist changes.
  - `isLibraryTrial` marks Try on a library artist; `trialKept` clears it.
  - `targetPreview`: the release a song brings in, using reads only.
  - `ArtistLidarr.listSingles`: the singles switch, for Magpie's own artists that follow no new releases.
  - `Provisioner.ensureLosslessPreferred`.
- **App:**
  - The menus.
  - "This song comes with the album X" and "Include singles" confirmations.
  - Keep on arrival, then Bring in more Everything in lossless-preferred.
  - Status lines: In your library / On trial · until / Coming · N% / Couldn't bring it in, with Retry.
  - Gating: hidden without Lidarr. Otherwise explained, and a tap reads nothing.
  - Add to library never lands in the queue.

**Tests:**
- Package `LibraryFindsTests`, 15 tests. Every row of the matrix:
  - a new artist: Try, and Add to library (the body, then AlbumSearch, then ArtistSearch);
  - a find artist;
  - a library artist: Add, and Try as a trial;
  - previews: an album said first, not listed, a new artist;
  - singles: lists them and monitors nothing; the owner's artist is refused; changes off sends nothing;
  - persistence, steps and status.
- `LosslessPreferredTests`, 3 tests: made once through the gate; a conflict is never changed; changes off makes nothing.
- Hosted `LibraryFindsAppTests`, 7 tests: gating (hidden / explained, a tap says why, nothing written); quality profile not made with changes off; Try on an album → trial Try sheet; unmatched album; keep on arrival; row status words; copy never says Lidarr or Aurral.
- check-writes and its selftest pass. RefreshArtist and ArtistSearch callers are pinned.

**Release UI check:** see the bottom of this file.

**Gaps closed in the completion round** (commits `e6c3757` package, `2e7468c` app; decisions D146, D147; D140 renumbered D146 because C4 owns D140–D145):

1. **Reject for a library trial (D147).**
   - At the monitor write, the album is read fresh just before. When it is unmonitored with `trackFileCount` 0, the ledger entry records:
     - album id and release group;
     - `trialHadNoFiles`;
     - `trialExpiresAt` (14 days).

     The request carries the date. An album that had files, or was already monitored, is not a trial.
   - **Keep** sets the ledger's `trialKeptAt`. The album stays monitored with the artist's profile.
   - **Reject:**
     1. The app first runs `trialRejectable`, which only reads.
     2. Item 7's playlist clean-up runs, with the same message and notification.
     3. `DELETE trackfile/bulk` goes under the new `ConfinedShape.trialDelete`. The gate checks, against the ledger and fresh reads:
        - every file belongs to the same one album;
        - the ledger entry is an open trial;
        - Lidarr's album is still that release group;
        - the ids are exactly all of that album's files now;
        - every file is inside the artist's folder;
        - a last-moment ledger check passes.
     4. The album is unmonitored.

     Nothing else of the artist's is touched, and never the artist.
   - **Expiry** mirrors Finds (D10): the date is shown, and nothing is removed by itself.
2. **Library trials in Finds (D147).**
   - A new section, "On trial in your library", shows "On trial · until <date>" with Keep and Not for me.
   - Finds shows, on the phone and in the car, while there is a trial, even without a Finds folder.
   - The car lists trials beside the finds. Keep stays on the phone, because the car's Keep is for finds only.
3. **Singles switch for any artist (D146).**
   - **Confirmation:** "Singles will be listed for <artist>. Only "<song>" downloads; nothing else changes."
   - **Steps** in `ArtistLidarr.includeSingles`, each under the new `ConfinedShape.singlesSwitch`:
     1. A change-log NOTE saves the profile and monitorNewItems. This is the undo.
     2. monitorNewItems is set to none.
     3. The artist moves to Magpie's Albums+EPs+Singles profile.
     4. RefreshArtist runs, and Magpie waits for it.
     5. Every newly listed, monitored release except the target is unmonitored. The gate refuses to unmonitor any release that has files.
     6. monitorNewItems goes back to its saved value.

     Then the usual Add to library monitors and searches only the single.
   - **Undo:** Settings › change log › Undo on that line. The gate allows exactly the saved profile back.
   - **Failure part-way:** monitorNewItems is put back where possible, and the message says whether it was.
   - **Pins:** check-writes pins the exact lines and the trial delete's one caller.

**Tests for the gaps:**
- Package `LibraryFindsTests` at that commit (2e7468c): 23 tests (five singles tests have since moved to `SinglesSwitchTests`; see below). New ones then:
  - trial recorded with its date;
  - Reject deletes only that album's files, then unmonitors;
  - an album with files before is refused, by the runner and directly at the gate;
  - a re-check on changed state refuses and sends nothing, including partial or extra file ids;
  - Keep, after which no Reject goes through;
  - expiry removes nothing;
  - an owner-added artist following "all" ends with only the target newly monitored, and following restored;
  - undo restores the saved profile and refuses any other;
  - a failure mid-way restores following and says so;
  - changes off sends nothing;
  - a release with files is never unmonitored by the switch.
- **RED evidence:** with the trial gate's release-group check disabled, `aRecheckOnChangedStateRefusesAndSendsNothing` failed (3 issues). The singles tests failed to compile before the API existed.
- Hosted `LibraryFindsAppTests` at that commit: 9 tests (the earlier "10" was wrong; review M9): a trial listed in Finds and the car with its date; a Reject that can't go changes no playlist and writes nothing; the new copy.
- Suites run:
  - Requests package: 397 tests;
  - LidarrKit: 169 tests;
  - hosted: LibraryFinds, FindCleanup, Round14Actions, OutsidePages, CarPlayFinds, FindsShelf, LibraryLayout (108 tests).

  All passed.
- **Release UI check, passed:** `Round15LetGoUITests.testALibraryTrialShowsInFindsWithKeepAndReject` shows the trial in Finds with its date, Keep and Not for me. It is seeded with the UI-tests-only `-MagpieUITestLibraryTrial`.

**Still not covered:**
- A hosted end-to-end successful trial Reject. The runner and gate halves have package tests, and the playlist half has item 7's tests.
- A real Try or Add against the dev stack, because that needs MusicBrainz on the public internet.

**Release UI check (item 6): PASSED.**
- `Round15LibraryActionsUITests.testATrendingSongOffersTryAndAddToLibraryAndSaysWhyWithChangesOff` ran in Release on the dev stack, the stub Aurral and the dev Lidarr. It took 67.9 s.
- The Trending song's ⋯ menu shows Try and Add to library.
- Each tap shows "…switched off…", and nothing is read or written.

**Checks:** check-writes passes, the selftest passes (42 planted violations and 26 allow-list weakenings caught), and check-release says OK.


## Review fixes (C3-review.md; commit `13094a0`)

### Critical and important

- **C1. The singles switch never narrows the artist's profile.**
  - The target profile is "<the artist's own profile> + Singles (Magpie)": its primary types plus Single, with the same secondary types and the same statuses.
  - A Magpie profile with exactly that spec is reused. Otherwise it is made from the artist's own profile through the gate. An existing profile is never modified, and a same-named profile set up differently stops the switch (a conflict).
  - A profile that already lists singles is left alone.
  - The Live, Compilation and Promotion test passes.
- **I1. A persisted journal** (`singles-switch-<instance>.json`, atomic, erased at sign-out).
  - Each step is saved before its write. The steps are: saved, followOff, profileSwitched, refreshSent, refreshed, extrasUnmonitored, done.
  - Unfinished switches are resumed on runner start and on requests updates (at most once a minute).
  - After 5 failures, or a conflict, a switch is rolled back: following, the profile, then a refresh. The owner is told.
  - The journal holds the original profile id and following.
  - Undo restores both, then refreshes.
- **I2. The RefreshArtist command id is required, and its completion is read from Lidarr.**
  - With no id, a timeout or failed reads, the switch stays pending with following off, and nothing is unmonitored.
  - Once the refresh completes, the extras are unmonitored. They are compared by id and by release group (M7).
- **I3. Serialisation and the gate.**
  - Switches are serialised per artist: a second waits, then finds singles listed. So Magpie's profile is never saved as the original.
  - The journal must save before any write, or nothing is sent.
  - The gate's `singlesSwitch` rule now reads the journal: no journal, no write.
    - A profile is allowed only if it is a "+ Singles (Magpie)" superset or the saved original.
    - Following may be "none" only while the switch is open; otherwise only its saved value.
  - The change-log line is information only, so the 5,000-entry cap can't lose the undo.
  - Undo shows only on the newest switch line of an artist whose switch finished.
  - check-writes pins the exact SinglesSwitch.swift lines.
- **I4.** `isOpenTrial` requires `closedAt == nil`.
- **I5.** A trial's playlist clean-up takes only the songs whose files are the album's Lidarr track files, path to path (`TrialSongs.match`, using the existing mapping). Unmatched files are left alone and said.
- **I6.** Reject is proven first and nothing is sent until then. Then it unmonitors, then deletes. If the unmonitor fails, nothing is deleted.

### Minors

- **M1:** a failed "comes with the album" check sends nothing and shows a retryable message.
- **M2:** a new artist's Add uses the owner's Add defaults (their release types' Magpie metadata profile, plus singles only when the song comes only as one, and their following), with Lossless Preferred (D136).
- **M3:** Lossless Preferred is made only for a new artist's add, one creation at a time.
- **M4:** clean-up retries back off: 1, 5, then 15 minutes.
- **M5:** the UI-test hooks act only on a loopback server.
- **M6:** the runner code moved to RequestRunner+LibraryAdds.swift. Only hook lines remain in RequestRunner.swift.
- **M8:** superseded trials are hidden (the ledger's open trials), and Trending albums show their status by name.

### Tests (accurate counts at `13094a0`)

**Package:**
- `SinglesSwitchTests`, 13 tests, new:
  - theSwitchNeverNarrowsTheProfile
  - anOwnersArtistEndsWithOnlyTheTargetNewlyMonitoredAndFollowingRestored
  - aMagpieSupersetProfileIsReusedAndAProfileWithSinglesIsLeftAlone
  - aProfileThatAlreadyListsSinglesSwitchesNothing
  - undoRestoresProfileAndFollowingThenRefreshes
  - anInterruptedSwitchIsFinishedOnRestart
  - aSwitchThatCantBeFinishedIsRolledBack
  - anUnconfirmedRefreshKeepsFollowingOffUntilItCompletes (no id, and a slow refresh with late singles)
  - twoSwitchesAtOnceAreOne
  - anUnsavedJournalSendsNothing
  - theGateFollowsTheJournal
  - changesOffSendsNothing
  - theJournalIsErasedWithTheRequests
- `LibraryFindsTests`, 21 tests. New:
  - aClosedTrialEntryIsRefusedAtTheGate
  - aRejectWhoseUnmonitorFailsDeletesNothing
  - aTrialsSongsAreItsFilesNotTheSameNamedAlbum
  - onlyANewArtistsAddNeedsTheLosslessPreferredProfile
  - the discography test now asserts the owner's metadata profile and following
- `FindCleanupTests`, 4 tests. `LosslessPreferredTests`, 3 tests.

**Hosted:**
- `LibraryFindsAppTests`, 13 tests. New:
  - whenWhatComesCantBeCheckedNothingIsSent
  - aSupersededTrialIsNotListed
  - anAlbumKnownByNameShowsItsStatus
  - theUITestHooksNeedALoopbackServer
- `FindCleanupAppTests`, 10 tests. New: anUnfinishedCleanupBacksOff.

**Failing runs captured** (the fix disabled, the test run, the fix restored):
- C1: narrowing the made profile's secondaries failed `theSwitchNeverNarrowsTheProfile` (3 issues).
- I2: treating the refresh as completed failed `aSwitchThatCantBeFinishedIsRolledBack` and `anUnconfirmedRefreshKeepsFollowingOffUntilItCompletes`.
- I4 and I6: before the fix, `aClosedTrialEntryIsRefusedAtTheGate` and `aRejectWhoseUnmonitorFailsDeletesNothing` failed (7 issues).
- I5: matching by album name failed `aTrialsSongsAreItsFilesNotTheSameNamedAlbum`.
- M2: ignoring the request's profile failed the discography test.
- M5 and M4: forcing the hooks and skipping the back-off failed `theUITestHooksNeedALoopbackServer` and `anUnfinishedCleanupBacksOff`.
- **Caveat:** the SinglesSwitch tests were written alongside the new type, so their first failure was a compile failure. The behavioural failing runs above came from disabling the fix afterwards.

**Suites run:**
- Requests: 408 tests. LidarrKit: 169 tests.
- Hosted, 149 tests: LibraryFinds, FindCleanup, Round14Actions, OutsidePages, CarPlayFinds, FindsShelf, LibraryLayout, FindFlow, Round14Discover.
- check-writes and its selftest pass.

**Not covered:**
- A hosted end-to-end successful trial Reject. The runner and gate halves have package tests; the playlist half has item 7's tests and the path matcher's test.
- Lidarr's real RefreshArtist drop behaviour is modelled in the test fake, not exercised on the dev stack (it needs MusicBrainz).

**Release UI checks after the review fixes, all passed** (Release, the "Magpie Tests" simulator):
- `testALibraryTrialShowsInFindsWithKeepAndReject` (23.1 s)
- `testARejectedFindLeavesItsPlaylistAndMagpieSaysSo` (14.2 s)
- `testATrendingSongOffersTryAndAddToLibraryAndSaysWhyWithChangesOff` (66.0 s)

check-release: OK.

## Re-review fixes (C3-rereview.md; commit `d5a2466`)

### Important

**R1. A retired switcher no longer keeps acting after a rebuild.**
- `rebuildRunner` stops the old `SinglesSwitcher`. The stopped state is checked before every Lidarr send, every journal save and every resume.
- There is one shared `SinglesSwitchStore` per journal file (`SinglesSwitchStore.shared(fileURL:)`), so two switchers can never hold stale copies.
- Sign-out or a disconnect closes the store (`close()`). After that, every save refuses, so the file is never recreated.
- Tests:
  - `aRebuildDuringASwitchLeavesOneSwitcherActing`: one journal; the old switcher does nothing; the new one finishes with a consistent end state.
  - `aSignOutDuringASwitchSendsNothingAndLeavesNoFile`.

**R2. A new artist's Add always lists the release that was asked for.**
- The owner's Add-default types are widened to the target's own kind with `ReleaseTypes.widened(toInclude:secondaryTypes:)`: EP, Single, and Studio / Live / Soundtrack.
- The album page previews that release group itself (`targetPreview(_:album:)`).
- A kind that can't be listed is refused before anything is sent.
- Tests:
  - `theAddsTypesAlwaysListTheTarget` (Albums-only defaults + an EP lists the EP);
  - `anAlbumPagePreviewIsThatRelease`;
  - hosted `aNewArtistsAddListsTheReleaseAskedFor`.

### Minors

- **m1:** the gate requires a "+ Singles (Magpie)" profile to be a true superset of the saved original plus Single, on all three allowed sets.
- **m2:** an unmonitor needs an open switch for the album's artist. check-writes pins who names and saves the journal (only SinglesSwitch.swift and the runner's rebuild; the one shared store).
- **m3:** an unreadable journal is moved aside (`.unreadable-<ts>`), and rows that don't decode are dropped one by one. The owner is told "A change to an artist couldn't be finished. Check Settings › change log." That line then offers **Put back**, which puts back the profile, then a confirmed refresh, then following, journaled. Hosted `aSwitchLineSaysWhatWasSaved` covers parsing the saved values.
- **m4:** roll-back and Undo now go profile, then a confirmed refresh, then following. Following stays off until the refresh is confirmed.
- **m5:** the song a pending switch is for is kept in the journal and handed over once when the switch finishes, also after a relaunch.
- **m6:** Undo leaves a profile the owner changed since, and says so.
- **m7:** Keep after a Reject whose delete failed monitors the album again.

### Tests at `d5a2466`

**Package:**
| Suite | Tests | New |
|---|---|---|
| `SinglesSwitchTests` | 19 | aRebuildDuringASwitchLeavesOneSwitcherActing, aSignOutDuringASwitchSendsNothingAndLeavesNoFile, aCorruptJournalIsKeptAsideAndTheArtistCanBePutBack, aPendingSwitchsSongIsAskedForAfterARelaunch, undoLeavesAProfileTheOwnerChanged, theGateChecksTheSupersetAndTheOpenSwitch |
| `LibraryFindsTests` | 24 | keepAfterAFailedDeleteMonitorsTheAlbumAgain, theAddsTypesAlwaysListTheTarget, anAlbumPagePreviewIsThatRelease |

Changed: the rollback test (the profile back, following not until the refresh is confirmed) and the undo test (the new order).

**Hosted:**
| Suite | Tests | New |
|---|---|---|
| `LibraryFindsAppTests` | 15 | aNewArtistsAddListsTheReleaseAskedFor, aSwitchLineSaysWhatWasSaved |
| `FindCleanupAppTests` | 10 | — |

**Failing runs captured** (the fix disabled, the test run, the fix restored):
- Disabling the stop guards failed `aRebuildDuringASwitchLeavesOneSwitcherActing` and `aSignOutDuringASwitchSendsNothingAndLeavesNoFile`.
- Disabling the store's close guard, the owner-change check, the persisted song and the move-aside failed:
  - `undoLeavesAProfileTheOwnerChanged`
  - `aPendingSwitchsSongIsAskedForAfterARelaunch`
  - `aCorruptJournalIsKeptAsideAndTheArtistCanBePutBack`
- Disabling the gate's superset and open checks failed `theGateChecksTheSupersetAndTheOpenSwitch`.
- Disabling the EP widening failed `theAddsTypesAlwaysListTheTarget`.
- Previewing the smallest release instead of the album failed `anAlbumPagePreviewIsThatRelease`.
- Disabling Keep's re-monitor failed `keepAfterAFailedDeleteMonitorsTheAlbumAgain`.
- Skipping the app's widening failed hosted `aNewArtistsAddListsTheReleaseAskedFor`.

**Suites run:**
- Requests: 417 tests. LidarrKit: 169 tests.
- Hosted LibraryFinds, FindCleanup and FindFlow: 32 tests.
- check-writes and its selftest pass.

**Release UI check (Trending song menu), passed:** `testATrendingSongOffersTryAndAddToLibraryAndSaysWhyWithChangesOff` (68.8 s).

check-release: OK.


## Re-review 2 fixes (C3-rereview2.md)

### Important

**N1. "Put back" is offered only where it belongs.**
- When a journal is quarantined, the artist ids it still names are recorded beside it in `singles-switch-<instance>.lost.json`, which is erased at sign-out.
- Change-log lines for switches now carry the Lidarr instance. Actions appear only on this Lidarr's lines, and only for those recorded artists.
- `restoreFromNote` reads the artist fresh before any write. The artist must still be on a "+ Singles (Magpie)" profile that is a superset of the saved one; otherwise it refuses (`changedByOwner`) and sends nothing.
- Tests:
  - `putBackIsOnlyForThisLidarrsLostSwitches` (a sign-out and sign-in, and another Lidarr);
  - `putBackRefusesAnArtistChangedByHand`;
  - `aCorruptJournalIsKeptAsideAndTheArtistCanBePutBack` (updated);
  - hosted `putBackIsOfferedOnlyOnThisLidarrsLostArtists`.

**N2. A failed profile restore is never reported as done.**
- While putting back, the original profile is resent on every pass until Lidarr reads the original id back.
- Only then is `profileRestored` saved.
- Test: `aFailedProfileRestoreIsSentAgain`.

### Minors

- **R2 status:** a release with no Official release is refused before anything is sent (hosted `aNonOfficialReleaseIsRefused`).
- **Song request:** if the request for a song fails after it was taken from the journal, it goes back into the journal and is retried (`aSongWhoseRequestFailedIsKept`).
- **Stop:** the old switcher's stop is now synchronous and nonisolated, called before the new runner starts.
- **Close and save:** the closed check and the journal write are taken under the same lock.

### Failing runs captured

Each fix was disabled, the tests run, then the fix restored:
- Lost list, superset guard, profile resend and give-back disabled together: SinglesSwitch tests failed with 14 issues, across N1's three tests, N2's test, the give-back test, and the undo and rollback order tests.
- Instance filter and Official guard disabled: both hosted tests failed (3 issues).

### Runs

- Requests: 421 tests. LidarrKit: 169 tests.
- `SinglesSwitchTests`: 23. `LibraryFindsTests`: 24.
- Hosted `LibraryFindsAppTests` and `FindCleanupAppTests`: 27.
- check-writes and its selftest pass.

check-release: OK.
