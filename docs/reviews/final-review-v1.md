# Magpie v1: final whole-branch review

- Range: `main..v1-build` at `af5ff8f` (58 commits, 188 files, about 26k lines).
- Scope: problems that span modules and that the per-task reviews could not see: AppModel ↔ RequestRunner ↔ Player ↔ CarPlay ↔ MatchIndex, lifecycle, isolation, duplicated logic, copy consistency, and what is likely to break when the owner points the M5 fallback Try path at a real Navidrome and Lidarr.
- Method: read-only. I read AppModel (+Requests), RequestRunner, Player, AVQueueEngine, NavidromeClient, LidarrClient/DTOs, MatchIndex, the stores, ServerAddress/consent, and the CarPlay delegate and controller. I also read the Try, Activity, Settings and Connect screens, the Info.plist, project.yml and entitlements, and the deferred/parked ledger.
- Test run: `scripts/test-packages.sh` passes (about 290 tests in 8.4 s; IT suites skipped without `MAGPIE_IT`). I did not run the app suite, because `test-app.sh` regenerates the Xcode project; the ledger records it green at `af5ff8f`.

## Strengths

- **The write path is disciplined end to end.** Every Lidarr write goes through `LidarrWriteGate`. A grep shows no POST/PUT/DELETE outside it apart from Navidrome login. M6 `persist()` runs before every write, and the ledger send states (`notSent` / `unclear` / `applied`) follow "when in doubt, don't write". The parked H1 item is fixed: `monitorExisting` now routes this request's own pending entry through `resolveOwnPending` (RequestRunner.swift:608-617), and `sendMonitor` persists before the PUT.
- **Records are scoped per instance.** Requests, ledger, write switch and setup are keyed by `instanceScope`, so ids from one Lidarr are never acted on against another. A runner whose ledger scope doesn't match refuses to start (RequestRunner.swift:123-126).
- **Runner lifecycle is clean.** `rebuildRunner` stops the old runner before the new one loads the same store. The `runner === runner` guard on the update stream and `pollGeneration` prevent cross-talk between runners.
- **Failover is single-flight.** `reconnect` is shared, `performReconnect` won't overwrite a session that changed meanwhile, `ClientBox` lets the Player and scrobbler follow the active client, and `urlsInvalidated` rebuilds stream URLs.
- **The real-world edge cases are covered.** These include proxy HTML vs JSON shape, servers that ignore `_start`, scans stuck at "scanning", the Navidrome 0.64 unauthenticated-ping shape, `inet_pton` host classification, and Lidarr's 7-digit fractional dates.
- **The package suite is fast and deterministic.** Its slowest test is 2.5 s (50k-song paging).

## Issues

### Critical

None found.

### Important

**I1. Turning "Count plays" back on does nothing until the app is relaunched**
- **Where:** `App/AppModel+Requests.swift:185-189`, `Packages/MagpieKit/Sources/Playback/Player.swift:40-42,82,315`.
- **What's wrong:** two switches share one setting. `Player.countPlays` (read from `magpie.countPlays` at init) gates every scrobble before `NavidromeScrobbler` checks `PlayCounting`. `AppModel.setCountPlays` updates `PlayCounting` and UserDefaults but never `player.countPlays`.
- **Scenario:** the owner turns Count plays off "while trying things out" (the footer suggests this), relaunches, then turns it back on. No plays are scrobbled until the next launch. Turning it off and on within one launch happens to work, which hides the bug.
- **Fix:** delete `Player.countPlays` and its defaults write, and keep `PlayCounting` as the only source. The minimal alternative is to also set `player.countPlays = on` in `setCountPlays`. Add an app test: launch with the setting off, turn it on, play past the threshold, expect a submission.

**I2. A Tailscale MagicDNS name typed without a scheme becomes https, fails, and the error says the server isn't running**
- **Where:**
  - parsing: `App/ServerAddress.swift:26-28`;
  - Connect copy: `App/Screens/Connect/ConnectErrorCopy.swift:76-97,99-103`;
  - Lidarr copy: `App/Screens/Settings/ConnectLidarrView.swift:218-223`.
