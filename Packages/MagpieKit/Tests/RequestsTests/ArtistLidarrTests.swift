import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Requests

/// P3: an artist page's Lidarr line, "Add to Lidarr and download" and "Monitor", over a scripted Lidarr. Writes only
/// through the gate; the owner's artists are never written.
@Suite struct ArtistLidarrTests {
    static let base = URL(string: "http://127.0.0.1:8686")!
    static let newMBID = MBID("11111111-1111-4111-8111-111111111111")!
    static let ownerMBID = MBID("22222222-2222-4222-8222-222222222222")!
    static let magpieMBID = MBID("33333333-3333-4333-8333-333333333333")!
    static let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: 7, metadataProfileId: 8,
                                           tagIds: [3])

    struct Fake {
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger
        let gate: LidarrWriteGate

        init(artists: String = "[]", changesOn: Bool = true, magpieLedger: Bool = true) async throws {
            client = LidarrClient(base: ArtistLidarrTests.base, apiKey: "devkey", transport: transport)
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            let dir = FileManager.default.temporaryDirectory.appending(path: "ArtistLidarr-\(UUID().uuidString)")
            gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"),
                                   defaultsSuite: "ArtistLidarrTests.\(UUID().uuidString)",
                                   confinement: WriteConfinement(ledger: ledger, roots: {
                                       WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
                                   }))
            await gate.setEnabled(changesOn)
            if magpieLedger {
                try await ledger.record(LedgerEntry(lidarrArtistId: 30, albumId: nil, rgMbid: ArtistLidarrTests.magpieMBID,
                                                    createdArtist: true, wasMonitoredBefore: false, root: "/music/library",
                                                    mode: .fallback, send: .applied,
                                                    artistMbid: ArtistLidarrTests.magpieMBID))
            }
            transport.stub(pathSuffix: "/api/v1/artist", body: Data(artists.utf8))
            transport.stub(pathSuffix: "/api/v1/command", body: Data("[]".utf8))
            transport.stub(pathSuffix: "/api/v1/artist/lookup", body: Data(#"""
            [{"foreignArtistId":"11111111-1111-4111-8111-111111111111","artistName":"New Artist","id":0,
              "rootFolderPath":"/owner/elsewhere","qualityProfileId":1,"monitored":false,"addOptions":{"monitor":"none"}}]
            """#.utf8))
            transport.stub(pathSuffix: "/api/v1/artist/20", body: Data(Self.artist(20, "Owner", ArtistLidarrTests.ownerMBID, false).utf8))
            transport.stub(pathSuffix: "/api/v1/artist/30", body: Data(Self.artist(30, "Mine", ArtistLidarrTests.magpieMBID, false).utf8))
            transport.stub(method: "POST", pathSuffix: "/api/v1/artist", body: Data(#"{"id":55}"#.utf8))
            transport.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor", body: Data("[]".utf8))
            transport.stub(method: "POST", pathSuffix: "/api/v1/command", body: Data(#"{"id":9}"#.utf8))
        }

        static func artist(_ id: Int, _ name: String, _ mbid: MBID, _ monitored: Bool) -> String {
            #"{"id":\#(id),"artistName":"\#(name)","foreignArtistId":"\#(mbid.rawValue)","monitored":\#(monitored),"tags":[]}"#
        }

        var writes: [URLRequest] { transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" } }
    }

    static func lidarrArtist(_ id: Int, _ name: String, _ mbid: MBID?, monitored: Bool) -> LidarrArtist {
        LidarrArtist(id: id, artistName: name, foreignArtistId: mbid, monitored: monitored)
    }

    static func search(_ id: Int, _ name: String, artistIds: [Int], status: String = "started") -> CommandStatus {
        try! JSONDecoder().decode(CommandStatus.self, from: Data(#"""
        {"id":\#(id),"name":"\#(name)","status":"\#(status)","body":{"artistId":\#(artistIds.first ?? 0)}}
        """#.utf8))
    }

    // MARK: - Status

    @Test func statusMapsEveryState() {
        let owner = Self.lidarrArtist(20, "Owner", Self.ownerMBID, monitored: false)
        let mine = Self.lidarrArtist(30, "Mine", Self.magpieMBID, monitored: false)
        let watched = Self.lidarrArtist(40, "Watched", MBID("44444444-4444-4444-8444-444444444444")!, monitored: true)
        let ledger = [LedgerEntry(lidarrArtistId: 30, albumId: nil, rgMbid: Self.magpieMBID, createdArtist: true,
                                  wasMonitoredBefore: false, root: "/music/library", mode: .fallback,
                                  artistMbid: Self.magpieMBID)]
        let all = [owner, mine, watched]
        func state(_ name: String, _ mbid: MBID?, commands: [CommandStatus] = []) -> ArtistLidarrState {
            ArtistLidarr.state(name: name, mbid: mbid, artists: all, commands: commands, ledger: ledger)
        }
        #expect(state("Watched", watched.foreignArtistId) == .monitored(lidarrId: 40, searching: false))
        #expect(state("Watched", watched.foreignArtistId, commands: [Self.search(1, "MissingAlbumSearch", artistIds: [40])])
                == .monitored(lidarrId: 40, searching: true))
        #expect(state("Watched", watched.foreignArtistId, commands: [Self.search(1, "ArtistSearch", artistIds: [40], status: "completed")])
                == .monitored(lidarrId: 40, searching: false))
        #expect(state("Owner", Self.ownerMBID) == .notMonitored(lidarrId: 20, magpieAdded: false))
        #expect(state("Mine", Self.magpieMBID) == .notMonitored(lidarrId: 30, magpieAdded: true))
        #expect(state("New Artist", Self.newMBID) == .notInLidarr(mbid: Self.newMBID))
        // By name when the library has no MBID: the match index's normalised name, one Lidarr artist only.
        #expect(state("watched!", nil) == .monitored(lidarrId: 40, searching: false))
        #expect(state("Nobody", nil) == .notInLidarr(mbid: nil))
        // An MBID decides: a same-named artist with another MBID isn't this one.
        #expect(state("Owner", Self.newMBID) == .notInLidarr(mbid: Self.newMBID))
        let twins = [Self.lidarrArtist(1, "Twin", nil, monitored: true), Self.lidarrArtist(2, "Twin", nil, monitored: false)]
        #expect(ArtistLidarr.state(name: "Twin", mbid: nil, artists: twins, commands: [], ledger: []) == .notInLidarr(mbid: nil))
        // A ledger entry with the same id but another MBID (Lidarr reused the id) doesn't make it Magpie's.
        let reused = Self.lidarrArtist(30, "Other", Self.ownerMBID, monitored: false)
        #expect(ArtistLidarr.state(name: "Other", mbid: Self.ownerMBID, artists: [reused], commands: [], ledger: ledger)
                == .notMonitored(lidarrId: 30, magpieAdded: false))
    }

    @Test func readFindsTheMBIDByNameWhenTheLibraryHasNone() async throws {
        let fake = try await Fake()
        fake.transport.stub(pathSuffix: "/api/v1/search", body: Data(#"""
        [{"foreignId":"11111111-1111-4111-8111-111111111111","artist":{"artistName":"New Artist","foreignArtistId":"11111111-1111-4111-8111-111111111111"}}]
        """#.utf8))
        let state = try await ArtistLidarr.read(name: "New Artist", mbid: nil, lidarr: fake.client, ledger: fake.ledger)
        #expect(state == .notInLidarr(mbid: Self.newMBID))
        #expect(fake.writes.isEmpty)
    }

    // MARK: - Add

    @Test func addPostsThroughTheGateAndLedgersTheArtistAsMagpies() async throws {
        let fake = try await Fake()
        let id = try await ArtistLidarr.add(mbid: Self.newMBID, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger,
                                            setup: Self.setup)
        #expect(id == 55)
        let post = try #require(fake.writes.first)
        #expect(fake.writes.count == 1)
        #expect(post.httpMethod == "POST" && post.url?.path == "/api/v1/artist")
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["rootFolderPath"] as? String == "/music/library")
        #expect(body["qualityProfileId"] as? Int == 7 && body["metadataProfileId"] as? Int == 8)
        #expect(body["tags"] as? [Int] == [3])
        #expect(body["monitored"] as? Bool == true)
        #expect(body["id"] == nil)
        let options = try #require(body["addOptions"] as? [String: Any])
        #expect(options["monitor"] as? String == "all" && options["searchForMissingAlbums"] as? Bool == true)
        let added = Self.lidarrArtist(55, "New Artist", Self.newMBID, monitored: true)
        #expect(try await fake.ledger.createdArtist(added))
        #expect(await fake.gate.changeLog().count == 1)
    }

    @Test func addWithChangesOffWritesNothing() async throws {
        let fake = try await Fake(changesOn: false)
        await #expect(throws: ArtistLidarrError.changesOff) {
            try await ArtistLidarr.add(mbid: Self.newMBID, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger,
                                       setup: Self.setup)
        }
        #expect(fake.writes.isEmpty)
    }

    /// The owner added the artist meanwhile: Magpie writes nothing to it.
    @Test func addOfAnArtistLidarrHasNowWritesNothing() async throws {
        let fake = try await Fake(artists: "[" + Fake.artist(20, "Owner", Self.newMBID, true) + "]")
        await #expect(throws: ArtistLidarrError.alreadyInLidarr) {
            try await ArtistLidarr.add(mbid: Self.newMBID, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger,
                                       setup: Self.setup)
        }
        #expect(fake.writes.isEmpty)
        #expect(try await fake.ledger.entries.count == 1, "only the fixture's entry")
    }

    // MARK: - Monitor (owner-data rule)

    @Test func anExistingNonMagpieArtistIsNeverWritten() async throws {
        let fake = try await Fake()
        await #expect(throws: ArtistLidarrError.notMagpies) {
            try await ArtistLidarr.monitor(lidarrId: 20, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger)
        }
        #expect(fake.writes.isEmpty)
        // Even straight at the gate, the owner's artist can't be monitored.
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "artist/editor", body: JSONValue.object([
                "artistIds": .array([.int(20)]), "monitored": .bool(true)]))
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func monitorsAnArtistMagpieAddedAndSearches() async throws {
        let fake = try await Fake()
        try await ArtistLidarr.monitor(lidarrId: 30, lidarr: fake.client, gate: fake.gate, ledger: fake.ledger)
        #expect(fake.writes.map { "\($0.httpMethod!) \($0.url!.path)" }
                == ["PUT /api/v1/artist/editor", "POST /api/v1/command"])
        let body = try #require(fake.writes.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["artistIds"] as? [Int] == [30] && body["monitored"] as? Bool == true && body.count == 2)
    }
}
