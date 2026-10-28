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
- **D3.** Every state (downloaded, downloading, waiting, full, offline, local network off) shows as text plus an SF Symbol, never as shape or colour alone.
- **D12.** CarPlay tab roots are list templates. At most 2 pushes go below a tab (`CPNavigator.maxBrowseDepth = 3`). Leaves play and never push. State copy describes and doesn't instruct; the one recorded exception is the spec §8 line "Open Magpie on your iPhone once to allow local network access" (Task 3, decisions.md).
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
  - `MARKETING_VERSION` is 0.0.1.
  - The interim TestFlight build is `--build 2` (Task 4). The final one is `--build 3` (Task 29).
  - The tag is `v0.0.1`.
- **Settings.** Every new customisation setting sits in one of four Settings sections, each with a default: "Home & Library", "Playback", "Downloads & Storage" and "Scrobbling". Nothing new is required.
- **Secrets.**
  - Tokens and passwords live only in the Keychain.
  - No URL carrying Subsonic auth (`u`, `t`, `s`) is ever written to a file. Logs go through `Log.request` / `Log.category` only.
  - The ListenBrainz token is read from the Keychain at send time.
- **Size rule.** New work goes in new files. `App/AppModel.swift` (759 lines), `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift` (852) and `RequestRunner.swift` (1146) only get the hook lines each task names.
- **Line references** (`file:NN-MM`) are to commit 45a20c5. Earlier tasks shift them, so match on the quoted code.
- **New files** are picked up by `xcodegen generate` (folder sources). Never hand-edit `Magpie.xcodeproj`.
- **Commits** end with a blank line and then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Controller-only steps.** Uploads to App Store Connect, and pushes of `main` or tags, are controller-only. Implementers never upload.

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
| `project.yml`, `scripts/check-release.sh`, `docs/TESTFLIGHT.md`, `ListenBrainzKit/MusicBrainzClient.swift`, `App/AppModel+Version.swift` (new) | Version 0.0.1 and the user agent | 1 |
| `project.yml`, `scripts/check-release.sh`, `App/ServerAddress.swift`, `App/Screens/Settings/SettingsView.swift`, `docs/{RUNBOOK,TESTFLIGHT}.md` | Release arbitrary loads, wider "local" class, the "Not encrypted" mark, consent-gate tests | 2 |
| `App/Network/LocalNetworkAccess.swift` (new), `App/Network/NWBrowserLocalNetworkProber.swift` (new), `App/Screens/Connect/ConnectDiagnosis.swift` (new), `App/Screens/Connect/{ConnectView,ConnectErrorCopy}.swift`, `App/AppModel.swift` (hooks), CarPlay state rows | Local Network permission, denial detection, diagnostics | 3 |
| none (controller) | Interim TestFlight build 2 | 4 |
| `MagpieCore/Preferences.swift` (new), `App/PreferencesStore.swift` (new), `App/AppModel+Preferences.swift` (new) | Every preference area, the store, the fan-out | 5 |
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
| `App/AppModel+Home.swift` (new), `App/Screens/Home/HomeView.swift`, `App/Screens/Settings/HomeLayoutView.swift` (new) | The Home layout | 20 |
| `App/Screens/Library/{LibraryView,SongsListView,FavouritesView}.swift`, `App/Screens/Settings/LibraryLayoutView.swift` (new) | Library rows, Songs, Favourites | 21 |
| `CarPlayUI/CustomisationRows.swift` (new), `CarPlayUI/CarPlayController+Customisation.swift` (new), `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift` (new) | CarPlay layout | 22 |
| Same CarPlay files | CarPlay genres, downloads, offline and sleep | 23 |
| `docs/reviews/security-0.0.1.md`, `docs/FLOWS.md`, `docs/decisions.md`, flow-verify tests, `docs/reviews/carplay-0.0.1/` | Process | 24–29 |

---

## Task 1: Version 0.0.1

**Files:**
- Modify: `project.yml:14`. `MARKETING_VERSION: "0.0.1"`.
- Modify: `scripts/check-release.sh:25`. Compare with `0.0.1` and say "is not 0.0.1".
- Modify: `App/Screens/Settings/SettingsView.swift:47-52`. Use `AppModel.marketingVersion`.
- Modify: `Packages/MagpieKit/Sources/ListenBrainzKit/MusicBrainzClient.swift:63`.
- Modify: `App/AppModel.swift:707`. `MusicBrainzClient(transport: transport, userAgent: MusicBrainzClient.userAgent(version: Self.marketingVersion))`.
- Create: `App/AppModel+Version.swift`
- Modify: `docs/TESTFLIGHT.md`. "The version stays 1.0" becomes "The version stays 0.0.1". "Version 1.0" becomes "Version 0.0.1". Add a note that build numbers keep rising (next is 2).
- Test: `Packages/MagpieKit/Tests/ListenBrainzKitTests/MusicBrainzTests.swift:44` (update), and `Tests/MagpieTests/VersionAppTests.swift`

**Interfaces:**
- Produces:
  - `public static func userAgent(version: String) -> String` on `MusicBrainzClient`. The format is `"Magpie/\(version) ( https://github.com/bleak-rooster )"`, and `defaultUserAgent = userAgent(version: "0.0.1")`.
  - `nonisolated static var marketingVersion: String` on `AppModel`. It reads `CFBundleShortVersionString` and falls back to `"0.0.1"`.

- [ ] **Step 1: Write the failing tests.** In MusicBrainzTests, change line 44's expectation to `"Magpie/0.0.1 ( https://github.com/bleak-rooster )"` and add:

```swift
@Test func userAgentCarriesVersion() {
    #expect(MusicBrainzClient.userAgent(version: "0.0.1") == "Magpie/0.0.1 ( https://github.com/bleak-rooster )")
}
```

`VersionAppTests`:

```swift
@Test func bundleIsVersion001() {
    #expect(AppModel.marketingVersion == "0.0.1")
    #expect(SettingsView.version.hasPrefix("0.0.1 ("))
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `MusicBrainzTests` (FAIL: `Magpie/0.1` ≠ `Magpie/0.0.1`), then APP `VersionAppTests` (FAIL: "1.0").
- [ ] **Step 3: Make the code changes listed under Files.**
- [ ] **Step 4: Run PKG `MusicBrainzTests` and APP `VersionAppTests`.** Expected: PASS.
- [ ] **Step 5: Run `scripts/check-release.sh`.** Expected: last line `check-release: OK`.
- [ ] **Step 6: Commit** with message "Version 0.0.1 (bundle, release check, Settings, MusicBrainz user agent, TestFlight doc)" plus the trailer.

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

`ConsentGateTests` are adversarial. They use the `ATSAppTests` set-up, but with `atsAllowsArbitraryLoads = true` (the Release behaviour):

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

## Task 3: Local Network permission and connection diagnostics

**Files:**
- Create: `App/Network/LocalNetworkAccess.swift`
- Create: `App/Network/NWBrowserLocalNetworkProber.swift`
- Create: `App/Screens/Connect/ConnectDiagnosis.swift`
- Modify: `project.yml` (`info.properties`, next to `NSLocalNetworkUsageDescription`, line 93). Add `NSBonjourServices: ["_http._tcp"]`.
- Modify: `scripts/check-release.sh`. Add `[ "$(pb NSBonjourServices:0 "$plist")" = "_http._tcp" ] || fail "$variant: NSBonjourServices missing"`. The `NSLocalNetworkUsageDescription` check already exists (line 32).
- Modify: `App/ServerAddress.swift`. Add `static func needsLocalNetworkPermission(_ url: URL) -> Bool`. It is true for `isLocalNetwork(url)` (private and link-local IPv4, `.local`, single-label names) and for IPv6 ULA and link-local. It is false for loopback, 100.64/10, `*.ts.net` and public hosts.
- Modify: `App/AppModel.swift`.
  - Init gains `localNetworkProber: (any LocalNetworkProbing)? = nil`. When it is nil, the real `NWBrowserLocalNetworkProber`, unless `XCTestConfigurationFilePath` is set (then `NotNeededProber`, so hosted tests never touch the system prompt).
  - Add a stored `let localNetwork: LocalNetworkAccess`.
  - `signIn` (lines 324-347): before the probe loop, `await localNetwork.ensureAccess(for: urls)`. For each failed local URL, set `ProbeFailure.localNetworkDenied = await localNetwork.checkDenied(for: base)`.
  - `resumeSavedSession` (line 289): when `localNetwork.state == .unknown`, start `Task { await localNetwork.ensureAccess(for: saved.endpoint.bases) }`.
  - `request`: a success while the active base needs permission calls `localNetwork.noteLocalSuccess()`.
  - `ProbeFailure` (lines 36-39) gains `var localNetworkDenied = false`.
- Modify: `App/Screens/Connect/ConnectErrorCopy.swift:63-112`. Under `SignInError.unreachable`, `unreachableMessage` uses `ConnectDiagnosis` for the first failure whose diagnosis isn't `.other`. It keeps the certificate and https-answer checks first. Add `static func offersOpenSettings(for error: Error) -> Bool`.
- Modify: `App/Screens/Connect/ConnectView.swift`.
  - Add an "Allow local network access" button (`connect-allow-local-network`). It shows while any typed address `needsLocalNetworkPermission` and the state isn't `.granted`.
  - When the error offers it, show an "Open Settings" button (`UIApplication.openSettingsURLString`).
- Modify: `App/Screens/Settings/SettingsView.swift:56-70` (Servers). Add the same button when the state isn't granted. When denied, show the denial message and "Open Settings".
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/TemplateModels.swift:108-129`. `CarPlayState` gains `.localNetworkDenied` ("Local network access is off for Magpie") and `.localNetworkPending` ("Open Magpie on your iPhone once to allow local network access").
- Modify: `Packages/MagpieKit/Sources/CarPlayUI/CarPlayController.swift`.
  - `CarPlayLibrary` (lines 12-42) gains `var localNetwork: CPLocalNetwork { get }`.
  - `showUnavailable` (lines 344-347) and the load-failure state mapping use `.localNetworkDenied` or `.localNetworkPending` instead of `.outOfReach` when `isOutOfReach(error)` and `localNetwork != .fine`.
- Modify: `App/CarPlay/CarPlaySceneDelegate.swift`. The adapter maps:
  - denied → `.denied`;
  - unknown, while the active base needs permission → `.pending`;
  - otherwise → `.fine`.
- Modify: `docs/FLOWS.md` §3a, `docs/RUNBOOK.md` and `docs/TESTFLIGHT.md` step 9. Explain the prompt, where to find Magpie in Settings › Privacy & Security › Local Network, the diagnostics, and the Open Settings path.
- Test: `Tests/MagpieTests/LocalNetworkAccessTests.swift`, `Tests/MagpieTests/ConnectDiagnosisTests.swift`, `Tests/MagpieTests/CarPlayModelTests.swift` (two tests)

**Interfaces:**
- Produces:

```swift
enum LocalNetworkState: String, Equatable, Sendable { case unknown, granted, denied, notNeeded }

@MainActor protocol LocalNetworkProbing: AnyObject {
    /// Triggers the system prompt if it hasn't been answered. Returns .granted or .denied, or .unknown on timeout.
    func requestAccess() async -> LocalNetworkState
    /// A connection to host:port is held back by the Local Network setting right now.
    func isDenied(host: String, port: Int) async -> Bool
}

@MainActor @Observable final class LocalNetworkAccess {
    static let stateKey = "magpie.localNetwork.state"
    init(prober: any LocalNetworkProbing, defaults: UserDefaults)
    private(set) var state: LocalNetworkState            // persisted (granted/denied); unknown at first launch
    func ensureAccess(for urls: [URL]) async -> LocalNetworkState
    func request() async -> LocalNetworkState            // the "Allow local network access" button
    func noteLocalSuccess()
    func checkDenied(for url: URL) async -> Bool
}

final class NWBrowserLocalNetworkProber: LocalNetworkProbing
final class NotNeededProber: LocalNetworkProbing          // tests: .notNeeded, never denied

enum ConnectDiagnosis: Equatable {
    case localhostOnDevice, nameNotFound(String), atsBlocked, localNetworkDenied, timedOut(String), loginFailed,
         unreachable(String), other
    static func classify(_ error: Error, url: URL, localNetwork: LocalNetworkState, pathDenied: Bool, onDevice: Bool) -> ConnectDiagnosis
    var message: String
}

public enum CPLocalNetwork: Sendable, Hashable { case fine, pending, denied }
```

