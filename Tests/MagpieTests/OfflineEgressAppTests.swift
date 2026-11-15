import CarPlayUI
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

/// Round 28 O1 (owner, 2026-11-15): one gate for everything Magpie sends (D328), counted on every transport. Manual
/// offline: nothing at all. Automatic offline: only the reconnect ping (no credentials) and its login.
@MainActor @Suite(.serialized) final class OfflineEgressAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineEgressAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OfflineEgressAppTests.\(UUID().uuidString)")!
    /// The main transport (the library, Lidarr, ListenBrainz, MusicBrainz, Aurral, slskd share it).
    let main = HostSwitchTransport()
    /// The probe's own transport.
    let probe = HostSwitchTransport()
    /// Previews and Aurral's image proxy.
    let preview = MockTransport()
    let engine = FakeEngine()

    init() {
        for t in [main, probe] {
            t.inner.stub(pathSuffix: "/rest/ping", body: ok)
            t.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
            t.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
            t.inner.stub(pathSuffix: "/rest/star", body: ok)
            t.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
            t.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        }
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedIn(fetcher: FakeFetcher) async throws -> (AppModel, ManualReachabilityClock) {
        let lidarr = MemoryLidarrStore()
        try lidarr.save(LidarrConnection(base: URL(string: "http://127.0.0.1:8686")!, apiKey: "test-key"))
        let model = AppModel(store: store, lidarrStore: lidarr, tokenStore: MemoryTokenStore("lb-token"),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: main, probeTransport: probe,
                             engine: engine, previewTransport: preview, defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: FakeNetwork(.wifi), audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        model.download([song("s1")], reason: .album("al-1"), coverArtId: "al-1"); await model.downloads!.settled()
        await model.matchIndexSettled()
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        return (model, clock)
    }

    func song(_ id: String) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", albumId: "al-1", track: 1, duration: 200, coverArtId: "mf-\(id)")
    }

    /// Everything a listener can do in a few minutes: play, browse, search, lyrics, Discover, Try, star, scrobble,
    /// pull to refresh, coming to the front, the car, and a direct send on each of the app's own transports.
    /// `checks`: pull to refresh and coming to the front too (each asks for a reconnect check while offline).
    func everything(_ model: AppModel, _ clock: ManualReachabilityClock, until: Double, checks: Bool = true) async {
        model.play([song("s1"), song("s2")], startAt: 0)
        model.player.listen(model.player.queue.current!.id, from: 0, to: 150, duration: 200)
        await model.player.waitForPendingScrobbles()
        _ = try? await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
        _ = try? await model.requestOnce { try await $0.createPlaylist(name: "Road trip", songIds: []) }
        _ = try? await model.mergedSearch().runReportingLibraryFailure("t")
        _ = try? await model.carPlaySearch("t")
        _ = try? await model.lyricsForPane(song("s1"))
        _ = await model.paneLyricsRead("s1")
        _ = try? await model.discoverPlaylists()
        _ = model.tryAvailability
        await model.toggleStar(song("s1"))
        _ = await model.lidarrAudit()
        await model.refreshFinds()
        await model.refreshMadeForYou()
        model.drainScrobblesSoon()
        #expect(model.coverArtURL("al-1", size: 300) == nil, "artwork asks nothing offline")
        if checks {
            await model.checkReachability()
            model.scenePhaseChanged(.active)
        }
        let page = URLRequest(url: URL(string: "http://192.168.1.2:4533/rest/getAlbumList2?u=jordan&t=x&s=y")!)
        _ = try? await model.transport.send(page)
        _ = try? await model.previewTransport.send(URLRequest(url: URL(string: "http://aurral:3001/api/health")!))
        // LRCLIB's client asked directly, past the lyrics pane's own offline check: the gate under it refuses.
        _ = await model.lyricsKeeper.lrclib?.get(title: "T", artist: "A", album: "B", duration: 200)
        await model.advanceReachability(clock, to: until)
    }

    @Test func egress_manualSendsNothingOnAnyTransport() async throws {
        let fetcher = FakeFetcher()
        let (model, clock) = try await signedIn(fetcher: fetcher)
        model.setOfflineMode(on: true)
        let fetched = fetcher.urls.count
        let sent = (main.inner.requests.count, probe.inner.requests.count, preview.requests.count)
        let passed = model.offlineGate.passedCount
        await everything(model, clock, until: 600)
        model.download([song("s9")], reason: .song); await model.downloads!.settled()
        #expect(model.offlineGate.passedCount == passed, "the gate let nothing out")
        #expect(model.offlineGate.refusedCount > 0, "and was asked")
        #expect(main.inner.requests.count == sent.0, "main: \(main.inner.requests.dropFirst(sent.0).map { $0.url!.path })")
        #expect(probe.inner.requests.count == sent.1 && preview.requests.count == sent.2)
        #expect(fetcher.urls.count == fetched, "no download task offline")
        #expect(engine.setItemsCalls.last!.items.allSatisfy { $0.1.isFileURL }, "stream URLs offline are local only")
    }

    @Test func egress_automaticSendsOnlyPingAndLogin() async throws {
        let fetcher = FakeFetcher()
        let (model, clock) = try await signedIn(fetcher: fetcher)
        main.setDown(["192.168.1.2"]); probe.setDown(["192.168.1.2"])
        model.noteUnreachable()
        #expect(await model.advanceReachability(clock, to: 30))
        #expect(model.offlineState == .automatic)
        // The library is back, but nothing tells Magpie until its next check (at 60 s): everything else sends nothing.
        main.setDown([]); probe.setDown([])
        // Each send, with whether Magpie was offline when it went (what follows going online is ordinary traffic).
        let sentOffline = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let box = model.offlineBox
        let seen = Recorder(), probed = Recorder()
        main.setHook { r in seen.add(r); if box.isOffline, let u = r.url { sentOffline.withLock { $0.append(u) } } }
        probe.setHook { r in probed.add(r); if box.isOffline, let u = r.url { sentOffline.withLock { $0.append(u) } } }
        let fetched = fetcher.urls.count
        await everything(model, clock, until: 59, checks: false)
        #expect(model.isOffline, "no check before 60 s")
        #expect(seen.urls.isEmpty && probed.urls.isEmpty, "sent: \((seen.urls + probed.urls).map(\.path))")
        #expect(preview.requests.isEmpty && fetcher.urls.count == fetched)
        // Pull to refresh: a ping without credentials, then one login, and nothing else; then online.
        await model.checkReachability()
        #expect(await eventually { !model.isOffline })
        let all = sentOffline.withLock { $0 }
        #expect(all.allSatisfy { Self.isBarePing($0) || $0.path.hasSuffix("/auth/login") }, "sent offline: \(all.map(\.path))")
        #expect(probed.urls.contains(where: Self.isBarePing))
        #expect(all.filter { $0.path.hasSuffix("/auth/login") }.count == 1)
    }

    nonisolated static func isBarePing(_ url: URL) -> Bool {
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        return url.path.hasSuffix("/rest/ping") && !names.contains("u") && !names.contains("t") && !names.contains("s")
    }
}
