import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
import os
@testable import NavidromeKit

@Suite struct BrowseMappingTests {
    private func connected(_ stubs: (MockTransport) -> Void) async throws -> (NavidromeClient, MockTransport) {
        let (client, transport) = makeClient()
        stubs(transport)
        _ = try await client.connect()
        return (client, transport)
    }

    @Test func multiDiscAlbumOrdersByDiscThenTrack() async throws {
        // Shuffle the server order so only the mapping can put it right.
        var root = Fixtures.json("getAlbum-multidisc") as! [String: Any]
        var resp = root["subsonic-response"] as! [String: Any]
        var album = resp["album"] as! [String: Any]
        album["song"] = Array((album["song"] as! [[String: Any]]).reversed())
        resp["album"] = album; root["subsonic-response"] = resp
        let body = try JSONSerialization.data(withJSONObject: root)
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/getAlbum", body: body) }
        let result = try await client.album(id: "2MsARQLkcirsVkzR9ovlI4")
        let songs = try #require(result.songs)
        #expect(songs.map { "\($0.disc!)-\($0.track!)" } ==
                ["1-1", "1-2", "1-3", "1-4", "1-5", "2-1", "2-2", "2-3", "2-4", "2-5"])
        #expect(result.name == "Atlas of Small Hours")
        #expect(result.songCount == 10)
        #expect(result.year == 2022)
        #expect(songs[0].title == "North by Northwest")
        #expect(songs[0].suffix == "flac")
    }

    @Test func songById() async throws {
        let body = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"s9","title":"Harbour Lights","artist":"Judie Tzuke","album":"The Cat Is Out","duration":232}}}"#.utf8)
        let (client, t) = try await connected { $0.stub(pathSuffix: "/rest/getSong", body: body) }
        let song = try await client.song(id: "s9")
        #expect(song.id == "s9" && song.title == "Harbour Lights" && song.duration == 232)
        #expect(t.requests.last.flatMap { queryValue($0, "id") } == "s9")
    }

    @Test func compilationArtistIsVarious() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getAlbum", body: Fixtures.data("getAlbum-compilation"))
        }
        let album = try await client.album(id: "2LQaBECy1fIxhT9Gs7ZpAV")
        #expect(album.artist == "Various Artists")
        let songs = try #require(album.songs)
        #expect(Set(songs.map(\.artist)).count == 6)   // per-track artists are preserved
        #expect(songs[0].artist == "Kites Over Lagos")
        #expect(songs.contains { $0.title == "高架下" && $0.artist == "坂本光" })
    }

    @Test func songMapsMBIDsFromSubsonicAndSurvivesBadOnes() async throws {
        var root = Fixtures.json("getAlbum-compilation") as! [String: Any]
        var resp = root["subsonic-response"] as! [String: Any]
        var album = resp["album"] as! [String: Any]
        var songs = album["song"] as! [[String: Any]]
        songs[1]["musicBrainzId"] = "not-a-uuid"
        album["song"] = songs; resp["album"] = album; root["subsonic-response"] = resp
        let body = try JSONSerialization.data(withJSONObject: root)
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/getAlbum", body: body) }
        let mapped = try #require(try await client.album(id: "x").songs)
        #expect(mapped[0].recordingMBID?.rawValue == "a1cd8787-a032-4834-aa15-134a19366277")
        #expect(mapped[0].isrcs == ["NGKOL2300001"])
        #expect(mapped[1].recordingMBID == nil)   // bad ID dropped, response still returned
        #expect(mapped.count == 6)
    }

    @Test func songPageMapsMBIDAndISRC() async throws {
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: Fixtures.data("apiSongPage"), headers: ["X-Total-Count": "42"])
        }
        let page = try await client.songsPage(start: 0, end: 8)
        #expect(page.total == 42)
        #expect(page.songs.count == 8)
        let first = page.songs[0]
        #expect(first.title == "First Light")
        #expect(first.recordingMBID?.rawValue == "20a2961b-d8e8-481c-bd5b-abb38a2850ad")
        #expect(first.isrcs == ["GBXYZ1900001"])
        #expect(first.libraryId == 1)
        #expect(first.disc == 1 && first.track == 1)
        #expect(first.suffix == "flac")
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/api/song") == true })
        #expect(queryValue(req, "_start") == "0")
        #expect(queryValue(req, "_end") == "8")
        #expect(queryValue(req, "_sort") == "id")
        #expect(queryValue(req, "_order") == "ASC")
    }

    @Test func skipsMissingSongs() async throws {
        var page = Fixtures.json("apiSongPage") as! [[String: Any]]
        page[2]["missing"] = true
        let body = try JSONSerialization.data(withJSONObject: page)
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: body, headers: ["X-Total-Count": "42"])
        }
        let result = try await client.songsPage(start: 0, end: 8)
        #expect(result.songs.count == 7)
        #expect(result.songs.allSatisfy { $0.id != (page[2]["id"] as! String) })
    }

    @Test func songPageMapsArtistMBIDFromParticipantsOrTopLevel() async throws {
        var page = Fixtures.json("apiSongPage") as! [[String: Any]]
        #expect(page[0]["mbzArtistId"] == nil, "the dev fixture has none")
        var participants = page[0]["participants"] as! [String: Any]
        var artists = participants["artist"] as! [[String: Any]]
        artists[0]["mbzArtistId"] = "4D8175EA-CC33-4565-8A8E-6B0F6C7A3F11"
        participants["artist"] = artists
        page[0]["participants"] = participants
        page[1]["mbzArtistId"] = "not-an-mbid"
        page[2]["mbzArtistId"] = "75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"
        let body = try JSONSerialization.data(withJSONObject: page)
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/song", body: body, headers: ["X-Total-Count": "8"])
        }
        let songs = try await client.songsPage(start: 0, end: 8).songs
        #expect(songs[0].artistMBID?.rawValue == "4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")
        #expect(songs[1].artistMBID == nil)
        #expect(songs[2].artistMBID?.rawValue == "75ab6ba6-9197-4f83-8a23-a1925a7ec5a2")
    }

    @Test func aacStreamURLHasNoEstimateContentLength() async throws {
        let (client, _) = try await connected { _ in }
        let items = Dictionary(uniqueKeysWithValues: URLComponents(
            url: client.streamURL(songId: "a", maxBitRate: 160, format: "aac")!, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["estimateContentLength"] == nil && items["format"] == "aac" && items["maxBitRate"] == "160")
        let raw = client.streamURL(songId: "a", maxBitRate: nil, format: "raw")!
        #expect(raw.absoluteString.contains("estimateContentLength=true"))
    }

    @Test func opusStreamURLHasNoEstimateContentLength() async throws {
        let (client, _) = try await connected { _ in }
        for rate in [192, 128, 96, 64] {
            let items = Dictionary(uniqueKeysWithValues: URLComponents(
                url: client.streamURL(songId: "a", maxBitRate: rate, format: "opus")!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(items["estimateContentLength"] == nil && items["format"] == "opus" && items["maxBitRate"] == String(rate))
        }
    }

    @Test func streamURLHasEstimateContentLength() async throws {
        let (client, _) = try await connected { _ in }
        let url = client.streamURL(songId: "abc 123", maxBitRate: 320, format: "mp3")!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(comps.path == "/navidrome/rest/stream")
        #expect(items["estimateContentLength"] == "true")
        #expect(items["id"] == "abc 123")
        #expect(items["maxBitRate"] == "320")
        #expect(items["format"] == "mp3")
        #expect(items["u"] == "admin" && items["s"] == "fakesalt" && items["p"] == nil)
        let plain = client.streamURL(songId: "a", maxBitRate: nil, format: nil)!
        #expect(!plain.absoluteString.contains("maxBitRate") && !plain.absoluteString.contains("format"))
    }

    @Test func coverArtURLKeepsBasePath() async throws {
        let (client, _) = try await connected { _ in }
        let url = client.coverArtURL(id: "al-1_abc", size: 600)!
        #expect(url.path == "/navidrome/rest/getCoverArt")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "id" }?.value == "al-1_abc")
        #expect(items.first { $0.name == "size" }?.value == "600")
    }

    @Test func albumListMapsAndHandlesEmpty() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getAlbumList2", body: Fixtures.data("getAlbumList2"))
        }
        let albums = try await client.albumList(.newest, size: 50, offset: 0)
        #expect(albums.count == 7)
        #expect(albums.first { $0.name == "夜明けの街" }?.artist == "坂本光")
        #expect(albums.allSatisfy { $0.songs == nil })

        let (emptyClient, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getAlbumList2",
                    body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{}}}"#.utf8))
        }
        #expect(try await emptyClient.albumList(.recent, size: 5, offset: 0).isEmpty)
    }

    @Test func artistsFlattenIndexes() async throws {
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/getArtists", body: Fixtures.data("getArtists")) }
        let artists = try await client.artists()
        #expect(artists.count == 6)
        let aurora = try #require(artists.first { $0.name == "Aurora Field" })
        #expect(aurora.albumCount == 2)
        #expect(aurora.mbid?.rawValue == "cbe813de-4d71-41e4-94a8-45aead0e87b4")
    }

    @Test func artistWithAlbums() async throws {
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/getArtist", body: Fixtures.data("getArtist")) }
        let (artist, albums) = try await client.artist(id: "4P6dcXuFfjX7ECrNZl8kpL")
        #expect(artist.name == "Aurora Field")
        #expect(albums.map(\.name).sorted() == ["Continuum", "Lowlands"])
    }

    @Test func playlistsAndPlaylistSongs() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getPlaylists", body: Fixtures.data("getPlaylists"))
            $0.stub(pathSuffix: "/rest/getPlaylist", body: Fixtures.data("getPlaylist"))
        }
        let lists = try await client.playlists()
        #expect(lists.map(\.name) == ["Fixture Mix"])
        let (playlist, songs) = try await client.playlist(id: lists[0].id)
        #expect(playlist.songCount == 1)
        #expect(songs.map(\.title) == ["Neon Rain"])
    }

    @Test func searchMapsAllThreeKindsAndEmpty() async throws {
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/rest/search3", body: Fixtures.data("search3")) }
        let result = try await client.search("aurora")
        #expect(result.artists.map(\.name) == ["Aurora Field"])
        #expect(result.albums.count >= 1)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("search3") == true })
        #expect(queryValue(req, "query") == "aurora")
        #expect(queryValue(req, "songCount") == "20")
        #expect(queryValue(req, "albumCount") == "10")
        #expect(queryValue(req, "artistCount") == "5")
    }

    @Test func extensionsAreNames() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getOpenSubsonicExtensions", body: Fixtures.data("getOpenSubsonicExtensions"))
        }
        let names = try await client.extensions()
        #expect(names.contains("songLyrics") && names.contains("transcoding"))
        #expect(!names.contains("apiKeyAuthentication"))
    }

    @Test func lyricsSyncedAndEmpty() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/rest/getLyricsBySongId", body: Fixtures.data("getLyricsBySongId"))
        }
        let lyrics = try #require(try await client.lyrics(songId: "x"))
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["Before the dawn", "The static hums", ""])
        #expect(lyrics.lines.map(\.start) == [0, 4.2, 9.0])

        let transport2 = MockTransport()
        let (empty, _) = makeClient(transport: transport2)
        transport2.stub(pathSuffix: "/rest/getLyricsBySongId",
                        body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{}}}"#.utf8))
        _ = try await empty.connect()
        #expect(try await empty.lyrics(songId: "x") == nil)
    }

    @Test func topSongsEmptyIsEmpty() async throws {
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/rest/getTopSongs", body: Fixtures.data("getTopSongs")) }
        #expect(try await client.topSongs(artistName: "Aurora Field").isEmpty)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("getTopSongs") == true })
        #expect(queryValue(req, "artist") == "Aurora Field")
    }

    @Test func scrobbleSendsSubmissionAndTime() async throws {
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/rest/scrobble", body: ok) }
        try await client.scrobble(songId: "s1", submission: true, at: Date(timeIntervalSince1970: 1_700_000_000))
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("scrobble") == true })
        #expect(queryValue(req, "id") == "s1")
        #expect(queryValue(req, "submission") == "true")
        #expect(queryValue(req, "time") == "1700000000000")
    }

    /// Hunt 2: a queued play's time comes back from `scrobble-queue.json`; one milliseconds can't hold sends no time
    /// instead of trapping.
    @Test func scrobbleTimeOutOfRangeSendsNoTime() async throws {
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
        let (client, transport) = try await connected { $0.stub(pathSuffix: "/rest/scrobble", body: ok) }
        for t in [1e300, -1e300, Double.infinity, -.infinity, .nan, 1e17] {
            try await client.scrobble(songId: "s1", submission: true, at: Date(timeIntervalSince1970: t))
            let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("scrobble") == true })
            #expect(queryValue(req, "time") == nil, "\(t)")
        }
    }

    @Test func starAndUnstarSendTheSongId() async throws {
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/rest/star", body: ok)
            $0.stub(pathSuffix: "/rest/unstar", body: ok)
        }
        try await client.star(id: "s1")
        let star = try #require(transport.requests.last { $0.url?.path.hasSuffix("/rest/star") == true })
        #expect(queryValue(star, "id") == "s1")
        #expect(star.url?.path == "/navidrome/rest/star")
        try await client.unstar(id: "s2")
        let unstar = try #require(transport.requests.last { $0.url?.path.hasSuffix("/rest/unstar") == true })
        #expect(queryValue(unstar, "id") == "s2")
    }

    @Test func starFailureSurfaces() async throws {
        let failed = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8)
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/star", body: failed) }
        await #expect(throws: NavidromeError.api(code: 70, message: "not found")) { try await client.star(id: "nope") }
    }

    @Test func startScanIsQuickAndDebouncedPerTarget() async throws {
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","scanStatus":{"scanning":true,"count":0}}}"#.utf8)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))
        let transport = MockTransport()
        transport.stub(pathSuffix: "/rest/startScan", body: ok)
        transport.stub(pathSuffix: "/rest/getScanStatus", body: ok)
        transport.stub(pathSuffix: "/rest/ping", body: ok)
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: Fixtures.data("login"))
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [testBase]), credentials: testCredentials,
                                     transport: transport, now: { clock.withLock { $0 } })
        _ = try await client.connect()
        func scans() -> [URLRequest] { transport.requests.filter { $0.url?.path.hasSuffix("startScan") == true } }
        try await client.startScan(target: "2:Artist/Album")
        try await client.startScan(target: "2:Artist/Album")      // debounced
        try await client.startScan(target: "1:Other")              // different target, goes through
        #expect(scans().count == 2)
        #expect(queryValue(scans()[0], "fullScan") == "false")
        #expect(queryValue(scans()[0], "target") == "2:Artist/Album")
        clock.withLock { $0 = $0.addingTimeInterval(10.5) }
        try await client.startScan(target: "2:Artist/Album")
        #expect(scans().count == 3)
        try await client.startScan(target: nil)
        #expect(queryValue(scans()[3], "target") == nil)
        #expect(try await client.scanStatus() == true)
    }

    @Test func failedStartScanCanBeRetriedImmediately() async throws {
        let first = OSAllocatedUnfairLock(initialState: true)
        let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/rest/startScan") { _ in
                first.withLock { v -> Bool in defer { v = false }; return v }
                    ? .init(status: 500) : .init(status: 200, body: ok)
            }
        }
        await #expect(throws: NavidromeError.http(status: 500)) { try await client.startScan(target: "1:x") }
        try await client.startScan(target: "1:x")
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("startScan") == true }.count == 2)
    }

    /// B6/G2: the library folders, as Navidrome sees them (`/api/library`, captured from Navidrome 0.64.2).
    @Test func librariesListIdNameAndPath() async throws {
        let (client, transport) = try await connected {
            $0.stub(pathSuffix: "/api/library", body: Fixtures.data("apiLibrary"), headers: ["X-Total-Count": "2"])
        }
        let libraries = try await client.libraries()
        #expect(libraries == [NavidromeLibrary(id: 1, name: "Music Library", path: "/music/library"),
                              NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples")])
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/api/library") == true })
        #expect(req.url?.path == "/navidrome/api/library", "keeps the base path")
        #expect(req.value(forHTTPHeaderField: "X-ND-Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func librariesForbiddenSurfaces() async throws {
        // Some Navidrome versions keep library management to admins.
        let (client, _) = try await connected { $0.stub(pathSuffix: "/api/library", status: 403) }
        await #expect(throws: NavidromeError.http(status: 403)) { try await client.libraries() }
    }

    @Test func apiErrorSurfacesCodeAndMessage() async throws {
        let body = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8)
        let (client, _) = try await connected { $0.stub(pathSuffix: "/rest/getAlbum", body: body) }
        await #expect(throws: NavidromeError.api(code: 70, message: "not found")) { try await client.album(id: "nope") }
    }
}