**Rules:**
- **`ensureAccess`:**
  - Returns `.notNeeded` without calling the prober when no URL `needsLocalNetworkPermission`.
  - Returns `.granted` without calling it when the state is already granted.
  - Otherwise it calls `prober.requestAccess()`, stores the answer, and persists `granted` or `denied`.
  - Once denied, it calls the prober again each time, so a later change in Settings is seen.
- **`NWBrowserLocalNetworkProber.requestAccess`:**
  - Starts `NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)`.
  - `.ready` or any result means `.granted`.
  - `.waiting(.dns(-65570 /* kDNSServiceErr_PolicyDenied */))` keeps waiting while the prompt may be up. If it still stands after 30 s, the answer is `.denied`.
  - `.failed` means `.unknown`.
  - The browser is always cancelled.
- **`isDenied(host:port:)`** opens an `NWConnection` (tcp). It returns true when, within 2 s, it is `.waiting` with `currentPath?.unsatisfiedReason == .localNetworkDenied`. It always cancels the connection.
- **`classify`, in order:**
  1. `onDevice && ServerAddress.isLoopback(url)` → `.localhostOnDevice`.
  2. `NavidromeError.badCredentials` → `.loginFailed`.
  3. A URLError ATS error → `.atsBlocked`.
  4. `needsLocalNetworkPermission(url)` and a connection-class URLError, and (`pathDenied` or `localNetwork == .denied`) → `.localNetworkDenied`. A `cannotFindHost` or `dnsLookupFailed` counts here only for a `.local` host.
  5. `cannotFindHost` / `dnsLookupFailed` → `.nameNotFound(host)`.
  6. `timedOut` → `.timedOut(hostAndPort)`.
  7. Other connection errors (`AppModel.isConnectionError`) → `.unreachable(hostAndPort)`.
  8. Anything else → `.other`.
- **`onDevice`** is true unless `targetEnvironment(simulator)`. Tests pass it explicitly.
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

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor final class FakeProber: LocalNetworkProbing {
    var answer: LocalNetworkState = .granted; var denied = false
    var calls = 0; var requestsSeenAtCall: [Int] = []; var onCall: () -> Int = { 0 }
    func requestAccess() async -> LocalNetworkState { calls += 1; requestsSeenAtCall.append(onCall()); return answer }
    func isDenied(host: String, port: Int) async -> Bool { denied }
}

@MainActor @Suite struct LocalNetworkAccessTests {
    @Test(arguments: [("http://192.168.1.20:4533", true), ("http://10.0.0.5", true), ("http://169.254.1.1", true),
                      ("http://nas:4533", true), ("http://nas.local:4533", true), ("http://[fd00::1]:4533", true),
                      ("http://[fe80::1]:4533", true), ("http://127.0.0.1:4533", false), ("http://localhost:4533", false),
                      ("http://100.64.10.20:4533", false), ("http://nas.tail1.ts.net:4533", false), ("https://music.example.com", false)])
    func needsPermission(_ text: String, _ expected: Bool) {
        #expect(ServerAddress.needsLocalNetworkPermission(URL(string: text)!) == expected)
    }
    @Test func notNeededSkipsProber() async {
        let p = FakeProber(); let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [URL(string: "https://music.example.com")!]) == .notNeeded && p.calls == 0)
    }
    @Test func grantedPersistsAndIsNotReasked() async {
        let d = freshDefaults(); let p = FakeProber()
        #expect(await LocalNetworkAccess(prober: p, defaults: d).ensureAccess(for: [lan]) == .granted)
        let again = LocalNetworkAccess(prober: p, defaults: d)
        #expect(again.state == .granted)
        _ = await again.ensureAccess(for: [lan]); #expect(p.calls == 1)
    }
    @Test func deniedIsReaskedAndCanTurnGranted() async {
        let p = FakeProber(); p.answer = .denied; let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [lan]) == .denied)
        p.answer = .granted
        #expect(await a.ensureAccess(for: [lan]) == .granted && p.calls == 2)
    }
    @Test func localSuccessMeansGranted() { /* state .unknown → noteLocalSuccess() → .granted, persisted */ }

    @Test func signInAsksBeforeTheFirstRequest() async throws {
        let p = FakeProber(); p.onCall = { transport.inner.requests.count }
        let model = makeModel(prober: p)
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        #expect(p.calls == 1 && p.requestsSeenAtCall == [0])
    }
    @Test func httpsPublicDoesNotAsk() async throws { /* https://music.example.com stubbed → p.calls == 0 */ }
    @Test func deniedSignInExplainsAndOffersSettings() async throws {
        // p.answer = .denied, p.denied = true; ping to 192.168.1.2 fails with URLError(.notConnectedToInternet)
        // → ConnectErrorCopy.message(for: error) == ConnectDiagnosis.localNetworkDenied.message; offersOpenSettings == true
    }
}