- **Scenario:**
  1. RUNBOOK:20 offers "a Tailscale name". `nas.tail1234.ts.net:4533` isn't classified as private, so it becomes `https://…:4533`.
  2. Navidrome on 4533 (and Lidarr on 8686) speak plain http, so TLS fails with `URLError.secureConnectionFailed` (-1200).
  3. `isCertificateError` doesn't include -1200, so the owner reads "Couldn't reach nas…. Check the address and that the server is running." The server is running.
- This is the most likely way the first sign-in against the real server fails tomorrow. The same happens on Connect Lidarr.
- **Fix (copy only, no security change):**
  - When an https failure is `.secureConnectionFailed`, `.cannotParseResponse` or `.badServerResponse`, say: "That address doesn't answer over https. If your server uses plain http, type http:// in front."
  - Add the same branch to `LidarrConnectCopy.message`.
  - Optionally, when the typed text had no scheme and a non-443 port, show the parsed URL under the field so the owner can see https was assumed.

**I3. A launch while the Keychain is locked loses the Lidarr connection for the rest of that process**
- **Where:** `App/AppModel.swift:136,150,165-168` (read once in `init`), `App/AppModel.swift:187-210` (`resumeSavedSession` never re-reads them), `App/LidarrConnectionStore.swift:29-32` (`try?` turns "locked" into "none").
- **What's wrong:** if the process starts before first unlock, `lidarr`, `changesAllowed`, `lidarrSetup` and `hasListenBrainzToken` are read as absent. When protected data becomes available, only the Navidrome session is restored.
- **Scenario:** a CarPlay cold start after a reboot, or app prewarming, runs `MagpieApp.init` → `AppModel.shared` before unlock. Later the phone UI opens:
  - Try says "Connect Lidarr in Settings";
  - saved requests are never polled, and owed clean-ups don't run;
  - Settings shows no Lidarr.
- If the owner then re-connects, the write switch is reset. Nothing is lost on disk, but the app looks broken until it is killed and relaunched.
- This doesn't affect the simulator test, but it hits the first real device or car use.
- **Fix:** in the `.session` branch of `resumeSavedSession`, before `rebuildRunner()`:
  - if `lidarr == nil`, re-read `lidarrStore.load()`;
  - re-derive `changesAllowed` and `lidarrSetup` (the same 3 lines as `init`);
  - refresh `hasListenBrainzToken`.
- **Also fix here:** `SessionStore.load` (`App/SessionStore.swift:44-50`) maps *every* Keychain error to `.unavailable`. A persistent non-lock error (for example `-34018`, which the decision review warns about for ad-hoc signing) leaves "Unlock to continue" on screen with no way to sign in. Treat only `errSecInteractionNotAllowed` as `.unavailable` and log the rest as `.none`. This is ledger minor 1.5, promoted.

**I4. While a request waits, every cause shows "Your server isn't answering"**
- **Where:** `RequestRunner.swift:1002-1017` (`event(for:)`), `:355` (MusicBrainz failure), `:649` (setup removed → `WriteGateError.disabled`), and `App/Screens/Activity/RequestCopy.swift:65`.
- **What's wrong:** all of these map to `.lidarrUnavailable`, which the UI shows as "Your server isn't answering. We'll try again.":
  - the owner switched "Allow Magpie to change Lidarr" off;
  - set-up or the root folder is missing;
  - Lidarr's API key was rejected (`unauthorized`, which is ledger minor 8.1);
  - the requests file couldn't be saved (`NotSaved`);
  - MusicBrainz was down or rate-limited.
- **Scenario:** during the M5 test the owner flips the switch, rotates the key or hits MusicBrainz 503s. The Requests row then blames "your server", while their music server is clearly playing. This misdiagnoses exactly the path being tested.
- **Fix, copy-level and cheap:**
  - in `RequestCopy.status`, for `waiting(.serviceUnavailable)`, use `model.tryAvailability`: when Try isn't available, show its message ("Turn on 'Allow Magpie…'");
  - call it "Lidarr isn't answering" rather than "your server" (the app already names Lidarr in Settings);
  - map `LidarrError.unauthorized` to a key message.
- **Better, later:** a separate `WaitReason.kind` for "changes off / not set up".

