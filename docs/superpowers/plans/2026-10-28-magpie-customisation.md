# Magpie 0.0.1 Customisation Round Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Magpie 0.0.1. The owner gets the network fix first, as an interim TestFlight build: plain http to the home server, Local Network permission and connection diagnostics. The full 0.0.1 then adds:
- a configurable Home and Library, and grouped genres;
- streaming and download quality, ReplayGain and a sleep timer;
- downloads and offline mode;
- two-path scrobbling with a configurable threshold;
- CarPlay coverage of all of it.

**Architecture:**
- Release ATS allows arbitrary loads. Magpie's own plain-http consent gate is the control, and it gets adversarial tests.
- A small `LocalNetworkAccess` helper requests the Local Network permission up front, detects denial and feeds a connection-diagnosis classifier.
- One `Preferences` value (MagpieCore, one UserDefaults key per area) drives the customisation. `AppModel+Preferences.swift` owns it, and both the phone UI and CarPlay observe it.
- Pure rules live in the packages, where `swift test` covers them: preference validation, the scrobble threshold, ReplayGain, the audio store, the offline catalog, the scrobble queue and genre grouping. App wiring goes into new `AppModel+X.swift` extensions and new screen files.
- Downloads and pre-downloads share one on-disk audio store per server scope. The player reads local files first and never swaps an already-enqueued item, which keeps gapless playback intact.

**Tech Stack:** iOS 27, Swift 6 (strict concurrency), SwiftUI, CarPlay templates, AVFoundation (`AVQueuePlayer`, `AVMutableAudioMix`), Network (`NWPathMonitor`, `NWBrowser`, `NWConnection`), URLSession download tasks, Swift Testing, XcodeGen (`project.yml`), Swift package `Packages/MagpieKit`.

**Spec:** `docs/superpowers/specs/2026-10-28-magpie-customisation-design.md` (revised §8, commit 45a20c5). Read it alongside this plan; references to §n point into it.

## Global Constraints

- **G0.** Tests talk only to the dev stack on 127.0.0.1/localhost (`dev/`, `docs/RUNBOOK.md`). Hosted tests run only on the "Magpie Tests" simulator (`scripts/test-sim.sh`). Never touch the owner's real servers. Never delete or modify owner data.
- **G1.** Lidarr writes go only through `LidarrWriteGate`, and `scripts/check-writes.sh` stays green. The one new allowlist entry is the ListenBrainz `submit-listens` POST (Task 16).
- **D29 on both scrobble paths.** A find is never sent as "now playing" or as a play, whether through Navidrome or directly to ListenBrainz. The same fail-closed `FindsIdentity.isFind` check runs before every send, and again when a queued play is dequeued.
- **D3.** Every state shows as text plus an SF Symbol, never as shape or colour alone. The symbols are fixed:

  | State | Symbol |
  |---|---|
  | Downloaded | `arrow.down.circle.fill` |
  | Downloading | `arrow.down.circle.dotted` |
  | Waiting for Wi-Fi | `wifi` |
  | Downloads are full | `externaldrive.badge.exclamationmark` |
  | You're offline | `wifi.slash` |
  | Local network access off (phone and car) | `network.slash` |
  | Local network pending (car) | `iphone` |
  | Not encrypted | `lock.open` |
- **D12.** CarPlay tab roots are list templates. At most 2 pushes go below a tab (`CPNavigator.maxBrowseDepth = 3`). Leaves play and never push. State copy describes and doesn't instruct; the one recorded exception is the spec §8 line "Open Magpie on your iPhone once to allow local network access" (written to `docs/decisions.md` as D33 in Task 3).
- **D15.** Text styles and Dynamic Type, 44 pt targets, VoiceOver labels and values, and Reduce Motion are respected. Reorderable rows also offer VoiceOver "Move up" and "Move down" actions.
- **§5 voice.** Plain and warm. The following copy is fixed; use it verbatim.
  - "Your server couldn't convert this song; playing the original"
  - "Gapless works best with Original"
  - "Downloaded", "Downloading 3 of 12" (pattern `Downloading \(done) of \(total)`), "Waiting for Wi-Fi", "Downloads are full"
  - "You're offline", "Recently played on this phone", "Reset to default order", "Not encrypted"
  - "If your Navidrome also sends plays to ListenBrainz, they'll be counted twice."
  - "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network.", with the buttons "Open Settings" and "Allow local network access"
  - "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533."
  - CarPlay: "Local network access is off for Magpie" and "Open Magpie on your iPhone once to allow local network access"
- **Release ATS (§8, revised).**
  - Release and Debug both have exactly `NSAppTransportSecurity { NSAllowsArbitraryLoads: true }`: no `NSAllowsLocalNetworking`, no `NSAllowsArbitraryLoadsInWebContent` and no `NSAllowsArbitraryLoadsForMedia` (any of these makes iOS ignore arbitrary loads).
  - The Debug post-build swap script is removed.
  - `NSLocalNetworkUsageDescription` and `NSBonjourServices = ["_http._tcp"]` are present.
- **Consent gate (the control).** No credential (the password, the Lidarr API key) is sent over plain http to a public host before the owner consents to that origin.
  - "Local" means loopback, 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, IPv6 ULA and link-local, single-label names, `.local` and `*.ts.net`. It is judged by name class only, with no DNS-based upgrade.
  - Settings marks public plain-http addresses "Not encrypted".
- **Version and builds.**
  - `MARKETING_VERSION` is 0.0.1, in `project.yml` only. Code reads it from the bundle at runtime (`AppModel.marketingVersion`, `ListenBrainzClient`/`MusicBrainzClient` take the version as a parameter), and `check-release.sh` reads the expected value from `project.yml`. No other file holds the literal.
  - The interim TestFlight build is `--build 2` (Task 4). The final one is `--build 3` (Task 29).
  - The tag is `v0.0.1`.