@Suite struct ConnectDiagnosisTests {
    let homebox = URL(string: "http://homeserver:4533")!
    @Test func localhostOnDeviceOnly() {
        let url = URL(string: "http://localhost:4533")!
        #expect(ConnectDiagnosis.classify(URLError(.cannotConnectToHost), url: url, localNetwork: .unknown, pathDenied: false, onDevice: true) == .localhostOnDevice)
        #expect(ConnectDiagnosis.classify(URLError(.cannotConnectToHost), url: url, localNetwork: .unknown, pathDenied: false, onDevice: false) == .unreachable("localhost:4533"))
        #expect(ConnectDiagnosis.localhostOnDevice.message == "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533.")
    }
    @Test func eachStep() {
        func c(_ e: Error, _ u: URL = URL(string: "http://homeserver:4533")!, _ s: LocalNetworkState = .granted, _ d: Bool = false) -> ConnectDiagnosis {
            ConnectDiagnosis.classify(e, url: u, localNetwork: s, pathDenied: d, onDevice: true)
        }
        #expect(c(URLError(.cannotFindHost)) == .nameNotFound("homeserver"))
        #expect(c(URLError(.appTransportSecurityRequiresSecureConnection)) == .atsBlocked)
        #expect(c(URLError(.timedOut), URL(string: "https://music.example.com")!) == .timedOut("music.example.com"))
        #expect(c(NavidromeError.badCredentials) == .loginFailed)
        #expect(c(URLError(.notConnectedToInternet), URL(string: "http://192.168.1.20:4533")!, .granted, true) == .localNetworkDenied)
        #expect(ConnectDiagnosis.localNetworkDenied.message == "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network.")
    }
    @Test func diagnosisOrderForOwnersSetup() {                               // Review Focus 1
        #expect(ConnectDiagnosis.classify(URLError(.cannotFindHost), url: homebox, localNetwork: .denied, pathDenied: false, onDevice: true) == .nameNotFound("homeserver"))
        #expect(ConnectDiagnosis.classify(URLError(.cannotFindHost), url: URL(string: "http://nas.local:4533")!, localNetwork: .denied, pathDenied: false, onDevice: true) == .localNetworkDenied)
        #expect(ConnectDiagnosis.classify(URLError(.timedOut), url: URL(string: "http://192.168.1.20:4533")!, localNetwork: .granted, pathDenied: true, onDevice: true) == .localNetworkDenied)
        #expect(ConnectDiagnosis.classify(URLError(.timedOut), url: URL(string: "http://192.168.1.20:4533")!, localNetwork: .granted, pathDenied: false, onDevice: true) == .timedOut("192.168.1.20:4533"))
        #expect(ConnectDiagnosis.classify(URLError(.timedOut), url: URL(string: "http://100.64.10.20:4533")!, localNetwork: .denied, pathDenied: false, onDevice: true) == .timedOut("100.64.10.20:4533"))
    }
}
```

CarPlayModelTests:

```swift
@Test func localNetworkStateCopy() {
    #expect(CarPlayRows.state(.localNetworkDenied).flatMap(\.rows).first?.title == "Local network access is off for Magpie")
    #expect(CarPlayRows.state(.localNetworkPending).flatMap(\.rows).first?.title == "Open Magpie on your iPhone once to allow local network access")
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `LocalNetworkAccessTests`, `ConnectDiagnosisTests` and `CarPlayModelTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement the files and the hook lines listed above.** Then add the check-release line and the `NSBonjourServices` entry.
- [ ] **Step 4: Run APP `LocalNetworkAccessTests`, `ConnectDiagnosisTests`, `CarPlayModelTests`, `ATSAppTests` and `EdgeCaseAppTests`.** Expected: PASS. Existing ConnectErrorCopy expectations still hold for certificate, https-answer and needsHTTPS cases.
- [ ] **Step 5: Run `scripts/check-release.sh`.** Expected: `check-release: OK`.
- [ ] **Step 6: Update FLOWS §3a, RUNBOOK and TESTFLIGHT, then commit:** "Local Network: ask up front, detect denial, explain each failed step, Open Settings" plus the trailer.

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
- Create: `Packages/MagpieKit/Sources/MagpieCore/Preferences.swift`
- Create: `App/PreferencesStore.swift`
- Create: `App/AppModel+Preferences.swift`
- Modify: `App/AppModel.swift`. Add a stored property `var preferences: Preferences` after line 49 (`var theme: Theme`) and `@ObservationIgnored let preferencesStore: PreferencesStore`. In `init` (near line 196) set `self.preferencesStore = PreferencesStore(defaults: defaults)` and `self.preferences = preferencesStore.load()`.
- Test: `Packages/MagpieKit/Tests/MagpieCoreTests/PreferencesTests.swift`
- Test: `Tests/MagpieTests/PreferencesAppTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (MagpieCore, all `public`, `Codable`, `Hashable` and `Sendable`):

  Enums:
  - `enum HomeSection: String, CaseIterable { case jumpBackIn, madeForYou, recentlyAdded, mostPlayed, favourites, randomAlbums, playlists, genres, downloaded; var title: String }`
    - Titles: "Jump back in", "Made for you", "Recently added", "Most played", "Favourites", "Random albums", "Playlists", "Genres", "Downloaded".
  - `enum LibraryRow: String, CaseIterable { case playlists, artists, albums, songs, genres, favourites, downloads, finds, requests; var title: String; var symbol: String }`
  - `enum StreamQuality: String, CaseIterable { case original, aac256, aac160, aac96, opus192, opus128, opus64, mp3_320, mp3_192; var format: String; var maxBitRate: Int?; var title: String }`
    - `format` is "raw", "aac", "opus" or "mp3".
    - Titles: "Original", "High · AAC 256 kbps", "Medium · AAC 160 kbps", "Low · AAC 96 kbps", "High · Opus 192 kbps", "Medium · Opus 128 kbps", "Low · Opus 64 kbps", "MP3 320 kbps", "MP3 192 kbps".
  - `enum ReplayGainMode: String { case off, track, album }`
  - `enum SleepTimerOption: String, CaseIterable { case m15, m30, m45, m60, m90, endOfSong; var seconds: TimeInterval? }`
  - `enum CacheLimit: String, CaseIterable { case mb500, gb1, gb2, gb5, gb10; var bytes: Int64 }` (decimal: 500_000_000 … 10_000_000_000)
  - `enum DownloadsLimit: String, CaseIterable { case none, gb5, gb10, gb20, gb50; var bytes: Int64? }`
  - `enum OfflineMode: String { case automatic, on, off }`
  - `enum GenreViewMode: String { case grouped, all }`

  Layout and area structs:
  - `struct HomeEntry { var section: HomeSection; var visible: Bool }`
  - `struct LibraryEntry { var row: LibraryRow; var visible: Bool }`
  - `protocol PreferenceArea: Codable, Hashable, Sendable { static var key: String { get }; static var `default`: Self { get }; func normalised() -> Self }`
    - Extension: `static func decode(_ data: Data?) -> Self` (nil or any decode failure gives `.default`; otherwise `normalised()`).
    - Extension: `func encoded() -> Data`.
  - `struct LayoutPreferences: PreferenceArea`
    - Key: `magpie.prefs.layout`.
    - Fields: `home: [HomeEntry]`, `library: [LibraryEntry]`, `showsRecentlyAdded: Bool`.
    - Mutating: `setHome(_:visible:)`, `moveHome(fromOffsets: IndexSet, toOffset: Int)`, `resetHome()`, `setLibrary(_:visible:) -> Bool`, `moveLibrary(fromOffsets:toOffset:)`, `resetLibrary()`.
    - `func visibleHomeSections(offline: Bool, hasListenBrainzToken: Bool, carPlay: Bool) -> [HomeSection]`
    - `func visibleLibraryRows(offline: Bool, findsSetUp: Bool, lidarrConnected: Bool, carPlay: Bool) -> [LibraryRow]`
  - `struct PlaybackPreferences: PreferenceArea`
    - Key: `magpie.prefs.playback`.
    - Fields: `wifi: StreamQuality`, `cellular: StreamQuality`, `replayGain: ReplayGainMode`, `sleepTimer: SleepTimerOption`.
  - `struct DownloadPreferences: PreferenceArea`
    - Key: `magpie.prefs.downloads`.
    - Fields: `quality: StreamQuality`, `overMobileData: Bool`, `concurrent: Int`, `preDownload: Int`, `keepRecentlyPlayed: Bool`, `cacheLimit: CacheLimit`, `downloadsLimit: DownloadsLimit`, `offlineMode: OfflineMode`, `keepFavourites: Bool`.
  - `struct ScrobbleRule { var percent: Int; var minutes: Int? }`
    - Codable as `{"percent": Int, "minutesCap": Int}`, where `0` means Never.
    - `static let default = ScrobbleRule(percent: 50, minutes: 4)`.
    - `func normalised() -> ScrobbleRule`.
    - `func threshold(duration: TimeInterval) -> TimeInterval?`.
  - `struct ScrobblePreferences: PreferenceArea`
    - Key: `magpie.prefs.scrobbling`.
    - Fields: `viaNavidrome: Bool`, `viaListenBrainz: Bool`, `rule: ScrobbleRule`.
  - `struct GenrePreferences: PreferenceArea`
    - Key: `magpie.prefs.genres`.
    - Fields: `mode: GenreViewMode`, `assignments: [String: String]` (genre key to group id), `groupNames: [String: String]`, `hidden: Set<String>`, `customGroups: [String]`.
  - `struct Preferences { var layout; var playback; var downloads; var scrobbling; var genres; static let default }`
  - Every area also encodes `"version": 1` and reads it back with `decodeIfPresent`. A newer version still decodes lossily.
- Produces (App):
  - `struct PreferencesStore { init(defaults: UserDefaults); func load() -> Preferences; func save(_ new: Preferences, previous: Preferences) }`. Writes only the areas that changed.
  - `extension AppModel { func updatePreferences(_ change: (inout Preferences) -> Void); func preferencesDidChange(from old: Preferences) }`
    - `preferencesDidChange` starts as an empty fan-out. Later tasks add one line each.

**Rules the signatures don't settle:**
- The `normalised()` lossy decode works like this:
  - Unknown raw values and duplicates are dropped (first occurrence wins).
  - Missing cases are appended in `allCases` order with their default visibility.
  - Integers are clamped: `concurrent` 1…4, `preDownload` 0…10, `percent` 10…90 rounded to the nearest 5 (half up), `minutes` 1…10. A `minutesCap` of 0 means Never.
- `setLibrary(_:visible: false)` returns false and changes nothing when the row is the last visible one among the always-available rows (`playlists, artists, albums, songs, genres, favourites, downloads`).
- `threshold(duration:)` works like this:
  - Duration ≥ 30: `min(duration * percent / 100, minutes * 60)`. With Never, it's the percentage only.
  - Duration > 0 and < 30: nil.
  - Duration ≤ 0 (unknown): `minutes * 60`, or nil with Never.
- `visibleHomeSections`:
  - When `offline`, the result is `[.downloaded]`.
  - Otherwise it's the visible entries in order. `madeForYou` is dropped without a token and always dropped when `carPlay`.
- `visibleLibraryRows`:
  - When `offline`, the result is `[.downloads]`.
  - Otherwise it's the visible entries in order. `finds` is dropped unless `findsSetUp`, and `requests` unless `lidarrConnected`. `requests` and `songs` are dropped when `carPlay`.

- [ ] **Step 1: Write the failing package tests**

```swift
@Suite struct PreferencesTests {
    @Test func defaultsMatchSpec() {
        let p = Preferences.default
        #expect(p.layout.home.map(\.section) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites,
                                                 .randomAlbums, .playlists, .genres, .downloaded])
        #expect(p.layout.home.map(\.visible) == [true, true, true, true, false, false, false, false, false])
        #expect(p.layout.library.map(\.row) == LibraryRow.allCases && p.layout.library.allSatisfy(\.visible))
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

    @Test func corruptDataFallsBackToDefault() {
        #expect(LayoutPreferences.decode(Data("{not json".utf8)) == .default)
        #expect(DownloadPreferences.decode(nil) == .default)
        #expect(PlaybackPreferences.decode(Data(#"{"version":1,"wifi":"lossless-ultra"}"#.utf8)).wifi == .original)
    }

    @Test func unknownAndDuplicateSectionsDropped() {
        let json = #"{"version":1,"home":[{"section":"mostPlayed","visible":true},{"section":"karaoke","visible":true},{"section":"mostPlayed","visible":false}]}"#
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.home.first == HomeEntry(section: .mostPlayed, visible: true))
        #expect(layout.home.count == 9)
        #expect(layout.home.filter { $0.section == .mostPlayed }.count == 1)
    }

    @Test func outOfRangeValuesClamp() {
        let d = DownloadPreferences.decode(Data(#"{"version":1,"concurrent":9,"preDownload":-1}"#.utf8))
        #expect(d.concurrent == 4 && d.preDownload == 0)
        #expect(ScrobbleRule(percent: 7, minutes: 0).normalised() == ScrobbleRule(percent: 10, minutes: 1))
        #expect(ScrobbleRule(percent: 52, minutes: 11).normalised() == ScrobbleRule(percent: 50, minutes: 10))
        #expect(ScrobbleRule(percent: 53, minutes: nil).normalised() == ScrobbleRule(percent: 55, minutes: nil))
    }

    @Test func neverRoundTrips() throws {
        var s = ScrobblePreferences.default
        s.rule = ScrobbleRule(percent: 90, minutes: nil)
        #expect(ScrobblePreferences.decode(s.encoded()).rule.minutes == nil)
    }

    @Test func scrobbleThresholds() {
        let rule = ScrobbleRule.default
        #expect(rule.threshold(duration: 200) == 100)
        #expect(rule.threshold(duration: 1000) == 240)
        #expect(rule.threshold(duration: 29) == nil)
        #expect(rule.threshold(duration: 30) == 15)
        #expect(rule.threshold(duration: 0) == 240)
        #expect(ScrobbleRule(percent: 90, minutes: nil).threshold(duration: 600) == 540)
        #expect(ScrobbleRule(percent: 50, minutes: nil).threshold(duration: 0) == nil)
    }

    @Test func lastVisibleLibraryRowCannotBeHidden() {
        var l = LayoutPreferences.default
        for row in [LibraryRow.playlists, .artists, .albums, .songs, .genres, .favourites] { #expect(l.setLibrary(row, visible: false)) }
        #expect(!l.setLibrary(.downloads, visible: false))
        #expect(l.library.first { $0.row == .downloads }?.visible == true)
    }

    @Test func visibleSectionRules() {
        let l = LayoutPreferences.default
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false, carPlay: false) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true, carPlay: true) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true, carPlay: false) == [.downloaded])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: true, carPlay: true)
                == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false) == [.downloads])
    }

    @Test func resetHomeRestoresTable() {
        var l = LayoutPreferences.default
        l.moveHome(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        l.setHome(.favourites, visible: true)
        l.resetHome()
        #expect(l.home == LayoutPreferences.default.home)
    }

    @Test func qualityStreamParameters() {
        #expect(StreamQuality.original.format == "raw" && StreamQuality.original.maxBitRate == nil)
        #expect(StreamQuality.aac160.format == "aac" && StreamQuality.aac160.maxBitRate == 160)
        #expect(StreamQuality.opus64.format == "opus" && StreamQuality.opus64.maxBitRate == 64)
        #expect(StreamQuality.mp3_320.format == "mp3" && StreamQuality.mp3_320.maxBitRate == 320)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `PreferencesTests`. Expected: `error: cannot find 'Preferences' in scope`.
- [ ] **Step 3: Implement `MagpieCore/Preferences.swift`** with the interfaces and rules above. Use a hand-written `init(from:)` per area, with `try? container.decodeIfPresent` per field, then `normalised()`.
- [ ] **Step 4: Run PKG `PreferencesTests`.** Expected: PASS.
- [ ] **Step 5: Write the failing app tests**

```swift
@MainActor @Suite(.serialized) struct PreferencesAppTests {
    let defaults = UserDefaults(suiteName: "magpie-tests-prefs-\(UUID().uuidString)")!
    func makeModel() -> AppModel { /* same initialiser as ATSAppTests.makeModel, with `defaults` */ }

    @Test func savesOneKeyPerChangedAreaAndReloads() {
        let model = makeModel()
        model.updatePreferences { $0.playback.cellular = .opus64 }
        #expect(defaults.data(forKey: "magpie.prefs.playback") != nil)
        #expect(defaults.data(forKey: "magpie.prefs.layout") == nil, "unchanged areas aren't written")
        #expect(makeModel().preferences.playback.cellular == .opus64)
    }

    @Test func corruptStoredAreaFallsBackWithoutCrashing() {
        defaults.set(Data([0xFF, 0x00]), forKey: "magpie.prefs.downloads")
        #expect(makeModel().preferences.downloads == .default)
    }
}
```

- [ ] **Step 6: Run APP `PreferencesAppTests`.** Expected: FAIL (`cannot find 'PreferencesStore'` / `updatePreferences`).
- [ ] **Step 7: Implement `PreferencesStore`, the `AppModel` property and init lines, and `AppModel+Preferences.swift`.** `updatePreferences` copies, applies the change, normalises each area, saves the areas that changed, assigns `preferences`, then calls `preferencesDidChange(from:)`.
- [ ] **Step 8: Run APP `PreferencesAppTests`, then the regression gate.** Expected: PASS.
- [ ] **Step 9: Commit**

```bash
git add Packages/MagpieKit/Sources/MagpieCore/Preferences.swift Packages/MagpieKit/Tests/MagpieCoreTests/PreferencesTests.swift App/PreferencesStore.swift App/AppModel+Preferences.swift App/AppModel.swift Tests/MagpieTests/PreferencesAppTests.swift
git commit -m "Preferences: one store for layout, playback, downloads, scrobbling and genres

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 6: Navidrome API additions

**Files:**
- Modify: `Packages/MagpieKit/Sources/MagpieCore/Models.swift`. On `Song`, add `public var genre: String?` and `public var replayGain: ReplayGain?`, plus init params `genre: String? = nil` and `replayGain: ReplayGain? = nil` (existing call sites keep compiling). Add `public struct ReplayGain: Sendable, Hashable, Codable { trackGain, albumGain, trackPeak, albumPeak: Double? }` and `public struct Genre: Sendable, Hashable, Codable { name: String; songCount: Int; albumCount: Int }`. Add `public struct Starred: Sendable, Hashable { songs: [Song]; albums: [Album] }`. Add `case starred` to `AlbumListType` (raw value "starred").
- Modify: `NavidromeKit/SubsonicDTOs.swift`.
  - `SubsonicSong` gains `genre: String?` and `replayGain: SubsonicReplayGain?`.
  - `SubsonicBody` gains `genres: Genres?` (`{ genre: [SubsonicGenre]? }` with `value`, `songCount`, `albumCount`), `songsByGenre: TopSongs?` and `starred2: SearchResult?`.
- Modify: `NavidromeKit/NativeDTOs.swift`. `NativeSong` gains `genre: String?`, `rgTrackGain`, `rgAlbumGain`, `rgTrackPeak` and `rgAlbumPeak` (`Double?`).
- Modify: `NavidromeKit/Mapping.swift:10-27`. Map those fields.
- Modify: `NavidromeKit/NavidromeClient.swift:169-242` and `:306`. Add the calls below.
- Modify: `dev/smoke.sh`. Add PASS/FAIL lines for `getGenres`, `getAlbumList2?type=byGenre`, `getSongsByGenre` and `getStarred2`.
- Test: `Packages/MagpieKit/Tests/NavidromeKitTests/GenreAPITests.swift`
- Test: `Packages/MagpieKit/Tests/NavidromeKitTests/GenreIT.swift`

**Interfaces:**
- Produces (on `NavidromeClient`):
  - `public func genres() async throws -> [Genre]` (`getGenres`)
  - `public func albums(genre: String, size: Int, offset: Int) async throws -> [Album]` (`getAlbumList2?type=byGenre&genre=`)
  - `public func songs(genre: String, count: Int, offset: Int) async throws -> [Song]` (`getSongsByGenre`)
  - `public func starred() async throws -> Starred` (`getStarred2`)
  - `public func songsPage(start: Int, end: Int, sort: String = "id")`. The existing callers are unchanged.

- [ ] **Step 1: Write the failing tests** with `makeClient` and MockTransport stubs:

```swift
@Test func genresMapCounts() async throws {
    let (client, t) = makeClient()
    t.stub(pathSuffix: "/rest/getGenres", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","genres":{"genre":[{"value":"Indie Rock","songCount":10,"albumCount":1},{"value":"Ambient","songCount":12,"albumCount":2}]}}}"#.utf8))
    #expect(try await client.genres() == [Genre(name: "Indie Rock", songCount: 10, albumCount: 1), Genre(name: "Ambient", songCount: 12, albumCount: 2)])
}
@Test func albumsByGenreQuery() async throws {
    // stub getAlbumList2 → empty; assert query type=byGenre, genre="Indie Rock", size=12, offset=0
}
@Test func songsByGenreQuery() async throws { /* count=500 offset=0 genre=Ambient */ }
@Test func starredSplitsSongsAndAlbums() async throws { /* starred2 with 1 song, 2 albums → counts 1 and 2 */ }
@Test func replayGainAndGenreMapped() async throws {
    // getSong fixture with "genre":"Ambient","replayGain":{"trackGain":-6.5,"albumGain":-7.1,"trackPeak":0.98,"albumPeak":1.0}
    #expect(song.genre == "Ambient" && song.replayGain?.trackGain == -6.5 && song.replayGain?.albumGain == -7.1)
}
@Test func nativeReplayGainMapped() async throws { /* /api/song row with rgTrackGain -3.2 → replayGain?.trackGain == -3.2 */ }
@Test func songsPageSortsByTitle() async throws { /* songsPage(start: 0, end: 100, sort: "title") → _sort=title */ }
```

`GenreIT` is G0, gated by `DevStack.enabled` like `NavidromeIT`, and expects the fixture genres from `dev/fixtures/make-library.sh`:

```swift
@Test func fixtureGenres() async throws {
    let client = try client(); _ = try await client.connect()
    let genres = try await client.genres()
    #expect(genres.first { $0.name == "Ambient" }?.albumCount == 2)
    #expect(genres.first { $0.name == "Indie Rock" }?.albumCount == 1)
    #expect(try await client.albums(genre: "Ambient", size: 50, offset: 0).count == 2)
    #expect(try await client.songs(genre: "Ambient", count: 500, offset: 0).count == 12)
    _ = try await client.starred()
}
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `GenreAPITests`. Expected: `cannot find 'Genre'` / `genres()`.
- [ ] **Step 3: Implement the model, DTO, mapping and client changes.**
- [ ] **Step 4: Run PKG `GenreAPITests`, PKG `BrowseMappingTests` and PKG `EdgeCaseTests`.** Expected: PASS.
- [ ] **Step 5: Run the IT.** Run `dev/bootstrap.sh`, then `MAGPIE_IT=1` PKG `GenreIT`. Expected: PASS. `dev/smoke.sh` exits 0.
- [ ] **Step 6: Commit** with "Navidrome: genres, songs by genre, starred, ReplayGain and genre on songs" plus the trailer.

---

## Task 7: Player plumbing for quality changes, local files and fallback

**Files:**
- Modify: `Packages/MagpieKit/Sources/Playback/PlaybackEngine.swift:21-42`
- Modify: `Packages/MagpieKit/Sources/Playback/Player.swift`. The edits are in `init` (69-84), `seek` (130-134), `urlsInvalidated` (213-218), `.failed` handling (245-253), `syncEngine` (287-297) and `beginEntry` (306-320).
- Modify: `Packages/MagpieKit/Sources/Playback/AVQueueEngine.swift`. The edits are in `setItems` (57-79) and `enqueue` (144-154), plus a new `enqueuedItems`.
- Modify: `Tests/MagpieTests/PlayerTests.swift:9-41`. `FakeEngine` records `setVolumes` and `setVolume` calls. `FakeURLs` gets `var original: ((Song) -> URL?)?`.
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

  A second failure behaves as today.
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
    try await waitUntil { engine.enqueuedItems.count == 2 }   // 2-s items: topUp enqueues at once
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
- Modify: `App/Playback/NavidromeAdapters.swift:108-125`. `NavidromeStreamURLs` takes `quality: @MainActor () -> StreamQuality` and `localURL: @MainActor (String) -> URL?` (default `{ _ in nil }`, filled by Task 13).
- Modify: `App/AppModel.swift`.
  - Init gains `network: (any NetworkStatusProviding)? = nil`.
  - Add stored `@ObservationIgnored let network: any NetworkStatusProviding` and `var playbackHint: String?`.
  - Lines 201-204 pass the quality closure.
  - After `watchPlaybackErrors()` (line 214), call `watchPlaybackQuality()`.
- Modify: `App/AppModel+Preferences.swift` (`preferencesDidChange`). On a playback change, call `player.upcomingURLsChanged()`.
- Modify: `App/Screens/Settings/SettingsView.swift:28-30`. Add a NavigationLink "Playback" to `PlaybackSettingsView`.
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

**Rules:** `watchPlaybackQuality` uses `Observations`:
- On a change of `network.status`, call `player.upcomingURLsChanged()`.
- On a change of `player.lastFallbackSongId` to non-nil, set `playbackHint = transcodeHint` once per process (`@ObservationIgnored var shownTranscodeHint`).

- [ ] **Step 1: Write the failing tests.** `QualityAppTests` uses a `FakeNetwork: NetworkStatusProviding` (`@Observable`, settable `status`) and the PlaybackFlowsVerifyTests model set-up:

```swift
@Test func wifiUsesOriginalRaw() async throws {
    let (model, engine) = try await signedIn(network: .wifi)
    model.play([song("s1")], startAt: 0)
    let q = query(engine.setItemsCalls.last!.items[0].1)
    #expect(q["format"] == "raw" && q["maxBitRate"] == nil)
}
@Test func cellularUsesAAC160() async throws {
    let (model, engine) = try await signedIn(network: NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
    model.play([song("s1")], startAt: 0)
    let q = query(engine.setItemsCalls.last!.items[0].1)
    #expect(q["format"] == "aac" && q["maxBitRate"] == "160")
}
@Test func lowDataModeOnWifiUsesMobileQuality() async throws { /* isConstrained true, isCellular false → aac/160 */ }
@Test func networkChangeRebuildsUpcomingOnly() async throws {
    let (model, engine, network) = try await signedInWithNetwork(.wifi)
    model.play([song("s1"), song("s2")], startAt: 0)
    network.status = NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
    try await eventually { query(engine.setItemsCalls.last!.items[1].1)["format"] == "aac" }
    #expect(query(engine.setItemsCalls.last!.items[0].1)["format"] == "raw")
    #expect(engine.seeks.isEmpty)
}
@Test func transcodeHintShownOncePerSession() async throws {
    // cellular; play s1, s2; .failed on current → hint == AppModel.transcodeHint; dismissPlaybackHint();
    // advance to s2, .failed → playbackHint == nil
}
```

`TranscodeIT` (G0, dev stack):

```swift
@Test(arguments: [("aac", 160), ("opus", 128), ("mp3", 192)])
func transcodedStreamsAreAudio(_ format: String, _ rate: Int) async throws {
    let client = try client(); _ = try await client.connect()
    let song = try #require(try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id).songs?.first)
    let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: rate, format: format)))
    let ok = response.statusCode == 200 && data.count > 1024
    let magic: Bool = switch format {
        case "aac": data.count > 1 && data[0] == 0xFF && (data[1] & 0xF6) == 0xF0          // ADTS
        case "opus": data.starts(with: Array("OggS".utf8))
        default: data.starts(with: Array("ID3".utf8)) || (data.count > 1 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0)
    }
    if !(ok && magic) {
        withKnownIssue("dev image can't transcode \(format); Magpie falls back to Original") { Issue.record("no \(format)") }
        let (raw, r2) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: nil, format: "raw")))
        #expect(r2.statusCode == 200 && raw.count > 1024)
    }
}
```

- [ ] **Step 2: Run them and check they fail.** Run APP `QualityAppTests`. Expected: FAIL to compile (`NetworkStatusProviding`).
- [ ] **Step 3: Implement NetworkStatus, NetworkMonitor, the adapter changes, `AppModel+Playback`, the hint and the init wiring.**
- [ ] **Step 4: Build `PlaybackSettingsView`.** One `Form` with these sections:
  - "Streaming": a "Wi-Fi" picker and a "Mobile data" picker over `StreamQuality.allCases`, each labelled with `title`. Footer: "Gapless works best with Original".
  - "Volume levelling": a ReplayGain picker labelled "Off / Same song volume / Same album volume", mapped to `.off/.track/.album`.
  - "Sleep timer": a default picker over `SleepTimerOption` ("15 min" … "End of song").
- [ ] **Step 5: Run APP `QualityAppTests` and `PlaybackFlowsVerifyTests`, then `MAGPIE_IT=1` PKG `TranscodeIT`.** Expected: PASS. A format the dev image can't transcode shows as a known issue, not a failure.
- [ ] **Step 6: Commit** with "Playback: quality per network, Low Data Mode, transcode fallback hint, Playback settings" plus the trailer.

---

## Task 9: ReplayGain (attenuation only)

**Files:**
- Create: `Packages/MagpieKit/Sources/MagpieCore/ReplayGain.swift`
- Modify: `Packages/MagpieKit/Sources/Playback/AVQueueEngine.swift`. Implement `setVolumes`, and apply an `AVMutableAudioMix` in `enqueue`.
- Modify: `App/AppModel.swift:201-204`. Pass `gain: { [weak self] in self?.preferences.playback.replayGain.volume(for: $0.replayGain) ?? 1 }`. Because `Player` is built in `init` before `self` is usable, pass a `ReplayGainBox` (`OSAllocatedUnfairLock<ReplayGainMode>`) the same way `PlayCounting` is passed. Keep it in sync in `preferencesDidChange`.
- Test: `Packages/MagpieKit/Tests/MagpieCoreTests/ReplayGainTests.swift`, `Tests/MagpieTests/PlayerTests.swift` (one test)

**Interfaces:**
- Produces: `public extension ReplayGainMode { func volume(for gain: ReplayGain?) -> Float }`.
  - `.track` uses `trackGain`, falling back to `albumGain`. `.album` uses `albumGain`, falling back to `trackGain`. `.off` and no tags give `1`.
  - The dB value is clamped to −15…0, and the result is `pow(10, dB / 20)`. Peaks are ignored (attenuation only).
- AVQueueEngine:
  - In `enqueue`, if the volume for the id is below 1, load the audio tracks asynchronously (`item.asset.loadTracks(withMediaType: .audio)`). Then set `item.audioMix` to one `AVMutableAudioMixInputParameters` per track with `setVolume(v, at: .zero)`.
  - `setVolumes` stores the map and updates the current item's mix the same way.

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

PlayerTests:

```swift
@Test func gainsSentWithItems() {
    let player = Player(engine: engine, scrobbler: scrobbler, urls: urls, gain: { $0.id == "1" ? 0.5 : 1 })
    player.play([Self.song("1"), Self.song("2")], startAt: 0)
    let ids = player.queue.current!.id
    #expect(engine.volumeCalls.last?[ids] == 0.5)
}
```

Give `ReplayGain` an init with all-`nil` defaults (`ReplayGain(trackGain: -6)`).
- [ ] **Step 2: Run them and check they fail.** Run PKG `ReplayGainTests` and APP `PlayerTests`. Expected: FAIL.
- [ ] **Step 3: Implement `ReplayGain.swift`, the engine mix and the AppModel wiring.**
- [ ] **Step 4: Run PKG `ReplayGainTests`, APP `PlayerTests` and APP `AVQueueEngineTests`.** Expected: PASS.
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
- `cancel()` stops the task, restores volume 1 and clears `stopsAfterCurrent`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func fadesThenPauses() async {
    let recorder = SleepRecorder()   // actor collecting durations, returns immediately
    let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
    player.play([PlayerTests.song("1")], startAt: 0)
    let timer = SleepTimer(player: player, sleep: { await recorder.record($0) })
    timer.start(.m15)
    await timer.settled()
    #expect(await recorder.durations == [.seconds(900)] + Array(repeating: .milliseconds(500), count: 10))
    #expect(engine.volumeSetCalls == [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0, 1.0].map(Float.init))
    #expect(!player.isPlaying && timer.mode == .off)
}
@Test func endOfSongSetsStopAfterCurrent() { /* start(.endOfSong) → player.stopsAfterCurrent; cancel() → false, mode .off */ }
@Test func cancelRestoresVolume() async { /* sleep that suspends; start(.m30); cancel(); engine.volumeSetCalls.last == 1 */ }
```