**I5. There is no documented path to a device build, and the CarPlay entitlement will block one**
- **Where:** `App/Magpie.entitlements` (`com.apple.developer.carplay-audio`), `project.yml:10,50` (`DEVELOPMENT_TEAM: ""`, entitlements always applied).
- **What's wrong:** the decision review (v1-decision-review.md:239) says a device build without Apple's approved entitlement "must strip the CarPlay entitlement (separate configuration)". No such configuration exists, and the RUNBOOK covers only the simulator.
- **Scenario:** the owner tries their phone or car tomorrow. Signing fails ("provisioning profile doesn't include com.apple.developer.carplay-audio").
- **Fix:** either a `Device` config, or a RUNBOOK note: set a team, and for device builds point `CODE_SIGN_ENTITLEMENTS` at an entitlements file without CarPlay. Also say plainly in the morning brief that tomorrow's test is simulator plus real servers.

### Minor

1. **`Session.isAdmin` is never read** (`AppModel.swift:24,343`). Navidrome's `startScan` is admin-only. For a non-admin account, every `startScan` the runner sends fails silently (`RequestRunner.swift:898,929`, `try?`), and Ready then depends on Navidrome's own watcher or schedule. Either use `isAdmin` to skip scans and log once, or delete it.
2. **Shuffle means two things.** Phone `AppModel.shuffle` (`AppModel.swift:564-566`) pre-shuffles the array and leaves `Player.isShuffled` false. CarPlay `start(shuffled:)` (`CarPlayController.swift:272-276`) uses `setShuffled(true)`. As a result the Shuffle toggle in Queue / CarPlay Now Playing reads "off" after the phone's Shuffle button, and turning it off doesn't restore album order. Route both through `play` + `setShuffled(true)`.
3. **`LibraryAccess.navidrome(_:index:)` is dead** (`RequestRunner.swift:24-30`; no callers) and would bypass AppModel failover if anyone used it. Delete it.
4. **`pollRequests` is a no-op while a poll loop is sleeping** (`AppModel+Requests.swift:113-124`). Coming back to the foreground and pull-to-refresh in Requests (`ActivityView.swift:35`) don't speed anything up; the 30 s sleep can run out first. Cancel and restart the loop in those two places.
5. **A stale audit can land on a different Lidarr** (`AppModel.swift:499-507`). `lidarrAudit()` only checks that *a* Lidarr is connected. An audit of the old Lidarr that finishes after a disconnect and reconnect to another one sets `lidarrStatus`, and `adoptOnlyRoot` can save the old server's root into the new setup. Compare `client.instanceScope == lidarrScope` before assigning.
6. **The "Allow Magpie to change Lidarr" toggle can flicker** (`SettingsView.swift:103-105`). The binding's setter is an async Task and its getter reads `changesAllowed`, which updates only after the await. Set `changesAllowed` first, synchronously.
7. **The old runner is stopped twice** (`AppModel+Requests.swift:63` and `:89`). Harmless; keep only the awaited one.
8. **Sign-out keeps the ListenBrainz token and the recent searches.** Recent searches are shared with CarPlay. Both carry over to the next account. Decide deliberately and document.
9. **A changed Navidrome password fails silently on resume** (`AppModel.swift:343`, `try?`). The app then shows browse errors everywhere and only offers Sign out. Surface `badCredentials` as "Sign in again".
10. **Test hygiene:**
    - `TryAndSettingsTests.swift:166` uses a fixed 500 ms sleep to assert that something does *not* happen.
    - 10 ms polling loops with 2 s budgets: `TryAndSettingsTests.swift:124-175`, `EdgeCaseAppTests.swift:177,265`.
    - `AVQueueEngineTests.swift:46` uses a real 1.5 s sleep.
    - 16 `UserDefaults(suiteName:)` suites against 6 removals.
    - These aren't flaky today, but they are the first places to look if CI gets loaded.

## Deferred-minor triage

**Fix before the owner tests (all small, app-level, no RequestRunner logic change except I4 copy):**