- **Settings.** Every new customisation setting sits in one of four Settings `Section`s, each with a default: "Home & Library", "Playback", "Downloads & Storage" and "Scrobbling". Each task that adds a screen adds it as a NavigationLink inside its named `Section` (creating the section if it isn't there yet). Nothing new is required.
- **Secrets.**
  - Tokens and passwords live only in the Keychain.
  - No URL carrying Subsonic auth (`u`, `t`, `s`) is ever written to a file. Logs go through `Log.request` / `Log.category` only.
  - The ListenBrainz token is read from the Keychain at send time.
- **Size rule.** New work goes in new files. `App/AppModel.swift` (759 lines), `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift` (852) and `RequestRunner.swift` (1146) only get the hook lines each task names.
- **Line references** (`file:NN-MM`) are to commit 45a20c5. Earlier tasks shift them, so match on the quoted code.
- **New files** are picked up by `xcodegen generate` (folder sources). Never hand-edit `Magpie.xcodeproj`.
- **Commits** end with a blank line and then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Controller-only steps.** Task 4 and Task 29 are controller-only in full: archives for upload, uploads, the merge to `main`, the tag and any push. Implementers never upload.
- **Fakes.** When a task adds a requirement to `CarPlayLibrary`, `PlaybackEngine` or `StreamURLProvider`, it also updates every fake and adapter that conforms (`FakeEngine`, `FakeURLs`, `CarPlayLibraryAdapter`, any test library).
- **Tests assert.** Every test has real `#expect` (or `#require`) assertions with the values shown. None is empty or comment-only.

### Commands used by every task

- **PKG `<Filter>`:** `cd /Users/dev/Dev/navidrome_player/Packages/MagpieKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Filter>`
- **APP `<Suite>`:** `cd /Users/dev/Dev/navidrome_player && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Magpie.xcodeproj -scheme Magpie -destination "platform=iOS Simulator,id=$(scripts/test-sim.sh)" -only-testing:MagpieTests/<Suite> -quiet`
- **Expected failures:**
  - A missing symbol fails with `error: cannot find '<Name>' in scope` (PKG), or with `** TEST FAILED **` plus that compiler error (APP).
  - A failing assertion prints `Expectation failed:`.
- **Passes:** PKG ends with `Test run with N tests passed`. APP exits 0 with no `** TEST FAILED **`.
- **Regression gate (the end of every task):** `scripts/check-writes.sh`, `scripts/test-packages.sh` and `scripts/test-app.sh` all pass. D25's known `testConnectLidarrShowsSummary` flake may be re-run once.

## Review Focus

These are the five conditions the spec implies but no feature test exercises, most likely to bite first. Each one has a pinned test in the task that owns the code.

1. **The owner's own setup.** `http://homeserver:4533` resolves only through Tailscale. Local Network may have been denied or never asked.
   - When Tailscale is off and the name doesn't resolve, the diagnosis says the name wasn't found, not that local network access is off.
   - It blames Local Network only when that is the cause: a `.local` lookup, or a LAN address while the permission is denied.
   - Test: Task 3 `diagnosisOrderForOwnersSetup`.
2. **Public plain-http hosts in disguise.** Examples: `http://MUSIC.example.com.`, `http://nas.:4533`, `http://0x7f000001`, `http://10.0.0.1.evil.com`, `http://192.168.1.20.nip.io`, `http://localhost.evil.com`. With arbitrary loads on, the consent gate is the only control. Each one must still ask before any request carries a credential. Test: Task 2 `disguisedPublicHostsStillNeedConsent`.
3. **Sign-out while downloads or pre-downloads are in flight.** A completion that arrives after sign-out must not write into the erased scope or into the next account's scope. Test: Task 12 `lateCompletionAfterSignOutIsDiscarded`.
4. **The network flips from Wi-Fi to mobile data mid-download.**
   - Manual downloads without "Download on mobile data" stop and show "Waiting for Wi-Fi", then resume on Wi-Fi.
   - No partial file ever reaches the store.
   - Test: Task 11 `networkFlipMidDownloadWaitsAndLeavesNoPartialFile`.
5. **Going offline with a queue that holds songs not on the phone.**
   - Playback carries on with the next song that is on the phone, instead of stopping on a failed stream.
   - The queue itself isn't edited.
   - Test: Task 14 `offlineSkipsToNextLocalSong`.

Edge tests that are pinned in their tasks but not listed above:
- storage filling partway through an album (Task 11 `fullMidAlbumKeepsWhatArrived`);
- a revoked ListenBrainz token with plays queued (Task 17 `unauthorizedStopsListenBrainzDrainAndKeepsQueue`).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `project.yml`, `scripts/check-release.sh`, `docs/TESTFLIGHT.md`, `ListenBrainzKit/MusicBrainzClient.swift`, `App/AppModel+Version.swift` (new) | Version 0.0.1 from `project.yml` only, and the user agent | 1 |
| `project.yml`, `scripts/check-release.sh`, `App/ServerAddress.swift`, `App/Screens/Settings/SettingsView.swift`, `docs/{RUNBOOK,TESTFLIGHT}.md` | Release arbitrary loads, wider "local" class, the "Not encrypted" mark, consent-gate tests | 2 |
| `App/Network/LocalNetworkAccess.swift` (new), `App/Network/NWBrowserLocalNetworkProber.swift` (new), `App/Screens/Connect/ConnectDiagnosis.swift` (new), `App/Screens/Connect/{ConnectView,ConnectErrorCopy}.swift`, `App/AppModel.swift` (hooks), CarPlay state rows | Local Network permission, denial detection, diagnostics | 3 |
| none (controller) | Interim TestFlight build 2 | 4 |
| `MagpieCore/{OrderedVisibility,Preferences}.swift` (new), `App/PreferencesStore.swift` (new), `App/AppModel+Preferences.swift` (new) | Every preference area, the one lossy decode strategy, the store, the fan-out | 5 |
| `MagpieCore/Models.swift`, `NavidromeKit/{NavidromeClient,SubsonicDTOs,NativeDTOs,Mapping}.swift` | Genre, ReplayGain, starred, genre calls, sorted song pages | 6 |
| `Playback/{PlaybackEngine,Player,AVQueueEngine}.swift` | The current URL stays put, upcoming refresh, fallback, volumes, playability, stop after current | 7 |
| `MagpieCore/NetworkStatus.swift` (new), `App/Playback/NetworkMonitor.swift` (new), `App/AppModel+Playback.swift` (new), `App/Playback/NavidromeAdapters.swift`, `App/Screens/Settings/PlaybackSettingsView.swift` (new) | Quality per network, transcode hint, Playback settings | 8 |
| `MagpieCore/ReplayGain.swift` (new), `Playback/AVQueueEngine.swift` | ReplayGain | 9 |
| `Playback/SleepTimer.swift` (new), `App/Screens/NowPlaying/SleepTimerMenu.swift` (new) | Sleep timer | 10 |
| `Playback/Storage/{AudioEntry,AudioStore}.swift` (new), `App/Downloads/{DownloadManager,AudioFetcher,DownloadStatus}.swift` (new) | The audio store and download jobs | 11 |
| `App/AppModel+Downloads.swift` (new), `App/Screens/Shared/DownloadButton.swift` (new), `App/Screens/Settings/DownloadsSettingsView.swift` (new) | Downloads in the app, Downloads & Storage settings | 12 |
| `Playback/Storage/PreDownloadPlan.swift` (new), `App/AppModel+PreDownload.swift` (new) | Local files first, pre-download, cache upkeep | 13 |
| `Playback/Storage/OfflineCatalog.swift` (new), `App/AppModel+Offline.swift` (new), `App/Screens/Downloads/DownloadsView.swift` (new), `App/Screens/Search/OfflineSearch.swift` (new) | Offline mode | 14 |
| `Playback/{PlaybackEngine,Player}.swift`, `App/Playback/ScrobbleSettings.swift` (new) | The threshold by listened time | 15 |
| `ListenBrainzKit/ListenBrainzClient+Submit.swift` (new), `scripts/check-writes.sh` | submit-listens | 16 |
| `Playback/ScrobbleQueue.swift` (new), `App/Playback/ScrobbleRouter.swift` (new), `App/AppModel+Scrobbling.swift` (new), `App/Screens/Settings/ScrobblingSettingsView.swift` (new) | Two destinations, the queue, Scrobbling settings | 17 |
| `Search/GenreGroups.swift` (new) | The grouping table | 18 |
| `App/AppModel+Genres.swift` (new), `App/Screens/Genres/*.swift` (new) | Genre screens | 19 |
| `App/AppModel+Home.swift` (new), `App/Screens/Home/HomeView.swift`, `App/Screens/Settings/{OrderedVisibilityEditor,HomeLayoutView}.swift` (new) | The Home layout and the shared editor | 20 |
| `App/Screens/Library/{LibraryView,SongsListView,FavouritesView}.swift`, `App/Screens/Settings/LibraryLayoutView.swift` (new) | Library rows, Songs, Favourites | 21 |
| `CarPlayUI/CustomisationRows.swift` (new), `CarPlayUI/CarPlayController+Customisation.swift` (new), `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift` (new) | CarPlay layout | 22 |
| Same CarPlay files | CarPlay genres, downloads, offline and sleep | 23 |
| `docs/reviews/security-0.0.1.md`, `docs/FLOWS.md`, `docs/decisions.md`, flow-verify tests, `docs/reviews/carplay-0.0.1/` | Process | 24–29 |

---

## Task 1: Version 0.0.1 (one source)

**Files:**
- Modify: `project.yml:14`. `MARKETING_VERSION: "0.0.1"`. This is the only place the literal lives.
- Modify: `scripts/check-release.sh:25`. Read the expected value from `project.yml` instead of a literal:
  ```bash
  want_version="$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' project.yml)"
  [ -n "$want_version" ] || fail "MARKETING_VERSION not found in project.yml"
  [ "$(pb CFBundleShortVersionString "$plist")" = "$want_version" ] || fail "$variant: CFBundleShortVersionString is not $want_version"
  ```
  Put the `want_version` lines once, above `check_variant`.
- Create: `App/AppModel+Version.swift`
- Modify: `App/Screens/Settings/SettingsView.swift:47-52`. `version` uses `AppModel.marketingVersion` and the bundle's `CFBundleVersion`, with no literal fallback other than `"unknown"`.
- Modify: `Packages/MagpieKit/Sources/ListenBrainzKit/MusicBrainzClient.swift:63-74`. Remove `defaultUserAgent`. Add `userAgent(version:)`. The `userAgent:` init parameter becomes required.
- Modify: `App/AppModel.swift:707`. `MusicBrainzClient(transport: transport, userAgent: MusicBrainzClient.userAgent(version: Self.marketingVersion))`.
- Modify: every other `MusicBrainzClient(` call site (tests: `MusicBrainzTests`, `RequestsTests/RunnerHarness.swift` and any found by `grep -rn "MusicBrainzClient(" Packages Tests App`). Pass `userAgent: MusicBrainzClient.userAgent(version: "test")`.
- Modify: `docs/TESTFLIGHT.md`. "The version stays 1.0" becomes "The version is 0.0.1 (set in project.yml)". "Version 1.0" becomes "Version 0.0.1". Add: build numbers keep rising; build 2 is the interim network build and build 3 the 0.0.1 release.
- Test: `Packages/MagpieKit/Tests/ListenBrainzKitTests/MusicBrainzTests.swift:44` (update) and `Tests/MagpieTests/VersionAppTests.swift`

**Interfaces:**
- Produces:
  - On `MusicBrainzClient`: `public static func userAgent(version: String) -> String`, formatted `"Magpie/\(version) ( https://github.com/bleak-rooster )"`. `init(transport:userAgent:limiter:)` with `userAgent` required.
  - On `AppModel`: `nonisolated static var marketingVersion: String`. It reads `CFBundleShortVersionString` from `Bundle.main`, falling back to `"unknown"`.
- Consumed later: Task 16 passes `AppModel.marketingVersion` into `ListenBrainzClient` as `clientVersion`.

- [ ] **Step 1: Write the failing tests.** In MusicBrainzTests, build the client with `userAgent: MusicBrainzClient.userAgent(version: "9.9.9")`, change line 44's expectation to `"Magpie/9.9.9 ( https://github.com/bleak-rooster )"`, and add:

```swift
@Test func userAgentCarriesVersion() {
    #expect(MusicBrainzClient.userAgent(version: "0.0.1") == "Magpie/0.0.1 ( https://github.com/bleak-rooster )")
}
```

`VersionAppTests` compares the bundle with `project.yml`, so neither the test nor the code holds a second copy:

```swift
@Test func bundleVersionComesFromProjectYml() throws {
    let yml = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "project.yml"), encoding: .utf8)
    let line = try #require(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
    let declared = line.split(separator: "\"")[1]
    #expect(declared == "0.0.1")
    #expect(AppModel.marketingVersion == String(declared))
    #expect(SettingsView.version.hasPrefix("\(declared) ("))
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `MusicBrainzTests`. Expected: FAIL (`userAgent(version:)` missing). Then run APP `VersionAppTests`. Expected: FAIL (`declared == "1.0"`).
- [ ] **Step 3: Make the changes listed under Files.**
- [ ] **Step 4: Run PKG `MusicBrainzTests`, PKG `RequestsTests` and APP `VersionAppTests`.** Expected: PASS.
- [ ] **Step 5: Run `scripts/check-release.sh`.** Expected: the last line is `check-release: OK`.
- [ ] **Step 6: Run `grep -rn '"0\.0\.1"\|"1\.0"' App Packages/MagpieKit/Sources scripts`.** Expected: no hits.
- [ ] **Step 7: Commit** with the message "Version 0.0.1 from project.yml only (bundle, release check, Settings, MusicBrainz user agent)" plus the trailer.

---

## Task 2: Release ATS allows arbitrary loads; the consent gate is the control

**Files:**
- Modify: `project.yml:94-95`. Replace `NSAllowsLocalNetworking: true` with `NSAllowsArbitraryLoads: true`.
- Modify: `project.yml:98-107`. Delete the "Debug-only ATS arbitrary loads" post-build script. Both configurations now carry the same dictionary.
- Modify: `scripts/check-release.sh:28-29`. Replace both lines with:
  ```bash
  [ "$(pb NSAppTransportSecurity:NSAllowsArbitraryLoads "$plist")" = "true" ] || fail "$variant: Release lacks NSAllowsArbitraryLoads"
  for k in NSAllowsLocalNetworking NSAllowsArbitraryLoadsInWebContent NSAllowsArbitraryLoadsForMedia; do
    pb "NSAppTransportSecurity:$k" "$plist" >/dev/null && fail "$variant: $k present (iOS would ignore arbitrary loads)"
  done
  ```
- Modify: `App/ServerAddress.swift:92-100`. `isPrivate` also returns true for `isTailscaleName` (new: host `ts.net` or ending in `.ts.net` on a label boundary). Leave `isLocalNetwork` and `atsBlocksPlainHTTP` unchanged. They still model local-networking-only ATS and are only consulted when `atsAllowsArbitraryLoads` is false.
- Modify: `App/AppModel.swift:610-615`. Split out `nonisolated static func allowsArbitraryLoads(ats: [String: Any]?) -> Bool`. `bundleAllowsArbitraryLoads` calls it with the bundle's dictionary.
- Modify: `App/Screens/Settings/SettingsView.swift:56-70`. Each server address with `ServerAddress.isUnencryptedPublic` shows the trailing label "Not encrypted" (symbol `lock.open`, D3), and Lidarr's summary row does the same.
- Modify: `App/Screens/Connect/ConnectErrorCopy.swift`. Add `static let notEncrypted = "Not encrypted"`.
- Modify: `docs/TESTFLIGHT.md`, step 9 plus "What is set for you" plus "Not certain".
  - Release now allows plain http to any address.
  - Magpie asks before sending a password unencrypted to an address outside home or Tailscale.
  - Add the App Store review justification for `NSAllowsArbitraryLoads`: "user-supplied self-hosted media server addresses".
  - Remove "is blocked" for ts.net and 100.x.
- Modify: `docs/RUNBOOK.md`. Same address forms.
- Modify: `Tests/MagpieTests/ATSAppTests.swift:99-108`. Drop `#if DEBUG` from `debugBuildAllowsArbitraryLoads` and rename it `everyBuildAllowsArbitraryLoads`.
- Create: `Tests/MagpieTests/ATSReleasePolicyTests.swift`
- Create: `Tests/MagpieTests/ConsentGateTests.swift`

**Interfaces:**
- Produces:
  - `ServerAddress.isTailscaleName(_ url: URL) -> Bool`
  - `AppModel.allowsArbitraryLoads(ats:) -> Bool`
  - `ConnectErrorCopy.notEncrypted`
- Unchanged and still tested: the pre-refusal path (`atsBlocks` with `atsAllowsArbitraryLoads = false`, which `ATSAppTests.makeModel` sets).

- [ ] **Step 1: Write the failing tests.**

  `ATSReleasePolicyTests` checks the generated `App/Info.plist`, which `xcodegen generate` writes from `project.yml`. That is the dictionary every configuration ships.

```swift
/// What iOS does with a plain-http URL given an ATS dictionary (the documented rules Magpie relies on).
private struct ATSOracle {
    let ats: [String: Any]
    func blocks(_ url: URL) -> Bool {
        let overrides = ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"]
        if ats["NSAllowsArbitraryLoads"] as? Bool == true, overrides.allSatisfy({ ats[$0] == nil }) { return false }
        guard ats["NSAllowsLocalNetworking"] as? Bool == true else { return true }
        return !(ServerAddress.isLoopback(url) || ServerAddress.isLocalNetwork(url))
    }
}

@Suite struct ATSReleasePolicyTests {
    static let releaseATS: [String: Any] = {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "App/Info.plist")
        return (NSDictionary(contentsOf: plist) as! [String: Any])["NSAppTransportSecurity"] as! [String: Any]
    }()

    @Test func releaseDictionaryIsArbitraryLoadsOnly() {
        #expect(Self.releaseATS as NSDictionary == ["NSAllowsArbitraryLoads": true] as NSDictionary)
        #expect(AppModel.allowsArbitraryLoads(ats: Self.releaseATS))
    }

    @Test(arguments: ["http://homeserver:4533", "http://192.168.0.77:4533", "http://10.0.0.5:4533", "http://nas.local:4533",
                      "http://100.64.10.20:4533", "http://homebox.tail1234.ts.net:4533", "http://music.example.com", "http://8.8.8.8"])
    func gateAgreesWithReleaseATS(_ text: String) {
        let url = URL(string: text)!
        let gate = ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: AppModel.allowsArbitraryLoads(ats: Self.releaseATS))
        #expect(gate == ATSOracle(ats: Self.releaseATS).blocks(url))
        #expect(!gate)
    }

    @Test func preRefusalPathStillMatchesLocalNetworkingATS() {
        let localOnly: [String: Any] = ["NSAllowsLocalNetworking": true]
        for text in ["http://100.64.10.20:4533", "http://nas:4533", "http://music.example.com"] {
            let url = URL(string: text)!
            #expect(ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: false) == ATSOracle(ats: localOnly).blocks(url))
        }
    }
}
```

`ConsentGateTests` are adversarial. They copy the `ATSAppTests` fixture (transport stubs, store, defaults). Their own `makeModel()` builds the model the same way, then sets `model.atsAllowsArbitraryLoads = true` (the Release behaviour) before returning it:

```swift
@Test func noCredentialBeforeConsent() async throws {
    let model = makeModel()
    await #expect(throws: PlainHTTPConsentRequired.self) {
        try await model.signIn(urls: [URL(string: "http://music.example.com:4533")!], username: "admin", password: "pw-secret")
    }
    #expect(transport.inner.requests.isEmpty, "not even a ping before consent")
}

@Test func consentIsPerHostAndAHostChangeReasks() async throws {
    let model = makeModel()
    model.allowPlainHTTP([URL(string: "http://a.example.com:4533")!])
    await #expect(throws: PlainHTTPConsentRequired.self) {
        try await model.signIn(urls: [URL(string: "http://b.example.com:4533")!], username: "admin", password: "pw")
    }
    await #expect(throws: PlainHTTPConsentRequired.self) {   // origin includes the port
        try await model.signIn(urls: [URL(string: "http://a.example.com:8080")!], username: "admin", password: "pw")
    }
    #expect(transport.inner.requests.isEmpty)
}

@Test func mixedListAsksOnlyForThePublicOne() async throws {
    do {
        try await makeModel().signIn(urls: [URL(string: "http://nas:4533")!, URL(string: "http://music.example.com")!],
                                     username: "admin", password: "pw")
        Issue.record("signed in")
    } catch let e as PlainHTTPConsentRequired {
        #expect(e.urls == [URL(string: "http://music.example.com")!])
    }
}

@Test func lidarrKeyNeedsConsent() async throws {
    await #expect(throws: PlainHTTPConsentRequired.self) {
        _ = try await makeModel().connectLidarr(base: URL(string: "http://lidarr.example.com:8686")!, apiKey: "key-secret")
    }
    #expect(!transport.inner.requests.contains { $0.value(forHTTPHeaderField: "X-Api-Key") != nil })
}

@Test(arguments: ["http://100.64.10.20:4533", "http://nas.tail0a1b2c.ts.net:4533", "http://[fd00::1]:4533",
                  "http://[fe80::1]:4533", "http://homeserver:4533", "http://nas.local:4533", "http://192.168.1.20:4533"])
func localAndTailscaleNeedNoConsent(_ text: String) async throws {
    try await makeModel().signIn(urls: [URL(string: text)!], username: "admin", password: "pw")
    #expect(transport.inner.requests.contains { $0.url?.path.hasSuffix("/auth/login") == true })
}

@Test(arguments: ["http://MUSIC.example.com.", "http://nas.:4533", "http://0x7f000001", "http://134744072",
                  "http://10.0.0.1.evil.com", "http://192.168.1.20.nip.io", "http://localhost.evil.com",
                  "http://evil-ts.net", "http://nas.ts.net.evil.com", "http://[2001:db8::1]:4533"])
func disguisedPublicHostsStillNeedConsent(_ text: String) async throws {   // Review Focus 2
    await #expect(throws: PlainHTTPConsentRequired.self) {
        try await makeModel().signIn(urls: [URL(string: text)!], username: "admin", password: "pw-secret")
    }
    #expect(!transport.inner.requests.contains { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("pw-secret") == true })
}

@Test func settingsLabelsPublicPlainHTTP() {
    #expect(ConnectErrorCopy.notEncrypted == "Not encrypted")
    #expect(ServerAddress.isUnencryptedPublic(URL(string: "http://music.example.com")!))
    #expect(!ServerAddress.isUnencryptedPublic(URL(string: "http://nas.tail0a1b2c.ts.net:4533")!))
    #expect(!ServerAddress.isUnencryptedPublic(URL(string: "https://music.example.com")!))
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `ATSReleasePolicyTests` and APP `ConsentGateTests`.
  - Expected: FAIL. The dictionary still has local networking, `allowsArbitraryLoads(ats:)` is missing, and the ts.net consent cases ask.
- [ ] **Step 3: Implement the project.yml, check-release, ServerAddress, AppModel and Settings changes.**
- [ ] **Step 4: Run APP `ATSReleasePolicyTests`, `ConsentGateTests` and `ATSAppTests`.** Expected: PASS.
- [ ] **Step 5: Run `scripts/check-release.sh`.** Expected: `check-release: OK`.
- [ ] **Step 6: Update TESTFLIGHT and RUNBOOK as listed, then commit:**

```bash
git add project.yml scripts/check-release.sh App/ServerAddress.swift App/AppModel.swift App/Screens/Settings/SettingsView.swift App/Screens/Connect/ConnectErrorCopy.swift docs/TESTFLIGHT.md docs/RUNBOOK.md Tests/MagpieTests/ATSAppTests.swift Tests/MagpieTests/ATSReleasePolicyTests.swift Tests/MagpieTests/ConsentGateTests.swift
git commit -m "ATS: Release allows arbitrary loads; consent gate tested adversarially; Tailscale counts as local

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 3: Local Network permission (asked at first launch) and connection diagnostics

**Files:**
- Create: `App/Network/LocalNetworkAccess.swift` (`LocalNetworkState`, `LocalNetworkProbing`, `LocalNetworkAccess`, `NotNeededProber`)
- Create: `App/Network/NWBrowserLocalNetworkProber.swift`
- Create: `App/Screens/Connect/ConnectDiagnosis.swift`
- Modify: `project.yml` (`info.properties`, next to `NSLocalNetworkUsageDescription`, line 93): `NSBonjourServices: ["_http._tcp"]`.
- Modify: `scripts/check-release.sh`. Add:
  ```bash
  [ "$(pb NSBonjourServices:0 "$plist")" = "_http._tcp" ] || fail "$variant: NSBonjourServices missing"
  ```
  The existing `NSLocalNetworkUsageDescription` check (line 32) stays.
- Modify: `App/ServerAddress.swift`. Add `static func needsLocalNetworkPermission(_ url: URL) -> Bool`:
  - true: `isLocalNetwork(url)` (private and link-local IPv4, `.local`, single-label names), plus IPv6 ULA and link-local;
  - false: loopback, 100.64/10, `*.ts.net`, public hosts.
- Modify: `App/AppModel.swift`.
  - The init gains `localNetworkProber: (any LocalNetworkProbing)? = nil`. When nil, use `NWBrowserLocalNetworkProber()`, except under `XCTestConfigurationFilePath`, where use `NotNeededProber()` so hosted tests never meet the system prompt.
  - Add a stored `let localNetwork: LocalNetworkAccess`.
  - `ProbeFailure` (lines 36-39) gains `var localNetworkDenied = false`.
  - In `signIn` (lines 324-347), before the probe loop, call `await localNetwork.ensureAccess(for: urls)`. For each failed URL that needs permission, set `failure.localNetworkDenied = await localNetwork.checkDenied(for: base)`.
  - In `request`, a success while `ServerAddress.needsLocalNetworkPermission(session.activeBase)` calls `localNetwork.noteLocalSuccess()`.
- Modify: `App/Screens/RootView.swift:28`. Add `.task { await model.localNetwork.requestAtFirstLaunch() }` on the root `Group`, so it runs when the first scene appears, whether it shows Connect or the tabs.
- Modify: `App/Screens/Connect/ConnectErrorCopy.swift:63-112`.
  - Under `SignInError.unreachable`, `unreachableMessage` keeps the certificate and https-answer checks first. It then uses `ConnectDiagnosis` for the first failure, in address order, whose diagnosis isn't `.other`.
  - Add `static func offersOpenSettings(for error: Error) -> Bool`.
- Modify: `App/Screens/Connect/ConnectView.swift`.
  - Add the button "Allow local network access" (`connect-allow-local-network`, symbol `network`). It shows while `model.localNetwork.state != .granted` and calls `request()`.
  - When `offersOpenSettings`, add the button "Open Settings" (`connect-open-settings`), which opens `UIApplication.openSettingsURLString`.
  - The denial message shows with the symbol `network.slash` (D3).
- Modify: `App/Screens/Settings/SettingsView.swift:56-70` (Servers). Add the same two buttons and the same message, under the same conditions.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/TemplateModels.swift:108-129`.
  - Add `public enum CPLocalNetwork: Sendable, Hashable { case fine, pending, denied }`.
  - `CarPlayState` gains `.localNetworkDenied` ("Local network access is off for Magpie", `statusSymbol` `network.slash`) and `.localNetworkPending` ("Open Magpie on your iPhone once to allow local network access", `statusSymbol` `iphone`).
  - `CarPlayRows.state` gives these rows the symbol.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift`.
  - `CarPlayLibrary` (lines 12-42) gains `var localNetwork: CPLocalNetwork { get }`.
  - Where a failure becomes `.outOfReach` (`showUnavailable`, lines 344-347, and the load-failure mapping), use `.localNetworkDenied` or `.localNetworkPending` when `isOutOfReach(error)` and `localNetwork != .fine`.
- Modify: `App/CarPlay/CarPlaySceneDelegate.swift`. `CarPlayLibraryAdapter.localNetwork` is:
  - `.denied` when the state is `.denied`;
  - `.pending` when the state is `.unknown` and the active base needs permission;
  - otherwise `.fine`.
- Modify: `docs/decisions.md`. Append D33 ("CarPlay 'Open Magpie on your iPhone once to allow local network access' is an instructive exception to D12; spec §8") and D38 ("Local Network prompt triggered at first launch by `NWBrowser` on `_http._tcp`; denial read from `NWConnection` `unsatisfiedReason == .localNetworkDenied`").
- Modify: `docs/FLOWS.md` §3a, `docs/RUNBOOK.md` and `docs/TESTFLIGHT.md` step 9. Cover:
  - the prompt at first launch;
  - where Magpie appears (Settings › Privacy & Security › Local Network);
  - the button to ask again;
  - the diagnostics;
  - Open Settings.
- Test: `Tests/MagpieTests/LocalNetworkAccessTests.swift`, `Tests/MagpieTests/ConnectDiagnosisTests.swift`, `Tests/MagpieTests/CarPlayModelTests.swift` (one test)

**Interfaces:**
- Produces:

```swift
enum LocalNetworkState: String, Equatable, Sendable { case unknown, granted, denied, notNeeded }

@MainActor protocol LocalNetworkProbing: AnyObject {
    /// Triggers the system prompt if it hasn't been answered; returns .granted, .denied, or .unknown on timeout.
    func requestAccess() async -> LocalNetworkState
    /// A connection to host:port is held back by the Local Network setting right now (answers within 2 s).
    func isDenied(host: String, port: Int) async -> Bool
}

@MainActor @Observable final class LocalNetworkAccess {
    static let stateKey = "magpie.localNetwork.state"
    static let askedAtLaunchKey = "magpie.localNetwork.askedAtLaunch"
    init(prober: any LocalNetworkProbing, defaults: UserDefaults)
    private(set) var state: LocalNetworkState
    func requestAtFirstLaunch() async
    func ensureAccess(for urls: [URL]) async -> LocalNetworkState
    func request() async -> LocalNetworkState
    func noteLocalSuccess()
    func checkDenied(for url: URL) async -> Bool
}

final class NWBrowserLocalNetworkProber: LocalNetworkProbing
final class NotNeededProber: LocalNetworkProbing   // requestAccess → .notNeeded; isDenied → false

enum ConnectDiagnosis: Equatable {
    case localhostOnDevice, nameNotFound(String), atsBlocked, localNetworkDenied, timedOut(String), loginFailed,
         unreachable(String), other
    static func classify(_ error: Error, url: URL, localNetwork: LocalNetworkState, pathDenied: Bool,
                         onDevice: Bool) -> ConnectDiagnosis
    var message: String
}
```

**Rules:**
- **State.**
  - `state` is persisted under `stateKey`. It is `granted` or `denied`, or `unknown` before any answer.
  - `notNeeded` is returned but never persisted.
- **`requestAtFirstLaunch()`** asks exactly once per install:
  - If `askedAtLaunchKey` is set, it does nothing.
  - Otherwise it sets the key, calls `prober.requestAccess()`, and stores a `granted` or `denied` answer.
- **`request()`** (the button) always calls `prober.requestAccess()`. iOS shows the prompt only once; afterwards the answer reflects the setting.
- **`ensureAccess(for:)`:**
  - With no URL needing permission, it returns `.notNeeded` and calls no prober method.
  - With `state == .granted`, it returns `.granted` and calls nothing.
  - With `state == .denied`, it doesn't ask again and doesn't wait 30 s. It calls `prober.isDenied(host:port:)` for the first URL that needs permission: false sets `.granted` (turned on in Settings), true keeps `.denied`.
  - With `state == .unknown`, it calls `requestAccess()` and stores the answer.
- **`checkDenied(for:)`** is `prober.isDenied(host:port:)`. The port is the URL's, or 80/443 by scheme.
- **`noteLocalSuccess()`** sets `.granted` and persists it.
- **`NWBrowserLocalNetworkProber`.**
  - `requestAccess`:
    - It starts `NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)`.
    - `.ready` or a browse result means `.granted`.
    - `.waiting(.dns(-65570))` (kDNSServiceErr_PolicyDenied) keeps waiting while the prompt may be up. If it still stands after 30 s, the answer is `.denied`.
    - `.failed` means `.unknown`.
    - It always cancels the browser.
  - `isDenied` opens a tcp `NWConnection`. It returns true if, within 2 s, the connection is `.waiting` with `currentPath?.unsatisfiedReason == .localNetworkDenied`. It always cancels the connection.
- **`classify`**, in order:
  1. `onDevice && ServerAddress.isLoopback(url)` → `.localhostOnDevice`.
  2. `NavidromeError.badCredentials` → `.loginFailed`.
  3. An ATS URLError → `.atsBlocked`.
  4. `needsLocalNetworkPermission(url)`, a connection-class URLError, and `pathDenied || localNetwork == .denied` → `.localNetworkDenied`. Here `cannotFindHost`/`dnsLookupFailed` count only for a `.local` host.
  5. `cannotFindHost`/`dnsLookupFailed` → `.nameNotFound(host)`.
  6. `timedOut` → `.timedOut(hostAndPort)`.
  7. Other connection errors (`AppModel.isConnectionError`) → `.unreachable(hostAndPort)`.
  8. Anything else → `.other`.
- **`onDevice`** is `false` under `targetEnvironment(simulator)`. Tests pass it explicitly.
- **Messages:**
  - `.localNetworkDenied`: "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network."
  - `.localhostOnDevice`: "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533."
  - `.nameNotFound(h)`: "This iPhone can't find \(h); check the name, or use the server's address instead."
  - `.timedOut(h)`: "\(h) didn't answer in time; check the server is on and reachable from this iPhone."
  - `.atsBlocked`: `ConnectErrorCopy.needsHTTPS`.
  - `.loginFailed`: `ConnectErrorCopy.badCredentials`.
  - `.unreachable(h)`: `ConnectErrorCopy.unreachable(h)`.
  - `.other`: `ConnectErrorCopy.generic`.
- **`offersOpenSettings`** is true exactly when the chosen diagnosis is `.localNetworkDenied`.

- [ ] **Step 1: Write the failing tests.** Two helpers: `freshDefaults()` returns `UserDefaults(suiteName: "magpie-tests-ln-\(UUID())")!`, and `lan` is `URL(string: "http://192.168.1.2:4533")!`. `makeModel(prober:)` is the `ATSAppTests.makeModel()` initialiser plus `localNetworkProber: prober`.

```swift
@MainActor final class FakeProber: LocalNetworkProbing {
    var answer: LocalNetworkState = .granted
    var denied = false
    private(set) var requestCalls = 0
    private(set) var deniedChecks: [String] = []
    private(set) var requestsSeenAtCall: [Int] = []
    var onRequest: () -> Int = { 0 }
    func requestAccess() async -> LocalNetworkState { requestCalls += 1; requestsSeenAtCall.append(onRequest()); return answer }
    func isDenied(host: String, port: Int) async -> Bool { deniedChecks.append("\(host):\(port)"); return denied }
}

@MainActor @Suite(.serialized) struct LocalNetworkAccessTests {
    @Test(arguments: [("http://192.168.1.20:4533", true), ("http://10.0.0.5", true), ("http://169.254.1.1", true),
                      ("http://nas:4533", true), ("http://nas.local:4533", true), ("http://[fd00::1]:4533", true),
                      ("http://[fe80::1]:4533", true), ("http://127.0.0.1:4533", false), ("http://localhost:4533", false),
                      ("http://100.64.10.20:4533", false), ("http://nas.tail1.ts.net:4533", false), ("https://music.example.com", false)])
    func needsPermission(_ text: String, _ expected: Bool) {
        #expect(ServerAddress.needsLocalNetworkPermission(URL(string: text)!) == expected)
    }

    @Test func firstLaunchAsksExactlyOnce() async {
        let d = freshDefaults(), p = FakeProber()
        let a = LocalNetworkAccess(prober: p, defaults: d)
        await a.requestAtFirstLaunch()
        await a.requestAtFirstLaunch()
        await LocalNetworkAccess(prober: p, defaults: d).requestAtFirstLaunch()   // relaunch
        #expect(p.requestCalls == 1)
        #expect(a.state == .granted && d.string(forKey: LocalNetworkAccess.stateKey) == "granted")
    }

    @Test func launchingTheAppTriggersTheRequestOnce() async throws {
        let p = FakeProber()
        let model = makeModel(prober: p)
        await model.localNetwork.requestAtFirstLaunch()   // what RootView's .task runs
        #expect(p.requestCalls == 1)
        await model.localNetwork.requestAtFirstLaunch()
        #expect(p.requestCalls == 1)
    }

    @Test func buttonAlwaysAsks() async {
        let p = FakeProber(); let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        await a.requestAtFirstLaunch(); _ = await a.request(); _ = await a.request()
        #expect(p.requestCalls == 3)
    }

    @Test func notNeededSkipsProber() async {
        let p = FakeProber(); let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [URL(string: "https://music.example.com")!]) == .notNeeded)
        #expect(p.requestCalls == 0 && p.deniedChecks.isEmpty)
    }

    @Test func grantedPersistsAndIsNotReasked() async {
        let d = freshDefaults(), p = FakeProber()
        #expect(await LocalNetworkAccess(prober: p, defaults: d).ensureAccess(for: [lan]) == .granted)
        let again = LocalNetworkAccess(prober: p, defaults: d)
        #expect(again.state == .granted)
        #expect(await again.ensureAccess(for: [lan]) == .granted)
        #expect(p.requestCalls == 1 && p.deniedChecks.isEmpty)
    }

    @Test func deniedUsesTheQuickCheckNotTheSlowAsk() async {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [lan]) == .denied)
        #expect(await a.ensureAccess(for: [lan]) == .denied)
        #expect(p.requestCalls == 1, "never re-asks while denied")
        #expect(p.deniedChecks == ["192.168.1.2:4533"])
        p.denied = false   // turned on in Settings
        #expect(await a.ensureAccess(for: [lan]) == .granted && p.requestCalls == 1)
    }

    @Test func localSuccessMeansGranted() {
        let d = freshDefaults(); let a = LocalNetworkAccess(prober: FakeProber(), defaults: d)
        #expect(a.state == .unknown)
        a.noteLocalSuccess()
        #expect(a.state == .granted && d.string(forKey: LocalNetworkAccess.stateKey) == "granted")
    }

    @Test func signInAsksBeforeTheFirstRequest() async throws {
        let p = FakeProber(); p.onRequest = { transport.inner.requests.count }
        try await makeModel(prober: p).signIn(urls: [lan], username: "admin", password: "pw")
        #expect(p.requestCalls == 1 && p.requestsSeenAtCall == [0])
    }

    @Test func httpsPublicDoesNotAsk() async throws {
        let p = FakeProber()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)   // also answers music.example.com
        try await makeModel(prober: p).signIn(urls: [URL(string: "https://music.example.com")!], username: "admin", password: "pw")
        #expect(p.requestCalls == 0 && p.deniedChecks.isEmpty)
    }

    @Test func deniedSignInExplainsAndOffersSettings() async throws {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        do {
            try await makeModel(prober: p).signIn(urls: [lan], username: "admin", password: "pw")
            Issue.record("signed in")
        } catch {
            #expect(ConnectErrorCopy.message(for: error) == ConnectDiagnosis.localNetworkDenied.message)
            #expect(ConnectErrorCopy.offersOpenSettings(for: error))
        }
    }
}
```

`HostSwitchTransport.setDown(_:with:)` (in `AppModelTests.swift:13`) already exists. Reuse it.

```swift
@Suite struct ConnectDiagnosisTests {
    let homebox = URL(string: "http://homeserver:4533")!
    func c(_ e: Error, _ u: URL, _ s: LocalNetworkState = .granted, denied d: Bool = false, device: Bool = true) -> ConnectDiagnosis {
        ConnectDiagnosis.classify(e, url: u, localNetwork: s, pathDenied: d, onDevice: device)
    }

    @Test func localhostOnDeviceOnly() {
        let url = URL(string: "http://localhost:4533")!
        #expect(c(URLError(.cannotConnectToHost), url) == .localhostOnDevice)
        #expect(c(URLError(.cannotConnectToHost), URL(string: "http://127.0.0.1:4533")!) == .localhostOnDevice)
        #expect(c(URLError(.cannotConnectToHost), url, device: false) == .unreachable("localhost:4533"))
        #expect(ConnectDiagnosis.localhostOnDevice.message == "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533.")
    }

    @Test func eachStep() {
        #expect(c(URLError(.cannotFindHost), homebox) == .nameNotFound("homeserver"))
        #expect(c(URLError(.appTransportSecurityRequiresSecureConnection), homebox) == .atsBlocked)
        #expect(c(URLError(.timedOut), URL(string: "https://music.example.com")!) == .timedOut("music.example.com"))
        #expect(c(NavidromeError.badCredentials, homebox) == .loginFailed)
        #expect(c(URLError(.networkConnectionLost), URL(string: "https://music.example.com:8443")!) == .unreachable("music.example.com:8443"))
        #expect(c(URLError(.notConnectedToInternet), URL(string: "http://192.168.1.20:4533")!, denied: true) == .localNetworkDenied)
        #expect(c(URLError(.badServerResponse), homebox) == .other)
        #expect(ConnectDiagnosis.nameNotFound("homeserver").message == "This iPhone can't find homeserver; check the name, or use the server's address instead.")
        #expect(ConnectDiagnosis.localNetworkDenied.message == "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network.")
    }

    @Test func diagnosisOrderForOwnersSetup() {                               // Review Focus 1
        #expect(c(URLError(.cannotFindHost), homebox, .denied) == .nameNotFound("homeserver"))
        #expect(c(URLError(.cannotFindHost), URL(string: "http://nas.local:4533")!, .denied) == .localNetworkDenied)
        #expect(c(URLError(.timedOut), URL(string: "http://192.168.1.20:4533")!, denied: true) == .localNetworkDenied)
        #expect(c(URLError(.timedOut), URL(string: "http://192.168.1.20:4533")!) == .timedOut("192.168.1.20:4533"))
        #expect(c(URLError(.timedOut), URL(string: "http://100.64.10.20:4533")!, .denied) == .timedOut("100.64.10.20:4533"))
    }
}
```

CarPlayModelTests:

```swift
@Test func localNetworkStateRows() {
    let denied = try! #require(CarPlayRows.state(.localNetworkDenied).flatMap(\.rows).first)
    #expect(denied.title == "Local network access is off for Magpie" && denied.statusSymbol == "network.slash")
    let pending = try! #require(CarPlayRows.state(.localNetworkPending).flatMap(\.rows).first)
    #expect(pending.title == "Open Magpie on your iPhone once to allow local network access" && pending.statusSymbol == "iphone")
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `LocalNetworkAccessTests`, then `ConnectDiagnosisTests`, then `CarPlayModelTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement the files, hook lines, `NSBonjourServices` entry, check-release line and decisions entries.**
- [ ] **Step 4: Run APP `LocalNetworkAccessTests`, `ConnectDiagnosisTests`, `CarPlayModelTests`, `ATSAppTests` and `EdgeCaseAppTests`.** Expected: PASS. The existing ConnectErrorCopy cases (certificate, https answer, needsHTTPS) still hold.
- [ ] **Step 5: Run `scripts/check-release.sh`.** Expected: `check-release: OK`.
- [ ] **Step 6: Update FLOWS §3a, RUNBOOK and TESTFLIGHT, then commit:** "Local Network: ask at first launch, detect denial, explain each failed step, Open Settings" plus the trailer.

---

## Task 4: Interim TestFlight build (controller only)

The owner can't connect on their iPhone today. This build ships Tasks 1–3 before the rest of the round. **Every step here is controller-only. Implementers don't run this task.**

- [ ] **Step 1: Bring up the dev stack.** Run `dev/bootstrap.sh`, then `dev/smoke.sh`. Expected: exit 0.
- [ ] **Step 2: Run `MAGPIE_IT=1 scripts/test-all.sh` on the `v0.0.1-custom` HEAD.** Expected: exit 0.
- [ ] **Step 3: Run `scripts/check-release.sh`.** It checks version 0.0.1, arbitrary loads only, `NSBonjourServices` and the Local Network text. Expected: `check-release: OK`.
- [ ] **Step 4: Archive and upload the default (non-CarPlay) variant.** Run `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 2 --upload`.
  - If App Store Connect refuses version 0.0.1 (a lower train than 1.0), stop and report it to the owner. Never pick another version.
  - Don't tag. `v0.0.1` is for Task 29.
- [ ] **Step 5: Send the owner a short checklist.**
  - Install build 2.
  - Connect to `http://homeserver:4533` with Tailscale on, and to the server's LAN IP with Tailscale off.
  - Confirm the Local Network prompt appears, and that Magpie is listed under Settings › Privacy & Security › Local Network.
  - If something fails, report the exact message Connect shows.
- [ ] **Step 6: Record the build number and the date in `docs/RUNBOOK.md`.** Commit "RUNBOOK: interim TestFlight build 2 (network fix)" plus the trailer.

---

## Task 5: Preferences store

**Files:**
- Create: `Packages/MagpieKit/Sources/MagpieCore/OrderedVisibility.swift`
- Create: `Packages/MagpieKit/Sources/MagpieCore/Preferences.swift`
- Create: `App/PreferencesStore.swift`
- Create: `App/AppModel+Preferences.swift`
- Modify: `App/AppModel.swift`.
  - After line 49 (`var theme: Theme`), add the stored property `var preferences: Preferences` and `@ObservationIgnored let preferencesStore: PreferencesStore`.
  - In `init` (near line 196), set `self.preferencesStore = PreferencesStore(defaults: defaults)` and `self.preferences = preferencesStore.load()`.
- Test: `Packages/MagpieKit/Tests/MagpieCoreTests/PreferencesTests.swift`, `Tests/MagpieTests/PreferencesAppTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (MagpieCore, all `public`, all `Codable`, `Hashable` and `Sendable`):

```swift
/// One generic ordered list of items with a visibility switch each. Used by Home sections and Library rows.
public struct OrderedVisibility<Item: CaseIterable & RawRepresentable & Hashable & Sendable>: Codable, Hashable, Sendable
    where Item.RawValue == String, Item.AllCases: Sendable {
    public struct Entry: Hashable, Sendable { public var item: Item; public var visible: Bool }
    public private(set) var entries: [Entry]
    public init(_ entries: [Entry])
    public var visibleItems: [Item] { get }
    /// false (and no change) when hiding `item` would leave no visible item among `keepingOneOf`.
    @discardableResult public mutating func set(_ item: Item, visible: Bool, keepingOneOf required: Set<Item> = []) -> Bool
    public mutating func move(fromOffsets: IndexSet, toOffset: Int)
    public mutating func moveUp(_ item: Item)
    public mutating func moveDown(_ item: Item)
    /// Drops duplicates (first wins), then appends items missing from `defaults` with their default visibility.
    public func normalised(against defaults: OrderedVisibility) -> OrderedVisibility
}
```

- Coding: `OrderedVisibility` encodes `[{"id": rawValue, "visible": Bool}]`. Decoding is lossy element by element: an entry with an unknown id or a wrong type is dropped. This is the only hand-written `Codable` in the file, apart from `ScrobbleRule`'s keys.
- Enums:
  - `enum HomeSection: String, CaseIterable { case jumpBackIn, madeForYou, recentlyAdded, mostPlayed, favourites, randomAlbums, playlists, genres, downloaded; var title: String }`. The titles are "Jump back in", "Made for you", "Recently added", "Most played", "Favourites", "Random albums", "Playlists", "Genres" and "Downloaded".
  - `enum LibraryRow: String, CaseIterable { case playlists, artists, albums, songs, genres, favourites, downloads, finds, requests; var title: String; var symbol: String }`.
  - `enum StreamQuality: String, CaseIterable { case original, aac256, aac160, aac96, mp3_320, mp3_192; var format: String; var maxBitRate: Int?; var title: String }`.
    - `format` is "raw", "aac" or "mp3".
    - The titles are "Original", "High · AAC 256 kbps", "Medium · AAC 160 kbps", "Low · AAC 96 kbps", "MP3 320 kbps" and "MP3 192 kbps".
    - No Opus: AVFoundation can't play Ogg Opus (spec §5, as updated in this round).
  - `enum ReplayGainMode: String { case off, track, album }`
  - `enum SleepTimerOption: String, CaseIterable { case m15, m30, m45, m60, m90, endOfSong; var seconds: TimeInterval? }`
  - `enum CacheLimit: String, CaseIterable { case mb500, gb1, gb2, gb5, gb10; var bytes: Int64 }`. Decimal sizes, from 500_000_000 to 10_000_000_000.
  - `enum DownloadsLimit: String, CaseIterable { case none, gb5, gb10, gb20, gb50; var bytes: Int64? }`
  - `enum OfflineMode: String { case automatic, on, off }`
  - `enum GenreViewMode: String { case grouped, all }`
- Areas: `protocol PreferenceArea: Codable, Hashable, Sendable { static var key: String { get }; static var defaultValue: Self { get }; func normalised() -> Self }`
  - Extension `static func decode(_ data: Data?) -> Self`. This is the single lossy strategy for all five areas (see Rules).
  - Extension `func encoded() -> Data`, which adds `"version": 1`.
- `struct LayoutPreferences: PreferenceArea`
  - Key `magpie.prefs.layout`.
  - Fields: `home: OrderedVisibility<HomeSection>`, `library: OrderedVisibility<LibraryRow>`, `showsRecentlyAdded: Bool`.
  - `static let alwaysAvailableRows: Set<LibraryRow> = [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads]`
  - `func visibleHomeSections(offline: Bool, hasListenBrainzToken: Bool, carPlay: Bool) -> [HomeSection]`
  - `func visibleLibraryRows(offline: Bool, findsSetUp: Bool, lidarrConnected: Bool, carPlay: Bool) -> [LibraryRow]`
- `struct PlaybackPreferences: PreferenceArea`
  - Key `magpie.prefs.playback`.
  - Fields: `wifi: StreamQuality`, `cellular: StreamQuality`, `replayGain: ReplayGainMode`, `sleepTimer: SleepTimerOption`.
- `struct DownloadPreferences: PreferenceArea`
  - Key `magpie.prefs.downloads`.
  - Fields: `quality`, `overMobileData`, `concurrent`, `preDownload`, `keepRecentlyPlayed`, `cacheLimit`, `downloadsLimit`, `offlineMode`, `keepFavourites`.
- `struct ScrobbleRule { var percent: Int; var minutes: Int? }`
  - Codable as `{"percent": Int, "minutesCap": Int}`. A `minutesCap` of 0 means Never: decode maps 0 to `nil` before `normalised()`.
  - `static let standard = ScrobbleRule(percent: 50, minutes: 4)`
  - `func normalised() -> ScrobbleRule`
  - `func threshold(duration: TimeInterval) -> TimeInterval?`
- `struct ScrobblePreferences: PreferenceArea`
  - Key `magpie.prefs.scrobbling`.
  - Fields: `viaNavidrome`, `viaListenBrainz`, `rule: ScrobbleRule`.
- `struct GenrePreferences: PreferenceArea`
  - Key `magpie.prefs.genres`.
  - Fields: `mode: GenreViewMode`, `assignments: [String: String]`, `groupNames: [String: String]`, `hidden: Set<String>`, `customGroups: [String]`.
  - `static let maxAssignments = 64`, `maxGroupNames = 32`, `maxCustomGroups = 16`, `maxHidden = 64`, `maxTextLength = 100`.
- `struct Preferences { var layout; var playback; var downloads; var scrobbling; var genres; static let standard }`
- Produces (App):
  - `struct PreferencesStore { init(defaults: UserDefaults); func load() -> Preferences; func save(_ new: Preferences, previous: Preferences) }`. It writes only the areas that changed.
  - `extension AppModel { func updatePreferences(_ change: (inout Preferences) -> Void); func preferencesDidChange(from old: Preferences) }`. The fan-out starts empty, and later tasks add one line each.

**Rules:**
- **`PreferenceArea.decode`** is the one strategy. Structs use synthesised `Codable`.
  1. Parse `data` with `JSONSerialization`. If it isn't a JSON object, return `defaultValue`.
  2. Start from `defaultValue` encoded as a JSON object.
  3. For each stored key, copy the value in and try `JSONDecoder().decode(Self.self, from:)` on the merged object. If that fails, put the default value back for that key.
  4. Return the decoded result, `normalised()`.

  One bad field can't reset the others.
- **`normalised()`:**
  - Integers are clamped: `concurrent` to 1…4, `preDownload` to 0…10, `percent` to 10…90 rounded to the nearest 5 (half up), `minutes` to 1…10 or `nil`.
  - `LayoutPreferences` runs `home` and `library` through `normalised(against:)` the defaults.
  - `GenrePreferences`:
    - Entries whose key or value is longer than `maxTextLength` are dropped.
    - `assignments` and `groupNames` keep the first `max…` entries in ascending key order.
    - `hidden` keeps its first 64 in ascending order.
    - `customGroups` keeps the first 16, de-duplicated.
- **`threshold(duration:)`:**
  - With a duration of 30 or more: `min(duration * percent / 100, minutes * 60)`. With Never, the percentage alone.
  - With a duration above 0 and below 30: nil.
  - With a duration of 0 or less: `minutes * 60`, or nil with Never.
- **`visibleHomeSections`:**
  - Offline gives `[.downloaded]`.
  - Otherwise it's `home.visibleItems`, without `madeForYou` when there's no token or when `carPlay`.
- **`visibleLibraryRows`:**
  - Offline gives `[.downloads]`.
  - Otherwise it's `library.visibleItems`, without `finds` unless `findsSetUp` and without `requests` unless `lidarrConnected`. With `carPlay`, it also drops `requests` and `songs`.

- [ ] **Step 1: Write the failing package tests**

```swift
@Suite struct PreferencesTests {
    @Test func defaultsMatchSpec() {
        let p = Preferences.standard
        #expect(p.layout.home.entries.map(\.item) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites,
                                                      .randomAlbums, .playlists, .genres, .downloaded])
        #expect(p.layout.home.entries.map(\.visible) == [true, true, true, true, false, false, false, false, false])
        #expect(p.layout.library.entries.map(\.item) == LibraryRow.allCases && p.layout.library.entries.allSatisfy(\.visible))
        #expect(p.layout.showsRecentlyAdded)
        #expect(p.playback.wifi == .original && p.playback.cellular == .aac160 && p.playback.replayGain == .track)
        #expect(p.playback.sleepTimer == .m30)
        let d = p.downloads
        #expect(d.quality == .original && !d.overMobileData && d.concurrent == 2 && d.preDownload == 3)
        #expect(d.keepRecentlyPlayed && d.cacheLimit == .gb2 && d.downloadsLimit == .none && d.offlineMode == .automatic)
        #expect(!d.keepFavourites)
        #expect(p.scrobbling.viaNavidrome && !p.scrobbling.viaListenBrainz && p.scrobbling.rule == ScrobbleRule(percent: 50, minutes: 4))
        #expect(p.genres.mode == .grouped)
    }

    @Test func noOpusPresets() {
        #expect(StreamQuality.allCases == [.original, .aac256, .aac160, .aac96, .mp3_320, .mp3_192])
        #expect(Set(StreamQuality.allCases.map(\.format)) == ["raw", "aac", "mp3"])
    }

    @Test func corruptDataFallsBackToDefault() {
        #expect(LayoutPreferences.decode(Data("{not json".utf8)) == .defaultValue)
        #expect(DownloadPreferences.decode(nil) == .defaultValue)
    }

    @Test func oneBadFieldKeepsTheOthers() {
        let p = PlaybackPreferences.decode(Data(#"{"version":1,"wifi":"lossless-ultra","cellular":"mp3_192","replayGain":7}"#.utf8))
        #expect(p.wifi == .original && p.cellular == .mp3_192 && p.replayGain == .track)
        #expect(PlaybackPreferences.decode(Data(#"{"cellular":"opus64"}"#.utf8)).cellular == .aac160, "old Opus value falls back")
    }

    @Test func unknownAndDuplicateSectionsDropped() {
        let json = #"{"version":1,"home":[{"id":"mostPlayed","visible":true},{"id":"karaoke","visible":true},{"id":"mostPlayed","visible":false},{"id":42}]}"#
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.home.entries.first == .init(item: .mostPlayed, visible: true))
        #expect(layout.home.entries.count == 9)
        #expect(layout.home.entries.filter { $0.item == .mostPlayed }.count == 1)
        #expect(layout.home.entries.first { $0.item == .favourites }?.visible == false, "missing items keep default visibility")
    }

    @Test func outOfRangeValuesClamp() {
        let d = DownloadPreferences.decode(Data(#"{"version":1,"concurrent":9,"preDownload":-1}"#.utf8))
        #expect(d.concurrent == 4 && d.preDownload == 0)
        #expect(ScrobbleRule(percent: 7, minutes: 0).normalised() == ScrobbleRule(percent: 10, minutes: 1))
        #expect(ScrobbleRule(percent: 52, minutes: 11).normalised() == ScrobbleRule(percent: 50, minutes: 10))
        #expect(ScrobbleRule(percent: 53, minutes: nil).normalised() == ScrobbleRule(percent: 55, minutes: nil))
    }

    @Test func neverRoundTrips() {
        var s = ScrobblePreferences.defaultValue
        s.rule = ScrobbleRule(percent: 90, minutes: nil)
        #expect(String(data: s.encoded(), encoding: .utf8)!.contains(#""minutesCap":0"#))
        #expect(ScrobblePreferences.decode(s.encoded()).rule == ScrobbleRule(percent: 90, minutes: nil))
    }

    @Test func hostileGenrePreferencesAreCapped() {
        var g = GenrePreferences.defaultValue
        for i in 0..<500 { g.assignments[String(format: "g%03d", i)] = "rock"; g.groupNames[String(format: "n%03d", i)] = "x" }
        g.hidden = Set((0..<500).map { String(format: "h%03d", $0) })
        g.customGroups = (0..<500).map { "custom.\($0)" } + ["custom.0"]
        g.assignments[String(repeating: "a", count: 101)] = "rock"
        let n = GenrePreferences.decode(g.encoded())
        #expect(n.assignments.count == 64 && n.assignments.keys.sorted().first == "g000" && n.assignments.keys.sorted().last == "g063")
        #expect(n.groupNames.count == 32 && n.hidden.count == 64 && n.customGroups.count == 16)
        #expect(n.customGroups.first == "custom.0" && Set(n.customGroups).count == 16)
        #expect(!n.assignments.keys.contains { $0.count > 100 })
    }

    @Test func scrobbleThresholds() {
        let rule = ScrobbleRule.standard
        #expect(rule.threshold(duration: 200) == 100)
        #expect(rule.threshold(duration: 1000) == 240)
        #expect(rule.threshold(duration: 29) == nil)
        #expect(rule.threshold(duration: 30) == 15)
        #expect(rule.threshold(duration: 0) == 240)
        #expect(ScrobbleRule(percent: 90, minutes: nil).threshold(duration: 600) == 540)
        #expect(ScrobbleRule(percent: 50, minutes: nil).threshold(duration: 0) == nil)
    }

    @Test func orderedVisibilityEditing() {
        var v = LayoutPreferences.defaultValue.home
        v.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(v.visibleItems == [.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
        v.moveDown(.mostPlayed); #expect(v.entries.map(\.item).prefix(2) == [.jumpBackIn, .mostPlayed])
        v.moveUp(.jumpBackIn); #expect(v.entries.first?.item == .jumpBackIn, "moveUp at the top is a no-op")
        #expect(v.set(.favourites, visible: true) && v.visibleItems.contains(.favourites))
    }

    @Test func lastVisibleLibraryRowCannotBeHidden() {
        var l = LayoutPreferences.defaultValue.library
        let keep = LayoutPreferences.alwaysAvailableRows
        for row in [LibraryRow.playlists, .artists, .albums, .songs, .genres, .favourites] { #expect(l.set(row, visible: false, keepingOneOf: keep)) }
        #expect(!l.set(.downloads, visible: false, keepingOneOf: keep))
        #expect(l.entries.first { $0.item == .downloads }?.visible == true)
        #expect(l.set(.finds, visible: false, keepingOneOf: keep), "rows outside the required set hide freely")
    }

    @Test func visibleSectionRules() {
        let l = LayoutPreferences.defaultValue
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false, carPlay: false) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true, carPlay: false) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true, carPlay: true) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true, carPlay: false) == [.downloaded])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: true, carPlay: true)
                == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: true, lidarrConnected: false, carPlay: false)
                == [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads, .finds])
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false) == [.downloads])
    }

    @Test func qualityStreamParameters() {
        #expect(StreamQuality.original.format == "raw" && StreamQuality.original.maxBitRate == nil)
        #expect(StreamQuality.aac160.format == "aac" && StreamQuality.aac160.maxBitRate == 160)
        #expect(StreamQuality.mp3_320.format == "mp3" && StreamQuality.mp3_320.maxBitRate == 320)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `PreferencesTests`. Expected: `error: cannot find 'Preferences' in scope`.
- [ ] **Step 3: Implement `OrderedVisibility.swift` and `Preferences.swift`** with the interfaces and rules above.
- [ ] **Step 4: Run PKG `PreferencesTests`.** Expected: PASS.
- [ ] **Step 5: Write the failing app tests.** `makeModel()` is the same initialiser as `ATSAppTests.makeModel()`, with `defaults` passed in:

```swift
@MainActor @Suite(.serialized) struct PreferencesAppTests {
    let defaults = UserDefaults(suiteName: "magpie-tests-prefs-\(UUID().uuidString)")!
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, transport: HostSwitchTransport(), probeTransport: HostSwitchTransport(), engine: FakeEngine(),
                 defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    @Test func savesOneKeyPerChangedAreaAndReloads() {
        let model = makeModel()
        model.updatePreferences { $0.playback.cellular = .mp3_192 }
        #expect(defaults.data(forKey: "magpie.prefs.playback") != nil)
        #expect(defaults.data(forKey: "magpie.prefs.layout") == nil, "unchanged areas aren't written")
        #expect(makeModel().preferences.playback.cellular == .mp3_192)
    }

    @Test func corruptStoredAreaFallsBackWithoutCrashing() {
        defaults.set(Data([0xFF, 0x00]), forKey: "magpie.prefs.downloads")
        #expect(makeModel().preferences.downloads == .defaultValue)
    }
}
```

- [ ] **Step 6: Run APP `PreferencesAppTests`.** Expected: FAIL, because `PreferencesStore` and `updatePreferences` are missing.
- [ ] **Step 7: Implement `PreferencesStore`, the `AppModel` lines and `AppModel+Preferences.swift`.** `updatePreferences` does the following in order:
  1. copies the current preferences and applies the change;
  2. normalises each area;
  3. saves the areas that changed;
  4. assigns `preferences`;
  5. calls `preferencesDidChange(from:)`.
- [ ] **Step 8: Run APP `PreferencesAppTests`, then the regression gate.** Expected: PASS.
- [ ] **Step 9: Commit**

```bash
git add Packages/MagpieKit/Sources/MagpieCore/OrderedVisibility.swift Packages/MagpieKit/Sources/MagpieCore/Preferences.swift Packages/MagpieKit/Tests/MagpieCoreTests/PreferencesTests.swift App/PreferencesStore.swift App/AppModel+Preferences.swift App/AppModel.swift Tests/MagpieTests/PreferencesAppTests.swift
git commit -m "Preferences: one store for layout, playback, downloads, scrobbling and genres

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 6: Navidrome API additions (and every `Models.swift` change for the round)

**Files:**
- Modify: `Packages/MagpieKit/Sources/MagpieCore/Models.swift`. This is the only task that edits this file.
  - On `Song`, add `public var genre: String?` and `public var replayGain: ReplayGain?`. The init gains `genre: String? = nil, replayGain: ReplayGain? = nil` at the end, so existing call sites still compile.
  - Add `public struct ReplayGain: Sendable, Hashable, Codable { public var trackGain, albumGain, trackPeak, albumPeak: Double? }`, with `public init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil)`.
  - Add `public struct Genre: Sendable, Hashable, Codable { public var name: String; public var songCount: Int; public var albumCount: Int }`, with `public init(name:songCount:albumCount:)`.
  - Add `public struct Starred: Sendable, Hashable { public var songs: [Song]; public var albums: [Album] }`, with `public init(songs: [Song] = [], albums: [Album] = [])`.
  - Add `case starred` to `AlbumListType` (raw value "starred").
- Modify: `NavidromeKit/SubsonicDTOs.swift`.
  - `SubsonicSong` gains `genre: String?` and `replayGain: SubsonicReplayGain?` (fields `trackGain`, `albumGain`, `trackPeak`, `albumPeak`).
  - `SubsonicBody` gains:
    - `genres: Genres?` (`{ genre: [SubsonicGenre]? }`, where `SubsonicGenre` has `value`, `songCount` and `albumCount`);
    - `songsByGenre: TopSongs?`;
    - `starred2: SearchResult?`.
- Modify: `NavidromeKit/NativeDTOs.swift`. `NativeSong` gains `genre: String?` and the four `Double?` fields `rgTrackGain`, `rgAlbumGain`, `rgTrackPeak`, `rgAlbumPeak`.
- Modify: `NavidromeKit/Mapping.swift:10-27`. Map the new fields into `Song`.
- Modify: `NavidromeKit/NavidromeClient.swift:169-242` and `:306`.
- Modify: `dev/smoke.sh`. Add PASS/FAIL lines for `getGenres`, `getAlbumList2?type=byGenre&genre=Ambient`, `getSongsByGenre?genre=Ambient` and `getStarred2`.
- Test: `Packages/MagpieKit/Tests/NavidromeKitTests/GenreAPITests.swift`, `Packages/MagpieKit/Tests/NavidromeKitTests/GenreIT.swift`

**Interfaces:**
- Produces on `NavidromeClient`:
  - `public func genres() async throws -> [Genre]`, from `getGenres`. A row with no `value` is dropped. Missing counts read as 0.
  - `public func albums(genre: String, size: Int, offset: Int) async throws -> [Album]`
  - `public func songs(genre: String, count: Int, offset: Int) async throws -> [Song]`
  - `public func starred() async throws -> Starred`
  - `public func songsPage(start: Int, end: Int, sort: String = "id")`. Existing callers are unchanged.
- Produces in MagpieCore: the public types and inits listed above. Tasks 9, 18, 22 and 23 build them from other modules.

- [ ] **Step 1: Write the failing tests.** Use the existing `makeClient()` and `queryValue` helpers (`TestHelpers.swift`). `ok(_ body: String)` wraps a JSON fragment as `{"subsonic-response":{"status":"ok","version":"1.16.1",<body>}}`.

```swift
@Suite struct GenreAPITests {
    @Test func genresMapCounts() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getGenres", body: ok(#""genres":{"genre":[{"value":"Indie Rock","songCount":10,"albumCount":1},{"value":"Ambient","songCount":12,"albumCount":2},{"songCount":3}]}"#))
        #expect(try await client.genres() == [Genre(name: "Indie Rock", songCount: 10, albumCount: 1),
                                              Genre(name: "Ambient", songCount: 12, albumCount: 2)])
    }

    @Test func albumsByGenreQuery() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getAlbumList2", body: ok(#""albumList2":{"album":[{"id":"a1","name":"Continuum","artist":"Aurora Field","songCount":6}]}"#))
        let albums = try await client.albums(genre: "Indie Rock", size: 12, offset: 24)
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "type") == "byGenre" && queryValue(r, "genre") == "Indie Rock")
        #expect(queryValue(r, "size") == "12" && queryValue(r, "offset") == "24")
        #expect(albums.map(\.id) == ["a1"])
    }

    @Test func songsByGenreQuery() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: ok(#""songsByGenre":{"song":[{"id":"s1","title":"One","genre":"Ambient"},{"id":"s2","title":"Two"}]}"#))
        let songs = try await client.songs(genre: "Ambient", count: 500, offset: 0)
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "genre") == "Ambient" && queryValue(r, "count") == "500" && queryValue(r, "offset") == "0")
        #expect(songs.map(\.id) == ["s1", "s2"] && songs[0].genre == "Ambient")
    }

    @Test func starredSplitsSongsAndAlbums() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{"song":[{"id":"s1","title":"One"}],"album":[{"id":"a1","name":"A"},{"id":"a2","name":"B"}]}"#))
        let s = try await client.starred()
        #expect(s.songs.map(\.id) == ["s1"] && s.albums.map(\.id) == ["a1", "a2"])
    }

    @Test func starredEmptyBody() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{}"#))
        #expect(try await client.starred() == Starred())
    }

    @Test func replayGainAndGenreMapped() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSong", body: ok(#""song":{"id":"s1","title":"One","genre":"Ambient","replayGain":{"trackGain":-6.5,"albumGain":-7.1,"trackPeak":0.98,"albumPeak":1.0}}"#))
        let song = try await client.song(id: "s1")
        #expect(song.genre == "Ambient")
        #expect(song.replayGain == ReplayGain(trackGain: -6.5, albumGain: -7.1, trackPeak: 0.98, albumPeak: 1.0))
    }

    @Test func nativeReplayGainMapped() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/song", body: Data(#"[{"id":"s9","title":"Nine","genre":"Jazz","rgTrackGain":-3.2,"rgAlbumGain":-4.0}]"#.utf8),
               headers: ["X-Total-Count": "1"])
        let page = try await client.songsPage(start: 0, end: 100)
        #expect(page.songs.first?.replayGain?.trackGain == -3.2 && page.songs.first?.replayGain?.albumGain == -4.0)
        #expect(page.songs.first?.genre == "Jazz")
    }

    @Test func songsPageSortsByTitle() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        _ = try await client.songsPage(start: 100, end: 200, sort: "title")
        let r = try #require(t.requests.last { $0.url?.path.hasSuffix("/api/song") == true })
        #expect(queryValue(r, "_sort") == "title" && queryValue(r, "_start") == "100" && queryValue(r, "_end") == "200")
        _ = try await client.songsPage(start: 0, end: 10)
        #expect(queryValue(t.requests.last!, "_sort") == "id", "default unchanged")
    }

    @Test func starredListType() { #expect(AlbumListType.starred.rawValue == "starred") }
}
```

`GenreIT` is G0, gated by `DevStack.enabled` like `NavidromeIT`. It expects the fixture genres from `dev/fixtures/make-library.sh`. It stars a song, reads `starred()`, then unstars it:

```swift
@Test func fixtureGenresAndStarred() async throws {
    let client = try client(); _ = try await client.connect()
    let genres = try await client.genres()
    #expect(genres.first { $0.name == "Ambient" }?.albumCount == 2)
    #expect(genres.first { $0.name == "Indie Rock" }?.albumCount == 1)
    #expect(try await client.albums(genre: "Ambient", size: 50, offset: 0).count == 2)
    let ambient = try await client.songs(genre: "Ambient", count: 500, offset: 0)
    #expect(ambient.count == 12 && ambient.allSatisfy { $0.genre == "Ambient" })
    let id = ambient[0].id
    try await client.star(id: id)
    #expect(try await client.starred().songs.map(\.id).contains(id))
    try await client.unstar(id: id)
    #expect(!(try await client.starred().songs.map(\.id).contains(id)))
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `GenreAPITests`. Expected: `cannot find 'Genre' in scope`.
- [ ] **Step 3: Implement the model, DTO, mapping and client changes.**
- [ ] **Step 4: Run PKG `GenreAPITests`, PKG `BrowseMappingTests` and PKG `EdgeCaseTests`.** Expected: PASS.
- [ ] **Step 5: Run the integration test.** Run `dev/bootstrap.sh`, then `MAGPIE_IT=1` PKG `GenreIT`. Expected: PASS. `dev/smoke.sh` should exit 0.
- [ ] **Step 6: Commit** with "Navidrome: genres, songs by genre, starred, ReplayGain and genre on songs" plus the trailer.

---

## Task 7: Player plumbing for quality changes, local files and fallback

**Files:**
- Modify: `Packages/MagpieKit/Sources/Playback/PlaybackEngine.swift:21-42`
- Modify: `Packages/MagpieKit/Sources/Playback/Player.swift`. The edits are in `init` (69-84), `urlsInvalidated` (213-218), `.failed` handling (245-253), `.ended` handling (254-263), `syncEngine` (287-297) and `beginEntry` (306-320).
- Modify: `Packages/MagpieKit/Sources/Playback/AVQueueEngine.swift`. The edits are in `setItems` (57-79) and `enqueue` (144-154), plus a new `enqueuedItems`.
- Modify: `Tests/MagpieTests/PlayerTests.swift:9-41`.
  - `FakeEngine` gains `private(set) var setVolumesCalls: [[UUID: Float]] = []` (one per `setVolumes`) and `private(set) var setVolumeCalls: [Float] = []` (one per `setVolume`). Every later task uses exactly these names.
  - `FakeURLs` gains `var original: ((Song) -> URL?)?`, returned by `originalURL(for:)`.
- Test: `Tests/MagpieTests/PlayerTests.swift` (new tests), `Tests/MagpieTests/AVQueueEngineTests.swift` (one new test)

**Interfaces:**
- Produces:
  - On `PlaybackEngine`:
    - `func setVolumes(_ volumes: [UUID: Float])`
    - `func setVolume(_ volume: Float)`
    - Both have no-op defaults in a protocol extension.
  - On `StreamURLProvider`, `func originalURL(for song: Song) -> URL?` with a default of `nil`.
  - On `Player`:
    - `public init(engine:scrobbler:urls:isFind:now:gain: @escaping (Song) -> Float = { _ in 1 })`
    - `public func upcomingURLsChanged()`
    - `public private(set) var lastFallbackSongId: String?`
    - `public var volume: Float` (forwards to `engine.setVolume`)
    - `@ObservationIgnored public var isPlayable: (Song) -> Bool = { _ in true }`
    - `public var stopsAfterCurrent: Bool`
  - On `AVQueueEngine`, `public var enqueuedItems: [(id: UUID, url: URL)]`.

**Rules:**
- **The current entry keeps its URL.** Player remembers `(entryId, url)` for what it last handed the engine as current. `syncEngine(rebuildCurrent:)` reuses that URL unless `rebuildCurrent` is true.
  - Only `urlsInvalidated()` (failover) and a fallback pass `true`.
  - `upcomingURLsChanged()` passes `false`. It also re-sends `setVolumes` and re-applies `isPlayable`.
- **The upcoming list** sent to the engine is `queue.upcoming.filter { isPlayable($0.song) }`. The current entry always goes. The existing `.itemChanged` loop (`while queue.current?.id != id, queue.advance()`) already skips filtered entries.
- **Fallback.** On `.failed(id, _)` for the current entry, if `urls.originalURL(for:)` is non-nil and this entry hasn't fallen back yet:
  - Record the entry id in `fellBack`.
  - Set `lastFallbackSongId`.
  - Rebuild with the original URL for that entry.
  - Resume, and do not set `lastError`.

  A second failure behaves as today, with one exception, the next rule.
- **A failed current song that can't play.** It has no fallback left and `isPlayable(current.song)` is false (offline, not on the phone). Advance to the next entry whose song `isPlayable`, load it and keep playing, without setting `lastError`. If none is left, behave as today.
- **`stopsAfterCurrent`** sends an empty upcoming list (like repeat one). On `.ended` while it is true:
  - Set it back to false.
  - Advance the queue without loading. Keep `needsReload = true` and `isPlaying = false`.
- **AVQueueEngine.** In `setItems`, when the current item matches, keep the already-enqueued item right after it if its id equals the new list's next id, even when the URL differs. Remove the rest. `enqueue` applies the stored volume for the id (Task 9 fills in the audio mix).

- [ ] **Step 1: Write the failing tests** (PlayerTests):

```swift
@Test func currentKeepsItsURLWhenUpcomingChange() {
    let player = makePlayer()
    player.play([Self.song("1"), Self.song("2")], startAt: 0)
    let before = engine.setItemsCalls.last!.items
    urls.base = URL(string: "http://10.0.0.9:4533")!
    player.upcomingURLsChanged()
    let after = engine.setItemsCalls.last!.items
    #expect(after[0].1 == before[0].1)
    #expect(after[1].1.host == "10.0.0.9")
    #expect(engine.seeks.isEmpty)
}

@Test func failoverStillRebuildsCurrent() {
    let player = makePlayer()
    player.play([Self.song("1")], startAt: 0)
    urls.base = URL(string: "http://10.0.0.9:4533")!
    player.urlsInvalidated()
    #expect(engine.setItemsCalls.last!.items[0].1.host == "10.0.0.9")
}

@Test func transcodedFailureFallsBackOnce() {
    urls.original = { URL(string: "http://192.168.1.2:4533/rest/stream?id=\($0.id)&format=raw")! }
    let player = makePlayer()
    player.play([Self.song("1")], startAt: 0)
    let id = player.queue.current!.id
    player.handle(.failed(id, "cannot open"))
    #expect(engine.setItemsCalls.last!.items[0].1.query?.contains("format=raw") == true)
    #expect(player.lastError == nil && player.lastFallbackSongId == "1" && player.isPlaying)
    player.handle(.failed(id, "still broken"))
    #expect(player.lastError == "still broken" && !player.isPlaying)
}

@Test func noFallbackWithoutOriginal() {
    let player = makePlayer()
    player.play([Self.song("1")], startAt: 0)
    player.handle(.failed(player.queue.current!.id, "x"))
    #expect(player.lastError == "x" && player.lastFallbackSongId == nil)
}

@Test func failedUnplayableCurrentSkipsToNextPlayable() {
    let player = makePlayer()
    player.play([Self.song("1"), Self.song("2"), Self.song("3")], startAt: 0)
    player.isPlayable = { $0.id == "3" }   // went offline; only 3 is on the phone
    player.upcomingURLsChanged()
    player.handle(.failed(player.queue.current!.id, "offline"))
    #expect(player.queue.current?.song.id == "3" && player.isPlaying && player.lastError == nil)
    #expect(engine.setItemsCalls.last!.items.count == 1)
}

@Test func failedUnplayableCurrentWithNothingLeftStops() {
    let player = makePlayer()
    player.play([Self.song("1"), Self.song("2")], startAt: 0)
    player.isPlayable = { _ in false }
    player.handle(.failed(player.queue.current!.id, "offline"))
    #expect(player.lastError == "offline" && !player.isPlaying)
}

@Test func gainsSentWithItems() {
    let player = Player(engine: engine, scrobbler: scrobbler, urls: urls, gain: { $0.id == "1" ? 0.5 : 1 })
    player.play([Self.song("1"), Self.song("2")], startAt: 0)
    let current = player.queue.current!.id, next = player.queue.upcoming[0].id
    #expect(engine.setVolumesCalls.last == [current: 0.5, next: 1])
}

@Test func volumeForwardsToEngine() {
    let player = makePlayer()
    player.volume = 0.3
    #expect(engine.setVolumeCalls == [0.3])
}

@Test func unplayableUpcomingSkipped() {
    let player = makePlayer()
    player.isPlayable = { $0.id != "2" }
    player.play([Self.song("1"), Self.song("2"), Self.song("3")], startAt: 0)
    #expect(engine.setItemsCalls.last!.items.count == 2)
    player.handle(.itemChanged(player.queue.upcoming[1].id))
    #expect(player.queue.current?.song.id == "3")
}

@Test func stopsAfterCurrentPausesOnNextSong() {
    let player = makePlayer()
    player.play([Self.song("1"), Self.song("2")], startAt: 0)
    player.stopsAfterCurrent = true
    #expect(engine.setItemsCalls.last!.items.count == 1)
    let plays = engine.playCount
    player.handle(.ended)
    #expect(!player.isPlaying && player.queue.current?.song.id == "2" && !player.stopsAfterCurrent)
    #expect(engine.playCount == plays)
}
```

AVQueueEngineTests (real AVQueuePlayer, silent WAVs):

```swift
@Test func setItemsKeepsEnqueuedNext() async throws {
    let w1 = try Self.silentWAV(), w2 = try Self.silentWAV(), w3 = try Self.silentWAV()
    let a = UUID(), b = UUID(), c = UUID()
    let engine = AVQueueEngine()
    engine.setItems([(a, w1), (b, w2)], startAt: 0)
    engine.play()
    try await waitUntil { engine.enqueuedItems.count == 2 }   // 2-s items: topUp enqueues at once; waitUntil polls every 20 ms for up to 5 s (add it if the file lacks one)
    engine.setItems([(a, w1), (b, w3)], startAt: 0)
    #expect(engine.enqueuedItems.map(\.url) == [w1, w2])
    engine.setItems([(a, w1), (c, w3)], startAt: 0)
    try await waitUntil { engine.enqueuedItems.count == 2 }
    #expect(engine.enqueuedItems.map(\.url) == [w1, w3])
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `PlayerTests` and APP `AVQueueEngineTests`. Expected: FAIL to compile (`upcomingURLsChanged`, `enqueuedItems`, …).
- [ ] **Step 3: Implement the protocol defaults, the Player rules and the engine change.**
- [ ] **Step 4: Run APP `PlayerTests`, `AVQueueEngineTests` and `PlaybackFlowsVerifyTests`.** Expected: PASS, including every existing test.
- [ ] **Step 5: Commit** with "Player: stable current URL, upcoming refresh, transcode fallback, playability, stop after current" plus the trailer.

---

## Task 8: Streaming quality per network and the Playback settings

**Files:**
- Create: `Packages/MagpieKit/Sources/MagpieCore/NetworkStatus.swift`
- Create: `App/Playback/NetworkMonitor.swift`
- Create: `App/AppModel+Playback.swift`
- Create: `App/Screens/Settings/PlaybackSettingsView.swift`
- Modify: `App/Playback/NavidromeAdapters.swift:108-125`.
  - Add `final class QualityBox: Sendable` (an `OSAllocatedUnfairLock<StreamQuality>` with `value` and `set(_:)`), the same pattern as `PlayCounting`.
  - `NavidromeStreamURLs` takes `quality: QualityBox` and `localURL: @MainActor (String) -> URL?` (default `{ _ in nil }`; Task 13 fills it in).
- Modify: `App/AppModel.swift`.
  - Init gains `network: (any NetworkStatusProviding)? = nil`.
  - Add stored `@ObservationIgnored let network: any NetworkStatusProviding` and `var playbackHint: String?`.
  - Add `@ObservationIgnored let qualityBox = QualityBox(.original)`, built before `player` in `init` and passed to `NavidromeStreamURLs` (lines 201-204), because `Player` is built before `self` is usable.
  - After `watchPlaybackErrors()` (line 214), call `watchPlaybackQuality()`.
- Modify: `App/AppModel+Preferences.swift` (`preferencesDidChange`). On a playback change, call `qualityBox.set(currentStreamQuality)` and then `player.upcomingURLsChanged()`.
- Modify: `App/Screens/Settings/SettingsView.swift:28-30`. Add `Section("Playback")`, holding a NavigationLink "Playback" to `PlaybackSettingsView`.
- Modify: `App/Screens/NowPlaying/NowPlayingView.swift`. Under the scrubber, show `model.playbackHint` as footnote text with the `info.circle` symbol, and let it be dismissed.
- Modify: `Tests/MagpieTests/PlaybackFlowsVerifyTests.swift:57-73`. The FLOWS claim changes for 0.0.1. With Wi-Fi Original, the names are `["u","t","s","v","c","f","id","format","estimateContentLength"]` and `format == "raw"`. Rename the test to `docClaim_appStreamURLOriginalIsRaw`.
- Test: `Tests/MagpieTests/QualityAppTests.swift`
- Test: `Packages/MagpieKit/Tests/NavidromeKitTests/TranscodeIT.swift`

**Interfaces:**
- Consumes:
  - `PlaybackPreferences` and `StreamQuality` (Task 5)
  - `Player.upcomingURLsChanged()`, `StreamURLProvider.originalURL(for:)`, `Player.lastFallbackSongId` (Task 7)
- Produces:
  - `public struct NetworkStatus: Sendable, Equatable { isConnected: Bool; isCellular: Bool; isConstrained: Bool; static let wifi }`
  - `public extension PlaybackPreferences { func quality(for status: NetworkStatus) -> StreamQuality }`. It returns `cellular` when `isCellular || isConstrained`, otherwise `wifi`.
  - `@MainActor protocol NetworkStatusProviding: AnyObject { var status: NetworkStatus { get } }`
  - `@MainActor @Observable final class NetworkMonitor: NetworkStatusProviding`. It wraps `NWPathMonitor`:
    - `isConnected = path.status == .satisfied`
    - `isCellular = path.usesInterfaceType(.cellular) || path.isExpensive`
    - `isConstrained = path.isConstrained`
  - `extension AppModel { var currentStreamQuality: StreamQuality; func watchPlaybackQuality(); static let transcodeHint = "Your server couldn't convert this song; playing the original"; func dismissPlaybackHint() }`
  - `NavidromeStreamURLs.originalURL(for:)` returns the `format=raw` URL when the current quality isn't `.original`, and nil when it is or the file is local.

**Rules:** `watchPlaybackQuality` sets `qualityBox` once at start, then uses `Observations`:
- On a change of `network.status`, call `qualityBox.set(currentStreamQuality)`, then `player.upcomingURLsChanged()`.
- On a change of `player.lastFallbackSongId` to non-nil, set `playbackHint = transcodeHint` once per process (`@ObservationIgnored var shownTranscodeHint`).

- [ ] **Step 1: Write the failing tests.** `QualityAppTests` relies on the fixtures below:
  - `FakeNetwork`: a `@MainActor @Observable final class FakeNetwork: NetworkStatusProviding` with a settable `status`.
  - `signedIn(_ status: NetworkStatus) async throws -> (AppModel, FakeEngine, FakeNetwork)`. It builds the model the way `PlaybackFlowsVerifyTests.makeModel()` does, adding `network:`, then signs in to `http://192.168.1.2:4533`.
  - `query(_ url: URL) -> [String: String]`
  - `song(_ id: String)`, which is `PlayerTests.song(id)`
  - `eventually`, as in `V1FlowsDocAppTests`

```swift
let cellular = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)

@Test func wifiUsesOriginalRaw() async throws {
    let (model, engine, _) = try await signedIn(.wifi)
    model.play([song("s1")], startAt: 0)
    let q = query(engine.setItemsCalls.last!.items[0].1)
    #expect(q["format"] == "raw" && q["maxBitRate"] == nil)
}
@Test func cellularUsesAAC160() async throws {
    let (model, engine, _) = try await signedIn(cellular)
    model.play([song("s1")], startAt: 0)
    let q = query(engine.setItemsCalls.last!.items[0].1)
    #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
}
@Test func lowDataModeOnWifiUsesMobileQuality() async throws {
    let (model, engine, _) = try await signedIn(NetworkStatus(isConnected: true, isCellular: false, isConstrained: true))
    model.play([song("s1")], startAt: 0)
    let q = query(engine.setItemsCalls.last!.items[0].1)
    #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
}
@Test func preferenceChangeAppliesToUpcoming() async throws {
    let (model, engine, _) = try await signedIn(.wifi)
    model.play([song("s1"), song("s2")], startAt: 0)
    model.updatePreferences { $0.playback.wifi = .mp3_320 }
    let items = engine.setItemsCalls.last!.items
    #expect(query(items[0].1)["format"] == "raw" && query(items[1].1)["format"] == "mp3" && query(items[1].1)["maxBitRate"] == "320")
}
@Test func networkChangeRebuildsUpcomingOnly() async throws {
    let (model, engine, network) = try await signedIn(.wifi)
    model.play([song("s1"), song("s2")], startAt: 0)
    network.status = cellular
    #expect(await eventually { query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" })
    #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
    #expect(engine.seeks.isEmpty)
}
@Test func transcodeHintShownOncePerSession() async throws {
    let (model, engine, _) = try await signedIn(cellular)
    model.play([song("s1"), song("s2")], startAt: 0)
    model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
    #expect(await eventually { model.playbackHint == AppModel.transcodeHint })
    #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
    model.dismissPlaybackHint()
    model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))
    model.player.handle(.failed(model.player.queue.current!.id, "cannot open"))
    #expect(model.player.lastFallbackSongId == "s2")
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.playbackHint == nil, "once per session")
}
```

`TranscodeIT` runs on the dev stack only (G0). It asserts that each preset format plays: AVFoundation must open what the server sends. It never swallows a failure. If the pinned dev image can't transcode a preset format, that is a real failure: fix the dev stack or drop the preset, and record which in `docs/decisions.md`.

```swift
@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1")) struct TranscodeIT {
    func playable(_ data: Data, ext: String) async throws -> (Bool, Double) {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let (ok, duration) = try await asset.load(.isPlayable, .duration)
        return (ok, duration.seconds)
    }

    @Test(arguments: [("aac", 160, "aac"), ("aac", 96, "aac"), ("mp3", 320, "mp3"), ("mp3", 192, "mp3")])
    func presetFormatsPlay(_ format: String, _ rate: Int, _ ext: String) async throws {
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: rate, format: format)))
        #expect(response.statusCode == 200 && data.count > 1024)
        let (ok, seconds) = try await playable(data, ext: ext)
        #expect(ok, "\(format) \(rate) kbps is playable")
        #expect(seconds > 1)
    }

    @Test func originalIsPlayable() async throws {   // the fallback target
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: nil, format: "raw")))
        #expect(response.statusCode == 200)
        #expect(try await playable(data, ext: song.suffix ?? "mp3").0)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `QualityAppTests`. Expected: FAIL to compile (`NetworkStatusProviding`).
- [ ] **Step 3: Implement NetworkStatus, NetworkMonitor, the adapter changes, `AppModel+Playback`, the hint and the init wiring.**
- [ ] **Step 4: Build `PlaybackSettingsView`.** One `Form` with these sections:
  - "Streaming": a "Wi-Fi" picker and a "Mobile data" picker, each over `StreamQuality.allCases` (Original, AAC 256/160/96, MP3 320/192) and labelled with `title`. Footer: "Gapless works best with Original".
  - "Volume levelling": a ReplayGain picker labelled "Off / Same song volume / Same album volume", mapped to `.off/.track/.album`.
  - "Sleep timer": a default picker over `SleepTimerOption` ("15 min" … "End of song").
- [ ] **Step 5: Run APP `QualityAppTests` and `PlaybackFlowsVerifyTests`, then `MAGPIE_IT=1` PKG `TranscodeIT`.** Expected: PASS for all of them.
- [ ] **Step 6: Commit** with "Playback: quality per network, Low Data Mode, transcode fallback hint, Playback settings" plus the trailer.

---

## Task 9: ReplayGain (attenuation only)

**Files:**
- Create: `Packages/MagpieKit/Sources/MagpieCore/ReplayGain.swift`
- Modify: `Packages/MagpieKit/Sources/Playback/AVQueueEngine.swift`. Implement `setVolumes`, and apply an `AVMutableAudioMix` in `enqueue`.
- Modify: `App/AppModel.swift:201-204`. Pass `gain: { [weak self] in self?.preferences.playback.replayGain.volume(for: $0.replayGain) ?? 1 }`. Because `Player` is built in `init` before `self` is usable, pass a `ReplayGainBox` (`OSAllocatedUnfairLock<ReplayGainMode>`) the same way `PlayCounting` is passed. Keep it in sync in `preferencesDidChange`.
- Test: `Packages/MagpieKit/Tests/MagpieCoreTests/ReplayGainTests.swift`, `Tests/MagpieTests/AVQueueEngineTests.swift` (one test). Task 7 already covers the Player sending gains (`gainsSentWithItems`).

**Interfaces:**
- Produces: `public extension ReplayGainMode { func volume(for gain: ReplayGain?) -> Float }`.
  - `.track` uses `trackGain`, falling back to `albumGain`. `.album` uses `albumGain`, falling back to `trackGain`. `.off` and no tags give `1`.
  - The dB value is clamped to −15…0, and the result is `pow(10, dB / 20)`. Peaks are ignored (attenuation only).
- AVQueueEngine:
  - In `enqueue`, if the volume for the id is below 1, load the audio tracks asynchronously (`item.asset.loadTracks(withMediaType: .audio)`). Then set `item.audioMix` to one `AVMutableAudioMixInputParameters` per track with `setVolume(v, at: .zero)`.
  - `setVolumes` stores the map and updates the current item's mix the same way.
  - A volume of 1 leaves `audioMix` nil.
  - Diagnostics: `public var currentItemMixVolume: Float?` reads the first input parameter's volume at `.zero` through `getVolumeRamp(for:startVolume:endVolume:timeRange:)`. It is nil without a mix.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ReplayGainTests {
    @Test func trackModeAttenuates() {
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -6)) - 0.501187) < 0.0001)
        #expect(ReplayGainMode.track.volume(for: ReplayGain(trackGain: 3)) == 1)
        #expect(abs(ReplayGainMode.track.volume(for: ReplayGain(trackGain: -20)) - 0.177828) < 0.0001)
    }
    @Test func albumModeAndFallbacks() {
        #expect(abs(ReplayGainMode.album.volume(for: ReplayGain(trackGain: -3, albumGain: -9)) - 0.354813) < 0.0001)
        #expect(abs(ReplayGainMode.album.volume(for: ReplayGain(trackGain: -6)) - 0.501187) < 0.0001)
        #expect(ReplayGainMode.off.volume(for: ReplayGain(trackGain: -6)) == 1)
        #expect(ReplayGainMode.track.volume(for: nil) == 1)
    }
}
```

AVQueueEngineTests (real AVQueuePlayer, the existing `silentWAV()` and Task 7's `waitUntil`):

```swift
@Test func volumeBelowOneAppliesAnAudioMix() async throws {
    let w = try Self.silentWAV(), a = UUID(), b = UUID()
    let engine = AVQueueEngine()
    engine.setVolumes([a: 0.5])
    engine.setItems([(a, w)], startAt: 0)
    try await waitUntil { engine.currentItemMixVolume != nil }
    #expect(abs(engine.currentItemMixVolume! - 0.5) < 0.001)
    engine.setVolumes([a: 0.25])
    try await waitUntil { abs((engine.currentItemMixVolume ?? 0) - 0.25) < 0.001 }
    engine.setItems([(b, try Self.silentWAV())], startAt: 0)
    try await waitUntil { engine.enqueuedItems.first?.id == b }
    #expect(engine.currentItemMixVolume == nil, "unity gain: no mix")
}
```
- [ ] **Step 2: Run them and check they fail.** Run PKG `ReplayGainTests` and APP `AVQueueEngineTests`. Expected: FAIL (`volume(for:)` and `currentItemMixVolume` are missing).
- [ ] **Step 3: Implement `ReplayGain.swift`, the engine mix and the AppModel wiring.**
- [ ] **Step 4: Run PKG `ReplayGainTests`, APP `AVQueueEngineTests` and APP `PlayerTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "ReplayGain: track/album levelling, attenuation only" plus the trailer.

---

## Task 10: Sleep timer (phone)

**Files:**
- Create: `Packages/MagpieKit/Sources/Playback/SleepTimer.swift`
- Create: `App/Screens/NowPlaying/SleepTimerMenu.swift`
- Modify: `App/AppModel.swift`. Add `let sleepTimer: SleepTimer`, built right after `player` in `init`.
- Modify: `App/Screens/NowPlaying/NowPlayingView.swift`. In the top bar, add `SleepTimerMenu` (a moon symbol, VoiceOver label "Sleep timer", value "Off" or "Sleeping in 12 minutes").
- Test: `Tests/MagpieTests/SleepTimerTests.swift`

**Interfaces:**
- Consumes: `Player.volume`, `Player.stopsAfterCurrent`, `Player.toggle()` (Task 7); `SleepTimerOption` (Task 5).
- Produces:

```swift
@MainActor @Observable public final class SleepTimer {
    public enum Mode: Equatable, Sendable { case off, at(Date), endOfSong }
    public private(set) var mode: Mode
    public init(player: Player, now: @escaping () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
    public func start(_ option: SleepTimerOption)
    public func cancel()
    public func remaining(at date: Date) -> TimeInterval?
    /// Tests: waits for the timer task to finish.
    public func settled() async
}
```

**Rules:**
- `start(.endOfSong)` sets `player.stopsAfterCurrent = true`.
- A minutes option sleeps `seconds`, then fades: 10 steps, setting `player.volume` to 0.9, 0.8 … 0.0 with `sleep(.milliseconds(500))` between them. It then pauses (`player.toggle()` if playing), restores `player.volume = 1` and sets `mode = .off`.
- `cancel()` stops the task, restores volume 1, clears `stopsAfterCurrent` and sets `mode = .off`.
- End of song: `SleepTimer` follows `player.stopsAfterCurrent` with `Observations`. When it turns false while `mode == .endOfSong` (the Player cleared it at the song's end), it sets `mode = .off`.

- [ ] **Step 1: Write the failing tests.** The fixtures:
  - `SleepRecorder` is an actor that records each duration and returns at once.
  - `SuspendingSleep` records the duration, then waits on `Task.sleep(for: .seconds(3600))` so it can be cancelled.
  - `close(_ a: [Float], _ b: [Float]) -> Bool` compares element-wise within 0.001.

```swift
@MainActor @Suite struct SleepTimerTests {
    let engine = FakeEngine()
    func player() -> Player {
        let p = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        p.play([PlayerTests.song("1"), PlayerTests.song("2")], startAt: 0)
        return p
    }

    @Test func fadesThenPauses() async {
        let recorder = SleepRecorder(); let p = player()
        let timer = SleepTimer(player: p, sleep: { await recorder.record($0) })
        timer.start(.m15)
        await timer.settled()
        #expect(await recorder.durations == [.seconds(900)] + Array(repeating: .milliseconds(500), count: 10))
        #expect(close(engine.setVolumeCalls, [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0, 1.0]))
        #expect(!p.isPlaying && timer.mode == .off)
    }

    @Test func atModeCountsDown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timer = SleepTimer(player: player(), now: { start }, sleep: SuspendingSleep().sleep)
        timer.start(.m30)
        #expect(timer.mode == .at(start.addingTimeInterval(1800)))
        #expect(timer.remaining(at: start.addingTimeInterval(600)) == 1200)
        timer.cancel()
    }

    @Test func endOfSongStopsAfterCurrentThenResetsToOff() async {
        let p = player(); let timer = SleepTimer(player: p, sleep: SuspendingSleep().sleep)
        timer.start(.endOfSong)
        #expect(p.stopsAfterCurrent && timer.mode == .endOfSong)
        p.handle(.ended)                       // the song finished; Player clears the flag
        #expect(!p.stopsAfterCurrent && !p.isPlaying)
        #expect(await eventually { timer.mode == .off })
    }

    @Test func cancelRestoresVolumeAndClears() async {
        let p = player(); let timer = SleepTimer(player: p, sleep: SuspendingSleep().sleep)
        timer.start(.endOfSong); timer.cancel()
        #expect(!p.stopsAfterCurrent && timer.mode == .off)
        timer.start(.m30); timer.cancel(); await timer.settled()
        #expect(engine.setVolumeCalls.last == 1 && timer.mode == .off && p.isPlaying)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `SleepTimerTests`. Expected: FAIL (`SleepTimer` missing).
- [ ] **Step 3: Implement `SleepTimer`, the AppModel property and `SleepTimerMenu`.** The menu lists the six options plus "Off" and shows the remaining minutes in SF Pro Rounded.
- [ ] **Step 4: Run APP `SleepTimerTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Sleep timer: 15–90 min or end of song, 5 s fade" plus the trailer.

---

## Task 11: Audio store and download manager

**Files:**
- Create: `Packages/MagpieKit/Sources/Playback/Storage/AudioEntry.swift`
- Create: `Packages/MagpieKit/Sources/Playback/Storage/AudioStore.swift`
- Create: `App/Downloads/AudioFetcher.swift`
- Create: `App/Downloads/DownloadStatus.swift`
- Create: `App/Downloads/DownloadManager.swift`
- Test: `Packages/MagpieKit/Tests/PlaybackTests/AudioStoreTests.swift`
- Test: `Tests/MagpieTests/DownloadManagerTests.swift`
- Test: `Tests/MagpieTests/AudioStoreAppTests.swift` (iOS-only file protection)

**Interfaces:**
- Consumes: `StreamQuality`, `DownloadPreferences` (Task 5); `NetworkStatusProviding`, `NetworkStatus` (Task 8); `Song` (Task 6).
- Produces (Playback, `public`):

```swift
public enum AudioKind: String, Codable, Sendable { case download, cache }
public enum DownloadReason: Codable, Hashable, Sendable { case song, album(String), playlist(String), favourites }
public struct AudioMetadata: Codable, Hashable, Sendable {
    public var songId: String; public var title: String; public var artist: String; public var artistId: String?
    public var album: String; public var albumId: String?; public var track: Int?; public var disc: Int?
    public var duration: TimeInterval; public var genre: String?; public var coverArtId: String?; public var suffix: String?
    public var replayGain: ReplayGain?
    public init(_ song: Song)
    public var song: Song
}
public struct AudioEntry: Codable, Hashable, Sendable { public var songId: String; public var quality: StreamQuality
    public var fileName: String; public var size: Int64; public var kind: AudioKind; public var reasons: Set<DownloadReason>
    public var downloadedAt: Date; public var lastPlayed: Date?; public var metadata: AudioMetadata }
public struct DownloadedPlaylist: Codable, Hashable, Sendable { public var id: String; public var name: String
    public var coverArtId: String?; public var songIds: [String]; public var savedAt: Date
    public init(id: String, name: String, coverArtId: String?, songIds: [String], savedAt: Date) }
public struct AudioUsage: Sendable, Equatable { public var downloadBytes: Int64; public var cacheBytes: Int64 }
public enum AudioStoreError: Error, Equatable { case downloadsFull, invalidFile, unknownSong }

public actor AudioStore {
    public init(root: URL, scope: String, now: @escaping @Sendable () -> Date = { Date() })
    public nonisolated let directory: URL                       // <root>/Magpie/Audio/<scope>
    public static func fileName(songId: String, quality: StreamQuality, fileExtension: String) -> String
    public static func fileExtension(quality: StreamQuality, suffix: String?, mimeType: String?) -> String
    public func load()
    public func entry(songId: String) -> AudioEntry?
    public func entries() -> [AudioEntry]
    public func localFiles() -> [String: URL]
    @discardableResult
    public func add(_ temporaryFile: URL, metadata: AudioMetadata, quality: StreamQuality, kind: AudioKind,
                    reason: DownloadReason?, fileExtension: String, downloadsLimit: Int64?) throws -> AudioEntry
    /// Re-download: stores the new file first, then deletes the old one; kind, reasons and lastPlayed carry over.
    @discardableResult
    public func replace(songId: String, with temporaryFile: URL, quality: StreamQuality, fileExtension: String) throws -> AudioEntry
    public func addReason(_ reason: DownloadReason, songIds: [String])  // also promotes cache → download
    @discardableResult public func removeReason(_ reason: DownloadReason) -> [String]
    public func markPlayed(songId: String)
    @discardableResult public func removeCache(songIds: Set<String>) -> [String]
    public func removeAll(kind: AudioKind)
    public func eraseScope()
    public func usage() -> AudioUsage
    @discardableResult public func evictCache(limit: Int64, protecting: Set<String>) -> [String]
    public func savePlaylist(_ playlist: DownloadedPlaylist)
    public func playlists() -> [DownloadedPlaylist]
    public func removePlaylist(id: String)
    public func saveCover(_ data: Data, coverArtId: String) throws
    public func coverURL(coverArtId: String) -> URL?
}
```

- Produces (App):

```swift
protocol AudioFetching: Sendable {
    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?)
}
struct URLSessionAudioFetcher: AudioFetching       // ephemeral config, urlCache nil, downloadTask; cancellable
enum DownloadStatus: Equatable { case none, downloaded, downloading(done: Int, total: Int), waitingForWiFi, full
    var text: String; var symbol: String }
@MainActor @Observable final class DownloadManager {
    static let coverSize = 600
    init(store: AudioStore, fetcher: any AudioFetching, network: any NetworkStatusProviding,
         preferences: @escaping @MainActor () -> DownloadPreferences,
         url: @escaping @MainActor (Song, StreamQuality) -> URL?,
         coverURL: @escaping @MainActor (String) -> URL?,
         limitBytes: @escaping (DownloadPreferences) -> Int64? = { $0.downloadsLimit.bytes })
    let store: AudioStore
    var storeDirectory: URL { get }                      // store.directory
    private(set) var localFiles: [String: URL]
    func start() async                                   // load store, mirror localFiles, re-queue pending.json
    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil, coverArtId: String? = nil)
    func preDownload(_ songs: [Song], quality: StreamQuality)
    func redownload(songIds: [String], quality: StreamQuality)   // uses AudioStore.replace
    func remove(_ reason: DownloadReason) async
    func status(for songIds: [String]) -> DownloadStatus
    func retryWaiting()
    func cancelAll()
    var onLocalFilesChanged: (@MainActor () -> Void)?
    func settled() async                                 // tests: every queued job finished, failed or waiting
}
```

**Rules:**
- **The index key is the song id.** `index.json` holds `{ "entries": [songId: AudioEntry], "playlists": [id: DownloadedPlaylist] }`, so there is at most one entry per song. Adding a download for a song that has a cache entry turns that entry into a download: the existing file is kept and the reason added. Adding a cache entry for a song that already has one is a no-op.
- **File names.** `fileName` is the lowercase hex SHA-256 of `songId + "|" + quality.rawValue`, plus `"." + fileExtension`.
- **`fileExtension`:**
  - AAC presets give "aac", MP3 presets give "mp3".
  - Original keeps the suffix when it's in `["mp3","flac","m4a","mp4","aac","wav","aif","aiff","alac","caf"]`.
  - Otherwise the MIME type decides: `audio/mpeg` → mp3, `audio/flac` → flac, `audio/mp4` → m4a, `audio/aac` → aac.
  - Otherwise "mp3".
  - There's no `ogg` or `opus`: AVFoundation can't play them, and there are no Opus presets.
- **Storage layout.**
  - Each audio file has a sidecar `<fileName>.json` (its `AudioEntry`). `index.json` is written with `AtomicFile`.
  - Playlists have sidecars at `playlists/<sha256(id)>.json`.
  - Covers live at `covers/<sha256(coverArtId)>.jpg`.
- **`load()`** reads the index. If that fails:
  - it rebuilds from the sidecars;
  - it deletes audio files without a sidecar, and sidecars without audio;
  - it rewrites the index.

  It never throws.
- **`add`:**
  - Moves the file in.
  - Sets `isExcludedFromBackup` on the file and on `directory`. On iOS, it also sets `.completeUntilFirstUserAuthentication`.
  - Throws `downloadsFull` when `kind == .download` and `downloadBytes + size > downloadsLimit`. Nothing is evicted and the temporary file is deleted.
- **`replace`** throws `unknownSong` when there's no entry.
- **`evictCache`** removes cache entries, oldest `lastPlayed ?? downloadedAt` first, skipping `protecting`, until `cacheBytes <= limit`.
- **`removeReason`** drops the reason everywhere and deletes entries left with no reasons.
- **Manager concurrency.** At most `concurrent` fetches run at once.
  - On mobile data (`isCellular`) without `overMobileData`, manual jobs (reason not nil) wait as `waitingForWiFi`. Pre-downloads never wait.
  - A manual fetch in flight when the network flips to mobile data without permission is cancelled. Its temporary file is deleted and the job goes back to waiting.
- **Pending jobs.** `pending.json` in `store.directory` holds `[{metadata, reason, quality, playlistId}]`, never URLs. URLs are built at fetch time.
- **`downloadsFull`** stops every queued manual job. `status` reads `.full` until `remove` or `retryWaiting` is called.
- **Covers.** `download(…, coverArtId:)` with a cover id fetches `coverURL(id)` once (600 px) at the start, through the same fetcher, and calls `store.saveCover`. A cover failure doesn't fail the download.
- **Status texts and symbols** (D3):

| Status | Text | Symbol |
|---|---|---|
| `.downloaded` | "Downloaded" | `arrow.down.circle.fill` |
| `.downloading` | "Downloading \(done) of \(total)" | `arrow.down.circle.dotted` |
| `.waitingForWiFi` | "Waiting for Wi-Fi" | `wifi` |
| `.full` | "Downloads are full" | `externaldrive.badge.exclamationmark` |
| `.none` | "" | "" |

- [ ] **Step 1: Write the failing package tests (`AudioStoreTests`).** Helpers:
  - `tmp`: a fresh temporary directory per test.
  - `tempFile(bytes:) -> URL`: writes that many zero bytes.
  - `meta(_ id: String, album: String = "a1") -> AudioMetadata`, built from `Song(id: id, title: "T\(id)", artist: "A", album: album, albumId: album, duration: 200)`.
  - `TestClock`: a lock-protected `Date` that starts at 0, with `advance(_:)`. Its `now` is passed to the store.
  - `add(_ store:, _ id:, bytes:, kind:, reason:, limit:)`, which wraps `store.add(tempFile(bytes:), metadata: meta(id), quality: .original, kind:, reason:, fileExtension: "mp3", downloadsLimit: limit)`.

```swift
@Suite struct AudioStoreTests {
    @Test func fileNameIsHashNotServerString() {
        let name = AudioStore.fileName(songId: "../../etc/passwd", quality: .original, fileExtension: "mp3")
        #expect(name.wholeMatch(of: /[0-9a-f]{64}\.mp3/) != nil)
        #expect(AudioStore.fileName(songId: "s1", quality: .original, fileExtension: "mp3")
                != AudioStore.fileName(songId: "s1", quality: .aac160, fileExtension: "mp3"))
    }
    @Test func fileExtensionAllowlist() {
        #expect(AudioStore.fileExtension(quality: .original, suffix: "flac", mimeType: nil) == "flac")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "../x", mimeType: "audio/mpeg") == "mp3")
        #expect(AudioStore.fileExtension(quality: .original, suffix: "opus", mimeType: "audio/ogg") == "mp3")
        #expect(AudioStore.fileExtension(quality: .original, suffix: nil, mimeType: "text/html") == "mp3")
        #expect(AudioStore.fileExtension(quality: .aac160, suffix: "flac", mimeType: nil) == "aac")
        #expect(AudioStore.fileExtension(quality: .mp3_192, suffix: "flac", mimeType: nil) == "mp3")
    }
    @Test func addMovesFileAndExcludesFromBackup() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let temp = tempFile(bytes: 1000)
        let e = try await add(store, "s1", bytes: 1000, kind: .download, reason: .song, limit: nil, file: temp)
        #expect(e.size == 1000 && e.kind == .download && e.reasons == [.song])
        let url = store.directory.appending(path: e.fileName)
        #expect(FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: temp.path))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(store.directory.path.hasSuffix("/Magpie/Audio/abc"))
        #expect(await store.localFiles() == ["s1": url])
    }
    @Test func oneEntryPerSong() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 400, kind: .cache, reason: nil, limit: nil)
        try await add(store, "s1", bytes: 400, kind: .cache, reason: nil, limit: nil)
        #expect(await store.entries().count == 1)
        await store.addReason(.album("a1"), songIds: ["s1"])
        #expect(await store.entry(songId: "s1")?.kind == .download && (await store.usage()) == AudioUsage(downloadBytes: 400, cacheBytes: 0))
    }
    @Test func downloadsLimitRefusesWithoutEvicting() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 1000, kind: .download, reason: .song, limit: 1500)
        try await add(store, "c1", bytes: 300, kind: .cache, reason: nil, limit: nil)
        let temp = tempFile(bytes: 1000)
        await #expect(throws: AudioStoreError.downloadsFull) {
            try await add(store, "s2", bytes: 1000, kind: .download, reason: .song, limit: 1500, file: temp)
        }
        #expect(await store.entries().map(\.songId).sorted() == ["c1", "s1"])
        #expect(await store.usage() == AudioUsage(downloadBytes: 1000, cacheBytes: 300))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
    @Test func cacheEvictsLeastRecentlyPlayedFirst() async throws {
        let clock = TestClock()
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now); await store.load()
        for id in ["s1", "s2", "s3"] { try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        for id in ["s1", "s2", "s3"] { clock.advance(10); await store.markPlayed(songId: id) }
        #expect(await store.evictCache(limit: 800, protecting: []) == ["s1"])
        #expect(await store.usage().cacheBytes == 800)
    }
    @Test func evictionSkipsProtectedAndDownloads() async throws {
        let clock = TestClock()
        let store = AudioStore(root: tmp, scope: "abc", now: clock.now); await store.load()
        try await add(store, "d1", bytes: 400, kind: .download, reason: .song, limit: nil)
        for id in ["s1", "s2", "s3"] { clock.advance(10); try await add(store, id, bytes: 400, kind: .cache, reason: nil, limit: nil) }
        #expect(await store.evictCache(limit: 800, protecting: ["s1"]) == ["s2"])
        #expect(await store.entry(songId: "d1") != nil && (await store.entry(songId: "s1")) != nil)
    }
    @Test func corruptIndexRebuildsFromSidecars() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        try Data("garbage".utf8).write(to: store.directory.appending(path: "index.json"))
        let orphan = store.directory.appending(path: String(repeating: "f", count: 64) + ".mp3")
        try Data(count: 10).write(to: orphan)
        let again = AudioStore(root: tmp, scope: "abc"); await again.load()
        #expect(await again.entry(songId: "s1")?.reasons == [.song])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: again.directory.appending(path: "index.json")))) != nil)
    }
    @Test func reasonsRemoveDownloadOnlyWhenEmpty() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let e = try await add(store, "s1", bytes: 100, kind: .download, reason: .album("a1"), limit: nil)
        await store.addReason(.playlist("p1"), songIds: ["s1"])
        #expect(await store.removeReason(.album("a1")) == [])
        #expect(await store.removeReason(.playlist("p1")) == ["s1"])
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: e.fileName).path))
    }
    @Test func replaceStoresNewThenDeletesOld() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        let old = try await add(store, "s1", bytes: 100, kind: .download, reason: .song, limit: nil)
        let new = try await store.replace(songId: "s1", with: tempFile(bytes: 50), quality: .mp3_320, fileExtension: "mp3")
        #expect(new.quality == .mp3_320 && new.size == 50 && new.reasons == [.song] && new.kind == .download)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: old.fileName).path))
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: new.fileName).path))
        await #expect(throws: AudioStoreError.unknownSong) {
            try await store.replace(songId: "nope", with: tempFile(bytes: 1), quality: .original, fileExtension: "mp3")
        }
    }
    @Test func coverSavedByHashedName() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await store.saveCover(Data([1, 2, 3]), coverArtId: "../al-1")
        let url = try #require(await store.coverURL(coverArtId: "../al-1"))
        #expect(url.lastPathComponent.wholeMatch(of: /[0-9a-f]{64}\.jpg/) != nil && url.deletingLastPathComponent().lastPathComponent == "covers")
        #expect(await store.coverURL(coverArtId: "al-2") == nil)
    }
    @Test func eraseScopeRemovesDirectory() async throws {
        let store = AudioStore(root: tmp, scope: "abc"); await store.load()
        try await add(store, "s1", bytes: 10, kind: .download, reason: .song, limit: nil)
        await store.eraseScope()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(await store.entries().isEmpty)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `AudioStoreTests`. Expected: `cannot find 'AudioStore'`.
- [ ] **Step 3: Implement `AudioEntry.swift` and `AudioStore.swift`.**
- [ ] **Step 4: Run PKG `AudioStoreTests`.** Expected: PASS.
- [ ] **Step 5: Write the failing app tests (`DownloadManagerTests`).**
  - `FakeFetcher` (`final class`, `@unchecked Sendable`, lock-protected) has:
    - `urls: [URL]`;
    - `maxInFlight: Int`;
    - `bytes: Int` (default 1000);
    - `hold(after n: Int)`, which makes every fetch past the first `n` wait until `release()`;
    - `failWith(_ error:)`.

    Each fetch writes a temporary file of `bytes` and returns `(file, "audio/mpeg")`.
  - `FakeNetwork` comes from Task 8.
  - `makeManager(_ prefs: DownloadPreferences = .defaultValue, network: NetworkStatus = .wifi, limit: Int64? = nil)` builds the store under `tmp`. The url closure is `URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)&format=\(q.format)" + (q.maxBitRate.map { "&maxBitRate=\($0)" } ?? ""))!`, and the cover closure is `URL(string: "http://192.168.1.2:4533/rest/getCoverArt?id=\($0)&size=600")!`. It calls `start()` and returns `(manager, fetcher, network)`.
  - `songs(_ ids: String...)` builds `Song`s with `albumId: "a1"`.

```swift
@MainActor @Suite(.serialized) struct DownloadManagerTests {
    @Test func albumDownloadStatusCounts() async {
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, f, _) = await makeManager(prefs)
        f.hold(after: 1)
        m.download(songs("s1", "s2", "s3"), reason: .album("a1"))
        #expect(await eventually { m.status(for: ["s1", "s2", "s3"]) == .downloading(done: 1, total: 3) })
        #expect(m.status(for: ["s1", "s2", "s3"]).text == "Downloading 1 of 3")
        #expect(m.status(for: ["s1", "s2", "s3"]).symbol == "arrow.down.circle.dotted")
        f.release(); await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3"]) == .downloaded)
        #expect(m.status(for: ["s1"]).text == "Downloaded" && m.status(for: ["s1"]).symbol == "arrow.down.circle.fill")
        #expect(Set(m.localFiles.keys) == ["s1", "s2", "s3"])
    }
    @Test func manualWaitsForWiFiOnMobileData() async {
        let (m, f, n) = await makeManager(network: NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
        m.download(songs("s1"), reason: .song); await m.settled()
        #expect(m.status(for: ["s1"]) == .waitingForWiFi && m.status(for: ["s1"]).text == "Waiting for Wi-Fi")
        #expect(m.status(for: ["s1"]).symbol == "wifi" && f.urls.isEmpty)
        n.status = .wifi; m.retryWaiting(); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }
    @Test func mobileDataAllowedWhenSettingOn() async {
        var prefs = DownloadPreferences.defaultValue; prefs.overMobileData = true
        let (m, f, _) = await makeManager(prefs, network: NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
        m.download(songs("s1"), reason: .song); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded && f.urls.count == 1)
    }
    @Test func preDownloadRunsOnMobileData() async {
        let (m, f, _) = await makeManager(network: NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
        m.preDownload(songs("s1"), quality: .aac160); await m.settled()
        #expect(f.urls.count == 1 && f.urls[0].query?.contains("format=aac") == true)
        #expect(await m.store.entry(songId: "s1")?.kind == .cache)
    }
    @Test func concurrencyRespectsSetting() async {
        let (m, f, _) = await makeManager()   // concurrent 2
        f.hold(after: 0)
        m.download(songs("s1", "s2", "s3", "s4"), reason: .album("a1"))
        #expect(await eventually { f.inFlight == 2 })
        f.release(); await m.settled()
        #expect(f.maxInFlight == 2 && f.urls.count == 4)
    }
    @Test func downloadsUseDownloadQuality() async {
        var prefs = DownloadPreferences.defaultValue; prefs.quality = .mp3_320
        let (m, f, _) = await makeManager(prefs)
        m.download(songs("s1"), reason: .song); await m.settled()
        let q = URLComponents(url: f.urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.first { $0.name == "format" }?.value == "mp3" && q.first { $0.name == "maxBitRate" }?.value == "320")
        #expect(await m.store.entry(songId: "s1")?.quality == .mp3_320)
    }
    @Test func coverFetchedOnceWhenAlbumDownloadStarts() async {
        let (m, f, _) = await makeManager()
        m.download(songs("s1", "s2"), reason: .album("a1"), coverArtId: "al-1"); await m.settled()
        #expect(f.urls.filter { $0.path.hasSuffix("/rest/getCoverArt") }.count == 1)
        #expect(f.urls.first { $0.path.hasSuffix("/rest/getCoverArt") }?.query?.contains("size=600") == true)
        #expect(await m.store.coverURL(coverArtId: "al-1") != nil)
    }
    @Test func pendingSurvivesRelaunchWithoutURLs() async throws {
        let cell = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
        let (m, _, _) = await makeManager(network: cell)
        m.download(songs("s1", "s2"), reason: .album("a1")); await m.settled()
        let text = try String(contentsOf: m.storeDirectory.appending(path: "pending.json"), encoding: .utf8)
        for needle in ["rest/stream", "t=", "s=", "u=", "http"] { #expect(!text.contains(needle), "\(needle)") }
        let (again, _, _) = await makeManager(network: cell)   // same tmp root and scope
        #expect(again.status(for: ["s1", "s2"]) == .waitingForWiFi)
    }
    @Test func networkFlipMidDownloadWaitsAndLeavesNoPartialFile() async throws {   // Review Focus 4
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1
        let (m, f, n) = await makeManager(prefs)
        f.hold(after: 0)
        m.download(songs("s1"), reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        n.status = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
        #expect(await eventually { m.status(for: ["s1"]) == .waitingForWiFi })
        f.release(); await m.settled()
        #expect(await m.store.entries().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: m.storeDirectory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".mp3") })
        n.status = .wifi; m.retryWaiting(); await m.settled()
        #expect(m.status(for: ["s1"]) == .downloaded)
    }
    @Test func fullMidAlbumKeepsWhatArrived() async {                               // edge test
        var prefs = DownloadPreferences.defaultValue; prefs.concurrent = 1           // deterministic order
        let (m, _, _) = await makeManager(prefs, limit: 1500)
        m.preDownload(songs("c1"), quality: .original); await m.settled()
        m.download(songs("s1", "s2", "s3"), reason: .album("a1")); await m.settled()
        #expect(m.status(for: ["s1", "s2", "s3"]) == .full)
        #expect(m.status(for: ["s1", "s2", "s3"]).text == "Downloads are full")
        #expect(m.status(for: ["s1", "s2", "s3"]).symbol == "externaldrive.badge.exclamationmark")
        #expect(await m.store.entries().map(\.songId).sorted() == ["c1", "s1"], "cache kept, nothing evicted")
    }
}
```

`makeManager(…, limit:)` passes `limitBytes: { _ in limit }` when `limit` is set. A second `makeManager` call in the same test reuses that test's `tmp`.

`AudioStoreAppTests` (iOS):

```swift
@Test func fileProtectionLetsTheCarPlayWhileLocked() async throws {
    let store = AudioStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), scope: "abc")
    await store.load()
    let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data(count: 100).write(to: temp)
    let e = try await store.add(temp, metadata: AudioMetadata(Song(id: "s1", title: "T", artist: "A", album: "B", duration: 200)),
                                quality: .original, kind: .download, reason: .song, fileExtension: "mp3", downloadsLimit: nil)
    let values = try store.directory.appending(path: e.fileName).resourceValues(forKeys: [.fileProtectionKey])
    #expect(values.fileProtection == .completeUntilFirstUserAuthentication)
}
```

- [ ] **Step 6: Run them and check they fail.** Run APP `DownloadManagerTests` and `AudioStoreAppTests`. Expected: FAIL to compile.
- [ ] **Step 7: Implement `AudioFetcher.swift`, `DownloadStatus.swift` and `DownloadManager.swift`.**
- [ ] **Step 8: Run APP `DownloadManagerTests` and `AudioStoreAppTests`.** Expected: PASS.
- [ ] **Step 9: Commit** with "Downloads: audio store (index + sidecars, quotas, LRU cache) and download manager" plus the trailer.

---

## Task 12: Downloads in the app, and the Downloads & Storage settings

**Files:**
- Create: `App/AppModel+Downloads.swift`
- Create: `App/Screens/Shared/DownloadButton.swift`
- Create: `App/Screens/Settings/DownloadsSettingsView.swift`
- Modify: `App/AppModel.swift`.
  - Add `@ObservationIgnored var downloads: DownloadManager?` and init param `audioFetcher: (any AudioFetching)? = nil`.
  - Call `startDownloads()` right after each `startMatchIndex()` (lines 290 and 362).
  - Call `stopDownloads(erase: true)` in `signOut()` before `store.clear()` (line 386).
- Modify: `App/Screens/Album/AlbumView.swift:90-108`. Below `PlayShuffleButtons`, add `DownloadButton(reason: .album(album.id), songs: songs, coverArtId: album.coverArtId)`.
- Modify: `App/Screens/Playlist/PlaylistView.swift`.
  - Add `DownloadButton(reason: .playlist(id), songs:, playlist:, coverArtId: playlist.coverArtId)`.
  - When `load()` succeeds with a connection, call `model.refreshDownloadedPlaylist(playlist, songs:)`.
- Modify: the song context menus in `AlbumView.swift` (`TrackList`), `PlaylistView.swift` and `SearchView.swift:263`. Add "Download" or "Remove download".
- Modify: `App/Screens/Settings/SettingsView.swift`. Add `Section("Downloads & Storage")` holding a NavigationLink "Downloads & Storage" to `DownloadsSettingsView`.
- Modify: `App/AppModel+Preferences.swift`. When downloads preferences change, call `downloads?.retryWaiting()`. When `keepFavourites` toggles, call `setKeepFavourites(_:)`.
- Test: `Tests/MagpieTests/DownloadsAppTests.swift`

**Interfaces:**
- Consumes: `DownloadManager`, `AudioStore`, `DownloadReason`, `DownloadedPlaylist` (Task 11); `NavidromeClient.starred()` (Task 6).
- Produces:

```swift
extension AppModel {
    func startDownloads()                                  // AudioStore(root: dataDirectory, scope: navidromeScope!)
    func stopDownloads(erase: Bool)
    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil, coverArtId: String? = nil)
    func removeDownload(_ reason: DownloadReason) async
    func downloadStatus(_ songIds: [String]) -> DownloadStatus
    func refreshDownloadedPlaylist(_ playlist: Playlist, songs: [Song]) async
    func setKeepFavourites(_ on: Bool) async
    func redownloadAtCurrentQuality() async
    func removeAllDownloads() async
    func clearCache() async
    var storageUsage: AudioUsage { get async }
}
```

**Rules:**
- **Scopes.** The store lives under `dataDirectory`. The `AppModel` designated init's `dataDirectory` is Application Support or a test temp folder.
- **Wiring.** `startDownloads()` builds the `DownloadManager` with:
  - `url: { client.streamURL(songId: $0.id, maxBitRate: $1.maxBitRate, format: $1.format) }`;
  - `coverURL: { coverArtURL($0, size: DownloadManager.coverSize) }`;
  - `network`, and the injected or real fetcher.
- **Covers.** `download(…, coverArtId:)` passes the cover id through: the album's or playlist's `coverArtId`, nil for single songs.
- **`stopDownloads(erase: true)`** calls `downloads?.cancelAll()`, then `store.eraseScope()`, then `downloads = nil`. Each manager captures the scope it was built for, and a completion arriving after `cancelAll()` deletes its temporary file and writes nothing.
- **Playlist refresh** diffs `songIds`: new songs are downloaded with `.playlist(id)`, and removed songs lose that reason.
- **Re-download** calls `downloads.redownload(songIds:quality:)` for every download entry whose quality ≠ `preferences.downloads.quality`. `AudioStore.replace` stores the new file before deleting the old one.
- **`DownloadButton`** shows:
  - `arrow.down.to.line` "Download" when nothing is downloaded.
  - Otherwise `StatusLine`-style text plus symbol from `DownloadStatus` (D3), with a "Remove download" action.

  It is a 44 pt target with VoiceOver label "Download" and value equal to the status text.
- **`DownloadsSettingsView`** (rows in spec §6 order):
  - Pickers and toggles for every `DownloadPreferences` field, including a "Download quality" picker and "Keep favourites downloaded".
  - The storage used ("Downloads 1.2 GB · Cache 340 MB", `ByteCountFormatter`).
  - "Re-download at new quality".
  - "Remove all downloads" and "Clear cache", each behind a `confirmationDialog`.

- [ ] **Step 1: Write the failing tests.** The fixtures:
  - `signedInModel(fetcher:user:)` builds the model with `dataDirectory: tmp`, `audioFetcher: fetcher`, `network: FakeNetwork(.wifi)` and the `HostSwitchTransport` stubs for ping and login. Its `/api/song` returns `[]`, and `/rest/getStarred2` and `/rest/getPlaylist` answer per test. It then signs in to `http://192.168.1.2:4533` as `user` (default "admin").
  - `FakeFetcher` comes from Task 11.

```swift
@MainActor @Suite(.serialized) struct DownloadsAppTests {
    @Test func signOutRemovesScopeAudio() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        let dir = try #require(model.downloads?.storeDirectory)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        model.signOut()
        #expect(model.downloads == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: dir.path) })
    }

    @Test func lateCompletionAfterSignOutIsDiscarded() async throws {           // Review Focus 3
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1")], reason: .song)
        #expect(await eventually { f.inFlight == 1 })
        let oldDir = try #require(model.downloads?.storeDirectory)
        model.signOut()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "other", password: "pw")
        let newDir = try #require(model.downloads?.storeDirectory)
        #expect(newDir != oldDir)
        f.release(); try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(await model.downloads!.store.entry(songId: "s1") == nil)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func albumDownloadSavesItsCover() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.download([song("s1"), song("s2")], reason: .album("a1"), coverArtId: "al-1"); await model.downloads!.settled()
        let cover = try #require(f.urls.first { $0.path.hasSuffix("/rest/getCoverArt") })
        #expect(URLComponents(url: cover, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value == "600")
        #expect(await model.downloads!.store.coverURL(coverArtId: "al-1") != nil)
    }

    @Test func playlistRefreshOnOpen() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let p = Playlist(id: "p1", name: "Mix", songCount: 2, duration: 400, coverArtId: "pl-1")
        model.download([song("s1"), song("s2")], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: "pl-1", songIds: ["s1", "s2"], savedAt: .now),
                       coverArtId: "pl-1")
        await model.downloads!.settled()
        await model.refreshDownloadedPlaylist(p, songs: [song("s2"), song("s3")])
        await model.downloads!.settled()
        #expect(Set(model.downloads!.localFiles.keys) == ["s2", "s3"])
        #expect(await model.downloads!.store.playlists().first?.songIds == ["s2", "s3"])
    }

    @Test func favouritesToggle() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.transport(stub: "/rest/getStarred2", #""starred2":{"song":[{"id":"s7","title":"Seven"},{"id":"s8","title":"Eight"}]}"#)
        await model.setKeepFavourites(true); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s7")?.reasons == [.favourites])
        #expect(Set(model.downloads!.localFiles.keys) == ["s7", "s8"])
        await model.setKeepFavourites(false)
        #expect(model.downloads!.localFiles.isEmpty)
    }

    @Test func reDownloadAtNewQuality() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .song); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.quality = .mp3_320 }
        await model.redownloadAtCurrentQuality(); await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s1")?.quality == .mp3_320)
        let audio = try FileManager.default.contentsOfDirectory(atPath: model.downloads!.storeDirectory.path)
            .filter { $0.hasSuffix(".mp3") || $0.hasSuffix(".flac") }
        #expect(audio.count == 1)
    }
}
```

`model.transport(stub:_:)` is a test-only helper on the fixture. It adds a Subsonic `ok` stub for the path to the fixture's `HostSwitchTransport`.

- [ ] **Step 2: Run them and check they fail.** Run APP `DownloadsAppTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement `AppModel+Downloads.swift`, the AppModel hook lines, `DownloadButton`, the screen hooks and `DownloadsSettingsView`.**
- [ ] **Step 4: Run APP `DownloadsAppTests` and `V1FlowsDocAppTests`.** Expected: PASS. Sign-out still clears what FLOWS §3a lists.
- [ ] **Step 5: Commit** with "Downloads: album, playlist, song and favourites downloads; Downloads & Storage settings" plus the trailer.

---

## Task 13: Play local files first, pre-download, cache upkeep

**Files:**
- Create: `Packages/MagpieKit/Sources/Playback/Storage/PreDownloadPlan.swift`
- Create: `App/AppModel+PreDownload.swift`
- Modify: `App/AppModel.swift:201-204`. `NavidromeStreamURLs(localURL:)` reads `downloads?.localFiles[$0]` through a `LocalFilesBox` (lock-protected, set by `onLocalFilesChanged`), because the player is built before `self`.
- Modify: `App/Playback/NavidromeAdapters.swift`. `streamURL` returns the local file when present. `originalURL` returns nil for a local file.
- Modify: `App/AppModel+Downloads.swift`. `startDownloads()` calls `watchQueueForPreDownload()`, and `onLocalFilesChanged` calls `player.upcomingURLsChanged()`.
- Test: `Packages/MagpieKit/Tests/PlaybackTests/PreDownloadPlanTests.swift`, `Tests/MagpieTests/LocalPlaybackTests.swift`

**Interfaces:**
- Consumes: `DownloadManager.preDownload`, `AudioStore.markPlayed/removeCache/evictCache` (Task 11); `Player.upcomingURLsChanged` (Task 7); `currentStreamQuality` (Task 8).
- Produces:
  - `public enum PreDownloadPlan { public static func songs(upcoming: [Song], count: Int, isLocal: (String) -> Bool) -> [Song] }`. It returns the first `count` upcoming songs that aren't local, de-duplicated by id, in order.
  - `extension AppModel { func watchQueueForPreDownload(); var cacheLimitBytes: Int64 }`. `cacheLimitBytes` is `cacheLimitOverride ?? preferences.downloads.cacheLimit.bytes`. `@ObservationIgnored var cacheLimitOverride: Int64?` is a stored property in `AppModel.swift`, used by tests only.

**Rules:** `watchQueueForPreDownload` uses `Observations` over `(current id, upcoming ids)`. On each change:
1. Call `downloads.preDownload(PreDownloadPlan.songs(...), quality: currentStreamQuality)`.
2. Call `store.markPlayed(current)`.
3. If `!keepRecentlyPlayed`, call `store.removeCache(songIds: [the previous current id])`.
4. Call `store.evictCache(limit: cacheLimitBytes, protecting: [current] + the next `preDownload` ids)`.

Finds are pre-downloaded like any song. Scrobbling doesn't depend on the source.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func planSkipsLocalAndDuplicates() {
    let up = ["a", "b", "c", "a", "d", "e"].map(song)
    #expect(PreDownloadPlan.songs(upcoming: up, count: 3, isLocal: { $0 == "b" }).map(\.id) == ["a", "c", "d"])
    #expect(PreDownloadPlan.songs(upcoming: up, count: 0, isLocal: { _ in false }).isEmpty)
}
```

LocalPlaybackTests (app). They use Task 12's `signedInModel(fetcher:)`, with the model built using `engine: engine` (a `FakeEngine`):

```swift
@MainActor @Suite(.serialized) struct LocalPlaybackTests {
    @Test func localFileUsedWhenPresent() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2")], startAt: 0)
        let items = engine.setItemsCalls.last!.items
        #expect(!items[0].1.isFileURL && items[1].1.isFileURL)
        #expect(items[1].1 == model.downloads!.localFiles["s2"])
    }
    @Test func completedPreDownloadSwapsOnlyUpcoming() async throws {
        let f = FakeFetcher(); f.hold(after: 0)
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s1"), song("s2")], startAt: 0)
        let first = engine.setItemsCalls.last!.items
        #expect(!first[1].1.isFileURL)
        f.release(); await model.downloads!.settled()
        #expect(await eventually { engine.setItemsCalls.last!.items[1].1.isFileURL })
        #expect(engine.setItemsCalls.last!.items[0].1 == first[0].1 && engine.seeks.isEmpty)
    }
    @Test func preDownloadsAheadByN() async throws {
        let f = FakeFetcher()
        let model = try await signedInModel(fetcher: f)
        model.updatePreferences { $0.downloads.preDownload = 2 }
        model.play((1...5).map { song("s\($0)") }, startAt: 0)
        await model.downloads!.settled()
        let ids = f.urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value }
        #expect(ids == ["s2", "s3"])
        #expect(f.urls.allSatisfy { $0.query?.contains("format=raw") == true }, "Wi-Fi quality")
        #expect(await model.downloads!.store.entry(songId: "s2")?.kind == .cache)
    }
    @Test func cacheRemovedAfterPlayWhenKeepOff() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.preDownload = 1; $0.downloads.keepRecentlyPlayed = false }
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        await model.downloads!.settled()
        #expect(await model.downloads!.store.entry(songId: "s2") != nil)
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s2
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // now on s3
        #expect(await eventually { await model.downloads!.store.entry(songId: "s2") == nil })
    }
    @Test func currentNeverEvicted() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.cacheLimitOverride = 1
        model.updatePreferences { $0.downloads.preDownload = 1 }
        model.play([song("s0"), song("s1")], startAt: 0)
        await model.downloads!.settled()
        model.player.handle(.itemChanged(model.player.queue.upcoming[0].id))   // s1 (cached) is current
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.downloads!.store.entry(songId: "s1") != nil)
    }
}
```

`eventually` here takes an `async` closure. Add an async overload next to the existing one.

- [ ] **Step 2: Run them and check they fail.** Run PKG `PreDownloadPlanTests`, then APP `LocalPlaybackTests`. Expected: FAIL.
- [ ] **Step 3: Implement the plan, the box, the adapter change and the watcher.**
- [ ] **Step 4: Run PKG `PreDownloadPlanTests`, APP `LocalPlaybackTests` and APP `PlayerTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Playback: local files first, pre-download ahead, cache upkeep" plus the trailer.

---

## Task 14: Offline mode

**Files:**
- Create: `Packages/MagpieKit/Sources/Playback/Storage/OfflineCatalog.swift`
- Create: `App/AppModel+Offline.swift`
- Create: `App/Screens/Downloads/DownloadsView.swift`
- Create: `App/Screens/Search/OfflineSearch.swift`
- Modify: `App/AppModel.swift`.
  - Add stored `var serverReachable = true`.
  - In `request` (lines 432-435), when `reconnect` returns false, call `noteUnreachable()` before rethrowing.
  - In `performReconnect` (line 486), call `noteReachable()` on success.
- Modify: `App/Screens/Home/HomeView.swift:21-40`. When `model.isOffline`, show a "You're offline" line (`wifi.slash`, D3) above a single Downloaded shelf (`OfflineCatalog.albums()`, albums only, at most 12). Task 20 keeps this line and this shelf source.
- Modify: `App/Screens/Library/LibraryView.swift:17-29`. When offline, show only the Downloads row and the "You're offline" line (`wifi.slash`), and hide the Recently added grid. Task 21 keeps all of this.
- Modify: `App/Screens/Shared/ScreenKit.swift:8-40`. Add `Route.downloads`.
- Modify: `App/Screens/Search/SearchView.swift`. When offline, the `SearchModel` source is `OfflineSearch`, with sections "Downloads" and "Recently played on this phone".
- Modify: `App/Screens/Activity/ActivityView.swift`, `App/Screens/Try/TrySheet.swift` and `App/Screens/Settings/SettingsView.swift` (Lidarr section). When offline, disable the actions and show "You're offline" with `wifi.slash`.
- Modify: `App/Screens/Shared/Artwork.swift:76-87`. Use `model.localCoverURL(coverArtId)` (a file image) before the network.
- Test: `Packages/MagpieKit/Tests/PlaybackTests/OfflineCatalogTests.swift`, `Tests/MagpieTests/OfflineAppTests.swift`

**Interfaces:**
- Consumes: `OfflineMode` (Task 5); `AudioStore.entries()/playlists()/coverURL` (Task 11); `Player.isPlayable`, `upcomingURLsChanged` (Task 7); `NetworkMonitor` (Task 8).
- Produces:

```swift
public struct OfflineCatalog: Sendable {
    public init(entries: [AudioEntry], playlists: [DownloadedPlaylist])
    public func albums() -> [Album]                // downloads only; grouped by albumId (title+artist when nil); sorted by name, case-insensitive
    public func album(id: String) -> Album?        // songs ordered disc, track
    public func artists() -> [Artist]              // albumCount from the snapshot
    public func playlists() -> [Playlist]
    public func songs(inPlaylist id: String) -> [Song]
    public func songs() -> [Song]                  // downloads, sorted by title
    public func genres() -> [Genre]                // counts from the snapshot genre strings
    public func search(_ query: String) -> LibrarySearchResult            // downloads; case- and diacritic-insensitive
    public func recentlyPlayed(matching query: String) -> [Song]          // cache entries with lastPlayed, newest first
}
extension AppModel {
    var isOffline: Bool { get }                     // .on → true; .off → false; .automatic → !serverReachable
    func noteUnreachable(); func noteReachable()
    func checkReachability() async                  // probe the session's addresses once
    var offlineCatalog: OfflineCatalog { get async }
    func localCoverURL(_ coverArtId: String?) -> URL?
}
```

**Rules:**
- **Becoming unreachable.** `noteUnreachable()` sets `serverReachable = false` and starts a probe loop: `checkReachability()` every 30 s, and immediately when `network.status.isConnected` turns true. The loop stops when the server is reachable.
- **Entering offline mode** (an `isOffline` change, observed) sets `player.isPlayable = { local file exists }` and calls `upcomingURLsChanged()`.
- **Leaving offline mode** restores `{ _ in true }`.
- **Lidarr.** Request polling (`pollRequests`) is skipped while offline.

- [ ] **Step 1: Write the failing tests.** The helper `entry(_ id: String, title: String = "T", album: String, albumId: String?, artist: String = "A", artistId: String? = "ar1", track: Int? = nil, genre: String? = nil, kind: AudioKind = .download, lastPlayed: Date? = nil) -> AudioEntry` builds an entry directly. Its file name is a placeholder, the size is 1, and the reasons are `[.song]` for downloads and `[]` for cache.

```swift
@Suite struct OfflineCatalogTests {
    @Test func albumsGroupedAndSorted() {
        let c = OfflineCatalog(entries: [entry("s1", album: "b-album", albumId: "b", track: 2), entry("s2", album: "b-album", albumId: "b", track: 1),
                                         entry("s3", album: "A-album", albumId: "a", track: 1), entry("c1", album: "Z", albumId: "z", kind: .cache)],
                               playlists: [])
        #expect(c.albums().map(\.name) == ["A-album", "b-album"], "cache entries aren't downloads")
        #expect(c.album(id: "b")?.songs?.map(\.id) == ["s2", "s1"])
        #expect(c.album(id: "b")?.songCount == 2)
        #expect(c.artists().map(\.albumCount) == [2])
    }
    @Test func albumWithoutIdGroupsByTitleAndArtist() {
        let c = OfflineCatalog(entries: [entry("s1", album: "Loose", albumId: nil), entry("s2", album: "Loose", albumId: nil)], playlists: [])
        #expect(c.albums().count == 1 && c.albums()[0].songCount == 2)
    }
    @Test func playlistsKeepOrder() {
        let p = DownloadedPlaylist(id: "p1", name: "Mix", coverArtId: nil, songIds: ["s2", "s1", "gone"], savedAt: .now)
        let c = OfflineCatalog(entries: [entry("s1", album: "x", albumId: "x"), entry("s2", album: "x", albumId: "x")], playlists: [p])
        #expect(c.playlists().map(\.name) == ["Mix"])
        #expect(c.songs(inPlaylist: "p1").map(\.id) == ["s2", "s1"], "songs not on the phone are skipped")
    }
    @Test func searchFoldsCaseAndDiacritics() {
        let c = OfflineCatalog(entries: [entry("s1", title: "Minuit", album: "Café de la Mémoire", albumId: "c"),
                                         entry("s2", title: "Other", album: "Elsewhere", albumId: "e")], playlists: [])
        #expect(c.search("cafe").albums.map(\.name) == ["Café de la Mémoire"])
        #expect(c.search("MEMOIRE").songs.map(\.id) == ["s1"])
        #expect(c.search("minuit").songs.map(\.id) == ["s1"])
        #expect(c.search("zzz") == LibrarySearchResult())
    }
    @Test func genresCountedFromSnapshot() {
        let c = OfflineCatalog(entries: [entry("s1", album: "a", albumId: "a", genre: "Ambient"), entry("s2", album: "a", albumId: "a", genre: "Ambient"),
                                         entry("s3", album: "b", albumId: "b", genre: "Ambient"), entry("s4", album: "b", albumId: "b", genre: nil)],
                               playlists: [])
        #expect(c.genres() == [Genre(name: "Ambient", songCount: 3, albumCount: 2)])
    }
    @Test func recentlyPlayedOnlyCacheWithPlays() {
        let t = Date(timeIntervalSince1970: 100)
        let c = OfflineCatalog(entries: [entry("c1", title: "Old", album: "x", albumId: "x", kind: .cache, lastPlayed: t),
                                         entry("c2", title: "New", album: "x", albumId: "x", kind: .cache, lastPlayed: t + 10),
                                         entry("c3", album: "x", albumId: "x", kind: .cache),
                                         entry("d1", album: "x", albumId: "x", lastPlayed: t + 20)], playlists: [])
        #expect(c.recentlyPlayed(matching: "").map(\.id) == ["c2", "c1"])
        #expect(c.recentlyPlayed(matching: "old").map(\.id) == ["c1"])
    }
}
```

OfflineAppTests use Task 12's `signedInModel(fetcher:)` with a `FakeEngine`. `transport.setDown(_:with:)` (existing) takes a host down, and `setDown([])` brings it back.

```swift
@MainActor @Suite(.serialized) struct OfflineAppTests {
    @Test func automaticOfflineWhenUnreachable() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(!model.isOffline)
        transport.setDown(["192.168.1.2"])
        await #expect(throws: URLError.self) { _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) } }
        #expect(model.isOffline && !model.serverReachable)
        transport.setDown([])
        await model.checkReachability()
        #expect(!model.isOffline)
    }
    @Test func forcedOnAndOff() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.isOffline && model.serverReachable)
        model.updatePreferences { $0.downloads.offlineMode = .off }
        model.noteUnreachable()
        #expect(!model.isOffline)
    }
    @Test func offlineSkipsToNextLocalSong() async throws {               // Review Focus 5
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1"), song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { engine.setItemsCalls.last!.items.count == 2 })
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
        #expect(model.player.queue.upcoming.map(\.song.id) == ["s2", "s3"], "queue untouched")
        model.updatePreferences { $0.downloads.offlineMode = .automatic }
        #expect(await eventually { engine.setItemsCalls.last!.items.count == 3 })
    }
    @Test func offlineCurrentStreamFailureSkipsToNextLocal() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s3")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2"), song("s3")], startAt: 0)      // s1 streams
        model.updatePreferences { $0.downloads.offlineMode = .on }
        model.player.handle(.failed(model.player.queue.current!.id, "offline"))
        #expect(model.player.queue.current?.song.id == "s3" && model.player.isPlaying && model.player.lastError == nil)
    }
    @Test func lidarrActionsDisabledOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.tryAvailability.message == "You're offline")
    }
    @Test func offlineHomeAndLibraryFlags() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .album("a1")); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.offlineCatalog.albums().count == 1)
        #expect(model.localCoverURL(nil) == nil)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `OfflineCatalogTests` and APP `OfflineAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement the catalog, `AppModel+Offline`, the AppModel hook lines and the views.** `DownloadsView` has a segmented control with Albums, Artists, Playlists and Songs; Task 19 adds Genres. Tapping plays from local files. Albums open an offline album page that reuses `AlbumView` content with `OfflineCatalog.album(id:)`.