Compare the floats with a tolerance helper, not exact `==`.
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
- Consumes: `StreamQuality`, `DownloadPreferences` (Task 5); `NetworkStatusProviding` (Task 8); `Song` (Task 6).
- Produces (Playback, `public`):

```swift
public enum AudioKind: String, Codable, Sendable { case download, cache }
public enum DownloadReason: Codable, Hashable, Sendable { case song, album(String), playlist(String), favourites }
public struct AudioMetadata: Codable, Hashable, Sendable { /* songId, title, artist, artistId, album, albumId, track, disc,
    duration, genre, coverArtId, suffix */ public init(_ song: Song); public var song: Song }
public struct AudioEntry: Codable, Hashable, Sendable { public var songId: String; public var quality: StreamQuality
    public var fileName: String; public var size: Int64; public var kind: AudioKind; public var reasons: Set<DownloadReason>
    public var downloadedAt: Date; public var lastPlayed: Date?; public var metadata: AudioMetadata }
public struct DownloadedPlaylist: Codable, Hashable, Sendable { public var id: String; public var name: String
    public var coverArtId: String?; public var songIds: [String]; public var savedAt: Date }
public struct AudioUsage: Sendable, Equatable { public var downloadBytes: Int64; public var cacheBytes: Int64 }
public enum AudioStoreError: Error, Equatable { case downloadsFull, invalidFile }

public actor AudioStore {
    public init(root: URL, scope: String, now: @escaping @Sendable () -> Date = { Date() })
    public nonisolated let directory: URL                       // <root>/Magpie/Audio/<scope>
    public static func fileName(songId: String, quality: StreamQuality, fileExtension: String) -> String
    public static func fileExtension(quality: StreamQuality, suffix: String?, mimeType: String?) -> String
    public func load()
    public func entry(songId: String) -> AudioEntry?           // download preferred over cache
    public func entries() -> [AudioEntry]
    public func localFiles() -> [String: URL]
    @discardableResult
    public func add(_ temporaryFile: URL, metadata: AudioMetadata, quality: StreamQuality, kind: AudioKind,
                    reason: DownloadReason?, fileExtension: String, downloadsLimit: Int64?) throws -> AudioEntry
    public func addReason(_ reason: DownloadReason, songIds: [String])  // also promotes cache → download
    @discardableResult public func removeReason(_ reason: DownloadReason) -> [String]  // removed song ids
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
struct URLSessionAudioFetcher: AudioFetching       // ephemeral config, urlCache nil, downloadTask
enum DownloadStatus: Equatable { case none, downloaded, downloading(done: Int, total: Int), waitingForWiFi, full
    var text: String; var symbol: String }
@MainActor @Observable final class DownloadManager {
    init(store: AudioStore, fetcher: any AudioFetching, network: any NetworkStatusProviding,
         preferences: @escaping @MainActor () -> DownloadPreferences,
         url: @escaping @MainActor (Song, StreamQuality) -> URL?,
         limitBytes: @escaping (DownloadPreferences) -> Int64? = { $0.downloadsLimit.bytes })
    private(set) var localFiles: [String: URL]
    func start() async                                   // load store, mirror localFiles, re-queue pending.json
    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil)
    func preDownload(_ songs: [Song], quality: StreamQuality)
    func remove(_ reason: DownloadReason) async
    func status(for songIds: [String]) -> DownloadStatus
    func retryWaiting()                                  // network or setting changed
    func cancelAll()                                     // sign-out
    var onLocalFilesChanged: (@MainActor () -> Void)?
    func settled() async                                 // tests
}
```

