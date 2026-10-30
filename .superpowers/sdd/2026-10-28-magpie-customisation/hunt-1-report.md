# Crash hunt 1: playback under chaos

Date: 2026-10-30. Branch `worktree-agent-a11aee41bec681a11` (base 7f93d25, build 9). Simulator: a new "Magpie Hunt 1" (iPhone 18 Pro, iOS 27.0, 382E6954-…), deleted at the end. Server: the localhost dev stack only (Navidrome on 127.0.0.1:4533, through `dev/netem/badnet.py` on 127.0.0.1:4611 for the bad-network run). No Lidarr writes.

## What I swept

| Sweep | Cases | Where |
|---|---|---|
| `Player` chaos: 2,000 seeded sequences × 50 ops (30 op kinds): play (startAt −2…10, empty lists), playNext, addToQueue, move (targets −3…20), remove, next, previous, seek (NaN, ±inf, −1e9, 1e12, 1e300, greatestFiniteMagnitude…), repeat modes, shuffle on/off, stop after current, `.ended`/`.failed` with current, stale, last-sent or unknown ids, `.time` ticks (stale, backward, huge, NaN; wall clock jumping −5 s…1 h), bursts of up to 4 min of listening, `.itemChanged` (stale/unknown), `.playing`, `.stalled`, failover (`urlsInvalidated`), quality/network refresh, offline on/off (as `offlineInputsChanged` applies it, with `stopUnplayableCurrent` and `retryAfterFailure`), downloads landing/going (local file vs stream fallback), lookahead −1…12, Keep (`replaceSong`), Not for me (`removeSongs`), sleep-timer volume, odd scrobble rules, sign-out mid-play. Songs with lengths 0, 12, 31, 200, 1e7, 1e300, NaN, inf; odd ReplayGain (±200 dB, NaN, inf, peaks 0/NaN/−1); finds mixed in. | 100,000 ops | `PlayerChaosFuzzTests.chaosSequences` (≈2.5 s) |
| Invariants after every op: no trap; current index valid or nil; no duplicate entry ids; engine list has unique ids, all from the queue; while playing, the engine holds the current entry and what follows it is in upcoming order; finite position; duration nil or > 0 and not NaN; volumes in 0…1; finite engine seeks; at the end, plays counted ≤ plays started and no find scrobbled. A coverage check makes sure plays are counted and >10,000 steps end playing. | | |
| `PlayQueue` alone: 2,000 × 50 ops, incl. shuffle/restoreOrder, wrap, removeSongs | 100,000 ops | `PlayerChaosFuzzTests.queueSequences` |
| Sleep timer: 300 × 40 ops (start every option, cancel, pause, skip, song ends, clock jumps, yields mid-fade) | 12,000 ops | `SleepTimerChaosTests` |
| Real `AVQueueEngine` on the simulator: seeks to 1e300, −1e300, 1e20, 9.3e15, greatestFiniteMagnitude, NaN, ±inf | 11 seeks | `PlaybackChaosHuntTests.realEngineTakesOddSeeks` |
| Real engine + `Player`, 3 seeds × 60 random ops with 0–250 ms real time between them (engine ends and item changes interleave) | 180 ops | `realEngineChaosSequence` |
| Lock screen (`NowPlayingBridge`) with a 1e300 length and huge/negative positions, NaN engine length | | `lockScreenTakesHugeLengthsAndPositions` |
| Bad network: `dev/netem/hunt.sh` (NetCrashHuntTests) through badnet, AAC and Opus × 10 faults (stall, drip, drop, reset, 5xx on retry, 5xx-all, header delay, flap, chaos ×2) with skips, seeks, pause/resume, Queue sheet | 20 fault runs, 338 s | passed, no new `Magpie-*.ips` |

## Crashes and bugs found