- [ ] **Step 4: Run PKG `OfflineCatalogTests`, APP `OfflineAppTests` and APP `AppModelTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Offline mode: automatic/on/off, downloads-only browsing and search" plus the trailer.

---

## Task 15: Scrobble threshold by listened time

**Files:**
- Modify: `Packages/MagpieKit/Sources/Playback/PlaybackEngine.swift:34-36`. The signature becomes `func scrobble(_ song: Song, submission: Bool, at: Date?) async throws`.
- Modify: `Packages/MagpieKit/Sources/Playback/Player.swift`.
  - Remove `scrobbleCap` (lines 42-43).
  - `TrackPlayback` (lines 62-67) gains `listened` and `lastTick`.
  - `init` gains `scrobbleRule: @escaping () -> ScrobbleRule = { .standard }`.
  - Update `seek` (lines 130-134), `urlsInvalidated`, `.time` (lines 238-242), `maybeSubmitScrobble` (lines 322-330) and `scrobble` (lines 332-346).
- Modify: `App/Playback/NavidromeAdapters.swift:96-106`. `NavidromeScrobbler.scrobble(_ song:…)` uses `song.id`.
- Create: `App/Playback/ScrobbleSettings.swift`. This task owns it. Task 17 only reads it.
- Modify: `App/AppModel.swift:201-204`. Add `@ObservationIgnored let scrobbleSettings: ScrobbleSettings`, built before `player` from `preferences.scrobbling`. Pass `scrobbleRule: { settings.value.rule }`. `preferencesDidChange` calls `scrobbleSettings.set(preferences.scrobbling)`.
- Modify: `Tests/MagpieTests/PlayerTests.swift:27-33`. `FakeScrobbler.scrobble(_ song:submission:at:)` keeps recording `Call(songId:submission:)` in `calls` and also appends `at` to `private(set) var dates: [Date?]`.
- Modify: `Tests/MagpieTests/TryAndSettingsTests.swift:215-219`. Use the new signature.
- Test: `Tests/MagpieTests/PlayerTests.swift`

**Interfaces:**
- Consumes: `ScrobbleRule` (Task 5).
- Produces:
  - `Scrobbler.scrobble(_:submission:at:)`
  - `Player.init(…, scrobbleRule:)`
  - `final class ScrobbleSettings: Sendable { init(_ p: ScrobblePreferences); var value: ScrobblePreferences { get }; func set(_ p: ScrobblePreferences) }`

**What `at:` means.** It's the play-start time: `now()` at `beginEntry` (`TrackPlayback.startedAt`, as today). It's `nil` for "now playing". Task 17 sends it as Navidrome's `time` and as ListenBrainz's `listened_at`.

**Algorithm:**

```text
beginEntry:         playback.listened = 0; playback.lastTick = 0
.time(id, t):       if t > lastTick { listened += t - lastTick }; lastTick = t
seek(t), urlsInvalidated resume at t:  lastTick = t      (a jump is not listening)
maybeSubmitScrobble: threshold = scrobbleRule().threshold(duration: entry.song.duration)   // API duration only
                     submit once when threshold != nil && listened >= threshold