**Rules:**
- **File naming.** `fileName` is the lowercase hex SHA-256 of `songId + "|" + quality.rawValue`, then `"." + fileExtension`.
- **Extensions.** `fileExtension` works like this:
  - Transcoded presets give "aac", "ogg" (Opus) or "mp3".
  - Original uses the suffix if it is in `["mp3","flac","m4a","mp4","aac","ogg","opus","wav","aif","aiff","alac"]`.
  - Otherwise the MIME type maps: `audio/mpeg` → mp3, `audio/flac` → flac, `audio/mp4` → m4a, `audio/aac` → aac, `audio/ogg` → ogg.
  - Otherwise it's "mp3".
- **Storage.** Each audio file has a sidecar `<fileName>.json` (its `AudioEntry`) and an `index.json` (all entries and playlists, written with `AtomicFile`). Playlists also get a sidecar `playlists/<sha256(id)>.json`. Covers live at `covers/<sha256(coverArtId)>.jpg`.
- **Loading.** `load()` reads the index. If it is unreadable, it rebuilds from the sidecars, deletes audio files without a sidecar and sidecars without audio, then rewrites the index. It never throws.
- **Adding.** `add` moves the file in:
  - It sets `isExcludedFromBackup` on the file and the directory.
  - On iOS it sets `FileProtectionType.completeUntilFirstUserAuthentication`.
  - It throws `downloadsFull` when `kind == .download` and `downloadBytes + size > downloadsLimit`. Nothing is evicted. The temporary file is deleted.
- **Eviction.** `evictCache` removes cache entries, oldest `lastPlayed ?? downloadedAt` first, skipping `protecting`, until `cacheBytes <= limit`.
- **Removing reasons.** `removeReason` drops the reason from every entry and deletes entries left with no reasons.
- **Manager concurrency.** At most `concurrent` fetches run at once.
- **Mobile data.** On mobile data (`status.isCellular`) without `overMobileData`, manual jobs (reason not nil) wait with `waitingForWiFi`. Pre-downloads never wait.
- **Network flips.** When a manual job is in flight and the network flips to mobile data without permission, cancel that fetch, delete its temporary file and put the job back to waiting.
- **Pending jobs.** They persist in `<store.directory>/pending.json` as `[{metadata, reason, quality, playlistId}]`. Never URLs. URLs are built at fetch time through `url(song, quality)`.
- **When full.** On `downloadsFull`, stop every queued manual job. The status reads `.full` until `remove`/`retryWaiting`.

- [ ] **Step 1: Write the failing package tests (`AudioStoreTests`)**

