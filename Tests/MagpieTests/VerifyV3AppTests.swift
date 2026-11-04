import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope

/// Verify V3: FLOWS.md §3f (landing) and §3i (CarPlay search) claims that had no app-level test of their own.
/// Stubbed transport only; no server is contacted.
@MainActor
@Suite(.serialized) struct VerifyV3AppTests {
    let transport = GatedTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library"}]"#.utf8))
        t.stub(pathSuffix: "/rest/getSong", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"jt-1","title":"Stay With Me Till Dawn","artist":"Judie Tzuke","album":"Welcome to the Cruise","duration":240}}}
        """#.utf8))
        t.stub(pathSuffix: "/rest/search3", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
          "song":[{"id":"jt-1","title":"Stay With Me Till Dawn","artist":"Judie Tzuke","album":"Welcome to the Cruise","duration":240}],
          "album":[{"id":"al-1","name":"Welcome to the Cruise","artist":"Judie Tzuke","songCount":1,"duration":240}]}}}
        """#.utf8))
        // Outside: an artist and an album from Lidarr's search, and (round 14, A5) the album's song that matches, from
        // its tracklist on MusicBrainz. ListenBrainz labs is only the backup when Lidarr has no album.
        t.stub(pathSuffix: "/ws/2/release", body: Data(#"""
        {"release-count":1,"releases":[{"id":"5c0b9a3e-6a55-4f0e-9a43-36f1c1b7f0a1","title":"Red Room Sessions","status":"Official",
         "media":[{"position":1,"tracks":[
          {"position":1,"title":"Song for Judie","length":200000,"recording":{"id":"7d3c4a7e-2c1f-4e7b-8f0d-3a9b6c5d4e21"}},
          {"position":2,"title":"Red Room","length":210000,"recording":{"id":"8e4d5b8f-3d2a-4f8c-9a1e-4b0c7d6e5f32"}}]}]}]}
        """#.utf8))
        t.stub(pathSuffix: "/recording-search/json", body: Data(#"""
        [{"recording_name":"Harbour Wall","recording_mbid":"4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11","artist_credit_name":"Ines Morrow"}]
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/search", body: Data(#"""
        [{"foreignId":"64db764c-2251-4f95-aa40-10fc91d509d8","artist":{"artistName":"Hollis Gray","foreignArtistId":"64db764c-2251-4f95-aa40-10fc91d509d8"}},
         {"foreignId":"01a340b4-1d99-4083-ad92-fa2803368bed","album":{"title":"Red Room Sessions","albumType":"Album","artist":{"artistName":"Hollis Gray"}}}]
        """#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    func ready() async throws -> AppModel {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1))
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        return model
    }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    static func readyRequest(_ tier: Tier) -> MagpieRequest {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: nil, title: "Stay With Me Till Dawn",
                                                           artist: "Judie Tzuke", source: .listenBrainz),
                              tier: tier, createdAt: Date())
        r.state = .ready
        r.songId = "jt-1"
        return r
    }

    /// §3f Landing: "Patient requests don't land: they just appear in the library or Finds." A Standard request
    /// that becomes ready (not on its wait screen) goes next with the Play now banner; a Patient one leaves the
    /// player alone.
    @Test func patientRequestsNeverLandStandardOnesDo() async throws {
        let model = try await ready()
        let patient = Self.readyRequest(.patient)
        await model.land(patient)
        #expect(model.player.queue.current == nil && model.player.queue.upNext.isEmpty)
        #expect(model.playNowBanner == nil)
        #expect(!model.landedRequests.contains(patient.id))

        let standard = Self.readyRequest(.standard)
        await model.land(standard)
        #expect(model.player.queue.current?.song.id == "jt-1" || model.player.queue.upNext.first?.song.id == "jt-1")
        #expect(!model.player.isPlaying, "not on its wait screen: never starts by itself")
        #expect(model.playNowBanner?.request == standard.id)
        cleanUp(model)
    }

    /// §3i Search: "Search in the car gives library songs and albums, then outside songs only." Lidarr's artist and
    /// album rows, which the phone shows in its band, are not offered in the car.
    @Test func carSearchOffersOutsideSongsOnly() async throws {
        let model = try await ready()
        let phone = try await model.mergedSearch().runReportingLibraryFailure("Judie")
        #expect(phone.notYet.artists.map(\.name) == ["Hollis Gray"] && phone.notYet.albums.map(\.title) == ["Red Room Sessions"],
                "the phone's band has them")

        let car = try await model.carPlaySearch("Judie")
        #expect(car.library.songs.map(\.id) == ["jt-1"])
        #expect(car.library.albums.map(\.id) == ["al-1"])
        #expect(car.library.artists.isEmpty)
        // Fix round 1 (I3): the car keeps ListenBrainz's songs beside the album's tracklist song.
        #expect(Set(car.notYet.map(\.title)) == ["Harbour Wall", "Song for Judie"])
        cleanUp(model)
    }
}
