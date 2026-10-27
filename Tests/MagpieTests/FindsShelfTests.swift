import DesignSystem
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let day: TimeInterval = 24 * 3600
private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

/// Task 6.2a: the Finds shelf (songs of the Finds library + finds on their way), days left, New finds,
/// Finds-mode Try set-up, and finds never scrobbled (D29).
@MainActor
@Suite(.serialized) struct FindsShelfTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    /// `/api/song` answers 503 (offline launch, server busy).
    let songsFail = OSAllocatedUnfairLock(initialState: false)
    /// `/api/v1/tag` lists `magpie-find` (id 2).
    let hasFindTag = OSAllocatedUnfairLock(initialState: false)

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/scrobble", body: ok)
        // Library 2 (the Finds library) holds one find; the whole library (match index) is empty here.
        let songsFail = self.songsFail, hasFindTag = self.hasFindTag
        t.stub(pathSuffix: "/api/v1/tag") { _ in
            let rows = hasFindTag.withLock { $0 } ? #"[{"id":1,"label":"magpie"},{"id":2,"label":"magpie-find"}]"# : "[]"
            return MockTransport.Response(status: 200, body: Data(rows.utf8))
        }
        t.stub(pathSuffix: "/api/song") { req in
            if songsFail.withLock({ $0 }) { return MockTransport.Response(status: 503) }
            let library = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "library_id" }?.value
            let rows = library == "2"
                ? #"[{"id":"find-1","title":"Paper Planes","artist":"Aurora Field","album":"Lowlands","duration":200,"#
                    + #""libraryId":2,"createdAt":"2026-10-26T15:00:19.667867Z"}]"#
                : "[]"
            return MockTransport.Response(status: 200, body: Data(rows.utf8), headers: ["X-Total-Count": library == "2" ? "1" : "0"])
        }
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library"},{"id":2,"path":"/music/samples"}]"#.utf8))
        t.stub(pathSuffix: "/api/library", body: Data(#"[{"id":1,"name":"Music","path":"/music/library"},{"id":2,"name":"Samples","path":"/music/samples"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/config/mediamanagement", body: Data(#"{"recycleBin":"/trash"}"#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    /// Signed in, Lidarr connected and provisioned (ids as `Provisioner` would store them), main root chosen.
    func connected() async throws -> AppModel {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        model.chooseRoot("/music/library")
        model.lidarrSetup?.fastStartProfileId = 4
        model.lidarrSetup?.findsMetadataProfileId = 3
        model.lidarrSetup?.magpieTagId = 1
        model.lidarrSetup?.findTagId = 2
        return model
    }

    /// Finds folder confirmed, its library chosen, and "Use a Finds folder" on.
    func findsSetUp(_ model: AppModel, on: Bool = true) async throws {
        let libraries = try await model.navidromeLibraries()
        try model.confirmFindsRoot("/music/samples")
        try model.chooseFindsLibrary(libraries[1], among: libraries, mapping: nil)
        model.setUseFindsFolder(on)
    }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    static func song(_ id: String, created: Date?, libraryId: Int? = 2) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: 200, libraryId: libraryId, createdAt: created)
    }

    // MARK: - The shelf

    /// Days left = 7 − whole days since the find arrived; never below 0, and nothing leaves by itself (D10).
    @Test func daysLeftCountsDownFromSeven() {
        #expect(FindsShelf.daysLeft(since: t0, now: t0) == 7)
        #expect(FindsShelf.daysLeft(since: t0, now: t0.addingTimeInterval(day - 1)) == 7)
        #expect(FindsShelf.daysLeft(since: t0, now: t0.addingTimeInterval(day)) == 6)
        #expect(FindsShelf.daysLeft(since: t0, now: t0.addingTimeInterval(6.5 * day)) == 1)
        #expect(FindsShelf.daysLeft(since: t0, now: t0.addingTimeInterval(7 * day)) == 0)
        #expect(FindsShelf.daysLeft(since: t0, now: t0.addingTimeInterval(30 * day)) == 0)
        #expect(FindsShelf.daysLeft(since: t0.addingTimeInterval(day), now: t0) == 7, "a clock behind the server")

        let old = FindsShelf(songs: [Self.song("old", created: t0)], requests: [], played: ["old"],
                             now: t0.addingTimeInterval(30 * day))
        #expect(old.finds.map(\.song.id) == ["old"], "no automatic expiry (D10)")
        #expect(old.finds.first?.state == .find(daysLeft: 0))
    }

    /// New finds = ready (in the Finds library) and not played yet. Played finds show their days left.
    @Test func newFindsAreReadyAndUnplayed() {
        let songs = [Self.song("a", created: t0), Self.song("b", created: t0.addingTimeInterval(day)),
                     Self.song("c", created: nil)]
        let shelf = FindsShelf(songs: songs, requests: [], played: ["a"], now: t0.addingTimeInterval(2 * day))
        #expect(shelf.newFinds.map(\.song.id) == ["b", "c"], "newest first; an unknown date last")
        #expect(shelf.newFinds.allSatisfy { $0.state == .newFind })
        #expect(shelf.finds.map(\.song.id) == ["a"])
        #expect(shelf.finds.first?.state == .find(daysLeft: 5))
        #expect(shelf.newFinds.first { $0.song.id == "c" }?.daysLeft == 7)
        #expect(!shelf.isEmpty)
        // Every find row is a record with a text status and a symbol (D3) and the Sample hallmark.
        for item in shelf.newFinds + shelf.finds {
            #expect(item.state.isRecord)
            #expect(!item.state.statusText.isEmpty && item.state.statusSymbol != nil)
            #expect(item.quality == .sample && Hallmark.text(for: item.quality) == "Sample")
        }
    }

    /// Finds on their way: active Finds-mode requests only. Library-bound requests aren't finds.
    @Test func onTheirWayAreActiveFindsRequests() {
        func request(_ mode: LedgerMode, _ state: RequestState) -> MagpieRequest {
            var r = MagpieRequest(recording: ExternalRecording(recordingMBID: nil, title: "S", artist: "A",
                                                               source: .listenBrainz),
                                  tier: .standard, createdAt: t0)
            r.state = state
            r.plan = Plan(recordingMBID: MBID("00000000-0000-0000-0000-000000000100")!,
                          releaseGroupMBID: MBID("00000000-0000-0000-0000-000000000010")!,
                          artistMBID: MBID("00000000-0000-0000-0000-000000000001")!, lidarrArtistId: nil, mode: mode)
            return r
        }
        let coming = request(.finds, .searching)
        let requests = [coming, request(.fallback, .searching), request(.finds, .ready), request(.finds, .cancelled)]
        let shelf = FindsShelf(songs: [], requests: requests, played: [], now: t0)
        #expect(shelf.onTheirWay.map(\.id) == [coming.id])
        #expect(FindsShelf(songs: [], requests: [], played: [], now: t0).isEmpty)
    }

    @Test func findStatusNeverPromisesAnExpiry() {
        // D10: nothing expires in v1, so the last day doesn't say it "leaves".
        #expect(RowState.find(daysLeft: 0).statusText == "Find · time to decide")
        #expect(RowState.find(daysLeft: 0).voiceOverValue == "Find, time to decide")
    }

    // MARK: - Finds-mode Try

    /// Finds mode only with "Use a Finds folder" on, the setup complete and the find tag known.
    @Test func runnerSetupUsesFindsOnlyWhenComplete() async throws {
        let model = try await connected()
        #expect(model.runnerSetup?.finds == nil)
        #expect(!model.triesGoIntoFinds)
        try await findsSetUp(model, on: false)
        #expect(model.runnerSetup?.finds == nil, "switched off: fallback")
        model.setUseFindsFolder(true)
        let setup = try #require(model.runnerSetup)
        #expect(setup.rootFolderPath == "/music/library" && setup.tagIds == [1])
        #expect(setup.finds == RequestRunner.Setup.Finds(rootFolderPath: "/music/samples", tagIds: [1, 2]))
        #expect(model.triesGoIntoFinds)
        model.lidarrSetup?.findTagId = nil   // set up before Task 6.2a: the find tag isn't known yet
        #expect(model.runnerSetup?.finds == nil)
        #expect(model.runnerSetup?.tagIds == [1], "fallback still works")
        cleanUp(model)
    }

    @Test func tryCopySaysWhereItGoes() async throws {
        let model = try await connected()
        #expect(model.tryNote == TryCopy.fallbackNote, "B8")
        try await findsSetUp(model)
        #expect(model.tryNote == TryCopy.findsNote)
        #expect(TryCopy.findsNote == "It goes into your Finds first, so you can try it before it joins your library.")
        #expect(TryCopy.findsUnavailable.contains("straight into your library"))
        cleanUp(model)
    }

    @Test func findRequestCopyNamesFinds() {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: nil, title: "S", artist: "A", source: .listenBrainz),
                              tier: .standard, createdAt: t0)
        r.state = .ready
        #expect(RequestCopy.status(r) == "Ready · in your library")
        r.plan = Plan(recordingMBID: MBID("00000000-0000-0000-0000-000000000100")!,
                      releaseGroupMBID: MBID("00000000-0000-0000-0000-000000000010")!,
                      artistMBID: MBID("00000000-0000-0000-0000-000000000001")!, lidarrArtistId: nil, mode: .finds)
        #expect(RequestCopy.status(r) == "Ready · in your Finds")
    }

    // MARK: - D29: finds are never scrobbled

    @Test func findsAreNeverScrobbled() async throws {
        let model = try await connected()
        try await findsSetUp(model)
        await model.refreshFinds()
        #expect(model.findSongs.map(\.id) == ["find-1"])

        func scrobbles() -> [String] {
            transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true }.compactMap {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            }
        }
        // By library id (native API songs), and by id for songs from album views (Subsonic has no library id).
        model.play([Self.song("other-find", created: nil, libraryId: 2)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        model.play([Self.song("find-1", created: nil, libraryId: nil)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbles().isEmpty)
        model.play([Self.song("kept", created: nil, libraryId: 1)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbles() == ["kept"])
        cleanUp(model)
    }

    func scrobbledIds() -> [String] {
        transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true }.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        }
    }

    /// Fix 6.2a-1: D29 fails closed. With a Finds library set but its songs never read (offline launch), a
    /// song without a library id (album, artist, search and playlist views) is treated as a find.
    @Test func unknownFindsFailClosed() async throws {
        let model = try await connected()
        songsFail.withLock { $0 = true }
        try await findsSetUp(model)
        await model.refreshFinds()
        model.play([Self.song("maybe-a-find", created: nil, libraryId: nil)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbledIds().isEmpty, "no now-playing, no scrobble")
        model.play([Self.song("library", created: nil, libraryId: 1)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbledIds() == ["library"], "a song known to be in another library still counts")
        cleanUp(model)
    }

    /// The Finds songs last read are kept per account and library, so a cold start knows them at once.
    @Test func savedFindIdsBlockAFindOnColdStart() async throws {
        let model = try await connected()
        try await findsSetUp(model)
        await model.refreshFinds()   // reads and saves ["find-1"]
        songsFail.withLock { $0 = true }
        let restored = makeModel()
        restored.resumeSavedSession()
        await restored.refreshFinds()   // fails: the saved ids stand
        #expect(restored.findSongs.isEmpty)
        restored.play([Self.song("find-1", created: nil, libraryId: nil)], startAt: 0)
        await restored.player.waitForPendingScrobbles()
        #expect(scrobbledIds().isEmpty)
        restored.play([Self.song("not-a-find", created: nil, libraryId: nil)], startAt: 0)
        await restored.player.waitForPendingScrobbles()
        #expect(scrobbledIds() == ["not-a-find"], "known ids: other songs scrobble as usual")
        cleanUp(restored)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(AppModel.findSongIdsKeyPrefix) },
                "sign-out forgets them")
    }

    /// The seed alone (written before any read this launch) blocks a find.
    @Test func seedAloneBlocksAFind() async throws {
        let model = try await connected()
        songsFail.withLock { $0 = true }
        let scope = try #require(model.navidromeScope)
        defaults.set(["seeded-find"], forKey: AppModel.findSongIdsKey(scope, libraryId: 2))
        try await findsSetUp(model)
        model.play([Self.song("seeded-find", created: nil, libraryId: nil)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbledIds().isEmpty)
        model.play([Self.song("other", created: nil, libraryId: nil)], startAt: 0)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbledIds() == ["other"])
        cleanUp(model)
    }

    // MARK: - Fix 6.2a-2: a Lidarr set up in M5 (no magpie-find id)

    /// The audit finds the tag by name (read-only) and saves its id.
    @Test func auditAdoptsFindTag() async throws {
        hasFindTag.withLock { $0 = true }
        let model = try await connected()
        model.lidarrSetup?.findTagId = nil
        _ = await model.lidarrAudit()
        #expect(model.lidarrSetup?.findTagId == 2)
        #expect(transport.inner.requests.filter { $0.url?.port == 8686 }.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        try await findsSetUp(model)
        #expect(model.findsStatus == .on)
        #expect(model.triesGoIntoFinds)
        cleanUp(model)
    }

    /// No tag yet: Finds says it isn't finished and how to finish it; fallback Try keeps working.
    @Test func missingFindTagSaysSetUpAgain() async throws {
        let model = try await connected()
        model.lidarrSetup?.findTagId = nil
        _ = await model.lidarrAudit()
        #expect(model.findsStatus == .off)
        try await findsSetUp(model)
        #expect(model.findsSetup?.isComplete == true)
        #expect(model.findsStatus == .needsSetUpAgain)
        #expect(model.findsStatus.summary == "Not finished")
        #expect(model.findsStatus.footer == FindsCopy.setUpAgain)
        #expect(FindsCopy.setUpAgain == "Tap \u{2018}Set up Magpie in Lidarr\u{2019} again to start using your Finds folder.")
        #expect(model.lidarrSetup?.isProvisioned == true, "fallback Try isn't blocked")
        #expect(model.runnerSetup != nil && !model.triesGoIntoFinds)
        model.setUseFindsFolder(false)
        #expect(model.findsStatus == .off && model.findsStatus.summary == "Off")
        cleanUp(model)
    }

    /// Playing a find makes it no longer new; the played set survives a relaunch.
    @Test func playingAFindMarksItPlayed() async throws {
        let model = try await connected()
        try await findsSetUp(model)
        await model.refreshFinds()
        #expect(model.findsShelf().newFinds.map(\.song.id) == ["find-1"])
        model.play(model.findSongs, startAt: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.findsShelf().newFinds.isEmpty)
        #expect(model.findsShelf().finds.map(\.song.id) == ["find-1"])
        let restored = makeModel()
        restored.resumeSavedSession()
        #expect(restored.playedFinds.contains("find-1"))
        cleanUp(model)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(AppModel.playedFindsKeyPrefix) },
                "sign-out forgets which finds were played")
    }
}