```swift
@Test func fileNameIsHashNotServerString() {
    let name = AudioStore.fileName(songId: "../../etc/passwd", quality: .original, fileExtension: "mp3")
    #expect(name.wholeMatch(of: /[0-9a-f]{64}\.mp3/) != nil)
}
@Test func fileExtensionAllowlist() {
    #expect(AudioStore.fileExtension(quality: .original, suffix: "flac", mimeType: nil) == "flac")
    #expect(AudioStore.fileExtension(quality: .original, suffix: "../x", mimeType: "audio/mpeg") == "mp3")
    #expect(AudioStore.fileExtension(quality: .original, suffix: nil, mimeType: "text/html") == "mp3")
    #expect(AudioStore.fileExtension(quality: .aac160, suffix: "flac", mimeType: nil) == "aac")
    #expect(AudioStore.fileExtension(quality: .opus128, suffix: nil, mimeType: nil) == "ogg")
}
@Test func addMovesFileAndExcludesFromBackup() async throws {
    let store = AudioStore(root: tmp, scope: "abc"); await store.load()
    let e = try await store.add(tempFile(bytes: 1000), metadata: meta("s1"), quality: .original, kind: .download,
                                reason: .song, fileExtension: "mp3", downloadsLimit: nil)
    #expect(e.size == 1000)
    let url = store.directory.appending(path: e.fileName)
    #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}
@Test func downloadsLimitRefusesWithoutEvicting() async throws { /* limit 1500, existing 1000 → add 1000 throws .downloadsFull; s1 still there; usage().downloadBytes == 1000 */ }
@Test func cacheEvictsLeastRecentlyPlayedFirst() async throws { /* 3 × 400-byte cache entries, markPlayed in order s1,s2,s3 with advancing now → evictCache(limit: 800, protecting: []) == ["s1"]; usage().cacheBytes == 800 */ }
@Test func evictionSkipsProtectedAndDownloads() async throws { /* protecting ["s1"] → evicts s2 instead; downloads untouched */ }
@Test func corruptIndexRebuildsFromSidecars() async throws { /* write "garbage" to index.json, drop an orphan .mp3 → new store.load(): entry("s1") != nil; orphan deleted */ }
@Test func reasonsRemoveDownloadOnlyWhenEmpty() async throws { /* .album("a1") + addReason(.playlist("p1")) → removeReason(.album("a1")) == []; removeReason(.playlist("p1")) == ["s1"]; file gone */ }
@Test func promoteCacheToDownload() async throws { /* cache s1 → addReason(.song, ["s1"]) → kind == .download; evictCache(limit: 0) == [] */ }
@Test func eraseScopeRemovesDirectory() async throws { /* eraseScope → directory doesn't exist */ }
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `AudioStoreTests`. Expected: `cannot find 'AudioStore'`.
- [ ] **Step 3: Implement `AudioEntry.swift` and `AudioStore.swift`.**
- [ ] **Step 4: Run PKG `AudioStoreTests`.** Expected: PASS.
- [ ] **Step 5: Write the failing app tests (`DownloadManagerTests`)**, with a `FakeFetcher` (records URLs, can gate each fetch on a continuation, writes N-byte temp files) and a `FakeNetwork`:

```swift
@Test func albumDownloadStatusCounts() async {
    // gate after first fetch → status(for: ["s1","s2","s3"]) == .downloading(done: 1, total: 3); text == "Downloading 1 of 3"
    // release → .downloaded; text == "Downloaded"; symbol == "arrow.down.circle.fill"
}
@Test func manualWaitsForWiFiOnMobileData() async {
    // cellular, overMobileData false → .waitingForWiFi, text "Waiting for Wi-Fi", fetcher.urls.isEmpty
    // network = .wifi; retryWaiting() → .downloaded
}
@Test func preDownloadRunsOnMobileData() async { /* cellular → preDownload([s1], .aac160) fetches once; entry kind .cache */ }
@Test func concurrencyRespectsSetting() async { /* concurrent 2, 4 songs → fetcher.maxInFlight == 2 */ }
@Test func downloadsUseDownloadQuality() async { /* quality .mp3_320 → fetched URL has format=mp3, maxBitRate=320 */ }
@Test func pendingSurvivesRelaunchWithoutURLs() async {
    // waiting jobs → pending.json exists; its text doesn't contain "rest/stream", "t=", "s=" or "u="; a new manager over the same store re-queues them (status .waitingForWiFi)
}
@Test func networkFlipMidDownloadWaitsAndLeavesNoPartialFile() async {   // Review Focus 2
    // wifi, gate s1 mid-fetch; flip to cellular → status .waitingForWiFi; store.entries().isEmpty; no *.tmp in directory
    // flip back to wifi → .downloaded
}
@Test func fullMidAlbumKeepsWhatArrived() async {                        // Review Focus 4
    // limitBytes { _ in 1500 }, 1000-byte files, album of 3 → s1 stored; status == .full; text "Downloads are full";
    // store has exactly ["s1"]; no cache entry evicted
}
```

`AudioStoreAppTests`, on iOS:

```swift
@Test func fileProtectionLetsTheCarPlayWhileLocked() async throws {
    // add a file → url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection == .completeUntilFirstUserAuthentication
}
```

- [ ] **Step 6: Run them and check they fail.** Run APP `DownloadManagerTests` and `AudioStoreAppTests`. Expected: FAIL to compile.
- [ ] **Step 7: Implement `AudioFetcher.swift`, `DownloadStatus.swift` and `DownloadManager.swift`.** The status texts and symbols:
  - `.downloaded`: "Downloaded", `arrow.down.circle.fill`
  - `.downloading`: "Downloading \(done) of \(total)", `arrow.down.circle`
  - `.waitingForWiFi`: "Waiting for Wi-Fi", `wifi`
  - `.full`: "Downloads are full", `exclamationmark.circle`
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
- Modify: `App/Screens/Album/AlbumView.swift:90-108`. Below `PlayShuffleButtons`, add `DownloadButton(reason: .album(album.id), songs: songs)`.
- Modify: `App/Screens/Playlist/PlaylistView.swift`. Add `DownloadButton(reason: .playlist(id), songs:, playlist:)`. On `load()` success with a connection, call `model.refreshDownloadedPlaylist(playlist, songs:)`.
- Modify: the song context menus in `AlbumView.swift` (`TrackList`), `PlaylistView.swift` and `SearchView.swift:263`. Add "Download" or "Remove download".
- Modify: `App/Screens/Settings/SettingsView.swift`. Add a NavigationLink "Downloads & Storage" to `DownloadsSettingsView`.
- Modify: `App/AppModel+Preferences.swift`. When downloads preferences change, call `downloads?.retryWaiting()`. When `keepFavourites` toggles, call `setKeepFavourites(_:)`.
- Test: `Tests/MagpieTests/DownloadsAppTests.swift`

**Interfaces:**
- Consumes: `DownloadManager`, `AudioStore`, `DownloadReason`, `DownloadedPlaylist` (Task 11); `NavidromeClient.starred()` (Task 6).
- Produces:

```swift
extension AppModel {
    func startDownloads()                                  // AudioStore(root: dataDirectory, scope: navidromeScope!)
    func stopDownloads(erase: Bool)
    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil)
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
- **`stopDownloads(erase: true)`** calls `downloads?.cancelAll()`, then `store.eraseScope()`, then `downloads = nil`. Each manager captures the scope it was built for, and a completion arriving after `cancelAll()` deletes its temporary file and writes nothing.
- **Playlist refresh** diffs `songIds`: new songs are downloaded with `.playlist(id)`, and removed songs lose that reason.
- **Re-download** re-fetches every download entry whose quality ≠ `preferences.downloads.quality`, and deletes the old file only after the new one is stored.
- **`DownloadButton`** shows:
  - `arrow.down.circle` "Download" when nothing is downloaded.
  - Otherwise `StatusLine`-style text plus symbol from `DownloadStatus` (D3), with a "Remove download" action.

  It is a 44 pt target with VoiceOver label "Download" and value equal to the status text.
- **`DownloadsSettingsView`** (rows in spec §6 order):
  - Pickers and toggles for every `DownloadPreferences` field, including a "Download quality" picker and "Keep favourites downloaded".
  - The storage used ("Downloads 1.2 GB · Cache 340 MB", `ByteCountFormatter`).
  - "Re-download at new quality".
  - "Remove all downloads" and "Clear cache", each behind a `confirmationDialog`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func signOutRemovesScopeAudio() async throws {
    let model = try await signedInModel(fetcher: FakeFetcher())
    model.download([song("s1")], reason: .song); await model.downloads!.settled()
    let dir = try #require(await model.downloads?.storeDirectory)
    model.signOut()
    try await eventually { !FileManager.default.fileExists(atPath: dir.path) }
}
@Test func lateCompletionAfterSignOutIsDiscarded() async throws {           // Review Focus 1
    // gated fetcher; download s1; signOut(); sign in as another user; release the gate
    // → old scope dir absent; new scope store has no entry "s1"; new model.downloads!.localFiles.isEmpty
}
@Test func playlistRefreshOnOpen() async throws {
    // downloaded playlist p1 [s1, s2]; refreshDownloadedPlaylist(p1, songs: [s2, s3])
    // → localFiles keys == ["s2", "s3"]; s1 removed
}
@Test func favouritesToggle() async throws {
    // stub getStarred2 with songs [s7, s8]; setKeepFavourites(true) → s7, s8 downloaded with .favourites
    // setKeepFavourites(false) → both removed
}
@Test func reDownloadAtNewQuality() async throws {
    // s1 at .original; preferences.downloads.quality = .mp3_320; redownloadAtCurrentQuality()
    // → entry(s1).quality == .mp3_320; one file for s1 in the directory
}
```

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
  - `extension AppModel { func watchQueueForPreDownload() }`

**Rules:** `watchQueueForPreDownload` uses `Observations` over `(current id, upcoming ids)`. On each change:
1. Call `downloads.preDownload(PreDownloadPlan.songs(...), quality: currentStreamQuality)`.
2. Call `store.markPlayed(current)`.
3. If `!keepRecentlyPlayed`, call `store.removeCache(songIds: [the previous current id])`.
4. Call `store.evictCache(limit: cacheLimit.bytes, protecting: [current] + next preDownload ids)`.

Finds are pre-downloaded like any song. Scrobbling doesn't depend on the source.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func planSkipsLocalAndDuplicates() {
    let up = ["a", "b", "c", "a", "d", "e"].map(song)
    #expect(PreDownloadPlan.songs(upcoming: up, count: 3, isLocal: { $0 == "b" }).map(\.id) == ["a", "c", "d"])
    #expect(PreDownloadPlan.songs(upcoming: up, count: 0, isLocal: { _ in false }).isEmpty)
}
```

LocalPlaybackTests (app):

```swift
@Test func localFileUsedWhenPresent() async throws { /* s2 downloaded → play [s1, s2] → items[1].1.isFileURL */ }
@Test func completedPreDownloadSwapsOnlyUpcoming() async throws {
    // play [s1, s2] streamed; pre-download of s2 completes → last setItems: items[0] same stream URL; items[1].isFileURL; no seeks
}
@Test func preDownloadsAheadByN() async throws { /* preDownload 2, play [s1..s5] → fetcher saw s2 and s3 only, at currentStreamQuality */ }
@Test func cacheRemovedAfterPlayWhenKeepOff() async throws { /* keepRecentlyPlayed false; s2 cached; advance past s2 → entry(s2) == nil */ }
@Test func currentNeverEvicted() async throws { /* cacheLimit tiny via store: current s1 cached → stays after eviction */ }
```

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
- Modify: `App/Screens/Home/HomeView.swift:21-40`. When `model.isOffline`, show only the Downloaded shelf (`OfflineCatalog.albums()` plus playlists), with "You're offline" (`wifi.slash`) as the subtitle.
- Modify: `App/Screens/Library/LibraryView.swift:17-29`. When offline, show only the Downloads row and hide the Recently added grid.
- Modify: `App/Screens/Shared/ScreenKit.swift:8-40`. Add `Route.downloads`.
- Modify: `App/Screens/Search/SearchView.swift`. When offline, the `SearchModel` source is `OfflineSearch`, with sections "Downloads" and "Recently played on this phone".
- Modify: `App/Screens/Activity/ActivityView.swift`, `App/Screens/Try/TrySheet.swift` and `App/Screens/Settings/SettingsView.swift` (Lidarr section). When offline, disable the actions and show "You're offline".
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

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct OfflineCatalogTests {
    @Test func albumsGroupedAndSorted() { /* entries for two albums (b-album 2 songs, A-album 1) → albums().map(\.name) == ["A-album","b-album"]; album("b").songs?.map(\.track) == [1, 2] */ }
    @Test func searchFoldsCaseAndDiacritics() { /* "cafe" matches album "Café de la Mémoire" songs; "MEMOIRE" too */ }
    @Test func genresCountedFromSnapshot() { /* 3 songs Ambient over 2 albums → Genre(name:"Ambient", songCount:3, albumCount:2) */ }
    @Test func recentlyPlayedOnlyCacheWithPlays() { /* cache s9 played → recentlyPlayed(matching: "") == [s9]; downloads not listed */ }
}
```

OfflineAppTests:

```swift
@Test func automaticOfflineWhenUnreachable() async throws {
    // signed in; make /rest/ping and /rest/getAlbumList2 fail with .cannotConnectToHost; a request throws → isOffline
    // ping answers again; await checkReachability() → !isOffline
}
@Test func forcedOnAndOff() async throws { /* offlineMode .on → isOffline while reachable; .off → !isOffline while unreachable */ }
@Test func offlineSkipsToNextLocalSong() async throws {               // Review Focus 3
    // play [s1 local, s2 streamed, s3 local]; go offline → engine items == [s1, s3]; queue still 3 entries
    // back online → items == [s1, s2, s3]
}
@Test func lidarrActionsDisabledOffline() async throws { /* isOffline → model.tryAvailability.message == "You're offline" */ }
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
  - `init` gains `scrobbleRule: @escaping () -> ScrobbleRule = { .default }`.
  - Update `seek` (lines 130-134), `urlsInvalidated`, `.time` (lines 238-242), `maybeSubmitScrobble` (lines 322-330) and `scrobble` (lines 332-346).
- Modify: `App/Playback/NavidromeAdapters.swift:96-106`. `NavidromeScrobbler.scrobble(_ song:…)` uses `song.id`.
- Modify: `App/AppModel.swift:201-204`. Pass `scrobbleRule` from a `ScrobbleSettings` box (lock-protected `ScrobblePreferences`, defined in Task 17's file; create it here in `App/Playback/ScrobbleSettings.swift`). `preferencesDidChange` updates it.
- Modify: `Tests/MagpieTests/PlayerTests.swift:27-33` (`FakeScrobbler` takes a `Song` and records `songId`) and `Tests/MagpieTests/TryAndSettingsTests.swift:215-219`.
- Test: `Tests/MagpieTests/PlayerTests.swift`

**Interfaces:**
- Consumes: `ScrobbleRule` (Task 5).
- Produces:
  - `Scrobbler.scrobble(_:submission:at:)`
  - `Player.init(…, scrobbleRule:)`
  - `final class ScrobbleSettings: Sendable { init(_ p: ScrobblePreferences); var value: ScrobblePreferences { get }; func set(_ p: ScrobblePreferences) }`

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
@Test func shortSongNeverCounted() async { /* duration 25; ticks to 25 → only the now-playing call */ }
@Test func engineDurationIgnored() async { /* song.duration 200, engine says 1000 → submits at listened 100 */ }
@Test func unknownDurationUsesMinutes() async { /* song.duration 0 → no submit at 239, submit at 240 */ }
```

- [ ] **Step 2: Run them and check they fail.** Run APP `PlayerTests`. Expected: FAIL.
- [ ] **Step 3: Implement the protocol change, the algorithm, `ScrobbleSettings` and the call-site updates.**
- [ ] **Step 4: Run APP `PlayerTests`, `PlaybackFlowsVerifyTests` and `TryAndSettingsTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Scrobbling: threshold by listened time, percentage or minutes" plus the trailer.

---

## Task 16: ListenBrainz submit-listens

**Files:**
- Create: `Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient+Submit.swift`
- Modify: `Packages/MagpieKit/Sources/ListenBrainzKit/ListenBrainzClient.swift`. Make `sendWithDeadline`, `token`, `apiTimeout` and `limiter` `internal` (they are private now), so the extension file can use them.
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
    public static let clientVersion: String          // "0.0.1"
    public func submitListens(_ listens: [Listen], type: ListenType) async throws
}
```

**Rules:**
- POST `https://api.listenbrainz.org/1/submit-listens` with `Authorization: Token <token>` and `Content-Type: application/json`, within `apiTimeout`, spaced by `limiter`.
- No token: throw `.unauthorized` and send nothing.
- `.importBatch` sends at most 100 listens per call; split larger arrays.
- `.playingNow` omits `listened_at`.
- The body (keys exactly):

