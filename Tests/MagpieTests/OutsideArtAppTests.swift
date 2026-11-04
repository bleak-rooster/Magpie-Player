import BackgroundTasks
import CarPlay
import CarPlayUI
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Requests
import Search
import SwiftUI
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope
private let rg = MBID("01a340b4-1d99-4083-ad92-fa2803368bed")!
private let release = MBID("b5cdfb5f-35a5-4bc5-bbca-57839a71813a")!
private let artistMBID = MBID("64db764c-2251-4f95-aa40-10fc91d509d8")!
private let recordingMBID = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!

/// R15 and R16 in the app: outside artwork for search (phone and car), Try and the request screens (B1, D122: kept in its
/// own folder on the phone, never in P4), while library artwork keeps the P4 cache; and requests that keep going away from their screen and
/// in the background. Every request goes to a stub (G0): nothing reaches coverartarchive.org or Lidarr's image host.
@MainActor @Suite(.serialized) final class OutsideArtAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OutsideArtAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OutsideArtAppTests.\(UUID().uuidString)")!
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let transport = HostSwitchTransport()
    /// Outside artwork's own transport (Cover Art Archive, Lidarr's image host).
    let outside = MockTransport()
    let tag = "x5t\(UUID().uuidString.prefix(8).lowercased())-"

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.orange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/rest/getCoverArt", body: Self.png, headers: ["Content-Type": "image/png"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library"}]"#.utf8))
        outside.stub(pathSuffix: "/front-250", body: Self.png, headers: ["Content-Type": "image/png"])
        outside.stub(pathSuffix: ".jpg", body: Self.png, headers: ["Content-Type": "image/jpeg"])
        AppModel.outsideArtTransportForTesting = outside
        ArtworkCache.shared.transportForTesting = t
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        Task { @MainActor in
            AppModel.outsideArtTransportForTesting = nil
            ArtworkCache.shared.transportForTesting = nil
        }
    }

    private func makeModel(notifications: Bool = false, lidarrStore: MemoryLidarrStore = MemoryLidarrStore()) -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: tmp, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: notifications,
                 network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    private func signedIn(notifications: Bool = false) async throws -> AppModel {
        let model = makeModel(notifications: notifications)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    private func withLidarr(_ model: AppModel) async throws {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1,
                                                              rootFolderPath: "/music/library"))
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
    }

    private var outsideRequests: [String] { outside.requests.compactMap { $0.url?.absoluteString } }

    // MARK: - R15: never cached; the library keeps P4

    @Test func outsideArtNeverReachesTheDiskWhileLibraryArtKeepsP4() async throws {
        let model = try await signedIn()
        let loader = model.makeOutsideArt()
        #expect(await loader.image(.releaseGroup(rg)) != nil)
        #expect(await loader.image(.release(release)) != nil)
        #expect(outsideRequests == ["https://coverartarchive.org/release-group/\(rg.rawValue)/front-250",
                                    "https://coverartarchive.org/release/\(release.rawValue)/front-250"])
        // The UA is the app's MusicBrainz one: no account, server or personal detail.
        for request in outside.requests {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == MusicBrainzClient.userAgent(version: AppModel.marketingVersion))
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
        #expect(await model.artworkUsage == 0, "nothing in the P4 disk cache")
        #expect(!FileManager.default.fileExists(atPath: ArtworkDiskCache.folder(root: tmp).path))
        #expect(OutsideArtTransport.configuration.urlCache == nil && OutsideArtTransport.configuration.httpCookieStorage == nil)

        // In-library results still go through P4: the cover is saved to disk and served from it.
        _ = await model.artworkImage("\(tag)al-1", size: 120)
        #expect(await model.artworkUsage > 0)
        let scope = try #require(model.navidromeScope)
        #expect(await model.artworkDisk.data(scope: scope, coverArtId: "\(tag)al-1", size: 120) != nil)
        model.signOut()
    }

    @Test func offlineOrOfflineModeSendsNothing() async throws {
        let model = try await signedIn()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.isOffline)
        let loader = model.makeOutsideArt()
        #expect(await loader.image(.releaseGroup(rg)) == nil)
        #expect(await loader.image(.artist(artistMBID)) == nil)
        #expect(outside.requests.isEmpty)

        // The car's search, offline: no outside hits, so no outside art either.
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(await adapter.artwork(coverArtId: OutsideArtKey.release(release).token, pixelSide: 100) == nil)
        #expect(outside.requests.isEmpty)
        model.signOut()
    }

    // MARK: - R15: phone search

    @Test func aNewSearchDropsTheArtFromMemoryAndShowsItFromThePhone() async throws {
        let model = try await signedIn()
        let search = SearchModel(search: { _, _ in .empty }, sleep: { _ in })
        search.outsideArt = model.makeOutsideArt()
        let loader = try #require(search.outsideArt)
        _ = await loader.image(.releaseGroup(rg))
        #expect(loader.cachedCount == 1)
        search.update(query: "harbour")
        #expect(loader.cachedCount == 0, "a new search drops it from memory")
        _ = await loader.image(.releaseGroup(rg))
        // B1 (D122, owner): a picture that loaded is kept on the phone, so the next search shows it without asking.
        #expect(outside.requests.count == 1, "from the phone, not fetched again")
        model.signOut()
    }

    @Test func artistPictureComesFromLidarrsLookup() async throws {
        let model = try await signedIn()
        try await withLidarr(model)
        transport.inner.stub(pathSuffix: "/api/v1/artist/lookup", body: Data(#"""
        [{"artistName":"Judie Tzuke","foreignArtistId":"\#(artistMBID.rawValue)","images":[
          {"coverType":"fanart","remoteUrl":"https://images.lidarr.audio/cache/fanart.jpg"},
          {"coverType":"poster","url":"/MediaCoverProxy/abc/poster.jpg","remoteUrl":"https://images.lidarr.audio/cache/poster.jpg"}]}]
        """#.utf8))
        let loader = model.makeOutsideArt()
        #expect(await loader.image(.artist(artistMBID)) != nil)
        let lookup = try #require(transport.inner.requests.last { $0.url?.path.hasSuffix("/api/v1/artist/lookup") == true })
        #expect(lookup.url?.query?.contains("lidarr:\(artistMBID.rawValue)") == true)
        #expect(outsideRequests == ["https://images.lidarr.audio/cache/poster.jpg"])
        #expect(await model.artworkUsage == 0)
        model.signOut()
    }

    @Test func withoutLidarrArtistsKeepThePlaceholder() async throws {
        let model = try await signedIn()
        #expect(await model.makeOutsideArt().image(.artist(artistMBID)) == nil)
        #expect(outside.requests.isEmpty)
        model.signOut()
    }

    // MARK: - R15: the car

    @Test func carPlayOutsideRowsGetTheArtInMemoryOnly() async throws {
        let recording = ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights", artist: "Judie Tzuke",
                                          source: .listenBrainz, releaseMBID: release)
        let rows = CarPlayRows.searchItems(LibrarySearchResult(), notYet: [recording], offer: .next)
        let key = try #require(rows.first?.artworkKey)
        #expect(key == OutsideArtKey.release(release).token && rows.first?.round == true)
        let bare = CarPlayRows.searchItems(LibrarySearchResult(), notYet: [ExternalRecording(title: "T", artist: "A", source: .listenBrainz)],
                                           offer: .next)
        #expect(bare.first?.artworkKey == nil, "no release named: the plain record")

        let model = try await signedIn()
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(await adapter.artwork(coverArtId: key, pixelSide: 100) != nil)
        #expect(outsideRequests == ["https://coverartarchive.org/release/\(release.rawValue)/front-250"])
        #expect(await model.artworkUsage == 0, "never in the P4 cache")
        #expect(adapter.outsideArt.cachedCount == 1)
        _ = try? await adapter.search("anything")
        #expect(adapter.outsideArt.cachedCount == 0, "a new car search drops it")
        // Fix round 1 (b): closing the car's search drops it too.
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: adapter, player: model.player)
        defer { controller.disconnect() }
        _ = await adapter.artwork(coverArtId: key, pixelSide: 100)
        #expect(adapter.outsideArt.cachedCount == 1)
        controller.templateDidDisappear(CPSearchTemplate(), animated: false)   // popped: not in the stack
        #expect(adapter.outsideArt.cachedCount == 0, "the car search closed")
        // A library cover id still goes through P4.
        _ = await adapter.artwork(coverArtId: "\(tag)al-2", pixelSide: 100)
        #expect(await model.artworkUsage > 0)
        model.signOut()
    }

    // MARK: - R16: request screens' art

    @Test func requestArtIsTheReleaseGroupThenTheLibraryCover() async throws {
        var request = MagpieRequest(recording: ExternalRecording(recordingMBID: recordingMBID, title: "S", artist: "A",
                                                                 source: .listenBrainz, releaseMBID: release),
                                    tier: .standard, createdAt: Date())
        #expect(request.cover.outside == .release(release), "before it's resolved: the release search named")
        request.plan = Plan(recordingMBID: recordingMBID, releaseGroupMBID: rg, artistMBID: artistMBID,
                            lidarrArtistId: nil, mode: .fallback)
        #expect(request.cover.outside == .releaseGroup(rg), "resolved: its release group")
        #expect(request.cover.songId == nil)

        let model = try await signedIn()
        #expect(await model.readyCoverArtId(request.cover) == nil, "not in the library yet")
        transport.inner.stub(pathSuffix: "/rest/getSong", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"\#(tag)s1","title":"S","artist":"A","album":"B","duration":200,"coverArt":"\#(tag)al-9"}}}
        """#.utf8))
        request.songId = "\(tag)s1"
        #expect(await model.readyCoverArtId(request.cover) == "\(tag)al-9", "listed: the library cover (P4)")
        let asked = transport.inner.requests.count
        #expect(await model.readyCoverArtId(request.cover) == "\(tag)al-9")
        #expect(transport.inner.requests.count == asked, "its cover id is remembered, not asked again")
        model.signOut()
    }

    /// A ready find's song id the library re-identified: Navidrome answers code 70 ("Song not found"). The runner's
    /// pass reads that as gone (false), any other failure as "can't tell" (nil); the art read gives no cover for it.
    @Test func goneSongIdIsToldApartFromUnreadable() async throws {
        let model = try await signedIn()
        let tag = self.tag
        transport.inner.stub(pathSuffix: "/rest/getSong") { req in
            let id = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            let body = switch id {
            case "\(tag)gone": #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"Song not found"}}}"#
            case "\(tag)s1": #"{"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"\#(tag)s1","title":"S","artist":"A","album":"B","duration":200}}}"#
            default: #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"Something"}}}"#
            }
            return MockTransport.Response(status: 200, body: Data(body.utf8))
        }
        #expect(await model.librarySongExists("\(tag)gone") == false)
        #expect(await model.readyCoverArtId(MagpieRequestCover(songId: "\(tag)gone", outside: nil, artist: nil)) == nil)
        #expect(await model.librarySongExists("\(tag)x") == nil)
        #expect(await model.librarySongExists("\(tag)s1") == true)
        model.signOut()
    }

    // MARK: - R16: away from the screen

    /// Try, open its wait screen, leave at once: the request keeps going (the runner is the model's, not the view's).
    @Test func aRequestKeepsGoingWhenItsScreenIsDismissed() async throws {
        let t = transport.inner
        t.stub(pathSuffix: "/ws/2/recording/\(recordingMBID.rawValue)", body: Data(#"""
        {"id":"\#(recordingMBID.rawValue)","title":"Harbour Lights","artist-credit":[{"artist":{"id":"\#(artistMBID.rawValue)"}}],
         "releases":[{"id":"\#(release.rawValue)","title":"The Cat Is Out","status":"Official",
           "release-group":{"id":"\#(rg.rawValue)","primary-type":"Album","secondary-types":[]}}]}
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"[{"id":7,"artistName":"Judie Tzuke","foreignArtistId":"\#(artistMBID.rawValue)","rootFolderPath":"/music/library"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/album", body: Data(#"[{"id":31,"title":"The Cat Is Out","artistId":7,"foreignAlbumId":"\#(rg.rawValue)","monitored":false}]"#.utf8))
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor", body: Data("[]".utf8))
        t.stub(method: "POST", pathSuffix: "/api/v1/command", body: Data(#"{"id":5,"name":"AlbumSearch","status":"queued"}"#.utf8))
        let model = try await signedIn()
        try await withLidarr(model)
        await model.setChangesAllowed(true)
        let id = try await model.tryRecording(ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights",
                                                                artist: "Judie Tzuke", source: .listenBrainz))
        model.waitScreenAppeared(id)
        model.waitScreenDisappeared(id)   // the owner left straight away
        #expect(!model.isOnWaitScreen(id))
        for _ in 0..<300 where model.magpieRequest(id)?.state != .searching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.magpieRequest(id)?.state == .searching, "it kept going")
        #expect(model.magpieRequest(id)?.plan?.releaseGroupMBID == rg)
        #expect(model.magpieRequest(id)?.cover.outside == .releaseGroup(rg))
        #expect(model.magpieRequest(id)?.cover.artist == .artist(artistMBID), "no cover: the artist's picture")
        // Live: going to the background (the scene phase) asks iOS for a refresh pass; coming back doesn't.
        let submitted = OSAllocatedUnfairLock(initialState: [String]())
        let record: (BGTaskRequest) async throws -> Void = { request in
            let id = request.identifier; submitted.withLock { $0.append(id) }
        }
        model.requestsScenePhaseChanged(.active, submit: record)
        model.requestsScenePhaseChanged(.inactive, submit: record)
        try await Task.sleep(for: .milliseconds(200))
        #expect(submitted.withLock { $0 }.isEmpty, "only going to the background asks")
        model.requestsScenePhaseChanged(.background, submit: record)
        for _ in 0..<100 where submitted.withLock({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(submitted.withLock { $0 } == [RequestsBackgroundRefresh.identifier])
        // Fix round 1: an offline pass sends nothing but still asks for the next one, so the chain doesn't stop.
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let sent = transport.inner.requests.count
        #expect(await model.backgroundRequestPass(submit: record) == false)
        for _ in 0..<100 where submitted.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(submitted.withLock { $0.count } == 2)
        #expect(transport.inner.requests.count == sent, "offline: nothing sent")
        model.updatePreferences { $0.downloads.offlineMode = .off }
        await model.cancelRequest(id)
        for _ in 0..<300 where model.magpieRequest(id)?.cleanupPending != false || model.magpieRequest(id)?.state != .cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.signOut()
    }

    /// Ready while the owner is elsewhere: D6 (next in the queue, the Play now banner) and the ready notification.
    @Test func readyWhileElsewhereLandsNextWithTheBannerAndNotifies() async throws {
        let model = try await signedIn(notifications: true)
        transport.inner.stub(pathSuffix: "/rest/getSong", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"\#(tag)ready","title":"Harbour Lights","artist":"Judie Tzuke","album":"B","duration":200}}}
        """#.utf8))
        model.play([Song(id: "\(tag)other", title: "Other", artist: "X", album: "Y", duration: 200)], startAt: 0)
        var request = MagpieRequest(recording: ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights",
                                                                 artist: "Judie Tzuke", source: .listenBrainz),
                                    tier: .standard, createdAt: Date())
        request.state = .ready
        request.songId = "\(tag)ready"
        request.plan = Plan(recordingMBID: recordingMBID, releaseGroupMBID: rg, artistMBID: artistMBID,
                            lidarrArtistId: 7, mode: .fallback)
        #expect(!model.isOnWaitScreen(request.id), "the owner is elsewhere")
        model.requestBecameReady(request)
        for _ in 0..<300 where model.playNowBanner == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.playNowBanner?.request == request.id)
        #expect(model.player.queue.current?.song.id == "\(tag)other", "it never cuts in")
        #expect(model.player.queue.upNext.first?.song.id == "\(tag)ready", "it goes next")
        #expect(ReadyNotifier.shared.postedForTesting.contains("ready-\(request.id.description)"))
        model.signOut()
    }

    // MARK: - R16: in the background

    @Test func aBackgroundPassRunsOneBoundedRunnerTick() async throws {
        let model = try await signedIn()
        #expect(await model.backgroundRequestPass() == false, "no Lidarr: nothing to run")
        try await withLidarr(model)
        let runner = try #require(model.runner)
        let before = await runner.tickCount
        #expect(await model.backgroundRequestPass(limit: .seconds(10)))
        #expect(await runner.tickCount > before, "the pass ran the runner (its own poll may run too)")
        #expect(Set(transport.inner.requests.compactMap(\.httpMethod)).isSubset(of: ["GET", "POST"]))
        #expect(!transport.inner.requests.contains { $0.httpMethod != "GET" && $0.url?.port == 8686 }, "no Lidarr writes")

        // Bounded: a pass that runs long reports it didn't finish in time.
        #expect(await AppModel.within(.milliseconds(20)) { try? await Task.sleep(for: .seconds(5)) } == false)
        #expect(await AppModel.within(.seconds(5)) {} == true)

        // Offline: nothing at all.
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.backgroundRequestPass() == false)
        model.signOut()
    }

    /// Fix round 1 (d): a cold background launch whose first Keychain read found no Lidarr (still locked) reads it
    /// again and builds the runner before the pass, instead of ending with nothing done.
    @Test func aColdBackgroundLaunchBuildsTheRunnerFirst() async throws {
        let lidarrStore = MemoryLidarrStore()
        let model = makeModel(lidarrStore: lidarrStore)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(model.runner == nil)
        #expect(await model.backgroundRequestPass(limit: .seconds(5)) == false, "no Lidarr at all: ends cleanly")
        try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "key"))   // readable now
        #expect(await model.backgroundRequestPass(limit: .seconds(10)))
        #expect(model.runner != nil, "the pass built the runner")
        model.signOut()
    }

    @Test func aBackgroundPassIsAskedForOnlyWhileRequestsAreLive() async throws {
        let model = try await signedIn()
        try await withLidarr(model)
        let submitted = OSAllocatedUnfairLock(initialState: [String]())
        model.scheduleRequestRefresh { request in let id = request.identifier; submitted.withLock { $0.append(id) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(submitted.withLock { $0 }.isEmpty, "nothing on its way: nothing asked for")
        let request = RequestsBackgroundRefresh.request(now: Date(timeIntervalSince1970: 0))
        #expect(request.identifier == "com.bleak-rooster.magpie.requests")
        #expect(request.earliestBeginDate == Date(timeIntervalSince1970: 15 * 60), "at most every 15 minutes")
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(ids == ["com.bleak-rooster.magpie.requests"])
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes == ["audio", "fetch"])
        model.signOut()
    }

    /// While audio plays in the background the process stays alive: polling goes on, every 30 s.
    @Test func backgroundPollingKeepsItsCadence() {
        #expect(RequestRunner.pollInterval(foreground: false) == .seconds(30))
        #expect(RequestRunner.pollInterval(foreground: true) == .seconds(5))
    }
}

// MARK: - B1 (owner items 4–6): pictures that fill every time, pull to refresh that never sticks

private func b1Group(_ id: String, _ title: String) -> MBReleaseGroupSummary {
    MBReleaseGroupSummary(id: MBID(id)!, title: title, primaryType: "Album", secondaryTypes: [], firstReleaseDate: "2020")
}

/// What an outside artist page reads, scripted per call (a wait, then the albums or a failure; no wait: never answers).
private final class ScriptedGroups: @unchecked Sendable {
    typealias Step = (wait: Duration?, groups: [MBReleaseGroupSummary]?)
    private let script: [Step]
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    init(_ script: [Step]) { self.script = script }
    var count: Int { calls.withLock { $0 } }
    func next(_: MBID) async throws -> [MBReleaseGroupSummary] {
        let n = calls.withLock { $0 += 1; return $0 - 1 }
        let step = script.indices.contains(n) ? script[n] : script[script.count - 1]
        if let wait = step.wait { try await Task.sleep(for: wait) } else { try await Task.sleep(for: .seconds(600)) }
        guard let groups = step.groups else { throw URLError(.notConnectedToInternet) }
        return groups
    }
}

extension OutsideArtAppTests {
    /// Item 4: Recommended's circles are filled without opening each artist: the artist page's picture (Lidarr's
    /// lookup) is fetched for every artist, kept on the phone, and shown at once on the next open; sign-out removes it.
    @Test func recommendedArtistsPicturesArePrefetchedAndKept() async throws {
        let model = try await signedIn()
        try await withLidarr(model)
        let ids = (1...6).map { MBID(String(format: "%08d-1111-4111-8111-111111111111", $0))! }
        transport.inner.stub(pathSuffix: "/api/v1/artist/lookup") { request in
            let term = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "term" }?.value ?? ""
            let mbid = term.replacingOccurrences(of: "lidarr:", with: "")
            return .init(status: 200, body: Data(#"""
            [{"artistName":"A","foreignArtistId":"\#(mbid)","images":[{"coverType":"poster","remoteUrl":"https://images.lidarr.audio/cache/\#(mbid).jpg"}]}]
            """#.utf8))
        }
        await model.prefetchArtistPictures(ids)
        #expect(Set(outsideRequests) == Set(ids.map { "https://images.lidarr.audio/cache/\($0.rawValue).jpg" }))
        let nextOpen = model.makeOutsideArt()
        #expect(ids.allSatisfy { nextOpen.cached(.artist($0)) != nil }, "at once on the next open, from the phone")
        let before = outside.requests.count
        _ = await model.recommendedArt.image(.artist(ids[0]))
        #expect(outside.requests.count == before, "nothing asked again")
        model.signOut()
        #expect(model.outsideArtDisk.count == 0, "sign-out removes the pictures")
    }

    /// Item 6: a pull to refresh while the first load is still under way supersedes it; the slower first answer never
    /// replaces the newer one, and nothing says it failed.
    @Test func aRefreshDuringALoadSupersedesIt() async throws {
        let model = try await signedIn()
        let first = [b1Group("11111111-2222-4333-8444-555555555555", "Old")]
        let second = first + [b1Group("21111111-2222-4333-8444-555555555555", "New")]
        let script = ScriptedGroups([(.milliseconds(400), first), (.milliseconds(10), second)])
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { try await script.next($0) }, releases: { _ in [] })
        let page = OutsideArtistModel(app: model, artist: NotYetArtist(name: "A", mbid: artistMBID))
        async let slow: Void = page.load()
        try await Task.sleep(for: .milliseconds(50))
        await page.load(fresh: true)
        await slow
        #expect(page.phase == .loaded)
        #expect(page.sections.albums.map(\.title).sorted() == ["New", "Old"], "the newer answer stays")
        #expect(script.count == 2)
        model.signOut()
    }

    /// Item 6: a source that never answers times out: with nothing shown the page says it couldn't load (and Try again
    /// works); with the albums shown they stay, with the quiet notice. Never a spinner for good.
    @Test func aSilentSourceTimesOutWithoutFreezingThePage() async throws {
        let model = try await signedIn()
        let albums = [b1Group("11111111-2222-4333-8444-555555555555", "Kept")]
        let script = ScriptedGroups([(nil, nil), (.milliseconds(10), albums), (nil, nil)])
        model.outsideCatalogStore = OutsideCatalog(releaseGroups: { try await script.next($0) }, releases: { _ in [] })
        let page = OutsideArtistModel(app: model, artist: NotYetArtist(name: "A", mbid: artistMBID))
        page.loadTimeout = .milliseconds(200)
        let start = ContinuousClock.now
        await page.load()
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(page.phase == .failed, "nothing to show: Couldn't load this page")
        await page.load()   // Try again
        #expect(page.phase == .loaded && page.sections.albums.map(\.title) == ["Kept"])
        await page.load(fresh: true)   // a pull to refresh that meets the silent source
        #expect(page.phase == .loaded && page.sections.albums.map(\.title) == ["Kept"], "what was shown stays")
        model.signOut()
    }

    /// Item 5: a cover the Cover Art Archive doesn't have comes from Lidarr's album lookup (after the album's releases);
    /// never the placeholder while a source has one.
    @Test func everyAlbumFillsThroughTheFallbacks() async throws {
        let model = try await signedIn()
        try await withLidarr(model)
        let fresh = MockTransport()
        fresh.stub(pathSuffix: "/front-250") { _ in .init(status: 404, body: Data()) }
        fresh.stub(pathSuffix: "/lidarr-cover.jpg", body: Self.png)
        AppModel.outsideArtTransportForTesting = fresh
        defer { AppModel.outsideArtTransportForTesting = outside }
        transport.inner.stub(pathSuffix: "/api/v1/album/lookup", body: Data(#"""
        [{"title":"T","foreignAlbumId":"\#(rg.rawValue)","images":[{"coverType":"cover","url":"/MediaCoverProxy/x/cover.jpg","remoteUrl":"https://images.lidarr.audio/cache/lidarr-cover.jpg"}]}]
        """#.utf8))
        let loader = model.makeOutsideArt()
        #expect(await loader.image(.releaseGroup(rg)) != nil, "Lidarr's named cover, last before the placeholder")
        #expect(fresh.requests.first?.url?.absoluteString == "https://coverartarchive.org/release-group/\(rg.rawValue)/front-250")
        #expect(fresh.requests.last?.url?.absoluteString == "https://images.lidarr.audio/cache/lidarr-cover.jpg")
        model.signOut()
    }
}
