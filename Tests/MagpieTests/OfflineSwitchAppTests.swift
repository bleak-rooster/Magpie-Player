import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let noNetwork = NetworkStatus(isConnected: false, isCellular: false, isConstrained: false)

/// Holds an awaiting send until released (cancellation lets it go too).
final class Hold: Sendable {
    private let state = OSAllocatedUnfairLock<(released: Bool, waiting: [CheckedContinuation<Void, Never>])>(initialState: (false, []))
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = state.withLock { s -> Bool in
                if s.released { return true }
                s.waiting.append(c)
                return false
            }
            if go { c.resume() }
        }
    }
    func release() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.released = true
            defer { s.waiting = [] }
            return s.waiting
        }
        waiting.forEach { $0.resume() }
    }
}

/// Round 28 O1 (owner, 2026-11-15): the switch and its mapping (D323), the notice (D329), relaunch (D327), coming to
/// the front (D326), the 30 s rule at launch (D324) and the transitions (D330), in all four setups.
@MainActor @Suite(.serialized) final class OfflineSwitchAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineSwitchAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "OfflineSwitchAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        transport.inner.stub(pathSuffix: "/rest/star", body: ok)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
    }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel(fetcher: any AudioFetching = FakeFetcher(), lidarrStore: MemoryLidarrStore = MemoryLidarrStore(),
                   tokenStore: MemoryTokenStore = MemoryTokenStore(nil),
                   aurralStore: MemoryAurralStore = MemoryAurralStore()) -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: tokenStore, aurralStore: aurralStore,
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: fetcher)
    }

    func signedIn(fetcher: any AudioFetching = FakeFetcher()) async throws -> (AppModel, ManualReachabilityClock) {
        let model = makeModel(fetcher: fetcher)
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        return (model, clock)
    }

    func song(_ id: String) -> Song { PlayerTests.song(id) }

    /// Unreachable from t = 0, offline at 30 s.
    func goAutomaticallyOffline(_ model: AppModel, _ clock: ManualReachabilityClock, from start: Double = 0) async {
        transport.setDown(["192.168.1.2"])
        #expect(await model.advanceReachability(clock, to: start))
        model.noteUnreachable()
        #expect(await model.advanceReachability(clock, to: start + 30))
        #expect(model.offlineState == .automatic)
    }

    /// No network path from `time`: offline 2 s later (Q1).
    func dropThePath(_ model: AppModel, _ clock: ManualReachabilityClock, at time: Double) async {
        #expect(await model.advanceReachability(clock, to: time))
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        (model.network as? FakeNetwork)?.status = noNetwork
        #expect(await eventually { !model.reachability.machine.connected })
        #expect(await model.advanceReachability(clock, to: time + 2))
        #expect(model.isOffline)
    }

    /// The path and the library are back: the check 2 s after the path answers.
    func restoreThePath(_ model: AppModel, _ clock: ManualReachabilityClock) async {
        transport.setDown([])
        (model.network as? FakeNetwork)?.status = .wifi
        #expect(await eventually { model.reachability.machine.connected })
        #expect(await model.advanceReachability(clock, to: clock.now() + 2))
        #expect(await eventually { !model.isOffline })
    }

    // MARK: - The switch (D323)

    @Test func settings_switchMapsToMode() async throws {
        let model = makeModel()
        #expect(model.preferences.downloads.offlineMode == .automatic && !model.offlineModeOn && model.goesOfflineAutomatically)
        // On, then off: back to Automatic.
        model.setOfflineMode(on: true)
        #expect(model.preferences.downloads.offlineMode == .on && model.offlineModeOn && model.goesOfflineAutomatically)
        #expect(defaults.object(forKey: AppModel.automaticChoiceKey) as? Bool == true)
        model.setOfflineMode(on: false)
        #expect(model.preferences.downloads.offlineMode == .automatic)
        // Go offline automatically off while online: Off.
        model.setGoOfflineAutomatically(false)
        #expect(model.preferences.downloads.offlineMode == .off && !model.goesOfflineAutomatically)
        // On from Off remembers "automatic off"; off goes back to Off.
        model.setOfflineMode(on: true)
        #expect(model.preferences.downloads.offlineMode == .on && !model.goesOfflineAutomatically)
        model.setOfflineMode(on: false)
        #expect(model.preferences.downloads.offlineMode == .off)
        // While on, the second switch changes only the remembered choice.
        model.setOfflineMode(on: true)
        model.setGoOfflineAutomatically(true)
        #expect(model.preferences.downloads.offlineMode == .on && model.goesOfflineAutomatically)
        #expect(defaults.object(forKey: AppModel.automaticChoiceKey) as? Bool == true)
        model.setOfflineMode(on: false)
        #expect(model.preferences.downloads.offlineMode == .automatic)
        model.setGoOfflineAutomatically(true)
        #expect(model.preferences.downloads.offlineMode == .automatic, "already on: no change")
        // The machine follows: Off never goes offline.
        model.setGoOfflineAutomatically(false)
        #expect(!model.reachability.machine.automaticEnabled)
        model.setOfflineMode(on: true)
        #expect(model.reachability.machine.state == .manualOffline && model.offlineGate.mode == .manual)
        model.setOfflineMode(on: false)
        #expect(model.reachability.machine.state == .online && model.offlineGate.mode == .open)
    }

    @Test func settings_existingOffReadsAsAutomaticOff() async throws {
        let first = makeModel()
        first.updatePreferences { $0.downloads.offlineMode = .off }
        let relaunched = makeModel()
        #expect(!relaunched.offlineModeOn && !relaunched.goesOfflineAutomatically)
        #expect(!relaunched.reachability.machine.automaticEnabled)
        // An existing `.on` with no remembered choice reads as on, with automatic on.
        relaunched.updatePreferences { $0.downloads.offlineMode = .on }
        defaults.removeObject(forKey: AppModel.automaticChoiceKey)
        let again = makeModel()
        #expect(again.offlineModeOn && again.goesOfflineAutomatically)
        again.setOfflineMode(on: false)
        #expect(again.preferences.downloads.offlineMode == .automatic)
    }

    @Test func settings_stateLines() {
        #expect(OfflineModeCopy.stateLine(.manual, automatic: true) == SettingsSummary("Only music on this phone plays", symbol: "wifi.slash"))
        #expect(OfflineModeCopy.stateLine(.automatic, automatic: true)
            == SettingsSummary("Offline for now: your library is out of reach", symbol: "wifi.exclamationmark"))
        #expect(OfflineModeCopy.stateLine(.online, automatic: true)
            == SettingsSummary("Goes offline by itself if your library is out of reach", symbol: "wifi"))
        #expect(OfflineModeCopy.stateLine(.suspect, automatic: true).text == OfflineModeCopy.automaticOn)
        #expect(OfflineModeCopy.stateLine(.online, automatic: false) == SettingsSummary("Stays online", symbol: "wifi"))
        #expect(OfflineModeCopy.automaticTitle == "Go offline automatically")
        // Fix round 1 (design L1): the footer names the no-connection case too.
        #expect(OfflineModeCopy.automaticFooter == "When your library can’t be reached for 30 seconds, or at once with no connection, Magpie plays what’s on this phone and keeps trying to reconnect. It switches back by itself.")
        // Fix round 1 (design M2, approved copy): no network path at all.
        #expect(OfflineModeCopy.stateLine(.automatic, automatic: true, noConnection: true)
            == SettingsSummary("Offline for now: no connection", symbol: "wifi.slash"))
        #expect(OfflineNotice.variant(.automatic, checking: false, noConnection: true)?.text == "No connection. Showing music on this phone.")
        // Design M3: Settings offers Try again in the automatic state only.
        #expect(OfflineModeSection.offersTryAgain(.automatic) && !OfflineModeSection.offersTryAgain(.manual)
            && !OfflineModeSection.offersTryAgain(.online) && !OfflineModeSection.offersTryAgain(.suspect))
    }

    // MARK: - The notice (D329)

    @Test func notice_manualOffersGoOnline() async throws {
        let (model, _) = try await signedIn()
        model.setOfflineMode(on: true)
        let variant = try #require(OfflineNotice.variant(model.offlineState, checking: model.reachability.checking))
        #expect(variant == .init(text: "Offline mode is on", symbol: "wifi.slash", action: .goOnline, actionTitle: "Go online",
                                 actionIdentifier: "offline-go-online"))
        model.goOnline()
        #expect(model.preferences.downloads.offlineMode == .automatic)
        // Fix round 1 (design H1): online once the check has answered, not before.
        #expect(await eventually { model.offlineState == .online && !model.isOffline })
    }

    @Test func notice_automaticOffersTryAgain() async throws {
        let (model, clock) = try await signedIn()
        await goAutomaticallyOffline(model, clock)
        let variant = try #require(OfflineNotice.variant(.automatic, checking: false))
        #expect(variant.text == "Your library is out of reach. Showing music on this phone." && variant.symbol == "wifi.exclamationmark")
        #expect(variant.action == .tryAgain && variant.actionTitle == "Try again" && variant.actionIdentifier == "offline-try-again")
        let trying = try #require(OfflineNotice.variant(.automatic, checking: true))
        #expect(trying.action == .trying && trying.actionTitle == "Trying…")
        // Try again, with the library back: a check now (not at the next scheduled one), and online.
        transport.setDown([])
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        let check = Task { await model.reconnectNow() }
        #expect(await eventually { model.reachability.checking || !model.isOffline })
        await check.value
        #expect(!model.isOffline && model.offlineState == .online && !model.reachability.checking)
        #expect(seen.urls.map(\.path).contains("/rest/ping") && seen.urls.map(\.path).contains("/auth/login"))
    }

    @Test func notice_nothingWhileSuspect() async throws {
        let (model, _) = try await signedIn()
        transport.setDown(["192.168.1.2"])
        model.noteUnreachable()
        #expect(model.offlineState == .suspect && !model.isOffline)
        #expect(OfflineNotice.variant(model.offlineState, checking: true) == nil)
        #expect(OfflineNotice.variant(.online, checking: false) == nil)
    }

    /// Each switch is said once: Offline mode from the notice's Go online says "Back online." only once the login has
    /// answered (fix round 1, design H1); a change made by the Settings switch itself says nothing (design M5).
    @Test func voiceOver_announcesEachSwitchOnce() async throws {
        let (model, clock) = try await signedIn()
        var heard: [String] = []
        model.reachability.announce = { heard.append($0) }
        model.setOfflineMode(on: true)
        model.setOfflineMode(on: true)
        #expect(heard == ["Offline. Showing music on this phone."])
        #expect(await model.advanceReachability(clock, to: 30))
        model.goOnline()
        #expect(await eventually { !model.isOffline })
        #expect(heard == ["Offline. Showing music on this phone.", "Back online."])
        heard = []
        #expect(await model.advanceReachability(clock, to: 200))
        await goAutomaticallyOffline(model, clock, from: 200)
        #expect(heard == ["Offline. Showing music on this phone."])
        model.setOfflineMode(on: true)   // offline already: no second announcement
        #expect(heard.count == 1)
    }

    /// Task review M2: a launch already in Offline mode is not a switch (read from the model's own record, so the test
    /// can fail: the announcer can't be swapped in before `init`).
    @Test func voiceOver_launchInOfflineModeSaysNothing() async throws {
        let first = makeModel()
        first.setOfflineMode(on: true)
        #expect(first.reachability.announced == ["Offline. Showing music on this phone."])
        let relaunch = makeModel()
        #expect(relaunch.isForcedOffline && relaunch.reachability.announced.isEmpty)
    }

    /// Design M5: the Settings switch speaks for itself (VoiceOver reads its new value): no announcement on top.
    @Test func voiceOver_settingsSwitchSaysNothing() async throws {
        let (model, clock) = try await signedIn()
        var heard: [String] = []
        model.reachability.announce = { heard.append($0) }
        model.setOfflineMode(on: true, fromSettings: true)
        #expect(model.isForcedOffline && heard.isEmpty)
        #expect(await model.advanceReachability(clock, to: 30))
        model.setOfflineMode(on: false, fromSettings: true)
        #expect(await eventually { !model.isOffline })
        #expect(heard.isEmpty)
    }

    /// Design H2: announcements only, with hysteresis: five drops in two minutes are said at most twice.
    @Test func voiceOver_flappingIsSaidAtMostTwice() async throws {
        let (model, clock) = try await signedIn()
        var heard: [String] = []
        model.reachability.announce = { heard.append($0) }
        var t = 0.0
        for _ in 0..<5 {
            await dropThePath(model, clock, at: t)   // offline 2 s later (Q1)
            t = clock.now() + 10
            #expect(await model.advanceReachability(clock, to: t))
            await restoreThePath(model, clock)       // the check 2 s later answers
            t = clock.now() + 8
            #expect(await model.advanceReachability(clock, to: t))
        }
        #expect(t <= 120, "five cycles inside two minutes (\(t) s)")
        #expect(heard.count <= 2, "heard: \(heard)")
        #expect(heard.first == "Offline. Showing music on this phone.")
    }

    /// Design H1: Go online with no connection shows "Trying…" in place, then the no-connection notice; it never says
    /// "Back online.".
    @Test func goOnline_withThePathDownNeverSaysBackOnline() async throws {
        let (model, clock) = try await signedIn()
        model.setOfflineMode(on: true)
        var heard: [String] = []
        model.reachability.announce = { heard.append($0) }
        (model.network as? FakeNetwork)?.status = noNetwork
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        #expect(await eventually { !model.reachability.machine.connected })
        let hold = Hold()
        transport.setHook { r in if r.url?.path == "/rest/ping" { await hold.wait() } }
        model.goOnline()
        #expect(await eventually { model.reachability.checking })
        let trying = try #require(OfflineNotice.variant(for: model))
        #expect(trying.text == "Offline mode is on" && trying.action == .trying && trying.actionTitle == "Trying…",
                "Trying… in place of Go online")
        hold.release()
        #expect(await eventually { !model.reachability.checking })
        #expect(model.isOffline && model.offlineState == .automatic)
        let after = try #require(OfflineNotice.variant(for: model))
        #expect(after.text == "No connection. Showing music on this phone." && after.action == .tryAgain)
        #expect(OfflineModeCopy.stateLine(for: model).text == "Offline for now: no connection")
        #expect(await model.advanceReachability(clock, to: 100))
        #expect(!heard.contains("Back online."), "heard: \(heard)")
    }

    /// Design M1: a Try again that finds the library still out of reach says so, on screen and to VoiceOver; a pull to
    /// refresh (not the button) says nothing.
    @Test func tryAgain_failedSaysStillOutOfReach() async throws {
        let (model, clock) = try await signedIn()
        await goAutomaticallyOffline(model, clock)
        var heard: [String] = []
        model.reachability.announce = { heard.append($0) }
        await model.reconnectNow()
        #expect(!model.reachability.stillOutOfReach && heard.isEmpty, "pull to refresh: nothing said")
        await model.tryAgain()
        #expect(model.reachability.stillOutOfReach && heard == ["Still out of reach"])
        let variant = try #require(OfflineNotice.variant(for: model))
        #expect(variant.detail == "Still out of reach" && variant.action == .tryAgain)
        transport.setDown([])
        await model.tryAgain()
        #expect(!model.isOffline && !model.reachability.stillOutOfReach)
    }

    /// Security H1 (= task I1): signing in is an explicit act: it turns Offline mode off first, in every setup, and
    /// Connect says so beforehand.
    @Test func signIn_withOfflineModeOn_goesOnline() async throws {
        let aurralConnection = AurralConnection(base: URL(string: "http://aurral:3001")!, username: "jordan", password: "pw",
                                                login: AurralLogin(token: "t", expiresAt: nil, user: AurralUser(id: 1, username: "jordan", role: "user")))
        #expect(ConnectOfflineCopy.line == "Offline mode is on. Signing in turns it off.")
        for setup in ["navidrome", "lidarr", "aurral", "all"] {
            store.clear()
            defaults.removePersistentDomain(forName: suite)
            let lidarr = MemoryLidarrStore()
            if setup == "lidarr" || setup == "all" {
                try lidarr.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key"))
            }
            let aurral = MemoryAurralStore()
            if setup == "aurral" || setup == "all" { try aurral.save(aurralConnection) }
            let model = makeModel(lidarrStore: lidarr, tokenStore: MemoryTokenStore(setup == "all" ? "lb-token" : nil),
                                  aurralStore: aurral)
            model.setOfflineMode(on: true)
            #expect(model.session == nil && model.isForcedOffline, "\(setup)")
            try await model.signIn(urls: [home], username: "jordan", password: "pw")
            #expect(model.session != nil && !model.isOffline && model.offlineState == .online, "\(setup)")
            #expect(model.preferences.downloads.offlineMode == .automatic && model.offlineGate.mode == .open, "\(setup)")
            model.signOut()
        }
    }

    /// Security L5: the remembered Go offline automatically is read again once the phone is unlocked (a launch before
    /// first unlock couldn't read it).
    @Test func unlockReadsTheRememberedChoiceAgain() async throws {
        let model = makeModel()
        model.setOfflineMode(on: true)
        defaults.set(false, forKey: AppModel.automaticChoiceKey)
        model.protectedDataBecameAvailable()
        #expect(!model.goesOfflineAutomatically && !model.reachability.machine.automaticEnabled)
    }


    // MARK: - Relaunch (D327)

    @Test func manualOfflineSurvivesRelaunch() async throws {
        let (model, _) = try await signedIn()
        model.setOfflineMode(on: true)
        let relaunch = makeModel()
        #expect(relaunch.isForcedOffline && relaunch.offlineState == .manual)
        #expect(relaunch.offlineGate.mode == .manual && relaunch.reachability.machine.state == .manualOffline)
    }

    @Test func automaticOfflineDoesNotSurviveRelaunch() async throws {
        let (model, clock) = try await signedIn()
        await goAutomaticallyOffline(model, clock)
        let relaunch = makeModel()
        #expect(!relaunch.isOffline && relaunch.serverReachable && relaunch.offlineState == .online)
        #expect(relaunch.offlineGate.mode == .open)
    }

    /// The 30 s rule at launch (plan §7.3, "a café with the server down"): the launch's reconnect fails, offline at
    /// 30 s, and the downloads play throughout.
    @Test func launchWithServerDownGoesOfflineAt30s() async throws {
        let (online, _) = try await signedIn()
        online.download([song("s1")], reason: .song); await online.downloads!.settled()
        online.stopDownloads(erase: false)
        await online.downloadsTeardown?.value

        transport.setDown(["192.168.1.2"])
        let model = makeModel()
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        model.resumeSavedSession()
        #expect(await eventually { model.reachability.isSuspect }, "the launch's reconnect went unanswered")
        await model.downloads!.settled()
        model.play([song("s1")], startAt: 0)
        #expect(model.player.isPlaying && engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
        #expect(await model.advanceReachability(clock, to: 29.9))
        #expect(!model.isOffline)
        #expect(await model.advanceReachability(clock, to: 30))
        #expect(model.isOffline && model.offlineState == .automatic)
        #expect(model.player.isPlaying && model.player.queue.current?.song.id == "s1")
    }

    // MARK: - Coming to the front (D326)

    @Test func becameActivePingsWhenStale() async throws {
        let (model, clock) = try await signedIn()
        _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }   // an answer at t = 0
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        #expect(await model.advanceReachability(clock, to: 40))
        model.reachabilitySceneChanged(active: true)
        #expect(await eventually { model.reachability.probeTask == nil })
        #expect(seen.urls.isEmpty, "answered 40 s ago: nothing")
        #expect(await model.advanceReachability(clock, to: 61))
        model.reachabilitySceneChanged(active: true)
        #expect(await eventually { seen.urls.contains { $0.path == "/rest/ping" } })
        #expect(await eventually { model.reachability.probeTask == nil })
        #expect(!seen.urls.contains { $0.path.hasSuffix("/auth/login") }, "the same address: a ping, no login")
        #expect(seen.urls.allSatisfy { $0.path == "/rest/ping" })
        #expect(model.offlineState == .online)
    }

    @Test func becameActiveInManualSendsNothing() async throws {
        let (model, clock) = try await signedIn()
        model.setOfflineMode(on: true)
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        #expect(await model.advanceReachability(clock, to: 500))
        model.reachabilitySceneChanged(active: true)
        model.scenePhaseChanged(.active)
        #expect(model.reachability.probeTask == nil && !model.reachability.hasScheduledWake)
        #expect(await model.advanceReachability(clock, to: 1000))
        #expect(seen.urls.isEmpty)
    }

    // MARK: - Transitions (D330)

    /// Automatic offline leaves a stream that is still playing alone (it plays until it fails); manual stops it
    /// (`OfflineAppTests.forcedOnStopsTheStreamingSong`).
    @Test func transitions_automaticLetsAPlayingStreamPlayOn() async throws {
        let (model, clock) = try await signedIn()
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2")], startAt: 0)   // s1 streams
        await goAutomaticallyOffline(model, clock)
        #expect(model.player.queue.current?.song.id == "s1" && model.player.isPlaying && model.player.lastError == nil)
        // When it fails, the next song on the phone plays.
        model.player.handle(.failed(model.player.queue.current!.id, "The network connection was lost."))
        #expect(model.player.queue.current?.song.id == "s2" && model.player.isPlaying)
    }

    /// Offline mode turned on while automatically offline, with a stream still playing: On sends nothing, so the
    /// stream gives way to the next song on the phone at once (plan §7.1, "manual on: stop a streaming song").
    @Test func transitions_manualFromAutomaticStopsTheStream() async throws {
        let (model, clock) = try await signedIn()
        model.download([song("s2")], reason: .song); await model.downloads!.settled()
        model.play([song("s1"), song("s2")], startAt: 0)   // s1 streams
        await goAutomaticallyOffline(model, clock)
        #expect(model.player.queue.current?.song.id == "s1" && model.player.isPlaying)
        model.setOfflineMode(on: true)
        #expect(model.player.queue.current?.song.id == "s2" && model.player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL })
    }

    /// Security M1: Offline mode turned on with a song streaming and nothing on the phone: the remote item is released
    /// (no stream URL stays loaded); Play loads it again once back online.
    @Test func transitions_manualWithNothingOnThePhoneReleasesTheStream() async throws {
        let (model, clock) = try await signedIn()
        model.play([song("s1"), song("s2")], startAt: 0)   // both stream
        #expect(engine.setItemsCalls.last!.items.contains { !$0.1.isFileURL })
        model.setOfflineMode(on: true)
        #expect(!model.player.isPlaying && model.player.lastError == "You're offline")
        #expect(engine.setItemsCalls.last!.items.isEmpty, "the remote item is released")
        #expect(await model.advanceReachability(clock, to: 30))
        model.setOfflineMode(on: false)
        #expect(await eventually { !model.isOffline })
        if !model.player.isPlaying { model.player.toggle() }
        #expect(await eventually { self.engine.setItemsCalls.last!.items.first.map { !$0.1.isFileURL } == true })
    }

    /// Back online: queued plays are sent, waiting downloads land, and a song that failed plays again from where it was;
    /// the local file playing is never reloaded (D282).
    @Test func transitions_backOnlineDrainsResumesAndRetries() async throws {
        let fetcher = FakeFetcher()
        let (model, clock) = try await signedIn(fetcher: fetcher)
        model.play([song("s1"), song("s2")], startAt: 0)
        await goAutomaticallyOffline(model, clock)
        model.download([song("s3")], reason: .song); await model.downloads!.settled()
        #expect(model.downloadStatus(["s3"]) == .waitingForConnection && fetcher.urls.isEmpty)
        model.player.listen(model.player.queue.current!.id, from: 0, to: 150, duration: 200)   // past the scrobble point
        await model.player.waitForPendingScrobbles()
        model.player.handle(.failed(model.player.queue.current!.id, "The network connection was lost."))
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        transport.setDown([])
        #expect(await model.advanceReachability(clock, to: 60))   // the first offline check (30 s after going offline)
        #expect(await eventually { !model.isOffline })
        #expect(await eventually { model.downloads!.localFiles["s3"] != nil }, "the waiting download lands")
        #expect(await eventually { seen.urls.contains { $0.path.hasSuffix("/rest/scrobble") } }, "the queued play is sent")
        #expect(await eventually { model.player.lastError == nil && model.player.isPlaying })
    }

    // MARK: - Four setups

    /// The switch and the notice are the same in every setup; manual offline explains every Lidarr control (D139) and
    /// sends nothing to Lidarr, Aurral or ListenBrainz.
    @Test func fourSetups() async throws {
        let aurralConnection = AurralConnection(base: URL(string: "http://aurral:3001")!, username: "jordan", password: "pw",
                                                login: AurralLogin(token: "t", expiresAt: nil, user: AurralUser(id: 1, username: "jordan", role: "user")))
        for setup in ["navidrome", "lidarr", "aurral", "all"] {
            store.clear()
            defaults.removePersistentDomain(forName: suite)
            let lidarr = MemoryLidarrStore()
            if setup == "lidarr" || setup == "all" {
                try lidarr.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key"))
            }
            let aurral = MemoryAurralStore()
            if setup == "aurral" || setup == "all" { try aurral.save(aurralConnection) }
            let tokens = MemoryTokenStore(setup == "all" ? "lb-token" : nil)
            let model = makeModel(lidarrStore: lidarr, tokenStore: tokens, aurralStore: aurral)
            try await model.signIn(urls: [home], username: "jordan", password: "pw")
            model.setOfflineMode(on: true)
            let passed = model.offlineGate.passedCount
            let variant = OfflineNotice.variant(model.offlineState, checking: false)
            #expect(variant?.action == .goOnline && variant?.text == "Offline mode is on", "\(setup)")
            #expect(OfflineModeCopy.stateLine(model.offlineState, automatic: model.goesOfflineAutomatically).text
                == "Only music on this phone plays", "\(setup)")
            if setup == "lidarr" || setup == "all" {
                #expect(model.tryAvailability.message == "You're offline", "\(setup)")
                #expect(SettingsSummaries.requests(model) == SettingsSummary("You're offline", symbol: "wifi.slash"), "\(setup)")
            }
            if setup == "aurral" || setup == "all" {
                #expect(try await model.discoverPlaylists().isEmpty, "\(setup): Discover hides offline (D89)")
            }
            await model.checkReachability()
            _ = try? await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
            await model.toggleStar(song("s1"))
            model.reachabilitySceneChanged(active: true)
            #expect(model.offlineGate.passedCount == passed, "\(setup): nothing sent in manual offline")
            model.signOut()
        }
    }
}