```

- [ ] **Step 1: Write the failing tests.** The existing `scrobblesAtHalf` must keep passing unchanged.

```swift
@Test func seekForwardDoesNotCount() async {
    let player = makePlayer()
    player.play([Self.song("1", duration: 300)], startAt: 0)
    let id = player.queue.current!.id
    player.handle(.time(id, 10, duration: 300)); player.seek(200)
    player.handle(.time(id, 201, duration: 300)); player.handle(.time(id, 290, duration: 300))
    await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls == [.init(songId: "1", submission: false)])
}
@Test func customRuleTenPercent() async {
    let player = Player(engine: engine, scrobbler: scrobbler, urls: urls, scrobbleRule: { ScrobbleRule(percent: 10, minutes: nil) })
    player.play([Self.song("1", duration: 600)], startAt: 0)
    let id = player.queue.current!.id
    player.handle(.time(id, 59, duration: 600)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.count == 1)
    player.handle(.time(id, 60, duration: 600)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.last == .init(songId: "1", submission: true))
}
@Test func shortSongNeverCounted() async {
    let player = makePlayer()
    player.play([Self.song("1", duration: 25)], startAt: 0)
    let id = player.queue.current!.id
    for t in stride(from: 0.5, through: 25, by: 0.5) { player.handle(.time(id, t, duration: 25)) }
    await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls == [.init(songId: "1", submission: false)])
}
@Test func engineDurationIgnored() async {
    let player = makePlayer()
    player.play([Self.song("1", duration: 200)], startAt: 0)
    let id = player.queue.current!.id
    player.handle(.time(id, 99, duration: 1000)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.count == 1)
    player.handle(.time(id, 100, duration: 1000)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.last == .init(songId: "1", submission: true))
}
@Test func unknownDurationUsesMinutes() async {
    let player = makePlayer()
    player.play([Self.song("1", duration: 0)], startAt: 0)
    let id = player.queue.current!.id
    player.handle(.time(id, 239, duration: nil)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.count == 1)
    player.handle(.time(id, 240, duration: nil)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.last == .init(songId: "1", submission: true))
}
@Test func submissionCarriesPlayStartTime() async {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var clock = t0
    let player = Player(engine: engine, scrobbler: scrobbler, urls: urls, now: { clock })
    player.play([Self.song("1", duration: 200)], startAt: 0)
    clock = t0.addingTimeInterval(100)
    player.handle(.time(player.queue.current!.id, 100, duration: 200)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.dates == [nil, t0], "now playing has no time; the play carries its start")
}
@Test func ruleChangeAppliesToTheNextCheck() async {
    let settings = ScrobbleSettings(.defaultValue)
    let player = Player(engine: engine, scrobbler: scrobbler, urls: urls, scrobbleRule: { settings.value.rule })
    player.play([Self.song("1", duration: 200)], startAt: 0)
    var p = ScrobblePreferences.defaultValue; p.rule = ScrobbleRule(percent: 10, minutes: nil); settings.set(p)
    player.handle(.time(player.queue.current!.id, 20, duration: 200)); await player.waitForPendingScrobbles()
    #expect(await scrobbler.calls.last == .init(songId: "1", submission: true))
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `PlayerTests`. Expected: FAIL.
- [ ] **Step 3: Implement the protocol change, the algorithm, `ScrobbleSettings` and the call-site updates.**
- [ ] **Step 4: Run APP `PlayerTests`, `PlaybackFlowsVerifyTests` and `TryAndSettingsTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Scrobbling: threshold by listened time, percentage or minutes" plus the trailer.

---

## Task 16: ListenBrainz submit-listens

**Files:**
- Create: `Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift`
- Modify: `Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient.swift`. Make `sendWithDeadline`, `token`, `apiTimeout` and `limiter` `internal` (they are private now), so the extension file can use them. `init` gains `clientVersion: String = "unknown"`, stored as `public let clientVersion`. The app passes `AppModel.marketingVersion` (Task 1). There's no version literal in the package.
- Modify: `scripts/check-writes.sh`. Add the allowlist entry `"Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift|G1 allowlist: listenbrainz submit-listens"` to the comment block and the `allow` array.
- Test: `Packages/MagpieKit/Tests/ListenBrainzKitTests/SubmitListensTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ListenType: String, Sendable { case single, playingNow = "playing_now", importBatch = "import" }
public struct Listen: Sendable, Hashable, Codable {
    public var listenedAt: Date?; public var trackName: String; public var artistName: String
    public var releaseName: String?; public var durationMs: Int?; public var recordingMBID: MBID?
    public init(listenedAt: Date?, trackName: String, artistName: String, releaseName: String? = nil,
                durationMs: Int? = nil, recordingMBID: MBID? = nil)
}
extension ListenBrainzClient {
    public static let maxListensPerCall = 100
    /// One request. The caller chunks: more than `maxListensPerCall` listens throws `.http(status: 413)` without sending.
    public func submitListens(_ listens: [Listen], type: ListenType) async throws
}
```

**Rules:**
- POST `https://api.listenbrainz.org/1/submit-listens` with `Authorization: Token <token>` and `Content-Type: application/json`, within `apiTimeout`, spaced by `limiter`.
- No token: throw `.unauthorized` and send nothing.
- One call is one request. The client doesn't split; Task 17's router sends chunks of 100.
- `.single` and `.playingNow` take exactly one listen.
- `.playingNow` omits `listened_at`.
- The body (keys exactly):

```json
{"listen_type":"single","payload":[{"listened_at":1700000000,"track_metadata":{"artist_name":"A","track_name":"T","release_name":"B","additional_info":{"duration_ms":200000,"recording_mbid":"…","submission_client":"Magpie","submission_client_version":"<clientVersion>","media_player":"Magpie"}}}]}
```

The line setting `httpMethod = "POST"` carries the comment `// G1 allowlist: listenbrainz submit-listens` within the 3 lines above it.

- [ ] **Step 1: Write the failing tests** (MockTransport):

```swift
@Test func singleListenBody() async throws {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
    let client = ListenBrainzClient(transport: t, token: "tok", clientVersion: "9.9.9")
    try await client.submitListens([Listen(listenedAt: Date(timeIntervalSince1970: 1_700_000_000), trackName: "T",
                                           artistName: "A", releaseName: "B", durationMs: 200_000)], type: .single)
    let r = try #require(t.requests.last)
    #expect(r.httpMethod == "POST" && r.url?.host == "api.listenbrainz.org")
    #expect(r.value(forHTTPHeaderField: "Authorization") == "Token tok")
    let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
    #expect(body["listen_type"] as? String == "single")
    let item = (body["payload"] as! [[String: Any]])[0]
    #expect(item["listened_at"] as? Int == 1_700_000_000)
    let meta = item["track_metadata"] as! [String: Any]
    #expect(meta["artist_name"] as? String == "A" && meta["track_name"] as? String == "T" && meta["release_name"] as? String == "B")
    let info = meta["additional_info"] as! [String: Any]
    #expect(info["submission_client"] as? String == "Magpie" && info["submission_client_version"] as? String == "9.9.9")
    #expect(info["duration_ms"] as? Int == 200_000)
}
func listen(_ i: Int) -> Listen { Listen(listenedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i)), trackName: "T\(i)", artistName: "A") }
func payload(_ r: URLRequest) throws -> (type: String?, items: [[String: Any]]) {
    let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
    return (body["listen_type"] as? String, body["payload"] as! [[String: Any]])
}
@Test func playingNowHasNoTimestamp() async throws {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
    try await ListenBrainzClient(transport: t, token: "tok").submitListens([listen(1)], type: .playingNow)
    let p = try payload(t.requests.last!)
    #expect(p.type == "playing_now" && p.items.count == 1 && p.items[0]["listened_at"] == nil)
}
@Test func noTokenSendsNothing() async {
    let t = MockTransport()
    await #expect(throws: ListenBrainzError.unauthorized) {
        try await ListenBrainzClient(transport: t, token: nil).submitListens([listen(1)], type: .single)
    }
    #expect(t.requests.isEmpty)
}
@Test func importIsOneRequestAndCapped() async throws {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
    let client = ListenBrainzClient(transport: t, token: "tok")
    try await client.submitListens((0..<100).map(listen), type: .importBatch)
    #expect(t.requests.count == 1)
    let p = try payload(t.requests[0])
    #expect(p.type == "import" && p.items.count == 100 && p.items[99]["listened_at"] as? Int == 1_700_000_099)
    await #expect(throws: ListenBrainzError.http(status: 413)) { try await client.submitListens((0..<101).map(listen), type: .importBatch) }
    #expect(t.requests.count == 1, "nothing sent for an oversized call")
}
@Test func unauthorizedMaps() async {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", status: 401)
    await #expect(throws: ListenBrainzError.unauthorized) {
        try await ListenBrainzClient(transport: t, token: "tok").submitListens([listen(1)], type: .single)
    }
}
@Test func tokenNeverGoesToLabs() async throws {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
    try await ListenBrainzClient(transport: t, token: "tok").submitListens([listen(1)], type: .single)
    #expect(t.requests.allSatisfy { $0.url?.host == "api.listenbrainz.org" })
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `SubmitListensTests`. Expected: FAIL.
- [ ] **Step 3: Implement the extension and the visibility changes.**
- [ ] **Step 4: Run PKG `SubmitListensTests` and PKG `ListenBrainzTests`.** Expected: PASS.
- [ ] **Step 5: Run `scripts/check-writes.sh`.** Expected: exit 0 and "G1 check: no write verbs outside LidarrWriteGate…". Then check the guard still bites by temporarily removing the marker comment and re-running (expected exit 1), and restore it.
- [ ] **Step 6: Commit** with "ListenBrainz: submit-listens (single, playing_now, import), G1 allowlist entry" plus the trailer.

---

## Task 17: Two scrobble destinations, the persisted queue, and the Scrobbling settings

**Files:**
- Create: `Packages/MagpieKit/Sources/Playback/ScrobbleQueue.swift`
- Create: `App/Playback/ScrobbleRouter.swift`
- Create: `App/AppModel+Scrobbling.swift`
- Create: `App/Screens/Settings/ScrobblingSettingsView.swift`
- Modify: `App/AppModel.swift:201-204`. Replace `NavidromeScrobbler(...)` with `ScrobbleRouter(...)` and keep a reference (`@ObservationIgnored let scrobbles: ScrobbleRouter`). In `signOut` (line 386), call `scrobbles.clearQueue()`. After `startReconnect` in `resumeSavedSession` (line 289), call `drainScrobblesSoon()`.
- Modify: `App/AppModel+Offline.swift`. `noteReachable()` calls `drainScrobblesSoon()` on a false→true change.
- Modify: `App/AppModel+Requests.swift`. After a token is saved (`setListenBrainzToken` succeeds), call `drainScrobblesSoon()`.
- Modify: `App/Screens/Settings/SettingsView.swift:226-231`. Remove the lone Count plays section. Add `Section("Scrobbling")` holding a NavigationLink "Scrobbling" to `ScrobblingSettingsView`.
- Modify: `App/AppModel.swift:689`, where `ListenBrainzClient(` is built. Pass `clientVersion: Self.marketingVersion` there and in the router's factory.
- Delete: `NavidromeScrobbler` from `NavidromeAdapters.swift`, and move its test (`TryAndSettingsTests.swift:210-220`) to the router.
- Test: `Packages/MagpieKit/Tests/PlaybackTests/ScrobbleQueueTests.swift`, `Tests/MagpieTests/ScrobbleRouterTests.swift`

**Interfaces:**
- Consumes: `Scrobbler` and `ScrobbleSettings` (Task 15); `ListenBrainzClient.submitListens`, `maxListensPerCall`, `Listen` (Task 16); `FindsIdentity` and `PlayCounting` (existing); `isOffline` (Task 14). Like `ScrobbleSettings`, `isOffline` reaches the router through a lock-protected `OfflineFlag` box. `AppModel+Offline` sets it.
- Produces:

```swift
public enum ScrobbleDestination: String, Codable, Sendable { case navidrome, listenBrainz }
public struct QueuedScrobble: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID; public var destination: ScrobbleDestination; public var song: AudioMetadata; public var listenedAt: Date }
public actor ScrobbleQueue {
    public static let limit = 500
    public init(fileURL: URL?)                       // Application Support/Magpie/scrobble-queue.json; nil = memory
    public func enqueue(_ s: QueuedScrobble)         // per destination, oldest dropped past 500
    public func pending(_ d: ScrobbleDestination) -> [QueuedScrobble]   // oldest first
    public func remove(ids: Set<UUID>)
    public func clear()
}
final class ScrobbleRouter: Scrobbler {
    init(box: ClientBox, counting: PlayCounting, findsIdentity: FindsIdentity, settings: ScrobbleSettings,
         queue: ScrobbleQueue, listenBrainz: @escaping @Sendable () -> ListenBrainzClient?, isOffline: @escaping @Sendable () -> Bool)
    func scrobble(_ song: Song, submission: Bool, at: Date?) async throws
    func drain() async
    func clearQueue()
}
final class OfflineFlag: Sendable { init(_ on: Bool); var value: Bool { get }; func set(_ on: Bool) }   // lock-protected
extension AppModel { func drainScrobblesSoon() }
```

**Rules:**
- **Gates.** `scrobble` returns at once when `!counting.isOn` or `findsIdentity.isFind(song)` (D29, both paths).
- **Now playing** (`submission == false`) goes to each enabled destination as best-effort and is never queued.
- **A submission** goes to each enabled destination: Navidrome through `box.client?.scrobble(songId:submission:true, at:)`, ListenBrainz through `.single` with `listenedAt = at`. If offline, or on any thrown error, it is enqueued for that destination.
- **The ListenBrainz destination** is enabled only when `settings.value.viaListenBrainz` and `listenBrainz()` is non-nil. The closure reads the Keychain token at call time.
- **Drain.** `drain()`, per destination, oldest first:
  - Drop and remove entries whose song `isFind` (D29 on dequeue).
  - Navidrome sends each entry with `time = listenedAt` and removes it after its request succeeds.
  - ListenBrainz sends `.importBatch` chunks of `ListenBrainzClient.maxListensPerCall` (100), oldest first, and removes each chunk's ids after that chunk succeeds.
  - On the first error, stop that destination and keep its rest. Chunks already removed are never resent.
- **The queue file** holds metadata only (`AudioMetadata`). It is written with `AtomicFile` and excluded from backup.

- [ ] **Step 1: Write the failing package tests.** `item(_ id: String, _ d: ScrobbleDestination, at: Double = 0) -> QueuedScrobble` builds one with metadata from `Song(id: id, title: "T", artist: "A", album: "B", duration: 200)`.

```swift
@Suite struct ScrobbleQueueTests {
    @Test func boundedPerDestination() async {
        let q = ScrobbleQueue(fileURL: nil)
        for i in 0..<501 { await q.enqueue(item("s\(i)", .navidrome)) }
        await q.enqueue(item("lb", .listenBrainz))
        let nd = await q.pending(.navidrome)
        #expect(nd.count == 500 && nd.first?.song.songId == "s1" && nd.last?.song.songId == "s500")
        #expect(await q.pending(.listenBrainz).map(\.song.songId) == ["lb"])
    }
    @Test func persistsAndHasNoCredentials() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        let q = ScrobbleQueue(fileURL: url)
        await q.enqueue(item("s1", .listenBrainz, at: 1_700_000_000))
        let again = ScrobbleQueue(fileURL: url)
        #expect(await again.pending(.listenBrainz).first?.listenedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let text = try String(contentsOf: url, encoding: .utf8)
        for needle in ["token", "t=", "s=", "password", "Authorization"] { #expect(!text.contains(needle), "\(needle)") }
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    @Test func removeAndClear() async {
        let q = ScrobbleQueue(fileURL: nil)
        let a = item("a", .navidrome), b = item("b", .navidrome)
        await q.enqueue(a); await q.enqueue(b)
        await q.remove(ids: [a.id])
        #expect(await q.pending(.navidrome).map(\.id) == [b.id])
        await q.clear()
        #expect(await q.pending(.navidrome).isEmpty)
    }
    @Test func corruptFileStartsEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/scrobble-queue.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        let q = ScrobbleQueue(fileURL: url)
        #expect(await q.pending(.navidrome).isEmpty)
        await q.enqueue(item("s1", .navidrome))
        #expect(await ScrobbleQueue(fileURL: url).pending(.navidrome).count == 1)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `ScrobbleQueueTests`. Expected: FAIL.
- [ ] **Step 3: Implement `ScrobbleQueue`.** Run PKG `ScrobbleQueueTests`. Expected: PASS.
- [ ] **Step 4: Write the failing app tests.** Fixture `RouterRig`:
  - `t`: a `MockTransport`. Its Navidrome stubs (ping, login, `/rest/scrobble`) answer from a lock-protected `ndStatus` (200 by default). Its `/1/submit-listens` stub answers from `lbStatus`.
  - `box`: a `ClientBox` holding a `NavidromeClient` on `http://192.168.1.2:4533` over `t`.
  - `counting = PlayCounting(on: true)`, `finds = FindsIdentity()`.
  - `settings = ScrobbleSettings(prefs)`.
  - `queue = ScrobbleQueue(fileURL: tmp/"scrobble-queue.json")`.
  - `tokens = MemoryTokenStore("tok-secret")`.
  - `offline = OfflineFlag(false)`.
  - `failLBAfter(chunks: n)`: once `n` submit-listens requests have succeeded, the next one answers 500 and the rig resets itself.
  - `router`: built with `listenBrainz: { tokens.load().map { ListenBrainzClient(transport: t, token: $0, clientVersion: "test") } }`.
  - Helpers: `scrobbles(submission:)` returns the `/rest/scrobble` requests with that `submission` value. `lbPayloads` returns the submit-listens bodies as `(type, count, firstListenedAt)`.
  - `t0 = Date(timeIntervalSince1970: 1_700_000_000)`. `bothOn` is prefs with `viaListenBrainz = true`.

```swift
@MainActor @Suite(.serialized) struct ScrobbleRouterTests {
    @Test func bothDestinationsGetSubmission() async throws {
        let r = RouterRig(prefs: bothOn)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let nd = try #require(r.scrobbles(submission: true).first)
        #expect(queryValue(nd, "id") == "s1" && queryValue(nd, "time") == "1700000000000")
        #expect(r.lbPayloads.map(\.type) == ["single"] && r.lbPayloads[0].firstListenedAt == 1_700_000_000)
        #expect(await r.queue.pending(.navidrome).isEmpty && (await r.queue.pending(.listenBrainz)).isEmpty)
    }
    @Test func listenBrainzOffByDefault() async throws {
        let r = RouterRig(prefs: .defaultValue)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.scrobbles(submission: true).count == 1 && r.lbPayloads.isEmpty)
    }
    @Test func findNeverSentEitherPath() async throws {      // D29
        let r = RouterRig(prefs: bothOn)
        r.finds.markLanded("s1")
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.scrobbles(submission: false).isEmpty && r.scrobbles(submission: true).isEmpty && r.lbPayloads.isEmpty)
        #expect(await r.queue.pending(.navidrome).isEmpty && (await r.queue.pending(.listenBrainz)).isEmpty)
    }
    @Test func failedSendIsQueuedAndRetried() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(await r.queue.pending(.listenBrainz).count == 1 && (await r.queue.pending(.navidrome)).isEmpty)
        r.lbStatus = 200
        await r.router.drain()
        #expect(r.lbPayloads.last?.type == "import" && r.lbPayloads.last?.count == 1 && r.lbPayloads.last?.firstListenedAt == 1_700_000_000)
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }
    @Test func navidromeQueuedOfflineCarriesOriginalTime() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.scrobbles(submission: true).isEmpty && (await r.queue.pending(.navidrome)).count == 1)
        r.offline.set(false); await r.router.drain()
        #expect(r.scrobbles(submission: true).map { queryValue($0, "time") } == ["1700000000000"])
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }
    @Test func findDroppedOnDequeue() async throws {
        let r = RouterRig(prefs: .defaultValue); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        r.finds.markLanded("s1"); r.offline.set(false)
        await r.router.drain()
        #expect(r.scrobbles(submission: true).isEmpty && (await r.queue.pending(.navidrome)).isEmpty)
    }
    @Test func drainChunksBy100AndRemovesEachChunk() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        for i in 0..<250 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0 + Double(i)) }
        #expect(await r.queue.pending(.listenBrainz).count == 250)
        r.lbStatus = 200; r.failLBAfter(chunks: 1)   // the second import chunk answers 500
        await r.router.drain()
        #expect(r.lbPayloads.filter { $0.type == "import" }.map(\.count) == [100, 100])
        let left = await r.queue.pending(.listenBrainz)
        #expect(left.count == 150 && left.first?.song.songId == "s100", "first chunk removed, the rest kept")
        r.lbStatus = 200; await r.router.drain()
        #expect(r.lbPayloads.filter { $0.type == "import" }.map(\.count) == [100, 100, 100, 50])
        #expect(await r.queue.pending(.listenBrainz).isEmpty)
    }
    @Test func unauthorizedStopsListenBrainzDrainAndKeepsQueue() async throws {   // edge test
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500; r.offline.set(true)
        for i in 0..<3 { try await r.router.scrobble(song("s\(i)"), submission: true, at: t0) }
        r.offline.set(false); r.lbStatus = 401
        let before = r.lbPayloads.count
        await r.router.drain()
        #expect(r.lbPayloads.count - before == 1)
        #expect(await r.queue.pending(.listenBrainz).count == 3)
        #expect(await r.queue.pending(.navidrome).isEmpty, "Navidrome drained in the same call")
    }
    @Test func countPlaysOffSendsNothing() async throws {
        let r = RouterRig(prefs: bothOn); r.counting.set(false)
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        #expect(r.t.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true }.isEmpty && r.lbPayloads.isEmpty)
        #expect(await r.queue.pending(.navidrome).isEmpty)
    }
    @Test func nowPlayingNeverQueued() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500; r.ndStatus = 500
        try await r.router.scrobble(song("s1"), submission: false, at: nil)
        #expect(r.lbPayloads.map(\.type) == ["playing_now"])
        #expect(await r.queue.pending(.listenBrainz).isEmpty && (await r.queue.pending(.navidrome)).isEmpty)
    }
    @Test func clearQueueEmptiesBoth() async throws {
        let r = RouterRig(prefs: bothOn); r.offline.set(true)
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        r.router.clearQueue()
        #expect(await eventually { await r.queue.pending(.navidrome).isEmpty && (await r.queue.pending(.listenBrainz)).isEmpty })
    }
    @Test func signOutClearsQueue() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())   // Task 12 fixture
        model.updatePreferences { $0.downloads.offlineMode = .on }
        try await model.scrobbles.scrobble(song("s1"), submission: true, at: t0)
        #expect(await model.scrobbles.queue.pending(.navidrome).count == 1)
        model.signOut()
        #expect(await eventually { await model.scrobbles.queue.pending(.navidrome).isEmpty })
    }
    @Test func queueFileLacksToken() async throws {
        let r = RouterRig(prefs: bothOn); r.lbStatus = 500
        try await r.router.scrobble(song("s1"), submission: true, at: t0)
        let text = try String(contentsOf: r.queueURL, encoding: .utf8)
        #expect(!text.contains("tok-secret") && text.contains("s1"))
    }
}
```

`ScrobbleRouter` exposes `let queue: ScrobbleQueue` (internal) for these tests.

- [ ] **Step 5: Run them and check they fail.** Run APP `ScrobbleRouterTests`. Expected: FAIL.
- [ ] **Step 6: Implement the router, `AppModel+Scrobbling` and the AppModel hook lines.** Then build `ScrobblingSettingsView`:
  - The "Count plays" toggle (moved here; it keeps the key `magpie.countPlays` and the footer copy).
  - "Send plays through Navidrome".
  - "Send plays directly to ListenBrainz", disabled without a token, with the footer "Save a ListenBrainz token in Settings first.".
  - When both are on, the double-count note verbatim.
  - "Counts as played after": a slider from 10 to 90, step 5, showing "50%".
  - "or after": a picker over 1…10 min plus "Never".
- [ ] **Step 7: Run APP `ScrobbleRouterTests`, `TryAndSettingsTests` and `PlaybackFlowsVerifyTests`.** Expected: PASS.
- [ ] **Step 8: Commit** with "Scrobbling: Navidrome and/or ListenBrainz, offline queue, Scrobbling settings" plus the trailer.

---

## Task 18: Genre grouping table

**Files:**
- Create: `Packages/MagpieKit/Sources/Search/GenreGroups.swift`
- Test: `Packages/MagpieKit/Tests/SearchTests/GenreGroupsTests.swift`

**Interfaces:**
- Consumes: `Genre` (Task 6); `GenrePreferences` (Task 5).
- Produces:

```swift
public struct GenreGroup: Hashable, Sendable, Codable { public var id: String; public var name: String }
public struct GenreGroupSection: Hashable, Sendable {
    public var group: GenreGroup; public var genres: [Genre]; public var albumCount: Int; public var songCount: Int }
public enum GenreGroups {
    /// Spec order: rock, pop, electronic, hiphop, rnb, jazz, blues, classical, country, metal, punk, reggae, latin, world, soundtrack, other.
    public static let builtIn: [GenreGroup]
    public static func key(_ genre: String) -> String
    public static func split(_ genre: String) -> [String]
    public static func groupId(for genre: String) -> String
    public static func grouped(_ genres: [Genre], preferences: GenrePreferences) -> [GenreGroupSection]
    public static func allGenres(_ genres: [Genre]) -> [Genre]
}
```

- Built-in names: "Rock", "Pop", "Electronic", "Hip-Hop & Rap", "R&B & Soul", "Jazz", "Blues", "Classical", "Country & Folk", "Metal", "Punk", "Reggae & Ska", "Latin", "World", "Soundtrack & Stage", "Other".

**Rules:**
- **`key`** folds case and diacritics, maps `-` and `_` to spaces, collapses whitespace and trims.
- **`split`** always splits on `;`, `/` and `,`. It splits on ` & ` only when both halves get a group other than "other" through the alias or keyword rules.
- **`groupId`** uses the exact alias map first, then the ordered keyword rules: the first rule with a whole-word match wins (a keyword ending in `*` matches a word prefix). Otherwise it's "other". The minimum table (the builder may extend it within these rules):
  - Aliases: "dnb", "drum & bass", "drum and bass", "dubstep" → electronic. "alt rock", "alt-rock" → rock. "rhythm & blues", "rnb" → rnb. "j pop", "k pop" → pop.
  - Ordered rules:
    1. metal, metal* → metal
    2. punk, hardcore, emo → punk
    3. hip, rap, trap, grime, drill → hiphop
    4. r&b, soul, funk, motown → rnb
    5. jazz, swing, bebop, bossa → jazz
    6. blues → blues
    7. classical, baroque, opera, orchestr*, symphon*, chamber → classical
    8. country, folk, bluegrass, americana → country
    9. reggae, ska, dub, dancehall → reggae
    10. latin, salsa, reggaeton, bachata, cumbia, tango, samba → latin
    11. soundtrack, score, musical, stage → soundtrack
    12. rock, grunge, shoegaze → rock
    13. electr*, techno, house, trance, edm, ambient, idm, synth*, downtempo, breakbeat, electronique → electronic
    14. pop → pop
    15. afro*, world, celtic, flamenco, chanson, fado → world
- **`grouped`**:
  - Hides genres with `albumCount == 0 && songCount == 0`.
  - Splits multi-value names for grouping only; the same `Genre` can sit in two groups.
  - Applies `assignments[key]` overrides first, then names (`groupNames`), and adds `customGroups`.
  - Drops `hidden` groups and empty groups.
  - Orders by `builtIn` order, then custom groups in creation order. Genres within a group are A–Z.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [("Indie Rock","rock"),("Alt-Rock","rock"),("Death Metal","metal"),("Metalcore","metal"),
                  ("Pop Punk","punk"),("Hip Hop","hiphop"),("Trap","hiphop"),("R&B","rnb"),("Neo-Soul","rnb"),
                  ("dnb","electronic"),("Drum & Bass","electronic"),("Dubstep","electronic"),("Ambient","electronic"),
                  ("J-Pop","pop"),("K-Pop","pop"),("Électronique","electronic"),("Bossa Nova","jazz"),
                  ("Reggaeton","latin"),("Soundtrack","soundtrack"),("Afrobeats","world"),("Chanson","world"),
                  ("Rhythm & Blues","rnb"),("Polka Noir","other"),("","other")])
func groupIds(_ genre: String, _ expected: String) { #expect(GenreGroups.groupId(for: genre) == expected) }

@Test func splitting() {
    #expect(GenreGroups.split("Rock; Pop") == ["Rock", "Pop"])
    #expect(GenreGroups.split("Rock/Pop") == ["Rock", "Pop"])
    #expect(GenreGroups.split("Folk, Country") == ["Folk", "Country"])
    #expect(GenreGroups.split("Rock & Pop") == ["Rock", "Pop"])
    #expect(GenreGroups.split("Drum & Bass") == ["Drum & Bass"])
    #expect(GenreGroups.split("Rhythm & Blues") == ["Rhythm & Blues"])
}

@Test func groupedOrderAndCounts() {
    let s = GenreGroups.grouped([Genre(name: "Indie Rock", songCount: 10, albumCount: 1),
                                 Genre(name: "Alt Rock", songCount: 20, albumCount: 2),
                                 Genre(name: "Ambient", songCount: 12, albumCount: 2),
                                 Genre(name: "Empty", songCount: 0, albumCount: 0)], preferences: .defaultValue)
    #expect(s.map(\.group.id) == ["rock", "electronic"])
    #expect(s[0].genres.map(\.name) == ["Alt Rock", "Indie Rock"] && s[0].albumCount == 3 && s[0].songCount == 30)
}

@Test func overridesRenameHideAndCustom() {
    var p = GenrePreferences.defaultValue
    p.assignments[GenreGroups.key("Ambient")] = "rock"
    p.groupNames["rock"] = "Guitars"
    p.customGroups = ["custom.dinner"]; p.groupNames["custom.dinner"] = "Dinner"
    p.assignments[GenreGroups.key("Chanson")] = "custom.dinner"
    let s = GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1), Genre(name: "Chanson", songCount: 1, albumCount: 1)], preferences: p)
    #expect(s.map(\.group.name) == ["Guitars", "Dinner"])
    p.hidden = ["rock"]
    #expect(GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1)], preferences: p).isEmpty)
}

