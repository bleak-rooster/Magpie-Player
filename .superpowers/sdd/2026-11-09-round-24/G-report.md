# R24 G report: CarPlay Now Playing next / previous (owner item 11)

**Status:** DONE_WITH_CONCERNS (the cause behind "jumps to the start while audio continues" is UNCONFIRMED on a device; see
Concerns)
Branch: `worktree-agent-ac9380b66466b7004` (base v0.0.1-custom @ fdf2aa7; the integration branch has not moved since)

Note: the harness refused writing this report to the shared checkout
(`/Users/dr_ecs/Dev/magpie/.superpowers/sdd/2026-11-09-round-24/G-report.md`) from this isolated worktree. It is
committed in the worktree at the same relative path instead.

## What the owner saw, and what was found

"CarPlay Now Playing next/previous don't work, sometimes jump to the start while audio continues."

The car's skip buttons are the system's remote commands (`NowPlayingBridge.registerCommands`). They go to a preview when
one owns them (D86), and otherwise to `Player.next()` / `Player.previous()`. I tested each of plan §6 G's five
hypotheses, in the plan's order. The tests found three real defects, all in `Player`. The preview, the handler lifecycle
and the main-actor hop are ruled out: their tests pass on the unchanged code and stay as guards.

| # | Hypothesis | Result | Tests | Fix (file:line) |
|---|---|---|---|---|
| 1 | A stale preview swallows the command | **Ruled out.** After a preview ends, is stopped, has no clip or can't play, it is no longer active, and next/previous go to the main queue. A preview left paused gives the buttons back as soon as the main player plays (D86's hand-off works). A preview the owner leaves paused *does* keep the buttons, as D86 intends, and Now Playing shows the preview while it does. | `remoteNext_afterPreviewEnded_advancesMainQueue` (4 cases), `remoteNext_previewLeftPaused_mainPlaysAgain_advancesMainQueue` | none |
| 2 | `next()` finds no playable upcoming song, or the skip is silent | **RED, real (a variant).** Unplayable songs are skipped correctly and a gapless advance is followed (ruled out). The defect: **after the player stopped by itself (the current song failed, as on a dropout in the car, or the queue ended), a skip loaded the next song and stayed silent.** `next()` took the `loadCurrent()` path and never played, so the car showed the new title, paused, and next/previous seemed to do nothing. | RED: `remoteNext_afterAFailure_playsTheNextSong`, `remotePrevious_afterTheQueueEnded_playsThePreviousSong`, `remotePrevious_afterTheQueueEndedPastThreeSeconds_playsItAgain`. Guards: `remoteNext_skipsUnplayableToNextPlayable`, `remoteNext_afterGaplessAdvance_goesToTheFollowingSong`, `remoteNext_nothingPlayableLeft_keepsPlayingTheCurrentSong` | `Player.swift:170` (`resumes` captured), `:189` (`if resumes { resume() }`), `:208–216` (`previous`), `:218–221` (`stoppedOnItsOwn`) |
| 3 | Previous restarts by design, and the engine and the screen disagree | **RED, real.** Within 3 s, previous goes back a song (ruled out). Past 3 s it restarted with `seek(0)` only. Converted streams (AAC, Opus) come chunked with no byte ranges (D42, D45), so a seek to 0 can leave the sound where it was while Now Playing shows 0:00. That matches the owner's "jumps to the start while audio continues" (UNCONFIRMED on a device). It also fits "sometimes": downloaded and Original songs seek normally. A second RED: a tick the engine sent before the restart, still in its stream, put the old position back on screen. | RED: `remotePrevious_pastThreeSeconds_restartsFromAFreshLoad`, `remotePrevious_pausedPastThreeSeconds_restartsPaused` (see the RED notes), `seekZero_duringLoadCurrent_neverLeavesAudioPlaying`. Guard: `remotePrevious_nearStart_goesBackNotRestart` | `Player.swift:223–240` (`restartFromTop` empties the engine's list and sends it again, so the same entry on the same URL loads anew from 0; paused stays paused), `:91–95` and `:379–382` (`restartedAt`: within 2 s of a restart, a tick above 3 s for that entry is dropped), `:245` (a seek clears it) |
| 4 | Handler lifecycle (registered twice, or never) | **Ruled out.** `AppModel.init` builds the one bridge (`AppModel.shared`), also on a CarPlay-only launch; CarPlay's scene never builds or removes one. A bridge registers each of the 9 commands exactly once, `invalidate` removes them all, and a new bridge registers each once again. The car connecting, disconnecting and connecting again leaves the handlers unchanged. | `bridge_reconnect_registersEachCommandOnce`, `carConnectDisconnectConnect_leavesTheHandlersAlone` | none (test seam only: `NowPlayingBridge.registeredCommands`) |
| 5 | The handler's hop returns before the skip runs | **Ruled out.** On the main thread (where MediaPlayer calls the handlers), the skip has happened before `.success` is returned. Off the main thread, the skip runs once, on the main actor. | `commandHandler_onMain_skipsBeforeAnswering`, `commandHandler_offMain_skipsOnceOnTheMainActor` | none (test seam only: `NowPlayingBridge.dispatch`, split out of `commandHandler` with the same body) |

