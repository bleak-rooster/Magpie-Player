import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
import Search
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let monitoredMBID = MBID("22222222-2222-4222-8222-222222222222")!
private let unmonitoredMBID = MBID("33333333-3333-4333-8333-333333333333")!
private let strangerMBID = MBID("44444444-4444-4444-8444-444444444444")!

/// Round 25 I (owner, 2026-11-10; D247–D250): an artist page's Top songs from Aurral or ListenBrainz show only the
/// library's songs when Lidarr monitors the artist and "In your library only, for artists in Lidarr" is on (the
/// default); off, an artist not in Lidarr, Lidarr's answer not known, or no Lidarr: every song, as before. The setting
/// shows only with Lidarr.
@MainActor @Suite(.serialized) struct TopSongsInLibraryAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!
    let data = FileManager.default.temporaryDirectory.appending(path: "TopSongsInLibraryAppTests-\(UUID().uuidString)")

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"""
        [{"id":20,"artistName":"Harbour Band","foreignArtistId":"22222222-2222-4222-8222-222222222222","monitored":true,"tags":[]},
         {"id":21,"artistName":"Quiet Band","foreignArtistId":"33333333-3333-4333-8333-333333333333","monitored":false,"tags":[]}]
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/command", body: Data("[]".utf8))
    }

    func makeModel(lidarr: Bool) throws -> AppModel {
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "key")) }
        return AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                        dataDirectory: data, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                        engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        try? FileManager.default.removeItem(at: data)
    }

    /// Five top songs; the second, fourth and fifth are in the library.
    func result(_ provider: TopSongsProvider = .aurral) -> TopSongsResult {
        let owned: Set<Int> = [1, 3, 4]
        let rows = (0..<5).map { i in
            TopSongRow(id: i, song: OutsideSong(title: "Song \(i)", artist: "Harbour Band", duration: 200),
                       library: owned.contains(i) ? Song(id: "lib-\(i)", title: "Song \(i)", artist: "Harbour Band",
                                                         album: "A", duration: 200) : nil,
                       preview: nil)
        }
        return TopSongsResult(provider: provider, rows: rows, fellBack: false)
    }

    @Test func onByDefaultAMonitoredArtistShowsOnlyTheLibrarysSongsInOrder() throws {
        let model = try makeModel(lidarr: true)
        defer { cleanUp(model) }
        #expect(model.preferences.layout.topSongsInLibraryOnly)
        for provider in [TopSongsProvider.aurral, .listenBrainz] {
            let shown = model.shownTopSongs(result(provider), lidarr: .monitored(lidarrId: 20, searching: false))
            #expect(shown.rows.map(\.id) == [1, 3, 4])
            #expect(shown.rows.allSatisfy { $0.library != nil } && shown.provider == provider)
        }
        let searching = model.shownTopSongs(result(), lidarr: .monitored(lidarrId: 20, searching: true))
        #expect(searching.rows.map(\.id) == [1, 3, 4], "searching for albums is still monitored")
    }

    /// Controller ruling (D249): a find the owner kept is in the main library, monitored: filtered. A find on trial
    /// (in your Finds, or being added) shows every song.
    @Test func aKeptFindIsFilteredAndATrialFindShowsEverything() throws {
        let model = try makeModel(lidarr: true)
        defer { cleanUp(model) }
        for lossless in [FindState.Lossless.lossless, .waiting(removedOn: nil), .mp3Removed] {
            let kept = model.shownTopSongs(result(), lidarr: .find(lidarrId: 30, state: .inLibrary(lossless)))
            #expect(kept.rows.map(\.id) == [1, 3, 4])
        }
        for trial in [FindState.find, .adding(queued: true), .adding(queued: false)] {
            #expect(model.shownTopSongs(result(), lidarr: .find(lidarrId: 30, state: trial)) == result())
        }
        model.updatePreferences { $0.layout.topSongsInLibraryOnly = false }
        #expect(model.shownTopSongs(result(), lidarr: .find(lidarrId: 30, state: .inLibrary(.lossless))) == result(),
                "off: every song")
    }

    @Test func offShowsEverySongWithPreviews() throws {
        let model = try makeModel(lidarr: true)
        defer { cleanUp(model) }
        model.updatePreferences { $0.layout.topSongsInLibraryOnly = false }
        let shown = model.shownTopSongs(result(), lidarr: .monitored(lidarrId: 20, searching: false))
        #expect(shown == result())
    }

    @Test func notInLidarrNotMonitoredAFindOrNotKnownShowsEverything() throws {
        let model = try makeModel(lidarr: true)
        defer { cleanUp(model) }
        let states: [ArtistLidarrState?] = [nil, .notInLidarr(mbid: strangerMBID), .notInLidarr(mbid: nil),
                                            .notMonitored(lidarrId: 21, magpieAdded: false), .unmatched,
                                            .find(lidarrId: 30, state: .find)]
        for state in states {
            #expect(model.shownTopSongs(result(), lidarr: state) == result(), "\(String(describing: state))")
        }
    }

    @Test func withoutLidarrEverythingShowsAndTheSettingIsHidden() throws {
        let model = try makeModel(lidarr: false)
        defer { cleanUp(model) }
        #expect(!ArtistTopSongsView.offersLibraryOnly(model), "no dead switch without Lidarr")
        #expect(model.shownTopSongs(result(), lidarr: .monitored(lidarrId: 20, searching: false)) == result())
        let with = try makeModel(lidarr: true)
        #expect(ArtistTopSongsView.offersLibraryOnly(with))
        with.signOut()
    }

    @Test func theLibrarysOwnListIsUnchanged() throws {
        let model = try makeModel(lidarr: true)
        defer { cleanUp(model) }
        #expect(model.shownTopSongs(result(.library), lidarr: .monitored(lidarrId: 20, searching: false)) == result(.library))
    }

    @Test func theCopy() {
        #expect(TopSongsInLibraryCopy.toggle == "In your library only, for artists in Lidarr")
        #expect(TopSongsInLibraryCopy.footer == "For an artist Lidarr looks after, show only the songs you already have. Off shows every top song, with previews for the ones you don\u{2019}t have.")
        #expect(TopSongsInLibraryCopy.noneInLibrary == "None of their top songs are in your library yet.")
        #expect(TopSongsInLibraryCopy.noneSymbol == "music.note.list")
    }

    /// Through the artist page's own Lidarr line: everything while Lidarr's answer isn't known, then only the library's
    /// songs once it says monitored; an unmonitored artist keeps everything. Lidarr is only read (GETs).
    @Test func filtersOnceTheArtistPagesLidarrLineKnows() async throws {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(
            base: lidarrBase, scope: LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope,
            fastStartProfileId: 4, findsMetadataProfileId: 3, magpieTagId: 1, losslessProfileId: 7, rootFolderPath: "/music"))
        let model = try makeModel(lidarr: false)
        defer { cleanUp(model) }
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")

        let line = ArtistLidarrModel(model: model, name: "Harbour Band", mbid: monitoredMBID)
        #expect(model.shownTopSongs(result(), lidarr: line.state) == result(), "not known yet: as before")
        await line.refresh()
        #expect(model.shownTopSongs(result(), lidarr: line.state).rows.map(\.id) == [1, 3, 4])

        let quiet = ArtistLidarrModel(model: model, name: "Quiet Band", mbid: unmonitoredMBID)
        await quiet.refresh()
        #expect(model.shownTopSongs(result(), lidarr: quiet.state) == result())

        let writes = transport.inner.requests.filter {
            $0.url?.path.contains("/api/v1/") == true && ($0.httpMethod ?? "GET") != "GET"
        }
        #expect(writes.isEmpty, "Lidarr is only read here")
    }
}