/// Round 28 O1 (owner, 2026-11-15): a reachability clock tests move by hand (plan §4: no sleeps). `sleep(until:)` waits
/// until the test moves the clock past the deadline, or the task is cancelled.
final class ManualReachabilityClock: ReachabilityClock, Sendable {
    private struct State {
        var now: Double = 0
        var next = 0
        var sleepers: [Int: (deadline: Double, continuation: CheckedContinuation<Void, Error>)] = [:]
        var cancelled: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func now() -> Double { state.withLock { $0.now } }

    func sleep(until deadline: Double) async throws {
        let id = state.withLock { s -> Int in s.next += 1; return s.next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case wait, now, cancelled }
                let outcome = state.withLock { s -> Outcome in
                    if s.cancelled.remove(id) != nil { return .cancelled }
                    if deadline <= s.now { return .now }
                    s.sleepers[id] = (deadline, continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .now: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiting = state.withLock { s -> CheckedContinuation<Void, Error>? in
                guard let sleeper = s.sleepers.removeValue(forKey: id) else { s.cancelled.insert(id); return nil }
                return sleeper.continuation
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock to `time` (never back) and wakes every sleeper due by then.
    func set(_ time: Double) {
        let due = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            s.now = max(s.now, time)
            let ready = s.sleepers.filter { $0.value.deadline <= s.now }
            for id in ready.keys { s.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

extension AppModel {
    /// Tests: the transport a test passed in, under the offline gate's wrapper (D328).
    /// (`MagpieCore.` because MadeForYouAppTests has a `GatedTransport` of its own.)
    var injectedTransport: HTTPTransport {
        let kept: HTTPTransport = transport
        return (kept as? MagpieCore.GatedTransport)?.innerForTesting ?? kept
    }

    /// Tests: moves `clock` to `time` one wake at a time (each probe finishes before the next wake), as the real clock
    /// would, so no tick arrives late. Returns false if the machine didn't settle.
    @discardableResult
    func advanceReachability(_ clock: ManualReachabilityClock, to time: Double) async -> Bool {
        var steps = 0
        while let wake = reachability.machine.nextWake, wake <= time, steps < 500 {
            steps += 1
            guard await settleReachability(clock, at: wake) else { return false }
        }
        return await settleReachability(clock, at: time)
    }

    /// Moves the clock to `time`, then waits until the machine has handled every wake due by then and its probe is over.
    func settleReachability(_ clock: ManualReachabilityClock, at time: Double) async -> Bool {
        clock.set(time)
        return await eventually(10) {
            self.reachability.probeTask == nil && (self.reachability.machine.nextWake ?? .infinity) > clock.now()
                && (self.reachability.timer != nil || self.reachability.machine.nextWake == nil)
        }
    }
}