### 1. Trap: ListenBrainz listen with a huge song length (fixed)
- **Where:** `App/Playback/ScrobbleRouter.swift:316` (at 7f93d25): `durationMs: song.duration > 0 ? Int(song.duration * 1000) : nil`.
- **Root cause:** `Int(_:)` traps when the value is past Int's range. `JSONDecoder` decodes any finite length (verified: 1e17 and 1e300 decode; only 1e400 is refused), so a song whose length is ≥ ~9.22e15 s (a broken tag or server) trapped on every "now playing" and every play sent to ListenBrainz. Reproduced on the simulator: `SIGTRAP` in `_assertionFailure` from `static ScrobbleRouter.listen(_:at:)` (crash report Magpie-2026-10-30-104146.ips).
- **Fix:** `ScrobbleRouter.durationMs(_:)` uses `Int(exactly: (seconds * 1000).rounded(.towardZero))`: same value as before for every real length, nil (left out) when it can't be counted.
- **Test:** `PlaybackChaosHuntTests.listenWithAHugeLengthDoesNotTrap` (1e300, 1e17, 9.3e15, greatestFiniteMagnitude; 200.5 s still gives 200,500 ms). RED: test process crashed. GREEN after the fix.

### 2. Desync: a late `.itemChanged` made the player name a song the engine wasn't playing (fixed)
- **Where:** `Packages/MagpieKit/Sources/Playback/Player.swift`, `handle(.itemChanged)` (now line 318).
- **Root cause:** engine events come through a buffered `AsyncStream`. If the engine moves on to `b` gaplessly and the listener edits the queue before `.itemChanged(b)` is handled (e.g. moves `b` to the end), the player re-sends `[a, c]` and the engine reloads `a`. The late `.itemChanged(b)` still matched "b is upcoming", so the player jumped to `b`: the lock screen and Now Playing named `b`, the ticks for `a` were dropped as stale (frozen position, no scrobble), and the window wasn't topped up (`topUpWindow` finds `b` nowhere in `sent`). Not a trap, but it breaks the "engine items match the window" invariant. Found by the sweep (op 16 in ~10 seeds of the first 350).
- **Fix:** after the repeat-one branch, ignore an `.itemChanged` for an id not in `sent` (the list last sent): the engine only ever reports items of its current list (`setItems`, `next`, `itemEnded` and the media-services rebuild all enqueue from `list`), so such an event is always stale. Repeat-one recovery is unchanged.
- **Tests:** `PlayerStaleEventTests.lateItemChangedForAnEntryNoLongerSentIsIgnored` (RED → GREEN) and `itemChangedForASentEntryAdvances`; the sweep passes on all 2,000 seeds. All existing Player/window/local-playback/queue tests still pass.

## Suspected issues not fixed / not reproduced
- **`App/AppModel+BringInMore.swift:31` (outside my area, not fixed):** `Int((duration / 3600).rounded())` traps for a finite but huge `duration` (≥ ~3.3e22 s) — the guard checks only `> 0` and `isFinite`. Same class as crash 1; the length comes from Lidarr. Flagged for the Lidarr/Requests hunter.
- **Scrubber `0...duration` (`NowPlayingView.swift:200`):** `max(NaN, 1)` is NaN in Swift, and `0...NaN` traps. Not reachable today: `Player.duration` only takes finite values and a JSON song length can't be NaN or inf. Worth a `isFinite` guard if lengths ever come from elsewhere.
- **`Player.seek` keeps a negative target** as `position` (−5 from a remote command); the UI clamps it, so only cosmetic.
- **Real `AVQueueEngine` seeks past CMTime's range** (1e20 s becomes +inf CMTime): AVPlayer took them without an exception on iOS 27.
- The end-of-song sleep timer follows the player's flag one main-actor turn late (through `Observations`); harmless, consistent after a yield.

## Commits
- `ec7d6c9` Hunt 1: Player ignores a late item change for an entry the engine no longer holds; seeded chaos sweep
- `34d210a` Hunt 1: a song length past Int range no longer traps the ListenBrainz listen; real-engine chaos tests
- `0734a8f` Hunt 1: sleep timer chaos sweep (fade, cancel, skips, song ends)
- (this report)

## Final runs
- Package tests (`swift test` in Packages/MagpieKit): all bundles pass (incl. the new 3 suites).
- App tests on "Magpie Hunt 1" (scripts/test-app.sh logic with my UDID and `-derivedDataPath <worktree>/dd`, no `MAGPIE_IT`): **TEST SUCCEEDED**, Swift Testing 678 tests in 71 suites passed; XCTest UI tests skipped without the dev-stack env (as usual).
- Bad-network UI hunt through badnet (AAC, Opus × 10 faults): passed, no crash, no hang.