| Item | Source | Why now |
|---|---|---|
| I1 Count plays sync | new | Silent loss of scrobbles in a flow the UI invites |
| I2 https/TLS copy (MagicDNS) | new | Likeliest first failure against the real server, with misleading copy |
| I4 waiting-reason copy | new + 8.1 "wrong Lidarr key shown as waiting" | Misdiagnoses the exact M5 path under test |
| I3 Lidarr reload after unlock + Keychain no-escape | new + 1.5 "persistent Keychain error … no escape" | About 10 lines. Required before any device or CarPlay use; harmless in the simulator |
| I5 device-build note | decision review A-notes | Documentation only |

**Leave (reviewed, low impact or already resolved):**

- **0.1:** sim OS pin is now done (`test-app.sh` pins OS=27.0). Placeholder smoke tests: leave.
- **0.2:** `Log.describe` test, `Log.logger` escape hatch, `url()` overwrites base query: leave.
  - Cookie not redacted: Magpie never sets Cookie, sessions are ephemeral, and `Log.request` is debug-level.
  - Keychain update path skips `kSecAttrAccessible`: every item is created with the same class, so leave.
- **1.1:** leave.
- **1.2:**
  - unauthenticated media URLs before connect: on resume, art and streams are only built after a request has logged in, and the queue isn't persisted;
  - stale login join, `f=json` on media URLs, `startScan` reentrancy;
  - all leave.
- **1.3:** stalled / scrobble-on-seek / previous-restart / engine deinit / dead NowPlaying branch / `PlayQueue` decode (the queue isn't persisted) / repeated `.failed` / mid-stream failure: leave.
- **1.4:** accessibility and design polish: leave for M7.
- **1.5:**
  - promoted: Keychain no-escape (part of I3);
  - leave: client-cert codes, developer copy (the owner is a developer), failover cooldown, `errorWatch` leak (singleton), AX clipping, raw error as hint, `.env` parsing, `playAll` fan-out, lock-screen like state, Magic Tap, dead-home latency (put the about 20 s away-from-home first load in the RUNBOOK), `loadMore`.
- **2.1, 3, 4.1, 4.2, 4.3:** leave. None changes what the owner sees on the M5 path.
- **5.1, 5.2, 5.3:** leave. The tap race is mitigated by the disabled button. Clean-up polls while the switch is off: about 5 s of idle work, acceptable. The rest are rare races or pre-release data.
  - Note: the ledgered "add a G1 grep check in M8" was not added as a script. A grep of `httpMethod` / POST|PUT|DELETE today shows no write outside `WriteGate` apart from Navidrome `auth/login`, so it can wait.
- **Parked 5.3 #1** (`monitorExisting` overwrites its own unclear entry): **resolved** in `15b982b`. `isOwnPending` → `resolveOwnPending`, and `sendMonitor` persists before the PUT.
- **Parked 5.3 #2** (the owner adds the same artist concurrently): leave, as ruled.
- **8.1 / 8.2:** promoted: wrong-key copy (part of I4). Leave: `unexpectedData` aggregation (sign-in `connect()` errors already map it; the probe never produces it), `maxPages < 1`, log-lint gaps, test tidies.

## Declined to judge

- M6 (Finds mode, Keep / Not for me) and M7 (Appearance, Classic/Immersive): deferred by the reorder ruling, not reviewed as missing.
- Visual design and accessibility polish: task-scoped reviews covered it (1.4 ledger).
- RUNBOOK.md and MORNING-BRIEF.md content: another agent is editing them. I only cite them as evidence (I2, I5).
- Release-build ATS behaviour: by ruling M2 the owner runs Debug.
- Lidarr 2.x vs 3.x API differences (`albumsToMonitor`, `history/since` shape): verified only against the 3.2 dev stack. I can't judge the owner's version from here, so it is listed as a test-day check, not an issue.
- The app UI test suite: not run, because `test-app.sh` regenerates the Xcode project in a read-only review.

## Assessment

**Ready for the owner's M5 test: with fixes.**

The architecture holds across module boundaries. The write safety, per-instance scoping, runner lifecycle and failover are all sound, and I found no data-loss or unsafe-write path. I1, I2 and I4 should be fixed first: about an hour of app-level work, mostly copy, plus a one-line state fix. They are the issues the owner is most likely to hit tomorrow, and they would make a working system look broken. I3 is required before the first device or CarPlay use. I5 is documentation.