```json
{"listen_type":"single","payload":[{"listened_at":1700000000,"track_metadata":{"artist_name":"A","track_name":"T","release_name":"B","additional_info":{"duration_ms":200000,"recording_mbid":"…","submission_client":"Magpie","submission_client_version":"0.0.1","media_player":"Magpie"}}}]}
```

The line setting `httpMethod = "POST"` carries the comment `// G1 allowlist: listenbrainz submit-listens` within the 3 lines above it.

- [ ] **Step 1: Write the failing tests** (MockTransport):

```swift
@Test func singleListenBody() async throws {
    let t = MockTransport(); t.stub(method: "POST", pathSuffix: "/1/submit-listens", body: Data(#"{"status":"ok"}"#.utf8))
    let client = ListenBrainzClient(transport: t, token: "tok")
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
    #expect(info["submission_client"] as? String == "Magpie" && info["submission_client_version"] as? String == "0.0.1")
}
@Test func playingNowHasNoTimestamp() async throws { /* type .playingNow → payload[0]["listened_at"] == nil; listen_type "playing_now" */ }
@Test func noTokenSendsNothing() async { /* token nil → throws .unauthorized; t.requests.isEmpty */ }
@Test func importSplitsAt100() async throws { /* 150 listens → 2 requests with 100 and 50 payload items */ }
@Test func unauthorizedMaps() async { /* 401 → .unauthorized */ }
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
- Modify: `App/Screens/Settings/SettingsView.swift:226-231`. Remove the lone Count plays section and add a NavigationLink "Scrobbling" to `ScrobblingSettingsView`.
- Delete: `NavidromeScrobbler` from `NavidromeAdapters.swift`, and move its test (`TryAndSettingsTests.swift:210-220`) to the router.
- Test: `Packages/MagpieKit/Tests/PlaybackTests/ScrobbleQueueTests.swift`, `Tests/MagpieTests/ScrobbleRouterTests.swift`

**Interfaces:**
- Consumes: `Scrobbler` (Task 15); `ListenBrainzClient.submitListens`, `Listen` (Task 16); `FindsIdentity`, `PlayCounting` (existing); `ScrobbleSettings` (Task 15); `isOffline` (Task 14).
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
extension AppModel { func drainScrobblesSoon() }
```

**Rules:**
- **Gates.** `scrobble` returns at once when `!counting.isOn` or `findsIdentity.isFind(song)` (D29, both paths).
- **Now playing** (`submission == false`) goes to each enabled destination as best-effort and is never queued.
- **A submission** goes to each enabled destination: Navidrome through `box.client?.scrobble(songId:submission:true, at:)`, ListenBrainz through `.single` with `listenedAt = at`. If offline, or on any thrown error, it is enqueued for that destination.
- **The ListenBrainz destination** is enabled only when `settings.value.viaListenBrainz` and `listenBrainz()` is non-nil. The closure reads the Keychain token at call time.
- **Drain.** `drain()`, per destination, oldest first:
  - Drop and remove entries whose song `isFind` (D29 on dequeue).
  - Navidrome sends each entry with its `listenedAt`. ListenBrainz sends one `.importBatch`.
  - On the first error, stop that destination and keep its rest.
- **The queue file** holds metadata only (`AudioMetadata`). It is written with `AtomicFile` and excluded from backup.

- [ ] **Step 1: Write the failing package tests**

```swift
@Test func boundedPerDestination() async {
    let q = ScrobbleQueue(fileURL: nil)
    for i in 0..<501 { await q.enqueue(item("s\(i)", .navidrome)) }
    await q.enqueue(item("lb", .listenBrainz))
    let nd = await q.pending(.navidrome)
    #expect(nd.count == 500 && nd.first?.song.songId == "s1")
    #expect(await q.pending(.listenBrainz).count == 1)
}
@Test func persistsAndHasNoCredentials() async throws { /* file round-trips; its text contains no "token", "t=", "s=" or "password" */ }
@Test func corruptFileStartsEmpty() async { /* garbage file → pending(.navidrome).isEmpty; no crash */ }
```

- [ ] **Step 2: Run them and check they fail.** Run PKG `ScrobbleQueueTests`. Expected: FAIL.
- [ ] **Step 3: Implement `ScrobbleQueue`.** Run PKG `ScrobbleQueueTests`. Expected: PASS.
- [ ] **Step 4: Write the failing app tests** (HostSwitchTransport stubs for `/rest/scrobble` and `api.listenbrainz.org/1/submit-listens`, `MemoryTokenStore` with "tok-secret"):

```swift
@Test func bothDestinationsGetSubmission() async throws {
    // viaListenBrainz on; router.scrobble(song, submission: true, at: t0)
    // → one /rest/scrobble with submission=true and time=String(Int64(t0*1000)); one POST submit-listens with listen_type "single"
}
@Test func findNeverSentEitherPath() async throws {      // D29
    // findsIdentity.markLanded("s1"); now playing + submission → no /rest/scrobble, no submit-listens; queue empty on both
}
@Test func failedSendIsQueuedAndRetried() async throws {
    // LB answers 500 → pending(.listenBrainz).count == 1; LB answers 200; drain() → submit-listens listen_type "import", listened_at == t0; queue empty
}
@Test func navidromeQueuedOfflineCarriesOriginalTime() async throws { /* isOffline true → nothing sent, queued; online + drain → time == t0 ms */ }
@Test func findDroppedOnDequeue() async throws { /* queued s1; then markLanded("s1"); drain → nothing sent; queue empty */ }
@Test func unauthorizedStopsListenBrainzDrainAndKeepsQueue() async throws {   // Review Focus 5
    // 3 LB entries queued, LB answers 401 → exactly one submit-listens request; pending(.listenBrainz).count == 3
    // Navidrome queue drains normally in the same call
}
@Test func countPlaysOffSendsNothing() async throws { }
@Test func nowPlayingNeverQueued() async throws { /* LB 500 on playing_now → queue empty */ }
@Test func signOutClearsQueue() async throws { }
@Test func queueFileLacksToken() async throws { /* after a queued LB play, scrobble-queue.json text doesn't contain "tok-secret" */ }
```

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
                                 Genre(name: "Empty", songCount: 0, albumCount: 0)], preferences: .default)
    #expect(s.map(\.group.id) == ["rock", "electronic"])
    #expect(s[0].genres.map(\.name) == ["Alt Rock", "Indie Rock"] && s[0].albumCount == 3 && s[0].songCount == 30)
}

@Test func overridesRenameHideAndCustom() {
    var p = GenrePreferences.default
    p.assignments[GenreGroups.key("Ambient")] = "rock"
    p.groupNames["rock"] = "Guitars"
    p.customGroups = ["custom.dinner"]; p.groupNames["custom.dinner"] = "Dinner"
    p.assignments[GenreGroups.key("Chanson")] = "custom.dinner"
    let s = GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1), Genre(name: "Chanson", songCount: 1, albumCount: 1)], preferences: p)
    #expect(s.map(\.group.name) == ["Guitars", "Dinner"])
    p.hidden = ["rock"]
    #expect(GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1)], preferences: p).isEmpty)
}

@Test func multiValueCountsInBothGroups() { /* "Rock; Electronic" → appears under rock and electronic */ }
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
    func groupSongs(_ groupId: String) async throws -> [Song]            // ≤ 500, shuffled
    func genreSongs(_ name: String) async throws -> [Song]               // ≤ 500
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
- `GenreView` has a menu with "Move to group…", which opens `MoveGenreSheet`. The sheet lists the visible groups plus "New group…" (text field).

- [ ] **Step 1: Write the failing tests** (stubs for `getGenres`, `getAlbumList2?type=byGenre` by genre query value, `getSongsByGenre`):

```swift
@Test func groupAlbumsMergedAndDeduped() async throws {
    // Indie Rock → [a1, a2], Alt Rock → [a2, a3]
    #expect(try await model.groupAlbums("rock").map(\.id) == ["a1", "a2", "a3"])
}
@Test func groupSongsCappedAt500() async throws { /* two rock genres × 300 songs → count == 500 */ }
@Test func moveGenreSurvivesRelaunch() async throws {
    model.moveGenre("Ambient", toGroup: "rock")
    let again = makeModel()   // same defaults
    #expect(try await again.genreSections().first { $0.group.id == "rock" }?.genres.map(\.name).contains("Ambient") == true)
}
@Test func newGroupNamed() async throws { /* createGroup(named: "Dinner"); moveGenre("Chanson", to: id) → a section named "Dinner" */ }
@Test func hiddenGroupLeavesAllGenresIntact() async throws { /* hide "rock" → sections lack rock; allGenres() still lists Indie Rock */ }
```

- [ ] **Step 2: Run them and check they fail.** Run APP `GenresAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement `AppModel+Genres`, the routes and the four views.** Play/Shuffle reuse `PlayShuffleButtons`.
- [ ] **Step 4: Run APP `GenresAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Genres: grouped and A–Z views, group and genre pages, Move to group" plus the trailer.

---

## Task 20: Home layout

**Files:**
- Create: `App/AppModel+Home.swift`
- Create: `App/Screens/Settings/HomeLayoutView.swift`
- Modify: `App/Screens/Home/HomeView.swift:14-104`. Replace the fixed `Shelves` with `[HomeShelf]` from `model.homeShelves(for:)`, in `visibleHomeSections` order. `madeForYouShelf` stays where `.madeForYou` sits. Shelf tiles route by kind.
- Modify: `App/Screens/Settings/SettingsView.swift`. Add a Section "Home & Library" with NavigationLinks "Home" (to `HomeLayoutView`) and "Library" (to `LibraryLayoutView`, Task 21).
- Test: `Tests/MagpieTests/HomeLayoutAppTests.swift`

**Interfaces:**
- Consumes: `LayoutPreferences.visibleHomeSections` (Task 5); `AlbumListType.starred`, `playlists()` (Task 6); `genreSections()` (Task 19); `offlineCatalog` (Task 14).
- Produces:

```swift
struct HomeShelf: Identifiable, Equatable {
    enum Item: Equatable { case album(Album), playlist(Playlist), genreGroup(GenreGroupSection), downloadedAlbum(Album) }
    var section: HomeSection; var items: [Item]; var id: HomeSection { section }
}
extension AppModel {
    static let homeShelfSize = 12
    var homeSections: [HomeSection] { get }       // visibleHomeSections(offline: isOffline, hasListenBrainzToken:, carPlay: false)
    func homeShelves(for sections: [HomeSection]) async throws -> [HomeShelf]   // .madeForYou excluded (own shelf); empties dropped
}
```

**Rules:** One concurrent fetch per section, each mapped to its source:

| Section | Source |
|---|---|
| jumpBackIn | `.recent` |
| recentlyAdded | `.newest` |
| mostPlayed | `.frequent` |
| favourites | `.starred` |
| randomAlbums | `.random` |
| playlists | `playlists().prefix(12)` |
| genres | `genreSections()` sorted by `albumCount` descending, prefix 12 |
| downloaded | `offlineCatalog.albums().prefix(12)` |

The fetch throws only when every server section fails. `HomeLayoutView`:
- A `List` in edit mode with `.onMove` and a Toggle per row.
- Each row has VoiceOver actions "Move up" and "Move down" (D15).
- "Made for you" shows the footer "Shows when a ListenBrainz token is saved".
- A "Reset to default order" button.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func onlyRequestedSectionsAreFetched() async throws {
    let shelves = try await model.homeShelves(for: [.favourites, .jumpBackIn])
    let types = transport.inner.requests.compactMap { queryValue($0, "type") }
    #expect(Set(types) == ["starred", "recent"])
    #expect(shelves.map(\.section) == [.favourites, .jumpBackIn])
}
@Test func emptySectionsSkipped() async throws { /* starred returns [] → [.jumpBackIn] */ }
@Test func homeSectionsFollowPreferences() async throws {
    model.updatePreferences { $0.layout.moveHome(fromOffsets: IndexSet(integer: 3), toOffset: 0); $0.layout.setHome(.randomAlbums, visible: true) }
    #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded, .randomAlbums])
}
@Test func offlineHomeIsDownloadedOnly() async throws { /* offlineMode .on → homeSections == [.downloaded] */ }
```

- [ ] **Step 2: Run them and check they fail.** Run APP `HomeLayoutAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement `AppModel+Home`, the HomeView change and `HomeLayoutView`.** "Finish setting up" stays pinned above the shelves.
- [ ] **Step 4: Run APP `HomeLayoutAppTests` and `MadeForYouAppTests`.** Expected: PASS.
- [ ] **Step 5: Commit** with "Home: reorderable and hideable shelves, Favourites/Random/Playlists/Genres/Downloaded" plus the trailer.

---

## Task 21: Library rows, Songs and Favourites

**Files:**
- Create: `App/Screens/Library/SongsListView.swift`
- Create: `App/Screens/Library/FavouritesView.swift`
- Create: `App/Screens/Settings/LibraryLayoutView.swift`
- Modify: `App/Screens/Library/LibraryView.swift:17-39`. Rows come from `model.libraryRows`, mapped to routes, titles and symbols. The Recently added grid shows only if `preferences.layout.showsRecentlyAdded`.
- Modify: `App/Screens/Shared/ScreenKit.swift`. Add `Route.songs` and `.favourites`.
- Modify: `App/AppModel+Home.swift`. Add `libraryRows` and `favourites()`.
- Test: `Tests/MagpieTests/LibraryLayoutAppTests.swift`

**Interfaces:**
- Consumes: `visibleLibraryRows`, `setLibrary(_:visible:)` (Task 5); `songsPage(start:end:sort:)`, `starred()` (Task 6).
- Produces:

```swift
extension AppModel {
    var libraryRows: [LibraryRow] { get }   // visibleLibraryRows(offline:, findsSetUp: findsSetup?.library != nil, lidarrConnected: lidarr != nil, carPlay: false)
    static let songsPageSize = 100
    func songsPage(_ page: Int) async throws -> [Song]   // songsPage(start: page*100, end: (page+1)*100, sort: "title")
    func favourites() async throws -> Starred
}
```

**Rules:**
- `LibraryLayoutView` works like `HomeLayoutView`, plus a "Recently added" toggle. The toggle of the last visible always-available row is disabled, with the footer "At least one row stays visible."
- `SongsListView` pages on appearing at the end. `FavouritesView` has a Songs section (rows playable from that list) and an Albums grid.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func songsListPagesByTitle() async throws {
    _ = try await model.songsPage(0); _ = try await model.songsPage(1)
    let pages = transport.inner.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.suffix(2)
    #expect(pages.map { queryValue($0, "_sort") } == ["title", "title"])
    #expect(pages.map { queryValue($0, "_start") } == ["0", "100"])
}
@Test func libraryRowsFollowPreferences() async throws {
    model.updatePreferences { _ = $0.layout.setLibrary(.songs, visible: false); $0.layout.moveLibrary(fromOffsets: IndexSet(integer: 4), toOffset: 0) }
    #expect(model.libraryRows.first == .genres && !model.libraryRows.contains(.songs))
    #expect(!model.libraryRows.contains(.requests), "no Lidarr connected")
}
@Test func favouritesReadStarred() async throws { /* getStarred2 stub 2 songs 1 album → counts */ }
```

- [ ] **Step 2: Run them and check they fail.** Run APP `LibraryLayoutAppTests`. Expected: FAIL.
- [ ] **Step 3: Implement the views, routes and model additions.**
- [ ] **Step 4: Run APP `LibraryLayoutAppTests`, then `MAGPIE_IT=1 scripts/test-app.sh`.** Expected: PASS. `BrowseFlowTests` still finds `library-albums` and the other identifiers; `row(_:)` keeps the identifier `library-<title lowercased>`.
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
@MainActor @Test func adapterDropsMadeForYouAndFollowsPrefs() async throws {
    // model with token; updatePreferences move mostPlayed first → CarPlayLibraryAdapter(model:).homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded]
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
  - `play(_:)` (lines 291-321): `default: playCustom(request)`.
- Modify: `App/CarPlay/CarPlayLibraryAdapter+Customisation.swift`. Implement the members below.
- Test: `Tests/MagpieTests/CarPlayCustomisationTests.swift` (more tests)

**Interfaces:**
- Consumes: `genreSections()`, `groupSongs`, `genreSongs` (Task 19); `offlineCatalog`, `isOffline` (Task 14); `SleepTimer` (Task 10); `favourites()` (Task 21).
- Produces:

```swift
extension CarPlayRows {
    public static func genres(_ groups: [(id: String, name: String, albumCount: Int)]) -> [CPSectionModel]   // rows open .genreGroup
    public static func genreGroup(id: String, subgenres: [Genre]) -> [CPSectionModel]  // "Play", "Shuffle" (play .genreGroup), then subgenre rows (play .genre shuffled), never push
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
- **Sleep button.** `CPNowPlayingImageButton(image: UIImage(systemName: "moon.zzz"))`, with `isSelected = sleepTimerActive`. A tap calls `toggleSleepTimer()` and shows the message "Sleep timer on" or "Sleep timer off" with the existing `showMessage`.
- **Search in the car while offline** uses `OfflineCatalog.search` and doesn't call the network.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func genreGroupLeafRowsPlay() {
    let s = CarPlayRows.genreGroup(id: "rock", subgenres: [Genre(name: "Indie Rock", songCount: 10, albumCount: 1)])
    let rows = s.flatMap(\.rows)
    #expect(rows.map(\.title) == ["Play", "Shuffle", "Indie Rock"])
    #expect(rows[2].action == .play(.genre(name: "Indie Rock", shuffled: true)))
    #expect(rows.allSatisfy { if case .open = $0.action { false } else { true } })
}
@Test func genreDepthBudget() {
    var nav = CPNavigator()
    #expect(nav.push(.genres) && nav.push(.genreGroup(id: "rock", name: "Rock")))
    #expect(nav.depth == CPNavigator.maxBrowseDepth)
    #expect(!nav.push(.genres), "only two pushes below the tab")
}
@Test func downloadsRowsOpenDownloadedAlbum() { /* album "a1" → row action .open(.downloadedAlbum(id: "a1", title: …)) */ }
@MainActor @Test func offlineCarLibraryIsDownloadsOnly() async throws { /* offlineMode .on → adapter.libraryRows == [.downloads]; adapter.homeSections == [.downloaded] */ }
@MainActor @Test func carSleepToggleUsesDefault() async throws { /* toggleSleepTimer → model.sleepTimer.mode == .at(now + 1800); again → .off */ }
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
  6. Preferences: hostile values (huge arrays, wrong types, negative numbers) decode to clamped defaults. Add a fuzz-style test if one is missing.
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
  - D33: the CarPlay "Open Magpie on your iPhone once…" line is an instructive exception to D12.
  - D38: the Local Network prompt is triggered by an `NWBrowser` for `_http._tcp` (`NSBonjourServices`), and denial is read from `NWConnection` `unsatisfiedReason == .localNetworkDenied`.
  - D39: an interim TestFlight build 2 ships the network fix first, and the final 0.0.1 is build 3.
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
- [ ] **Step 4: Run `scripts/check-release.sh`.** Expected: `check-release: OK`. It covers version 0.0.1, the build number, arbitrary loads only, `NSBonjourServices` and the Local Network text.
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

## Task 29: Release prep

- [ ] **Step 1: Pre-flight.**
  - `git status` is clean on `v0.0.1-custom`.
  - Task 27 is green on the current HEAD (re-run `MAGPIE_IT=1 scripts/test-all.sh` if anything changed since).
  - `scripts/check-release.sh` is OK.
- [ ] **Step 2: Merge and tag.**

```bash
git checkout main
git merge --no-ff v0.0.1-custom -m "Merge v0.0.1-custom: Magpie 0.0.1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a v0.0.1 -m "Magpie 0.0.1"
```

  Expected: no conflicts, and `git describe --tags` prints `v0.0.1`.
- [ ] **Step 3: Archive the CarPlay variant first** (signs while archiving; no upload). Run `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --carplay --out build/testflight-carplay`.
  - Expected: the archive succeeds.
  - If signing fails with a provisioning error naming `com.apple.developer.carplay-audio`, record "CarPlay entitlement not on the App ID" and go to Step 4 with the default variant.
- [ ] **Step 4: Fallback archive** (only if Step 3 failed on the entitlement). Run `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --out build/testflight`. Expected: an `.ipa` exported to `build/testflight/export/`.
- [ ] **Step 5: CONTROLLER ONLY. Implementers never run this step.** Upload with the variant that archived:
  - `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --carplay --upload`, or, after the fallback, `scripts/archive.sh --team "$MAGPIE_TEAM_ID" --build 3 --upload`. Build 2 was the interim build (Task 4).
  - If App Store Connect refuses version 0.0.1 (a lower train than 1.0), stop and report it to the owner. Never pick another version on your own (§10).
  - If the fallback was used, tell the owner exactly how to request the entitlement: `docs/TESTFLIGHT.md` step 12, developer.apple.com/contact/carplay, choose Audio.
  - Pushing `main` and the tag is also the controller's call.
- [ ] **Step 6: Owner report (controller).**
  - The calls made: spec *(call)* items plus D31–D39.
  - Which variant was uploaded, and build 3.
  - The manual checks left for the owner:
    - private-IP and `.local` sign-in on the device;
    - the Local Network prompt;
    - a device CarPlay check once the entitlement exists;
    - transcoding formats on the real server;
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
   - the order of the diagnosis classifier.

   Each test sketch marked `/* … */` gives its inputs and its exact expected values.
3. **Type consistency.** Checked across tasks:
   - `LocalNetworkAccess`/`LocalNetworkState`/`LocalNetworkProbing`, `ConnectDiagnosis.classify(_:url:localNetwork:pathDenied:onDevice:)`, `CPLocalNetwork`
   - `upcomingURLsChanged()`, `isPlayable`, `stopsAfterCurrent`, `lastFallbackSongId`
   - `AudioStore`/`AudioEntry`/`DownloadReason`, `DownloadManager.localFiles`, `OfflineCatalog`
   - `ScrobbleSettings`/`ScrobbleRouter`/`ScrobbleQueue`
   - `GenreGroups.grouped`, `homeShelves(for:)`, `libraryRows`, `CPHomeShelf`, `CarPlayRows.libraryRoot(_:hasFindsTab:)`
   - `visibleHomeSections(offline:hasListenBrainzToken:carPlay:)`, `visibleLibraryRows(offline:findsSetUp:lidarrConnected:carPlay:)`
4. **Review Focus.** There are five lines, each with a test in its owning task: Tasks 3, 2, 12, 11 and 14.
5. **Proportion.** The plan is longer than the spec. The extra length is test assertions with exact values, not implementation bodies.
