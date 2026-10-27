import Foundation
import LidarrKit
import MagpieCore
import Search
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let playlistId = MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11")!
private let token = "secret-token-123"

/// The library has "Harbour Lights" by Corin Hale (232 s).
private let songPage = Data(#"""
[{"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232,"missing":false}]
"""#.utf8)
private let getSong = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232}}}
"""#.utf8)
private let createdFor = Data(#"""
{"playlists":[{"playlist":{"identifier":"https://listenbrainz.org/playlist/5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11","title":"Weekly Exploration for rob",
 "extension":{"https://musicbrainz.org/doc/jspf#playlist":{"additional_metadata":{"algorithm_metadata":{"source_patch":"weekly-exploration"}}}}}}]}
"""#.utf8)
private let playlist = Data(#"""
{"playlist":{"track":[{"title":"Harbour Lights","creator":"Corin Hale","duration":232000},
                      {"title":"Tidal","creator":"Ines Morrow","identifier":["https://musicbrainz.org/recording/4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11"]}]}}
"""#.utf8)

@MainActor
@Suite(.serialized) struct MadeForYouAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let tokens = MemoryTokenStore()

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: songPage, headers: ["X-Total-Count": "1"])
        t.stub(pathSuffix: "/rest/getSong", body: getSong)
        t.stub(pathSuffix: "/1/validate-token", body: Data(#"{"valid":true,"user_name":"rob"}"#.utf8))
        t.stub(pathSuffix: "/1/user/rob/playlists/createdfor", body: createdFor)
        t.stub(pathSuffix: "/1/playlist/\(playlistId.rawValue)", body: playlist)
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library"}]"#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: tokens, matchIndexDirectory: nil, dataDirectory: nil,
                 gateDefaultsSuite: "magpie-tests-gate-\(UUID().uuidString)", transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: UserDefaults(suiteName: UUID().uuidString)!, systemNowPlaying: false,
                 notifications: false)
    }

    private var listenBrainzRequests: [URLRequest] {
        transport.inner.requests.filter { $0.url?.host?.hasSuffix("listenbrainz.org") == true }
    }

    @Test func withoutATokenTheSectionIsAbsentAndNothingIsAsked() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(await model.madeForYouPlaylists().isEmpty)
        #expect(await model.madeForYouTracks(playlistId) == nil)
        #expect(listenBrainzRequests.isEmpty)
    }

    @Test func withATokenPlaylistsComeFromTheAPIHostOnly() async throws {
        try tokens.save(token)
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let shelf = await model.madeForYouPlaylists()
        #expect(shelf.map(\.title) == ["Weekly Exploration"])
        #expect(!listenBrainzRequests.isEmpty)
        for request in listenBrainzRequests {   // A9: the token only ever goes to api.listenbrainz.org
            #expect(request.url?.host == "api.listenbrainz.org")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token \(token)")
        }
    }

    @Test func libraryTracksArePlayableSongsTheRestAreNotYet() async throws {
        try tokens.save(token)
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()
        let rows = try #require(await model.madeForYouTracks(playlistId))
        #expect(rows.count == 2)
        guard case .library(let song) = rows[0], case .notYet(let other) = rows[1] else {
            Issue.record("unexpected rows \(rows)"); return
        }
        #expect(song.id == "s1")
        #expect(other.title == "Tidal")
        #expect(other.recordingMBID == MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11"))
    }

    @Test func artistNotYetAlbumsNeedLidarrAndOnlyRead() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let corin = Artist(id: "ar1", name: "Corin Hale", albumCount: 1, mbid: MBID("75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"))
        #expect(await model.artistNotYetAlbums(corin, library: []).isEmpty)   // no Lidarr: nothing, nothing asked
        #expect(!transport.inner.requests.contains { $0.url?.port == lidarrBase.port })

        transport.inner.stub(pathSuffix: "/api/v1/artist/lookup", body: Data(#"""
        [{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","id":7}]
        """#.utf8))
        transport.inner.stub(pathSuffix: "/api/v1/album", body: Data(#"""
        [{"id":1,"title":"Glasshouse","albumType":"Album"},{"id":2,"title":"Northern Rooms","albumType":"Album"}]
        """#.utf8))
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        let library = [Album(id: "al1", name: "Glasshouse", artist: "Corin Hale", songCount: 1, duration: 200)]
        let found = await model.artistNotYetAlbums(corin, library: library)
        #expect(found.map(\.title) == ["Northern Rooms"])
        let lidarr = transport.inner.requests.filter { $0.url?.port == lidarrBase.port }
        #expect(lidarr.contains { $0.url?.path.hasSuffix("/api/v1/artist/lookup") == true })
        #expect(lidarr.allSatisfy { $0.httpMethod == "GET" })   // read-only
    }
}