@Test func multiValueCountsInBothGroups() {
    let s = GenreGroups.grouped([Genre(name: "Rock; Electronic", songCount: 4, albumCount: 1)], preferences: .defaultValue)
    #expect(s.map(\.group.id) == ["rock", "electronic"])
    #expect(s.allSatisfy { $0.genres.map(\.name) == ["Rock; Electronic"] && $0.albumCount == 1 })
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `GenreGroupsTests`. Expected: FAIL.
- [ ] **Step 3: Implement `GenreGroups.swift`.**
- [ ] **Step 4: Run PKG `GenreGroupsTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Genres: hand-written grouping table with aliases, ordered keywords and owner overrides" plus the trailer.

---

## Task 19: Genre screens

**Files:**
- Create: `App/AppModel+Genres.swift`
- Create: `App/Screens/Genres/GenresView.swift`
- Create: `App/Screens/Genres/GenreGroupView.swift`
- Create: `App/Screens/Genres/GenreView.swift`
- Create: `App/Screens/Genres/MoveGenreSheet.swift`
- Modify: `App/Screens/Shared/ScreenKit.swift:8-40`. Add `Route.genres`, `.genreGroup(id: String)` and `.genre(name: String)`, plus their destinations.
- Modify: `App/Screens/Downloads/DownloadsView.swift`. Add a Genres segment built from `GenreGroups.grouped(offlineCatalog.genres(), …)` (offline genres, §6).
- Test: `Tests/MagpieTests/GenresAppTests.swift`

**Interfaces:**
- Consumes: `NavidromeClient.genres/albums(genre:)/songs(genre:)` (Task 6); `GenreGroups` (Task 18); `updatePreferences` (Task 5).
- Produces:

```swift
extension AppModel {
    static let groupSongCap = 500
    func genreSections() async throws -> [GenreGroupSection]
    func allGenres() async throws -> [Genre]
    func groupAlbums(_ groupId: String) async throws -> [Album]          // merged, de-duplicated by id, first-seen order
    func groupSongs(_ groupId: String) async throws -> [Song]            // ≤ 500, shuffled (groups offer Shuffle only)
    func genreSongs(_ name: String) async throws -> [Song]               // ≤ 500, server order (Play) — Shuffle shuffles them
    func moveGenre(_ name: String, toGroup groupId: String)
    @discardableResult func createGroup(named: String) -> String         // "custom.<uuid>"
    func renameGroup(_ id: String, to name: String)
    func setGroupHidden(_ id: String, _ hidden: Bool)
}
```

**Rules:**
- `groupSongs` asks each genre in the group for pages of 500 (`songs(genre:count:offset:)`) until the union reaches 500 or the genres run out. It then shuffles.
- `GenresView` has a segmented control, "Grouped" / "All genres", bound to `preferences.genres.mode`.
  - Grouped shows a `DisclosureGroup` per group with its counts (SF Pro Rounded) and subgenre rows.
  - Tapping the group title opens `GenreGroupView`. Tapping a subgenre opens `GenreView`.
  - Edit (toolbar) offers per-group "Rename" and "Hide".
- **Buttons.** A group page (`GenreGroupView`) offers only a "Shuffle" button (a group mixes many genres, so playing it in order means nothing). A subgenre page (`GenreView`) offers "Play" and "Shuffle" (`PlayShuffleButtons` over `genreSongs`). The car follows the same rule (Task 23).
- `GenreView` has a menu with "Move to group…", which opens `MoveGenreSheet`. The sheet lists the visible groups plus "New group…" (text field).

- [ ] **Step 1: Write the failing tests.** Fixture: Task 12's `signedInModel(fetcher:)` with these stubs on the fixture's transport:
  - `getGenres` returns Indie Rock (10, 1), Alt Rock (20, 2), Ambient (12, 2) and Chanson (6, 1).
  - `getAlbumList2` answers by its `genre` query value: Indie Rock gives `[a1, a2]`, Alt Rock gives `[a2, a3]`, anything else `[]`.
  - `getSongsByGenre` answers by `genre` and `offset`. Indie Rock and Alt Rock each have 300 songs (`ir0…ir299`, `ar0…ar299`). A page is `count` songs from `offset`.

  `makeModel()` builds a second model over the same defaults.

```swift
@MainActor @Suite(.serialized) struct GenresAppTests {
    @Test func groupAlbumsMergedAndDeduped() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(try await model.groupAlbums("rock").map(\.id) == ["a1", "a2", "a3"])
    }
    @Test func groupSongsCappedAt500AndShuffled() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let songs = try await model.groupSongs("rock")
        #expect(songs.count == 500 && Set(songs.map(\.id)).count == 500)
        #expect(songs.map(\.id) != songs.map(\.id).sorted(), "shuffled")
    }
    @Test func genreSongsKeepServerOrder() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let songs = try await model.genreSongs("Indie Rock")
        #expect(songs.count == 300 && songs.prefix(3).map(\.id) == ["ir0", "ir1", "ir2"])
    }
    @Test func moveGenreSurvivesRelaunch() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.moveGenre("Ambient", toGroup: "rock")
        let again = try await signedInModel(fetcher: FakeFetcher())   // same defaults
        let rock = try #require(try await again.genreSections().first { $0.group.id == "rock" })
        #expect(rock.genres.map(\.name) == ["Alt Rock", "Ambient", "Indie Rock"])
        #expect(!(try await again.genreSections()).contains { $0.group.id == "electronic" })
    }
    @Test func newGroupNamed() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let id = model.createGroup(named: "Dinner")
        #expect(id.hasPrefix("custom."))
        model.moveGenre("Chanson", toGroup: id)
        let dinner = try #require(try await model.genreSections().first { $0.group.id == id })
        #expect(dinner.group.name == "Dinner" && dinner.genres.map(\.name) == ["Chanson"])
        model.renameGroup(id, to: "Supper")
        #expect(try await model.genreSections().first { $0.group.id == id }?.group.name == "Supper")
    }
    @Test func hiddenGroupLeavesAllGenresIntact() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.setGroupHidden("rock", true)
        #expect(!(try await model.genreSections()).contains { $0.group.id == "rock" })
        #expect(try await model.allGenres().map(\.name) == ["Alt Rock", "Ambient", "Chanson", "Indie Rock"])
        model.setGroupHidden("rock", false)
        #expect(try await model.genreSections().contains { $0.group.id == "rock" })
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `GenresAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement `AppModel+Genres`, the routes and the four views.** `GenreView` reuses `PlayShuffleButtons`. `GenreGroupView` has a single "Shuffle" `CapsuleButton`.
- [ ] **Step 4: Run APP `GenresAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Genres: grouped and A–Z views, group and genre pages, Move to group" plus the trailer.

