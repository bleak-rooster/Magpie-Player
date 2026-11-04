import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Search
import Testing
@testable import Magpie

/// Aurral (stub) on its host; Navidrome, Lidarr, ListenBrainz and MusicBrainz to the mock (never the internet).
final class CombinedSearchRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let inner = MockTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        return try await inner.send(request)
    }
}

private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let pingOK = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
/// The library has "Harbour Lights" by Corin Hale (232 s), which `search3` finds for "harbour".
private let songPage = Data(#"""
[{"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232,"missing":false},
 {"id":"s2","title":"Harbour Bells","artist":"Corin Hale","album":"Bells","duration":181,"missing":false}]
"""#.utf8)
private let search3 = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[
 {"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232}]}}}
"""#.utf8)
private let labs = Data(#"""
[{"recording_name":"Harbour Song From LB","recording_mbid":"4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11","artist_credit_name":"Ines Morrow"}]
"""#.utf8)
/// Lidarr's search: the artist Ines Morrow and her album "Harbour" (release group 1111…).
private let lidarrSearch = Data(#"""
[{"foreignId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","artist":{"artistName":"Ines Morrow","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}},
 {"foreignId":"11111111-1111-4111-8111-111111111111","album":{"title":"Harbour","albumType":"Album",
   "artist":{"artistName":"Ines Morrow","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}}}]
"""#.utf8)
/// The album's release on MusicBrainz: "Harbour Wall" matches "harbour"; "Low Tide" doesn't; "Harbour Bells" is the
/// library's (same artist? no: another artist's song of that name, so it stays outside).
private let release = Data(#"""
{"release-count":1,"releases":[{"id":"22222222-2222-4222-8222-222222222222","title":"Harbour","date":"2020","status":"Official",
 "media":[{"position":1,"tracks":[
  {"position":1,"title":"Harbour Wall","length":201000,"recording":{"id":"33333333-3333-4333-8333-333333333333"}},
  {"position":2,"title":"Low Tide","length":190000,"recording":{"id":"44444444-4444-4444-8444-444444444444"}}]}]}]}
"""#.utf8)

/// Round 14 A5 (owner answer 5, plan's four setups): what Search asks and shows with Navidrome only, with Lidarr, with
/// Aurral, and with all three.
@MainActor @Suite(.serialized) final class CombinedSearchSetupsTests {
    let transport = CombinedSearchRouting()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "CombinedSearchSetupsTests.\(UUID().uuidString)"
    var aurral: StubAurral { transport.aurral }
    var mock: MockTransport { transport.inner }
    /// Lidarr's search finds no album (only the artist).
    let lidarrHasNoAlbum = OSAllocatedUnfairLock(initialState: false)

    init() {
        mock.stub(pathSuffix: "/rest/ping", body: pingOK)
        mock.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        mock.stub(pathSuffix: "/api/song", body: songPage, headers: ["X-Total-Count": "2"])
        mock.stub(pathSuffix: "/rest/search3", body: search3)
        mock.stub(pathSuffix: "/recording-search/json", body: labs)
        mock.stub(pathSuffix: "/api/v1/system/status",
                  body: Data(#"{"version":"3.2.0.4999","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        mock.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library","freeSpace":1000000000}]"#.utf8))
        let noAlbum = lidarrHasNoAlbum
        mock.stub(pathSuffix: "/api/v1/search") { _ in
            .init(status: 200, body: noAlbum.withLock { $0 } ? Data(#"[]"#.utf8) : lidarrSearch, headers: [:])
        }
        mock.stub(pathSuffix: "/ws/2/release", body: release)
        aurral.useAurral213()
    }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func model(lidarr: Bool, aurral useAurral: Bool) async throws -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: MemoryAurralStore(), matchIndexDirectory: nil, dataDirectory: nil,
                             transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: suite)!, systemNowPlaying: false)
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.matchIndexSettled()
        if lidarr { _ = try await model.connectLidarr(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "key") }
        if useAurral {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
            #expect(model.aurralCapabilities.search)
        }
        mark()
        return model
    }

    var mockMark = 0, aurralMark = 0
    /// What was asked from here on counts.
    func mark() { mockMark = mock.requests.count; aurralMark = aurral.asked.count }
    func asked(_ suffix: String) -> Int {
        mock.requests.dropFirst(mockMark).filter { $0.url?.path.hasSuffix(suffix) == true }.count
    }
    var aurralSearches: Int { aurral.asked.dropFirst(aurralMark).filter { $0 == "GET /api/search" }.count }

    @Test func navidromeOnlyIsTheLibraryOnly() async throws {
        let model = try await model(lidarr: false, aurral: false)
        let s = await model.mergedSearch().run("harbour")
        #expect(s.songs.map(\.title) == ["Harbour Lights"])
        #expect(s.notYet.isEmpty)
        #expect(asked("/recording-search/json") == 0 && asked("/api/v1/search") == 0 && asked("/ws/2/release") == 0)
        #expect(aurralSearches == 0)
        #expect(!model.searchLooksOutside)
    }

    @Test func withLidarrSongsComeFromItsAlbumsTracklists() async throws {
        let model = try await model(lidarr: true, aurral: false)
        let s = await model.mergedSearch().run("harbour")
        #expect(s.songs.map(\.title) == ["Harbour Lights"])
        #expect(s.notYet.songs.map(\.title) == ["Harbour Wall"], "Low Tide doesn't match; ListenBrainz isn't asked")
        #expect(s.notYet.songs.first?.recordingMBID == MBID("33333333-3333-4333-8333-333333333333"))
        #expect(s.notYet.artists.map(\.name) == ["Ines Morrow"])
        #expect(s.notYet.albums.map(\.title) == ["Harbour"])
        #expect(asked("/api/v1/search") == 1, "one Lidarr search for both its rows and the songs")
        #expect(asked("/ws/2/release") == 1)
        #expect(asked("/recording-search/json") == 0)
        #expect(aurralSearches == 0)
        #expect(model.searchLooksOutside)
    }

    /// Fix round 1 (I3, controller's ruling): the car keeps today's ListenBrainz songs. On its short deadline they race
    /// the tracklist read, and whatever answers in time shows.
    @Test func theCarKeepsListenBrainzSongsBesideTheTracklists() async throws {
        let model = try await model(lidarr: true, aurral: false)
        let car = try await model.carPlaySearch("harbour")
        #expect(car.notYet.map(\.title).contains("Harbour Song From LB"))
        #expect(asked("/recording-search/json") == 1)
        // The phone keeps ListenBrainz as the backup only.
        mark()
        _ = await model.mergedSearch().run("harbour")
        #expect(asked("/recording-search/json") == 0)
    }

    @Test func withLidarrButNoAlbumHitListenBrainzIsTheBackup() async throws {
        lidarrHasNoAlbum.withLock { $0 = true }
        let model = try await model(lidarr: true, aurral: false)
        let s = await model.mergedSearch().run("harbour")
        #expect(s.notYet.songs.map(\.title) == ["Harbour Song From LB"])
        #expect(asked("/ws/2/release") == 0)
    }

    @Test func withAurralArtistsAndAlbumsComeFromItsSearch() async throws {
        let model = try await model(lidarr: false, aurral: true)
        let search = model.mergedSearch()
        var s = await search.run("harbour")
        #expect(s.notYet.songs.isEmpty, "no song search without Lidarr")
        #expect(s.notYet.artists.count == MergedSearch.limits.artists)
        #expect(s.notYet.albums.count == MergedSearch.limits.albums)
        #expect(aurralSearches == 2)
        #expect(asked("/recording-search/json") == 0 && asked("/api/v1/search") == 0)
        // Load more: what's queued, then Aurral's next page.
        while s.hasMoreOutside(.artists) { s.append(try await search.moreOutside(.artists, in: s)) }
        #expect(s.notYet.artists.count == 30, "the stub has 30")
        #expect(aurralSearches == 3)
    }

    @Test func allThreeMergeByMBID() async throws {
        let model = try await model(lidarr: true, aurral: true)
        let s = await model.mergedSearch().run("harbour")
        #expect(s.notYet.songs.map(\.title) == ["Harbour Wall"])
        // Aurral's artists match "harbour" better: Lidarr's Ines Morrow waits for More.
        let artists = s.notYet.artists + (s.outside?.queued.artists ?? [])
        #expect(artists.contains { $0.name == "Ines Morrow" })
        #expect(s.notYet.artists.contains { $0.name.hasPrefix("harbour") })
        #expect(s.notYet.albums.contains { $0.title == "Harbour" })
        #expect(aurralSearches == 2 && asked("/api/v1/search") == 1)
    }

    @Test func anAurralThatIsDownLeavesLidarrsRows() async throws {
        let model = try await model(lidarr: true, aurral: true)
        aurral.setDown(true)
        let s = await model.mergedSearch().run("harbour")
        #expect(s.notYet.artists.map(\.name) == ["Ines Morrow"])
        #expect(s.notYet.songs.map(\.title) == ["Harbour Wall"])
    }

    @Test func aurral210KeepsTodaysSearch() async throws {
        aurral.setVersion("2.10.0")
        aurral.setFeatures(nil)
        let model = try await model(lidarr: false, aurral: false)
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                          password: StubAurral.defaultPassword)
        #expect(!model.aurralCapabilities.search)
        mark()
        _ = await model.mergedSearch().run("harbour")
        #expect(aurralSearches == 0)
    }
}