## Built

- `Player.swift` (next/previous only, plus the tick guard that belongs to previous's restart):
  - `stoppedOnItsOwn` (`failedEntryId != nil || hasEnded`): when the player stopped by itself, a skip plays the song it
    lands on. After the owner's pause, skipping still stays paused, as before. A stop after the current song is also
    the owner's request, so a skip after it stays paused too.
  - `restartFromTop(resumes:)`: previous past 3 s (or with nothing before it) empties the engine's list and sends it
    again. `AVQueueEngine` keeps an item that has the same id and URL, so emptying the list first makes it drop the item
    and load the same entry from 0. The position goes to 0 and the listening clock is re-anchored; a restart doesn't
    count as listening and sends no new now-playing ping, as before. If the player had stopped by itself, the song loads
    and plays as a new play.
  - `restartedAt`, plus one hook line in `handle(.time)`: after a restart, a tick above 3 s for that entry is dropped
    until a tick lands at or below 3 s, or 2 s pass. `seek` clears it.
- `NowPlayingBridge.swift`: `dispatch` split out of `commandHandler` (same body), and `registeredCommands` (internal),
  for the tests of hypotheses 4 and 5. No behaviour change.
- `CarPlayController+NowPlaying.swift` (new): `configureNowPlaying`, `updateNowPlayingButtons`, `keepButton` and
  `keepCurrent`, moved verbatim from `CarPlayController.swift` (old lines 395–455). The moved code is now in another file,
  so three things lost `private`: `configureNowPlaying`, and the `keeping` / `kept` properties (two lines in
  `CarPlayController.swift`). Nothing else changed in `CarPlayController.swift`.

## Decisions (rows for the controller to add)

| D234 | **Why the car's next and previous seemed not to work (cause found).** Each of plan §6 G's five hypotheses was tested. Ruled out, with their tests kept as guards: (a) a stale preview: once a preview ends, stops, has no clip or can't play, it no longer takes the commands, and one left paused gives them back when the main player plays (D86); (b) unplayable songs and gapless advances: next goes to the next playable song; (c) the remote handlers' lifecycle: there is one bridge, built with the app's model; each command is registered once; the car connecting and going never touches them; (d) the hop to the main actor: on the main thread the skip has happened before `.success`, and off it the skip runs once on the main actor. Found: (1) after the player stopped by itself (the song failed, as on a dropout in the car, or the queue ended), next and previous loaded the song and stayed silent; (2) previous past 3 s restarted with a seek, which a converted stream (chunked, no byte ranges: D42, D45) may not honour, so Now Playing showed 0:00 while the sound went on (UNCONFIRMED on a device); (3) a position tick sent before that restart could put the old time back on screen. Tests: `RemoteSkipTests` (package), `RemoteSkipBridgeTests` and two tests in `CarPlayRound13Tests` (hosted). | Owner item 11 (round 24) | Done |
| D235 | **Skips play after a stop, and previous restarts from a fresh load.** When the player had stopped by itself (the current song failed, or the queue ended), `Player.next()` / `previous()` play the song they land on. After the owner's pause, or a stop after the current song, a skip leaves the player paused. Previous past 3 s (or on the first song) no longer seeks: it empties the engine's list and sends it again, so the song loads anew from 0. Paused stays paused; if the player had stopped by itself, the song plays as a new play. For 2 s after a restart, a tick above 3 s for that song (one sent before the restart) is dropped, until a tick lands within the first 3 s; a seek ends this. The phone's Now Playing buttons call the same methods, so they behave the same way. Cost: restarting a streamed song asks the server for it again. Supersedes the seek-to-0 restart. | Owner item 11 (round 24), D234 | Done |

D236 unused.

## Tests

- Package `RemoteSkipTests` (new, `Packages/MagpieKit/Tests/PlaybackTests/RemoteSkipTests.swift`): 12 tests (15 cases).
- Hosted, in the new file `Tests/MagpieTests/RemoteSkipBridgeTests.swift`:
  - `RemoteSkipBridgeTests`: 3 tests.
  - An extension of `CarPlayRound13Tests` in the same file: 2 tests (`carConnectDisconnectConnect_leavesTheHandlersAlone`
    and `carplay_nowPlayingButtons_enabledMatchQueue`).
- Updated: `PlayerTests.backRestartsBefore3s` pinned the old seek (`engine.seeks.last == 0`). It now pins the fresh load:
  an empty list, then the song.

### RED (on the unchanged Player)

Command: `cd Packages/MagpieKit && swift test --filter RemoteSkipTests`. For this run `Player.swift` was put back to
fdf2aa7's text; the fixed file was copied aside first and restored afterwards.

```
✘ Test seekZero_duringLoadCurrent_neverLeavesAudioPlaying() recorded an issue at RemoteSkipTests.swift:244:9: Expectation failed: player.position < 3
✘ Test remoteNext_afterAFailure_playsTheNextSong() recorded an issue at RemoteSkipTests.swift:151:9: Expectation failed: player.isPlaying
✘ Test remoteNext_afterAFailure_playsTheNextSong() recorded an issue at RemoteSkipTests.swift:152:9: Expectation failed: engine.wantsToPlay
✘ Test remotePrevious_afterTheQueueEnded_playsThePreviousSong() recorded an issue at RemoteSkipTests.swift:189:9: Expectation failed: player.isPlaying && engine.wantsToPlay
✘ Test remotePrevious_pastThreeSeconds_restartsFromAFreshLoad() recorded an issue at RemoteSkipTests.swift:202:9: Expectation failed: engine.loadsFromStart.count == loadsBefore + 1 && engine.loadsFromStart.last == b
✘ Test remotePrevious_afterTheQueueEndedPastThreeSeconds_playsItAgain() recorded an issue at RemoteSkipTests.swift:231:9: Expectation failed: player.isPlaying && engine.wantsToPlay
✔ remoteNext_skipsUnplayableToNextPlayable, remoteNext_nothingPlayableLeft_keepsPlayingTheCurrentSong,
  remoteNext_afterPreviewEnded_advancesMainQueue (4 cases), remoteNext_previewLeftPaused_mainPlaysAgain_advancesMainQueue,
  remotePrevious_nearStart_goesBackNotRestart, remoteNext_afterGaplessAdvance_goesToTheFollowingSong,
  remotePrevious_pausedPastThreeSeconds_restartsPaused
✘ Test run with 12 tests in 1 suite failed after 0.023 seconds with 6 issues.
```

Notes on the RED evidence:
- The first RED run (commit 2bac0be) had two test-setup mistakes, both fixed before the run above:
  - The failure test's first `.failed` triggered the converted-stream fallback: the player retried the original and kept
    playing. The test now fails the song twice.
  - The "queue ended" test ended an entry that wasn't the last one sent, and the player rightly ignored it. The test now
    ends the last song.
  Both tests are RED on the unchanged player, for the real reason, in the run above.
- `remotePrevious_pausedPastThreeSeconds_restartsPaused` passed in that run because its load check was too weak. I then
  tightened it to "one more load from the start" and re-ran it alone against the old player, where it is RED:
  `✘ Test remotePrevious_pausedPastThreeSeconds_restartsPaused() recorded an issue at RemoteSkipTests.swift:217:9:
  Expectation failed: engine.loadsFromStart.count == loadsBefore + 1 && engine.loadsFromStart.last == b`. After the
  fixed Player was restored, all 12 `RemoteSkipTests` pass.
- Hypotheses 4 and 5 (hosted) never had a RED. They needed two small test seams to compile, and they pass, which is what
  rules them out. They ran with the Player fix in place; the fix touches neither registration nor dispatch.

### GREEN

- `RemoteSkipTests`: 12/12 tests (15 cases) pass, together with `PlayerChaosFuzzTests`, `PlayerJumpTests`,
  `PlayerStaleEventTests`, `PreviewPlayerTests` and `SleepTimer*` (46 tests in 6 suites, all passing).
- Full package suite (`swift test`):
  - Final run: all 12 test binaries passed, 1607 tests in total (20 + 157 + 501 + 153 + 121 + 37 + 169 + 43 + 188 + 22
    + 41 + 155), exit 0.
  - An earlier run had one unrelated failure, `B1OutsideArtTests.aCancelledLoadNeverPoisonsTheCache` (outside-art disk
    cache; it ran next to an xcodebuild). It passed 3/3 alone and passed in the final full run.
- Targeted hosted run on "Magpie X5" (`RemoteSkipBridgeTests`, `CarPlayRound13Tests`, `PlayerTests`,
  `NowPlayingModesTests`, `CarPlayControllerTests`, `PlaybackChaosHuntTests`, `NowPlayingVerifyTests`): 102/102 passed.
  All 5 new hosted tests were present in the result bundle.
- Full hosted + UI suite on "Magpie X5"
  (`xcodebuild test … -destination "platform=iOS Simulator,name=Magpie X5" -derivedDataPath dd/G`): Passed, 1356 total,
  1306 passed, 0 failed, 50 skipped (the skips were not looked into), exit 0.
- `scripts/check-writes.sh`: exit 0. No write, route or host was touched, so the selftest was not run.

## Self-review

- Against the brief: the five hypotheses were tested in the plan's order, the RED results are recorded, and only the RED
  ones got fixes, kept minimal. In `CarPlayController.swift` the only changes are the move and the two `private` →
  internal lines it needs (reported above).
- Files outside my list: `Tests/MagpieTests/PlayerTests.swift`, one expectation in `backRestartsBefore3s`. It pinned the
  seek that D235 supersedes. The new hosted test file is mine.
- `Player.swift` beyond next/previous: the `restartedAt` property, one guard in `handle(.time)` and one line in `seek`.
  All three serve previous's restart.
- No Lidarr, slskd or Aurral writes, no new routes, no hosts and no UI copy. Fixtures use no real addresses.
- Swift Testing throughout, no sleeps (the off-main test waits with `eventually`, a poll with a deadline). The package
  tests drive the bridge's own logic (`handleRemote`, then `next`/`previous`), because the bridge is iOS-only.
- Doc comments cite round 24 G and D234/D235.

## Concerns / not done

- **UNCONFIRMED on a device or in a car:** that a seek to 0 on a chunked AAC/Opus stream leaves the sound where it was.
  The fresh-load restart is correct either way. Please have the owner press previous mid-song, on a streamed (not
  downloaded) song, in the car. If next still does nothing while music is playing normally, the cause is outside all
  five hypotheses (the head unit, for example), and a device log is needed. My tests can't reach the real CarPlay
  transport.
- A preview the owner leaves paused still takes the car's buttons. That is D86 by design, and Now Playing shows the
  preview while it does.
- "Next with nothing playable left" (repeat off, end of the queue) still does nothing and says nothing. The plan's "or say
  why" comes with no copy, so I added none. A guard test pins that the current song plays on.
- Restarting a streamed song now asks the server for it again (one request).

## FLOWS.md changes needed

- §3 (playback, Now Playing buttons), to add: "Previous restarts the song once it has played more than 3 seconds,
  otherwise it goes back a song. A restart loads the song again from the start, so the sound and the time shown always
  agree. After the player stopped by itself (a song couldn't play, or the queue ended), next and previous play the song
  they land on; after a pause, they leave it paused."
- §3c (remote commands, CarPlay): no copy change. The car's next and previous are the same commands as the lock
  screen's.

## Commits

- 2bac0be R24G: tests for the car's next and previous, one per hypothesis (RED: skips after a stop stay silent, a restart only seeks)
- 36a7fb8 R24G: Now Playing's own buttons move to CarPlayController+NowPlaying.swift, unchanged
- 5caf396 R24G: tests for the remote handlers' lifecycle and main-actor hop (the bridge exposes its handlers and dispatch for them)
- 42695bb R24G: a skip after the player stopped by itself plays; previous past 3 s starts the song from a fresh load, and a tick from before it is dropped
- (this report) R24G: report

## Fix round 1

Commit ff19534 (`R24G fix round 1: I1 …; M1 …; M3 …; M5 …; M6 …`). This section supersedes the earlier sections where they
differ: the D235 row below, the restart scope, the renamed tests, and the hypothesis 4 evidence.

**I1: the fresh-load restart is narrowed to sources that can't seek.**
- `Player.restartFromTop` (`Player.swift:229–243`) now decides by the current URL:
  - A source that seeks keeps `seek(0)`, exactly as before. That covers a file on the phone and an Original or MP3
    stream, which carries `estimateContentLength=true`.
  - Only a converted AAC or Opus stream (chunked, no length: D42, D45) gets the fresh load.
- The check is the new `Player.seeksReliably(_:)` (`:245–251`). It reads the same query item `NavidromeClient.streamURL`
  sets (`NavidromeClient.swift:361`).
- The restart guard for stale ticks is set only on the fresh-load path, so a seekable source follows its ticks as before.
- After the player stopped by itself (H2's fix), previous still loads and plays the song, whatever the source: the engine
  has no item left to seek in.
- New tests in `RemoteSkipTests`:
  - `remotePrevious_pastThreeSeconds_seekableSource_seeksToZero` (file, original, mp3): one `seek(0)`, no fresh load, no
    new stream URL built (no request), and ticks followed as before.
  - `remotePrevious_repeatedOnTheFirstSong_seekableSource_noNewRequest` (file, original, mp3): previous pressed 5 times on
    the first song gives five seeks to 0 and no new load or stream URL.
  - `remotePrevious_onTheFirstSong_convertedStream_freshLoad`: the converted branch on the first song.
- Renamed to name their branch: `remotePrevious_pastThreeSeconds_convertedStream_restartsFromAFreshLoad` and
  `remotePrevious_pausedPastThreeSeconds_convertedStream_restartsPaused`. Their URLs are `format=aac` with no estimate.
- RED against the round-0 fix (42695bb's `Player.swift`, swapped in for the run and restored after): 18 issues, in all 6
  seekable cases. For example:
  ```
  ✘ Test remotePrevious_pastThreeSeconds_seekableSource_seeksToZero(_:) recorded an issue with 1 argument kind → "file" at RemoteSkipTests.swift:290:9: Expectation failed: engine.seeks == [0]
  ✘ … kind → "file" at RemoteSkipTests.swift:292:9: Expectation failed: urls.built.count == built
  ✘ Test remotePrevious_repeatedOnTheFirstSong_seekableSource_noNewRequest(_:) recorded an issue with 1 argument kind → "mp3" at RemoteSkipTests.swift:307:9: Expectation failed: engine.loadsFromStart.count == loads && urls.built.count == built
  ✘ Test run with 17 tests in 1 suite failed after 0.003 seconds with 18 issues.
  ```
  With the fix, all 17 tests pass.

**M1.** `seekZero_duringLoadCurrent_neverLeavesAudioPlaying` is renamed `remotePrevious_staleTickAfterRestart_isDropped`.
The stale-tick guard (`restartedAt`, `Player.swift:94, 242, 256, 390–392`) is a **second, cosmetic fix**: it stops the
old time flashing back on screen for half a second after a fresh-load restart. It isn't part of the owner's symptom.

**M2. Hypothesis 4 is ruled out by reading the code, not by the tests.** `AppModel.swift:392` is the only place a
`NowPlayingBridge` is built, in `AppModel.init`. The model is the single `AppModel.shared`, used by the phone scene and
`CarPlaySceneDelegate` alike, and nothing ever calls `invalidate` in the app. `bridge_reconnect_registersEachCommandOnce`
and `carConnectDisconnectConnect_leavesTheHandlersAlone` are guards that keep it that way; they don't prove it.

**M3. Guards that the owner's pause holds** (both pass, on the round-0 fix too):
- `remoteNext_afterTheOwnersPause_reloadPath_staysPaused`: repeat one sends the engine the current song alone, so next
  takes the `loadCurrent()` path; while paused it stays paused.
- `remotePrevious_afterTheOwnersPause_nearStart_staysPaused`: previous within 3 s while paused goes back a song and stays
  paused.

**M4.** D235 now says a fresh load rebuilds the song's URL, so the song comes from whatever source is current then: a
download that landed, the quality setting, a failover address. With I1 this applies only to converted streams.

**M5.** `carplay_nowPlayingButtons_enabledMatchQueue` now reads the controller's own state, not the shared
`CPNowPlayingTemplate`. In `CarPlayController+NowPlaying.swift`, `updateNowPlayingButtons` now applies two pieces split
out of it: `nowPlayingButtons()` (the list it built before) and `upNextButtonEnabled` (`player.queue.current != nil`). The
behaviour is unchanged. The test checks shuffle, repeat and the star in `nowPlayingButtons()`, and that
`upNextButtonEnabled` is off, then on with a queue, then off again after it empties, all synchronously.

**M6.** The double blank line in `RemoteSkipBridgeTests.swift` is removed.

**D235, replacing the earlier row:**

| D235 | **Skips play after a stop; previous on a converted stream restarts from a fresh load.** When the player had stopped by itself (the current song failed, or the queue ended), `Player.next()` / `previous()` play the song they land on. After the owner's pause, or a stop after the current song, a skip leaves the player paused. Previous past 3 s (or on the first song) still seeks to 0 on a source that seeks: a file on the phone, or an Original or MP3 stream sent with its length (`estimateContentLength`). On a converted AAC or Opus stream (chunked, no byte ranges: D42, D45), it instead empties the engine's list and sends it again, so the song loads anew from 0. This is a defensive change for the owner's symptom ("jumps to the start while audio continues"); the cause is unconfirmed on a device. Paused stays paused. The fresh load builds the song's URL again, so it comes from whatever source is current then (a download that landed, the quality setting, a failover address), and it is one new request to the server. For 2 s after such a restart, a tick above 3 s for that song (one sent before the restart) is dropped, until a tick lands within the first 3 s; a seek ends this (cosmetic). The phone's Now Playing buttons call the same methods, so they behave the same way. Supersedes the seek-only restart for converted streams. | Owner item 11 (round 24), D234 | Done |

**Tests after fix round 1:**
- `RemoteSkipTests`: 17/17 (26 cases).
- Full package suite (`swift test`), run alone: exit 0. All 12 test binaries passed, 1612 tests
  (20 + 157 + 501 + 158 + 121 + 37 + 169 + 43 + 188 + 22 + 41 + 155).
  - An earlier run alongside the xcodebuild had the same unrelated `B1OutsideArtTests.aCancelledLoadNeverPoisonsTheCache`
    failure seen in round 0. It fails only under that load; it passed in the run alone.
- Targeted hosted on Magpie X5: 102/102 passed, 0 skipped. This covers `RemoteSkipBridgeTests`, `CarPlayRound13Tests`
  (incl. the two G tests), `PlayerTests` (incl. `backRestartsBefore3s`, whose `FakeURLs` stream has no estimate, so it
  takes the fresh-load branch), `NowPlayingModesTests`, `CarPlayControllerTests`, `PlaybackChaosHuntTests` and
  `NowPlayingVerifyTests`.
- The full hosted + UI suite was not re-run this round. The round-0 run was 1356 total: 1306 passed, 0 failed, 50 skipped.

**FLOWS.md §3, replacing the earlier text:** "Previous restarts the song once it has played more than 3 seconds, otherwise
it goes back a song. A song on the phone, or an Original or MP3 stream, restarts with a seek. A converted stream (AAC,
Opus) can't seek reliably, so it is loaded again from the start. After the player stopped by itself (a song couldn't
play, or the queue ended), next and previous play the song they land on; after a pause, they leave it paused."