---

## Task 20: Home layout

**Files:**
- Create: `App/AppModel+Home.swift`
- Create: `App/Screens/Settings/OrderedVisibilityEditor.swift`. This is the generic reorderable editor, shared by Home (here) and Library (Task 21).
- Create: `App/Screens/Settings/HomeLayoutView.swift`. It's a thin instance of the editor.
- Modify: `App/Screens/Home/HomeView.swift:14-104`. Replace the fixed `Shelves` with `[HomeShelf]` from `model.homeShelves(for: model.homeSections)`.
  - `madeForYouShelf` stays where `.madeForYou` sits in the order.
  - Shelf tiles route by kind.
  - Keep Task 14's offline behaviour: while `model.isOffline`, show the "You're offline" line (`wifi.slash`) above the shelves. `homeSections` is then `[.downloaded]`, and the Downloaded shelf stays albums-only (`offlineCatalog.albums()`).
- Modify: `App/Screens/Settings/SettingsView.swift`. Add `Section("Home & Library")` with a NavigationLink "Home" to `HomeLayoutView`. Task 21 adds the "Library" link to this section.
- Test: `Tests/MagpieTests/HomeLayoutAppTests.swift`

**Interfaces:**
- Consumes:
  - `OrderedVisibility`, `LayoutPreferences.visibleHomeSections` (Task 5);
  - `AlbumListType.starred`, `playlists()` (Task 6);
  - `genreSections()` (Task 19);
  - `offlineCatalog`, `isOffline` (Task 14).
