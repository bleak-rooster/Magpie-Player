import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

@Suite struct ClientTests {
    @Test func keepsBasePathSendsKeyAndOnlyGets() async throws {
        let (client, t) = makeClient(auditTransport())
        _ = await LidarrAudit.run(client)
        _ = try? await client.filesystemExists(path: "/music/library/x")
        #expect(!t.requests.isEmpty)
        for r in t.requests {
            #expect(r.httpMethod == "GET")
            #expect(r.value(forHTTPHeaderField: "X-Api-Key") == testKey)
            #expect(r.url!.path.hasPrefix("/lidarr/api/v1/"))
            #expect(r.httpBody == nil)
        }
    }

    @Test func unauthorizedIsDistinguished() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/system/status", status: 401)
        let (client, _) = makeClient(t)
        await #expect(throws: LidarrError.unauthorized) { try await client.status() }
    }

    @Test func artistLookupUsesLidarrPrefixedMBID() async throws {
        let mbid = MBID("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")!
        let t = MockTransport()
        t.stub(pathSuffix: "/artist/lookup", body: Fixtures.data("artist-lookup"))
        let (client, _) = makeClient(t)
        let hit = try await client.artistLookup(mbid: mbid)
        #expect(hit?.artistName == "The Beatles")
        #expect(hit?.foreignArtistId == mbid)
        #expect(hit?.id == nil)
        let term = t.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "term" }?.value
        #expect(term == "lidarr:b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")

        let other = MBID("00000000-0000-4000-8000-000000000000")!
        #expect(try await client.artistLookup(mbid: other) == nil)
    }

    @Test func searchReturnsArtistAndAlbumRowsOnly() async throws {
        let t = MockTransport()
        var rows = try #require(JSONSerialization.jsonObject(with: Fixtures.data("search")) as? [[String: Any]])
        rows.append(["foreignId": "x", "track": ["title": "unsupported row kind"]])
        t.stub(pathSuffix: "/search", body: try JSONSerialization.data(withJSONObject: rows))
        let (client, _) = makeClient(t)
        let hits = try await client.search(term: "radiohead")
        #expect(hits.count == 4)
        #expect(hits.map(\.kind) == [.artist, .album, .album, .artist])
        #expect(hits[0].artistName == "Radiohead")
        #expect(hits[0].foreignId == MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711"))
        #expect(hits[1].albumTitle == "Radiohead")
        #expect(hits[1].artistName == "X-Dream")
        #expect(hits[1].releaseDate != nil)
    }

    @Test func artistsAlbumsAndTrackFiles() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/artist", body: Fixtures.data("artist"))
        t.stub(pathSuffix: "/album", body: Fixtures.data("album-artistId"))
        t.stub(pathSuffix: "/trackfile", body: Fixtures.data("trackfile"))
        let (client, _) = makeClient(t)

        let artists = try await client.artists()
        #expect(artists.count == 2)
        #expect(artists[0].path == "/music/finds/Aurora Field")
        #expect(artists[0].tags == [1])
        #expect(artists[0].foreignArtistId == MBID("0f2a3c4d-1111-4a2b-8c3d-5e6f7a8b9c0d"))
        #expect(artists[1].foreignArtistId == nil)     // invalid MBID decodes to nil, row survives

        let albums = try await client.albums(artistId: 7)
        #expect(albums[0].title == "Lowlands")
        #expect(albums[0].trackCount == 10)
        #expect(t.requests.last?.url?.query == "artistId=7")

        let files = try await client.trackFiles(albumId: 31)
        #expect(files[0].path == "/music/finds/Aurora Field/Lowlands (2016)/01 - Intro.flac")
        #expect(files[0].quality == "FLAC")
    }

    @Test func commands() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/command/367", body: Fixtures.data("command-id"))
        t.stub(pathSuffix: "/command", body: Fixtures.data("command"))
        let (client, _) = makeClient(t)
        let one = try await client.command(id: 367)
        #expect(one.id == 367)
        #expect(one.status == "completed")
        #expect(one.result == "successful")
        #expect(one.ended != nil)
        #expect(try await client.commands().count == 3)
    }

    /// Task 6.2b (A3): Keep follows the `BulkMoveArtist` that covers its artist; the artist ids come from the
    /// command body (`artist[].artistId` in Lidarr's BulkMoveArtistCommand; other spellings defensively).
    @Test func commandBodyArtistIds() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/command", body: Data(#"""
        [{"id":5,"name":"BulkMoveArtist","status":"started","body":{"artist":[{"artistId":42,"sourcePath":"/music/samples/A"}],"destinationRootFolder":"/music/library"}},
         {"id":6,"name":"RefreshArtist","status":"queued","body":{"artistIds":[7,8]}},
         {"id":7,"name":"MoveArtist","status":"queued","body":{"artistId":9}},
         {"id":8,"name":"RssSync","status":"completed","body":{"artist":"not a list"}}]
        """#.utf8))
        let (client, _) = makeClient(t)
        #expect(try await client.commands().map(\.artistIds) == [[42], [7, 8], [9], []])
    }

    @Test func profilesAndTags() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/qualityprofile", body: Fixtures.data("qualityprofile"))
        t.stub(pathSuffix: "/metadataprofile", body: Fixtures.data("metadataprofile"))
        t.stub(pathSuffix: "/tag", body: json(#"[{"id":1,"label":"magpie-find"}]"#))
        let (client, _) = makeClient(t)
        #expect(try await client.qualityProfiles().first?.name == "Any")
        #expect(try await client.metadataProfiles().first?.name == "Standard")
        #expect(try await client.tags() == [LidarrTag(id: 1, label: "magpie-find")])
    }

    @Test func filesystemExistsListsParentAndMatchesDirectory() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/filesystem", body: Fixtures.data("filesystem"))
        let (client, _) = makeClient(t)
        #expect(try await client.filesystemExists(path: "/music/library/Aurora Field"))
        #expect(try await client.filesystemExists(path: "/music/library/Aurora Field/"))
        #expect(try await client.filesystemExists(path: "/music/library/Aurora") == false)   // not a prefix match
        #expect(try await client.filesystemExists(path: "/music/library/nothere") == false)
        let q = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(q?.first { $0.name == "path" }?.value == "/music/library/")
    }

    @Test func decodingIsDefensive() async throws {
        let t = MockTransport()
        let long = String(repeating: "x", count: 900)
        t.stub(pathSuffix: "/health", body: json("""
        [{"source":"A","type":"error","message":"\(long)","extraNew":{"a":1}}, 42, {"message":null,"type":7}]
        """))
        t.stub(pathSuffix: "/system/status", body: json(#"{"version":5,"somethingNew":[1,2]}"#))
        t.stub(pathSuffix: "/queue/details", body: json(#"[{"size":"big","sizeleft":null,"statusMessages":"nope"},{"albumId":4,"size":10,"sizeleft":5}]"#))
        let (client, _) = makeClient(t)

        let issues = try await client.health()
        #expect(issues.count == 2)                       // the non-object element is dropped, the rest survive
        #expect(issues[0].message.count == 500)
        #expect(issues[1].message.isEmpty)

        let status = try await client.status()
        #expect(status.version == "")                    // wrong type falls back, no throw

        let queue = try await client.queueDetails(albumIds: [])
        #expect(queue.count == 2)
        #expect(queue[1].progress == 0.5)
    }

    @Test func httpErrorsSurface() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/rootfolder", status: 500)
        let (client, _) = makeClient(t)
        await #expect(throws: LidarrError.http(status: 500)) { try await client.rootFolders() }
    }
}

@Suite struct FixRoundTests {
    @Test func dateParsingHandlesLidarrVariants() {
        let base = LidarrDates.parse("2026-10-26T18:00:00Z")!
        for s in ["2026-10-26T18:00:00.1234567Z", "2026-10-26T18:00:00.123Z", "2026-10-26T18:00:00+00:00",
                  "2026-10-26T18:00:00.5+00:00"] {
            let d = LidarrDates.parse(s)
            #expect(d != nil, "\(s)")
            #expect(abs((d ?? .distantPast).timeIntervalSince(base)) < 1, "\(s)")
        }
        #expect(abs(LidarrDates.parse("2026-10-26T18:00:00.1234567Z")!.timeIntervalSince(base) - 0.123) < 0.001)
        #expect(LidarrDates.parse("garbage") == nil)
    }

    @Test func historyDatesWithSevenDigitFractionDecode() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/history/since", body: json(#"[{"id":1,"eventType":"grabbed","date":"2026-10-26T18:00:00.1234567Z"}]"#))
        let (client, _) = makeClient(t)
        #expect(try await client.historySince(.now).first?.date != nil)
    }

    @Test func rowsWithoutIdAreDropped() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/rootfolder", body: json(#"[{"path":"/a"},{"id":2,"path":"/b"},{"id":"x","path":"/c"}]"#))
        t.stub(pathSuffix: "/artist", body: json(#"[{"artistName":"No id"},{"id":3,"artistName":"Ok"}]"#))
        t.stub(pathSuffix: "/command", body: json(#"[{"name":"x"},{"id":9,"name":"y","status":"queued"}]"#))
        t.stub(pathSuffix: "/trackfile", body: json(#"[{"path":"/p"},{"id":5,"path":"/q"}]"#))
        let (client, _) = makeClient(t)
        #expect(try await client.rootFolders().map(\.id) == [2])
        #expect(try await client.artists().map(\.id) == [3])
        #expect(try await client.commands().map(\.id) == [9])
        #expect(try await client.trackFiles(albumId: 1).map(\.id) == [5])
    }

    @Test func singleObjectWithoutIdThrows() async {
        let t = MockTransport()
        t.stub(pathSuffix: "/artist/7", body: json(#"{"artistName":"No id"}"#))
        let (client, _) = makeClient(t)
        await #expect(throws: LidarrError.decoding) { try await client.artist(id: 7) }
    }
}