- Produces:

```swift
struct HomeShelf: Identifiable, Equatable {
    enum Item: Equatable { case album(Album), playlist(Playlist), genreGroup(GenreGroupSection), downloadedAlbum(Album) }
    var section: HomeSection; var items: [Item]; var id: HomeSection { section }
}
extension AppModel {
    static let homeShelfSize = 12
    var homeSections: [HomeSection] { get }       // visibleHomeSections(offline: isOffline, hasListenBrainzToken: hasListenBrainzToken, carPlay: false)
    func homeShelves(for sections: [HomeSection]) async throws -> [HomeShelf]   // .madeForYou excluded (own shelf); empties dropped
}
/// One editor for any OrderedVisibility list: drag handles (edit mode), a Toggle per row, VoiceOver "Move up"/"Move down"
/// actions, a footer per item, disabled toggles, and a "Reset to default order" button.
struct OrderedVisibilityEditor<Item: CaseIterable & RawRepresentable & Hashable & Sendable>: View where Item.RawValue == String {
    init(title: String, list: Binding<OrderedVisibility<Item>>, defaults: OrderedVisibility<Item>,
         label: @escaping (Item) -> String, footer: @escaping (Item) -> String? = { _ in nil },
         keepingOneOf: Set<Item> = [], @ViewBuilder extra: () -> some View = { EmptyView() })
}
```

**Rules:**
- **Fetching.** `homeShelves(for:)` runs one concurrent fetch per section, from these sources (12 items each):

  | Section | Source |
  |---|---|
  | jumpBackIn | `.recent` |
  | recentlyAdded | `.newest` |
  | mostPlayed | `.frequent` |
  | favourites | `.starred` |
  | randomAlbums | `.random` |
  | playlists | `playlists().prefix(12)` |
  | genres | `genreSections()` by `albumCount` descending, prefix 12 |
  | downloaded | `offlineCatalog.albums().prefix(12)` |

  It throws only when every server section fails.
- **The editor.**
  - A toggle is disabled when hiding its item would leave none of `keepingOneOf` visible (`OrderedVisibility.set` returns false).
  - The "Made for you" footer: "Shows when a ListenBrainz token is saved".
  - `HomeLayoutView` is `OrderedVisibilityEditor(title: "Home", list: $model.preferences.layout.home via updatePreferences, defaults: LayoutPreferences.defaultValue.home, label: \.title, footer: …)`.

- [ ] **Step 1: Write the failing tests.** Fixture: Task 12's `signedInModel(fetcher:)` with these stubs:
  - `getAlbumList2` answers by `type`: `recent` gives `[r1]`, `starred` gives `[f1]`, and `newest`, `frequent` and `random` give one album each;
  - `getPlaylists` gives `[p1]`;
  - `getGenres` gives Ambient (12, 2).

  Each test also has a `starredEmpty` variant, where `starred` answers `[]`.

```swift
@MainActor @Suite(.serialized) struct HomeLayoutAppTests {
    @Test func onlyRequestedSectionsAreFetched() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let before = transport.inner.requests.count
        let shelves = try await model.homeShelves(for: [.favourites, .jumpBackIn])
        let types = transport.inner.requests.dropFirst(before).compactMap { queryValue($0, "type") }
        #expect(Set(types) == ["starred", "recent"])
        #expect(shelves.map(\.section) == [.favourites, .jumpBackIn])
        #expect(shelves[0].items == [.album(album("f1"))])
    }
    @Test func emptySectionsSkipped() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher(), starredEmpty: true)
        #expect(try await model.homeShelves(for: [.favourites, .jumpBackIn]).map(\.section) == [.jumpBackIn])
    }
    @Test func playlistsAndGenresShelves() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let shelves = try await model.homeShelves(for: [.playlists, .genres])
        #expect(shelves.map(\.section) == [.playlists, .genres])
        guard case .playlist(let p) = shelves[0].items.first, case .genreGroup(let g) = shelves[1].items.first else { Issue.record("kinds"); return }
        #expect(p.id == "p1" && g.group.id == "electronic")
    }
    @Test func homeSectionsFollowPreferences() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0); $0.layout.home.set(.randomAlbums, visible: true) }
        #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded, .randomAlbums])
    }
    @Test func offlineHomeIsDownloadedOnly() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .album("a1")); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.homeSections == [.downloaded])
        let shelves = try await model.homeShelves(for: model.homeSections)
        #expect(shelves.map(\.section) == [.downloaded] && shelves[0].items.count == 1)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `HomeLayoutAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement `AppModel+Home`, `OrderedVisibilityEditor`, `HomeLayoutView` and the HomeView change.** "Finish setting up" stays pinned above the shelves.
- [ ] **Step 4: Run APP `HomeLayoutAppTests`, `MadeForYouAppTests` and `OfflineAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Home: reorderable and hideable shelves, Favourites/Random/Playlists/Genres/Downloaded" plus the trailer.

---

## Task 21: Library rows, Songs and Favourites

**Files:**
- Create: `App/Screens/Library/SongsListView.swift`
- Create: `App/Screens/Library/FavouritesView.swift`
- Create: `App/Screens/Settings/LibraryLayoutView.swift`. It's a thin instance of Task 20's `OrderedVisibilityEditor`.
- Modify: `App/Screens/Library/LibraryView.swift:17-39`.
  - Rows come from `model.libraryRows`, mapped to routes, titles and symbols.
  - The Recently added grid shows only when `preferences.layout.showsRecentlyAdded && !model.isOffline`.
  - Keep Task 14's offline behaviour: the "You're offline" line (`wifi.slash`), with only the Downloads row.
- Modify: `App/Screens/Shared/ScreenKit.swift`. Add `Route.songs` and `.favourites`.
- Modify: `App/AppModel+Home.swift`. Add `libraryRows`, `songsPage(_:)` and `favourites()`.
- Modify: `App/Screens/Settings/SettingsView.swift`. Add the NavigationLink "Library" to `LibraryLayoutView` inside Task 20's `Section("Home & Library")`.
- Test: `Tests/MagpieTests/LibraryLayoutAppTests.swift`

**Interfaces:**
- Consumes:
  - `visibleLibraryRows`, `OrderedVisibility.set(_:visible:keepingOneOf:)`, `LayoutPreferences.alwaysAvailableRows` (Task 5);
  - `OrderedVisibilityEditor` (Task 20);
  - `songsPage(start:end:sort:)`, `starred()` (Task 6).
- Produces:

```swift
extension AppModel {
    var libraryRows: [LibraryRow] { get }   // visibleLibraryRows(offline: isOffline, findsSetUp: findsSetup?.library != nil, lidarrConnected: lidarr != nil, carPlay: false)
    var showsRecentlyAddedGrid: Bool { get } // preferences.layout.showsRecentlyAdded && !isOffline
    static let songsPageSize = 100
    func songsPage(_ page: Int) async throws -> [Song]   // songsPage(start: page*100, end: (page+1)*100, sort: "title")
    func favourites() async throws -> Starred
}
```

**Rules:**
- **`LibraryLayoutView`** is `OrderedVisibilityEditor(title: "Library", …, keepingOneOf: LayoutPreferences.alwaysAvailableRows)`. Its `extra` section holds a "Recently added" toggle bound to `showsRecentlyAdded`, with the footer "At least one row stays visible."
- **`SongsListView`** pages when its last row appears.
- **`FavouritesView`** has a Songs section (rows play from that list) and an Albums grid.

- [ ] **Step 1: Write the failing tests.** Fixture: Task 12's `signedInModel(fetcher:)`, with `/api/song` answering `[]` and `getStarred2` answering 2 songs and 1 album.

```swift
@MainActor @Suite(.serialized) struct LibraryLayoutAppTests {
    @Test func songsListPagesByTitle() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        _ = try await model.songsPage(0); _ = try await model.songsPage(1)
        let pages = Array(transport.inner.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.suffix(2))
        #expect(pages.map { queryValue($0, "_sort") } == ["title", "title"])
        #expect(pages.map { queryValue($0, "_start") } == ["0", "100"] && pages.map { queryValue($0, "_end") } == ["100", "200"])
    }
    @Test func libraryRowsFollowPreferences() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences {
            _ = $0.layout.library.set(.songs, visible: false, keepingOneOf: LayoutPreferences.alwaysAvailableRows)
            $0.layout.library.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        }
        #expect(model.libraryRows == [.genres, .playlists, .artists, .albums, .favourites, .downloads])
        #expect(!model.libraryRows.contains(.requests), "no Lidarr connected")
    }
    @Test func recentlyAddedGridToggleAndOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(model.showsRecentlyAddedGrid)
        model.updatePreferences { $0.layout.showsRecentlyAdded = false }
        #expect(!model.showsRecentlyAddedGrid)
        model.updatePreferences { $0.layout.showsRecentlyAdded = true; $0.downloads.offlineMode = .on }
        #expect(!model.showsRecentlyAddedGrid && model.libraryRows == [.downloads])
    }
    @Test func favouritesReadStarred() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let f = try await model.favourites()
        #expect(f.songs.count == 2 && f.albums.count == 1)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `LibraryLayoutAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement the views, routes, Settings link and model additions.**
- [ ] **Step 4: Run APP `LibraryLayoutAppTests` and `OfflineAppTests`, then `MAGPIE_IT=1 scripts/test-app.sh`.** Expected: PASS.
  - `BrowseFlowTests` still finds `library-albums` and the other identifiers, because `row(_:)` keeps the identifier `library-<title lowercased>`.
- [ ] **Step 5: Commit** with "Library: reorderable rows, Songs, Genres, Favourites, Downloads; Recently added toggle" plus the trailer.

---

## Task 22: CarPlay Home and Library from Preferences

**Files:**
- Create: `Packages/MagpieKit/Sources/CarPlayUI/CustomisationRows.swift`
- Create: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController+Customisation.swift`
- Create: `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift`
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift`.
  - Lines 61-75: change `library`, `home`, `libraryRoot`, `findsRoot`, `bindings`, `watches` and `Content` from `private` to `internal`. Also change `load`, `refresh`, `apply` and `perform`, which the extension calls.
  - `showTabs` (lines 142-160): the library root becomes `CarPlayRows.libraryRoot(library.libraryRows, hasFindsTab: findsList != nil)`. Then call `watchLayout()`.
  - `loadHome` (lines 170-182): the body becomes `loadCustomHome()`.
  - `fetcher(for:)` (lines 253-289): `default: return customFetcher(for: destination)`.
  - `play(_:)` (lines 291-321): `default: playCustom(request)`.
  - Both hooks land here. In this task, `customFetcher` returns `{ _ in CarPlayRows.state(.empty) }` for every new destination, and `playCustom` does nothing. Task 23 fills both in, so this task builds and runs on its own.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/TemplateModels.swift`.
  - `CPDestination` (lines 9-30) gains `.genres`, `.genreGroup(id: String, name: String)`, `.favourites`, `.downloads`, `.downloadedAlbum(id: String, title: String)` and `.finds`, with titles.
  - `CPPlayRequest` (lines 33-37) gains `.genre(name: String, shuffled: Bool)` and `.genreGroup(id: String, shuffled: Bool)`.
  - Remove `home(recent:newest:frequent:)` (lines 139-151) and `libraryRoot()` (lines 153-159). Their replacements live in `CustomisationRows.swift`.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift` (`CarPlayLibrary`, lines 12-42). Add the requirements below.
- Modify: `Tests/MagpieTests/CarPlayModelTests.swift`. Port the tests that used the removed builders.
- Test: `Tests/MagpieTests/CarPlayCustomisationTests.swift`

**Interfaces:**
- Consumes: `HomeSection`, `LibraryRow`, `visibleHomeSections(carPlay: true)`, `visibleLibraryRows(carPlay: true)` (Task 5); `homeShelves(for:)` (Task 20).
- Produces:

```swift
public struct CPHomeShelf: Sendable, Hashable {
    public enum Item: Sendable, Hashable { case album(Album), playlist(Playlist), genreGroup(id: String, name: String, albumCount: Int) }
    public var section: HomeSection; public var items: [Item]
}
extension CarPlayRows {
    public static func homeShelfSize(sectionCount: Int) -> Int      // max(2, min(4, 12 / max(1, n)))
    public static func home(_ shelves: [CPHomeShelf]) -> [CPSectionModel]   // header = section.title; rows id "home.<section>.<item id>"
    public static func libraryRoot(_ rows: [LibraryRow], hasFindsTab: Bool) -> [CPSectionModel]
}
// CarPlayLibrary additions:
var homeSections: [HomeSection] { get }      // observable
var libraryRows: [LibraryRow] { get }        // observable
func homeShelves(_ sections: [HomeSection], size: Int) async throws -> [CPHomeShelf]
```

**Rules:**
- `libraryRoot` maps rows to destinations: playlists, artists, albums, genres, favourites, downloads, and finds only when `!hasFindsTab`. `songs` and `requests` never appear (they are already dropped by `carPlay: true`, and dropped again here defensively).
- `watchLayout()` follows `homeSections` and `libraryRows` with `Observations`. It reloads Home and re-applies the Library root. A shape change on screen waits until the list is off screen (the existing `apply` behaviour).
- The adapter computes `homeShelves` from `model.homeShelves(for:)` with each shelf's items cut to `size`. `downloaded` items become `.album`, with the id routed to `.downloadedAlbum` (Task 23).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func homeShelfSizeBySectionCount() {
    #expect([1, 3, 4, 5, 6, 9].map(CarPlayRows.homeShelfSize(sectionCount:)) == [4, 4, 3, 2, 2, 2])
}
@Test func homeFollowsOrder() {
    let s = CarPlayRows.home([CPHomeShelf(section: .mostPlayed, items: [.album(album("a"))]),
                              CPHomeShelf(section: .jumpBackIn, items: [.album(album("b"))])])
    #expect(s.map(\.header) == ["Most played", "Jump back in"])
}
@Test func emptyHomeIsEmptyState() { #expect(CarPlayRows.home([]) == CarPlayRows.state(.empty)) }
@Test func libraryRootFollowsRowsWithoutRequestsOrSongs() {
    let titles = CarPlayRows.libraryRoot([.albums, .songs, .requests, .playlists, .genres], hasFindsTab: true).flatMap(\.rows).map(\.title)
    #expect(titles == ["Albums", "Playlists", "Genres"])
}
@Test func findsRowOnlyWithoutFindsTab() {
    #expect(CarPlayRows.libraryRoot([.finds], hasFindsTab: false).flatMap(\.rows).map(\.title) == ["Finds"])
    #expect(CarPlayRows.libraryRoot([.finds, .albums], hasFindsTab: true).flatMap(\.rows).map(\.title) == ["Albums"])
}
@Test func homeRowsOpenTheirScreens() {
    let rows = CarPlayRows.home([CPHomeShelf(section: .genres, items: [.genreGroup(id: "rock", name: "Rock", albumCount: 3)]),
                                 CPHomeShelf(section: .playlists, items: [.playlist(Playlist(id: "p1", name: "Mix", songCount: 2, duration: 1))])])
        .flatMap(\.rows)
    #expect(rows.map(\.id) == ["home.genres.rock", "home.playlists.p1"])
    #expect(rows[0].action == .open(.genreGroup(id: "rock", name: "Rock")) && rows[1].action == .open(.playlist(id: "p1", title: "Mix")))
}
@MainActor @Test func adapterDropsMadeForYouAndFollowsPrefs() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())   // Task 12 fixture
    try model.setListenBrainzToken("tok")
    model.updatePreferences { $0.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0) }
    let adapter = CarPlayLibraryAdapter(model: model)
    #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
    #expect(adapter.homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded])
    #expect(adapter.libraryRows == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
}
@MainActor @Test func adapterShelvesCutToSize() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())   // getAlbumList2 recent answers 12 albums
    let shelves = try await CarPlayLibraryAdapter(model: model).homeShelves([.jumpBackIn], size: 3)
    #expect(shelves.map(\.section) == [.jumpBackIn] && shelves[0].items.count == 3)
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `CarPlayCustomisationTests`. Expected: FAIL.
- [ ] **Step 3: Implement the rows, the controller extension, the hook edits and the adapter.**
- [ ] **Step 4: Run APP `CarPlayCustomisationTests`, `CarPlayModelTests` and `CarPlayFindsAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "CarPlay: Home and Library follow the phone's layout" plus the trailer.

---

## Task 23: CarPlay genres, downloads, offline mode and the sleep timer

**Files:**
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CustomisationRows.swift`. Add the genre, downloads and offline builders.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController+Customisation.swift`. Add the fetchers for the new destinations, play handling for `.genre`/`.genreGroup`, the offline watch, and `addSleepButton(to:)`.
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift`.
  - `updateNowPlayingButtons` (lines 403-425): append `sleepButton()`.
  - Replace Task 22's stub `customFetcher` and `playCustom` bodies with the real ones (no new hook lines).
- Modify: `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift`. Implement the members below.
- Test: `Tests/MagpieTests/CarPlayCustomisationTests.swift` (more tests)

**Interfaces:**
- Consumes: `genreSections()`, `groupSongs`, `genreSongs` (Task 19); `offlineCatalog`, `isOffline` (Task 14); `SleepTimer` (Task 10); `favourites()` (Task 21).
- Produces:

```swift
extension CarPlayRows {
    public static func genres(_ groups: [(id: String, name: String, albumCount: Int)]) -> [CPSectionModel]   // rows open .genreGroup
    public static func genreGroup(id: String, subgenres: [Genre]) -> [CPSectionModel]  // "Shuffle" (play .genreGroup shuffled: true), then one row per subgenre (play .genre shuffled: false); never push
    public static func downloads(albums: [Album], playlists: [Playlist]) -> [CPSectionModel]  // albums open .downloadedAlbum, playlists open .playlist (served from the snapshot)
    public static func favourites(_ starred: Starred, playingId: String?) -> [CPSectionModel]
}
// CarPlayLibrary additions:
var isOffline: Bool { get }                     // observable; when true, Home = [.downloaded], Library root = [.downloads], search = the snapshot
var sleepTimerActive: Bool { get }              // observable
func toggleSleepTimer()                         // off → start(preferences.playback.sleepTimer); on → cancel()
func genreGroups() async throws -> [(id: String, name: String, albumCount: Int)]
func genreSubgenres(_ groupId: String) async throws -> [Genre]
func songs(for request: CPPlayRequest) async throws -> [Song]   // .genre / .genreGroup
func downloadedAlbums() async -> [Album]; func downloadedPlaylists() async -> [Playlist]
func downloadedAlbum(id: String) async -> Album?
func favourites() async throws -> Starred
```

**Rules:**
- **Depth.** The Genres list is depth 2 and a group page is depth 3. Group pages only play (D12). `CPNavigator` refuses a push past depth 3.
- **Group and subgenre buttons** (same rule as the phone, Task 19):
  - A group offers only "Shuffle".
  - A subgenre row is its Play: songs in server order.
  - Shuffle for a subgenre is Now Playing's shuffle button, which is always there. A leaf at depth 3 can't push a second screen, and two rows per subgenre would crowd the car's list limit.
  - `songs(for: .genreGroup(id, shuffled: true))` is `groupSongs(id)`. `songs(for: .genre(name, shuffled: false))` is `genreSongs(name)`.
- **Sleep button.** `CPNowPlayingImageButton(image: UIImage(systemName: "moon.zzz"))`, with `isSelected = sleepTimerActive`. A tap calls `toggleSleepTimer()` and shows the message "Sleep timer on" or "Sleep timer off" with the existing `showMessage`.
- **Search in the car while offline** uses `OfflineCatalog.search` and doesn't call the network.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func genreGroupRows() {
    let s = CarPlayRows.genreGroup(id: "rock", subgenres: [Genre(name: "Alt Rock", songCount: 20, albumCount: 2),
                                                            Genre(name: "Indie Rock", songCount: 10, albumCount: 1)])
    let rows = s.flatMap(\.rows)
    #expect(rows.map(\.title) == ["Shuffle", "Alt Rock", "Indie Rock"])
    #expect(rows[0].action == .play(.genreGroup(id: "rock", shuffled: true)))
    #expect(rows[2].action == .play(.genre(name: "Indie Rock", shuffled: false)))
    #expect(rows.allSatisfy { if case .open = $0.action { false } else { true } }, "leaves never push")
}
@Test func genresListOpensGroups() {
    let rows = CarPlayRows.genres([(id: "rock", name: "Rock", albumCount: 3)]).flatMap(\.rows)
    #expect(rows.map(\.title) == ["Rock"] && rows[0].detail == "3 albums")
    #expect(rows[0].action == .open(.genreGroup(id: "rock", name: "Rock")))
}
@Test func genreDepthBudget() {
    var nav = CPNavigator()
    #expect(nav.push(.genres) && nav.push(.genreGroup(id: "rock", name: "Rock")))
    #expect(nav.depth == CPNavigator.maxBrowseDepth)
    #expect(!nav.push(.genres), "only two pushes below the tab")
}
@Test func downloadsRowsOpenDownloadedAlbum() {
    let rows = CarPlayRows.downloads(albums: [Album(id: "a1", name: "Continuum", artist: "Aurora Field", songCount: 6, duration: 1)],
                                     playlists: [Playlist(id: "p1", name: "Mix", songCount: 2, duration: 1)]).flatMap(\.rows)
    #expect(rows.map(\.title) == ["Continuum", "Mix"])
    #expect(rows[0].action == .open(.downloadedAlbum(id: "a1", title: "Continuum")) && rows[1].action == .open(.playlist(id: "p1", title: "Mix")))
}
@Test func favouritesRowsPlay() {
    let song = Song(id: "s1", title: "One", artist: "A", album: "B", duration: 200)
    let rows = CarPlayRows.favourites(Starred(songs: [song], albums: []), playingId: "s1").flatMap(\.rows)
    #expect(rows.map(\.title) == ["One"] && rows[0].playing && rows[0].action == .play(.songs([song], startAt: 0)))
}
@MainActor @Test func offlineCarLibraryIsDownloadsOnly() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())
    model.updatePreferences { $0.downloads.offlineMode = .on }
    let adapter = CarPlayLibraryAdapter(model: model)
    #expect(adapter.isOffline && adapter.libraryRows == [.downloads] && adapter.homeSections == [.downloaded])
}
@MainActor @Test func carSongsForGenreRequests() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())   // Task 19 genre stubs
    let adapter = CarPlayLibraryAdapter(model: model)
    #expect(try await adapter.songs(for: .genre(name: "Indie Rock", shuffled: false)).prefix(2).map(\.id) == ["ir0", "ir1"])
    #expect(try await adapter.songs(for: .genreGroup(id: "rock", shuffled: true)).count == 500)
}
@MainActor @Test func carSleepToggleUsesDefault() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())
    let adapter = CarPlayLibraryAdapter(model: model)
    adapter.toggleSleepTimer()
    guard case .at(let fire) = model.sleepTimer.mode else { Issue.record("not started"); return }
    #expect(abs(fire.timeIntervalSinceNow - 1800) < 5 && adapter.sleepTimerActive)
    adapter.toggleSleepTimer()
    #expect(model.sleepTimer.mode == .off && !adapter.sleepTimerActive)
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `CarPlayCustomisationTests`. Expected: FAIL.
- [ ] **Step 3: Implement the builders, fetchers, play handling, sleep button, offline watch and adapter members.** The Local Network states come from Task 3.
- [ ] **Step 4: Run APP `CarPlayCustomisationTests`, `CarPlayModelTests` and `CarPlayFindsAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "CarPlay: genres, downloads, offline mode, sleep timer" plus the trailer.

---

## Task 24: Security review of the round

**Files:**
- Create: `docs/reviews/security-0.0.1.md`
- Modify: whatever the fix wave touches, one commit per finding, each with a test.

- [ ] **Step 1: Dispatch a reviewer.** It's a fresh subagent on the most capable model, with the spec §11 list and this plan's Global Constraints. It reviews `git diff main...v0.0.1-custom` adversarially. Required checks, each answered with file:line evidence:
  1. ATS and the consent gate (the control under arbitrary loads):
     - Release has exactly `NSAllowsArbitraryLoads` and none of the keys that override it.
     - Every path that sends a credential checks consent first: sign-in, reconnect and failover to a saved address, re-login after 401, Connect Lidarr, and any new path this round added.
     - The "local" class can't be spoofed (Task 2 `disguisedPublicHostsStillNeedConsent`).
     - Consent is per origin.
     - Settings marks public plain-http addresses "Not encrypted".
     - Redirects stay same-origin.
  2. Local Network:
     - The prober never sends credentials.
     - The `NWBrowser` and `NWConnection` probes are cancelled.
     - Diagnostics never echo a password or a token.
     - `NSBonjourServices` declares only `_http._tcp`.
  3. Downloaded files:
     - Backup exclusion is set on files and on the directory.
     - The protection class is `completeUntilFirstUserAuthentication`.
     - File names are SHA-256 only, and extensions come from the allowlist.
     - `downloadsFull` evicts nothing.
     - A corrupt index rebuilds and never crashes.
     - Sign-out erases the scope, and late completions are discarded.
  4. Scrobble queue:
     - The file holds no credentials.
     - It is bounded at 500 per destination.
     - D29 holds on enqueue and on dequeue.
     - The ListenBrainz token is read only at send time and only sent to `api.listenbrainz.org`.
  5. Downloads:
     - `pending.json` holds no URLs.
     - No Subsonic URL reaches `Log` outside `Log.request` / redaction.
     - The fetcher session is ephemeral with no URLCache.
  6. Preferences: hostile values (huge arrays, wrong types, negative numbers) decode to clamped defaults. Task 5's `hostileGenrePreferencesAreCapped` and `oneBadFieldKeepsTheOthers` cover this; extend them if the reviewer finds another input.
  7. G1: `scripts/check-writes.sh` passes, and the only new allowlist entry is ListenBrainz's.
- [ ] **Step 2: Record the findings** in `docs/reviews/security-0.0.1.md` (severity, evidence, fix, test name).
- [ ] **Step 3: Fix wave.** For each Critical, High or Medium finding: write the failing test, fix it, run the regression gate, and commit "Security 0.0.1: <finding id> <summary>" plus the trailer. Low findings are fixed or accepted, with a reason in the doc.
- [ ] **Step 4: Have the reviewer re-check the fixed findings.** Expected: every Critical, High and Medium is closed in the doc.
- [ ] **Step 5: Commit** the review doc with "Security review: Magpie 0.0.1" plus the trailer.

---

## Task 25: Update FLOWS.md

**Files:**
- Modify: `docs/FLOWS.md`
- Modify: `docs/decisions.md`. Append D31 onwards.

- [ ] **Step 1: Rewrite the affected parts of FLOWS from the code**, not from this plan:
  - §1 table: move Downloads, quality settings, direct ListenBrainz and Downloaded-in-CarPlay into the "In" column.
  - §2: the `ListenBrainzKit → api.listenbrainz.org` submit edge.
  - §3a: Release arbitrary loads. The consent gate's "local" class: 100.64/10, `*.ts.net`, ULA and the rest. "Not encrypted" in Settings. The Local Network prompt, denial and Open Settings. Connection diagnostics. (Task 3 already added a first note.)
  - §3b: Home order and visibility, Library rows, Songs, Favourites, Genres (API calls, grouping, overrides).
  - §3c: quality per network and Low Data Mode, `format=raw`, fallback and hint, ReplayGain, sleep timer, local-first URLs, the current URL kept, the enqueued item kept.
  - §3d: both scrobble paths, the threshold by listened time, D29 on both, the queue file and retries.
  - New §3k "Downloads, cache and offline":
    - storage layout, protection and backup;
    - quotas and eviction;
    - pending jobs;
    - offline mode and probing;
    - snapshot browsing and search;
    - playability while offline.
  - §3i CarPlay:
    - layout from Preferences;
    - Genres, Downloads and Favourites;
    - offline;
    - sleep button;
    - the Local Network states (pending, denied).
  - §3j: the G1 allowlist entry.
  - §4: data table rows for audio, `pending.json`, `scrobble-queue.json` and the `magpie.prefs.*` keys, with what sign-out clears. The hosts table: what goes to api.listenbrainz.org now.
  - §5: known limits:
    - transcoded gapless;
    - private IP and `.local` unverified on a device;
    - App Store review needs the arbitrary-loads justification;
    - the CarPlay entitlement;
    - ReplayGain is attenuation only;
    - no stream capture into the cache.
- [ ] **Step 2: Append to decisions.md, one row each (#, decision, driven by, status):**
  - D31: the G1 allowlist entry for ListenBrainz `submit-listens`.
  - D32: Release `NSAllowsArbitraryLoads`, with the consent gate as the control and 100.64/10 and `*.ts.net` as local (spec §8 revised).
  - (D33 and D38 were written in Task 3. Check they're still accurate.)
  - D39: an interim TestFlight build 2 ships the network fix first, and the final 0.0.1 is build 3.
  - D40: no Opus presets (AVFoundation can't play Ogg Opus).
  - D41: genre groups offer Shuffle only, and subgenres Play and Shuffle; in the car, a subgenre's Shuffle is Now Playing's shuffle button.
  - D34: foreground ephemeral URLSession plus `pending.json` instead of a background session (§13).
  - D35: `format=raw` for Original replaces "no format" (FLOWS §3c v1 claim).
  - D36: playability filtering instead of removing non-local songs from the queue while offline.
  - D37: genre grouping keyword order.
- [ ] **Step 3: Commit** with "Docs: FLOWS and decisions for 0.0.1" plus the trailer.

---

## Task 26: Flow verification

**Files:**
- Create: `Tests/MagpieTests/FlowsVerify001Tests.swift`
- Create: `Packages/MagpieKit/Tests/PlaybackTests/FlowsVerify001Tests.swift`

- [ ] **Step 1: Dispatch verifier subagents.** There are four: §3a+§3j, §3b+§3i, §3c+§3d, and §3k+§4. Each reads its FLOWS sections and the code, and lists every concrete claim (a number, path, key, copy, order or guard) with its code location or "MISMATCH".
- [ ] **Step 2: For every claim without an existing test, add a `docClaim_<topic>` test** to the files above (app or package as fits). The pattern is `PlaybackFlowsVerifyTests.docClaim_*`. Examples:
  - `docClaim_scrobbleQueueLimit500`
  - `docClaim_audioPathIsApplicationSupportMagpieAudioScope`
  - `docClaim_cacheDefault2GB`
  - `docClaim_offlineProbeEvery30s`
  - `docClaim_carPlayShelfSizes`
- [ ] **Step 3: Resolve each MISMATCH.** Either fix the code (with a failing test first) or correct FLOWS, whichever the spec supports. Record which in the commit message.
- [ ] **Step 4: Run `scripts/test-packages.sh` and `scripts/test-app.sh`.** Expected: all green.
- [ ] **Step 5: Commit** with "Flow verification 0.0.1: doc claims pinned by tests" plus the trailer.

---

## Task 27: Final test run

- [ ] **Step 1: Bring up the dev stack.** Run `dev/bootstrap.sh`, then `dev/smoke.sh`. Expected: exit 0.
- [ ] **Step 2: Run `MAGPIE_IT=1 scripts/test-all.sh`.** Expected: exit 0. G1 check, packages including the ITs, and app plus UI tests are all green.
- [ ] **Step 3: Run `MAGPIE_IT=1 scripts/test-all.sh` a second time.** Expected: exit 0 again (no order or state dependence). A D25 flake counts only if it is the known `testConnectLidarrShowsSummary` and passes on one re-run; note it.
- [ ] **Step 4: Run `scripts/check-release.sh`.** Expected: `check-release: OK`. It checks the version against `project.yml`, arbitrary loads only, `NSBonjourServices` and the Local Network text. Its build-number check is for its own `--build 7` test archive, not for 2 or 3.
- [ ] **Step 5: Record** the commands, dates and results in `docs/RUNBOOK.md` under a "0.0.1" milestone entry. Commit "RUNBOOK: 0.0.1 final test run" plus the trailer.

---

## Task 28: CarPlay simulator captures

**Files:**
- Create: `docs/reviews/carplay-0.0.1/{home,library,genres,genre-group,downloads,offline-home,offline-library,now-playing}.png`
- Create: `docs/reviews/carplay-0.0.1/README.md` (what each capture shows, and what was checked)

- [ ] **Step 1: Prepare a separate simulator.** Create one named "Magpie CarPlay" (never "Magpie Tests"; G0 keeps that one for tests). Build Debug with `scripts/build.sh`, install it, and sign in to the dev stack (`http://127.0.0.1:4533`, `NAVIDROME_ADMIN_*` from `dev/.env.local`). On the phone:
  - Show Favourites and Genres on Home.
  - Download one album.
  - Set the sleep timer default.
- [ ] **Step 2: Open the CarPlay window.** Simulator › I/O › External Displays › CarPlay.
- [ ] **Step 3: Capture each screen** with `xcrun simctl io "Magpie CarPlay" screenshot --display=external docs/reviews/carplay-0.0.1/<name>.png`: Home, Library, Genres, a genre group, Downloads, and Now Playing with the sleep button. Then set Offline mode to On on the phone and capture offline Home and Library.
- [ ] **Step 4: Check each capture** against D12 and Tasks 22–23:
  - order as on the phone;
  - no Requests or Songs in the car Library;
  - depth ≤ 3;
  - text plus symbol states.

  Write the findings to the README. Fix any defect with a test-first commit.
- [ ] **Step 5: Commit** with "CarPlay simulator captures for 0.0.1" plus the trailer.

---

## Task 29: Release prep (controller only)

**Every step of this task is controller-only.** Implementers don't archive, upload, merge, tag or push. Merging to `main` and tagging `v0.0.1` happen only after the archive and upload have both succeeded.

- [ ] **Step 1: Pre-flight.**
  - `git status` is clean on `v0.0.1-custom`.
  - Task 27 is green on the current HEAD. Re-run `MAGPIE_IT=1 scripts/test-all.sh` if anything has changed since.
  - `scripts/check-release.sh` reports `check-release: OK`.
- [ ] **Step 2: Archive and upload the CarPlay variant first.** Run `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --carplay --upload` from `v0.0.1-custom`.
  - Expected: the upload succeeds. Build 2 was the interim build (Task 4).
  - If signing fails with a provisioning error that names `com.apple.developer.carplay-audio`, record "CarPlay entitlement not on the App ID" and go to Step 3.
- [ ] **Step 3: Fallback, only if Step 2 failed on the entitlement.** Run `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --upload`. Expected: the upload succeeds.
- [ ] **Step 4: Stop on any other failure.** If App Store Connect refuses version 0.0.1 (a lower train than 1.0), or any upload fails, stop here. Don't merge or tag; report to the owner. Never pick another version on your own (§10).
- [ ] **Step 5: Merge and tag, only after a successful upload.**

```bash
git checkout main
git merge --no-ff v0.0.1-custom -m "Merge v0.0.1-custom: Magpie 0.0.1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a v0.0.1 -m "Magpie 0.0.1 (build 3)"
```

  Expected: no conflicts, and `git describe --tags` prints `v0.0.1`. Pushing `main` and the tag is the controller's call.
- [ ] **Step 6: Report to the owner.**
  - The calls made: spec *(call)* items plus D31–D41.
  - Which variant was uploaded, as build 3. If the fallback was used, include the exact steps to request the entitlement: `docs/TESTFLIGHT.md` step 12, developer.apple.com/contact/carplay, choose Audio.
  - The manual checks left to the owner:
    - signing in by private IP and by `.local` on the device;
    - the Local Network prompt at first launch;
    - a device CarPlay check once the entitlement exists;
    - AAC and MP3 transcoding on the real server;
    - locked-phone playback of downloads in the car.

---

## Self-review

1. **Spec coverage.**
   - §8 ATS: Task 2. Local Network permission and diagnostics: Task 3, including the CarPlay states. Interim build: Task 4.
   - §10 version: Task 1.
   - §2 Preferences: Task 5.
   - §3 Home: Task 20. Library: Task 21. CarPlay layout: Task 22.
   - §4 Genres:
     - data: Task 6;
     - grouping: Task 18;
     - views and offline genres: Task 19;
     - CarPlay: Task 23.
   - §5 quality: Tasks 7 and 8. ReplayGain: Task 9. Sleep timer: Task 10 (phone) and Task 23 (car).
   - §6 downloads:
     - store and manager: Task 11;
     - UI and settings: Task 12;
     - local-first and pre-download: Task 13;
     - offline: Task 14.
   - §7 scrobbling: the threshold is Task 15, the ListenBrainz API Task 16, and the router, queue and settings Task 17.
   - §9 CarPlay: Tasks 22 and 23, captures in Task 28.
   - §11: Task 24.
   - §12 process: Tasks 24–29.
   - The owner's Local Network report (the coordinator's must-have): Task 3.

   No gaps found.
2. **Step scan.** Every code step names its signatures, its file and the values it pins. Bodies appear only where the signature doesn't determine the algorithm:
   - the listened-time algorithm;
   - the ATS oracle;
   - the transcode-IT byte checks;
   - the order of the diagnosis classifier;
   - the single lossy decode strategy.

   Every test has real `#expect` assertions with exact values. There are no comment-only bodies, and no `withKnownIssue`.
3. **Type consistency.** Checked across tasks:
   - `LocalNetworkAccess`/`LocalNetworkState`/`LocalNetworkProbing`, `ConnectDiagnosis.classify(_:url:localNetwork:pathDenied:onDevice:)`, `CPLocalNetwork`
   - `upcomingURLsChanged()`, `isPlayable`, `stopsAfterCurrent`, `lastFallbackSongId`
   - `AudioStore`/`AudioEntry`/`DownloadReason`, `DownloadManager.localFiles`, `OfflineCatalog`
   - `ScrobbleSettings`/`ScrobbleRouter`/`ScrobbleQueue`
   - `GenreGroups.grouped`, `homeShelves(for:)`, `libraryRows`, `CPHomeShelf`, `CarPlayRows.libraryRoot(_:hasFindsTab:)`
   - `visibleHomeSections(offline:hasListenBrainzToken:carPlay:)`, `visibleLibraryRows(offline:findsSetUp:lidarrConnected:carPlay:)`
   - `OrderedVisibility.set(_:visible:keepingOneOf:)`/`move`/`moveUp`/`moveDown`, `OrderedVisibilityEditor`
   - `FakeEngine.setVolumesCalls`/`setVolumeCalls`
   - `DownloadManager.store`/`storeDirectory`/`redownload`, `AudioStore.replace`/`saveCover`
   - `.defaultValue` for areas, `.standard` for `Preferences` and `ScrobbleRule`
4. **Review Focus.** There are five lines, each with a test in its owning task: Tasks 3, 2, 12, 11 and 14. The test comments carry the same numbers. The storage-full and revoked-token tests are labelled "edge test".
5. **Proportion.** The plan is longer than the spec. The extra length is test assertions with exact values, not implementation bodies.
