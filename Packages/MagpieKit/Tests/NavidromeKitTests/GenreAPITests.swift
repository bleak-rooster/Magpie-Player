import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

@Suite struct GenreAPITests {
    @Test func genresMapCounts() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getGenres", body: ok(#""genres":{"genre":[{"value":"Indie Rock","songCount":10,"albumCount":1},{"value":"Ambient","songCount":12,"albumCount":2},{"songCount":3}]}"#))
        #expect(try await client.genres() == [Genre(name: "Indie Rock", songCount: 10, albumCount: 1),
                                              Genre(name: "Ambient", songCount: 12, albumCount: 2)])
    }

    @Test func albumsByGenreQuery() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getAlbumList2", body: ok(#""albumList2":{"album":[{"id":"a1","name":"Continuum","artist":"Aurora Field","songCount":6}]}"#))
        let albums = try await client.albums(genre: "Indie Rock", size: 12, offset: 24)
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "type") == "byGenre" && queryValue(r, "genre") == "Indie Rock")
        #expect(queryValue(r, "size") == "12" && queryValue(r, "offset") == "24")
        #expect(albums.map(\.id) == ["a1"])
    }

    @Test func songsByGenreQuery() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: ok(#""songsByGenre":{"song":[{"id":"s1","title":"One","genre":"Ambient"},{"id":"s2","title":"Two"}]}"#))
        let songs = try await client.songs(genre: "Ambient", count: 500, offset: 0)
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "genre") == "Ambient" && queryValue(r, "count") == "500" && queryValue(r, "offset") == "0")
        #expect(songs.map(\.id) == ["s1", "s2"] && songs[0].genre == "Ambient")
    }

    @Test func starredSplitsSongsAndAlbums() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{"song":[{"id":"s1","title":"One"}],"album":[{"id":"a1","name":"A"},{"id":"a2","name":"B"}]}"#))
        let s = try await client.starred()
        #expect(s.songs.map(\.id) == ["s1"] && s.albums.map(\.id) == ["a1", "a2"])
    }

    @Test func starredEmptyBody() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{}"#))
        #expect(try await client.starred() == Starred())
    }

    @Test func replayGainAndGenreMapped() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSong", body: ok(#""song":{"id":"s1","title":"One","genre":"Ambient","replayGain":{"trackGain":-6.5,"albumGain":-7.1,"trackPeak":0.98,"albumPeak":1.0}}"#))
        let song = try await client.song(id: "s1")
        #expect(song.genre == "Ambient")
        #expect(song.replayGain == ReplayGain(trackGain: -6.5, albumGain: -7.1, trackPeak: 0.98, albumPeak: 1.0))
    }

    @Test func nativeReplayGainMapped() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/song", body: Data(#"[{"id":"s9","title":"Nine","genre":"Jazz","rgTrackGain":-3.2,"rgAlbumGain":-4.0}]"#.utf8),
               headers: ["X-Total-Count": "1"])
        let page = try await client.songsPage(start: 0, end: 100)
        #expect(page.songs.first?.replayGain?.trackGain == -3.2 && page.songs.first?.replayGain?.albumGain == -4.0)
        #expect(page.songs.first?.genre == "Jazz")
    }

    @Test func songsPageSortsByTitle() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        _ = try await client.songsPage(start: 100, end: 200, sort: "title")
        let r = try #require(t.requests.last { $0.url?.path.hasSuffix("/api/song") == true })
        #expect(queryValue(r, "_sort") == "title" && queryValue(r, "_start") == "100" && queryValue(r, "_end") == "200")
        _ = try await client.songsPage(start: 0, end: 10)
        #expect(queryValue(t.requests.last!, "_sort") == "id", "default unchanged")
    }

    @Test func starredListType() { #expect(AlbumListType.starred.rawValue == "starred") }

    // MARK: - Parked T6 minors (Task 19)

    /// A genre with `&`, `/`, spaces and `+` reaches the server as itself: `&` and `+` can't be read as separators.
    @Test func genreQueryEncoding() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: ok(#""songsByGenre":{}"#))
        t.stub(pathSuffix: "/rest/getAlbumList2", body: ok(#""albumList2":{}"#))
        _ = try await client.songs(genre: "R&B / Soul + Funk", count: 10, offset: 0)
        _ = try await client.albums(genre: "R&B / Soul + Funk", size: 10, offset: 0)
        let genreRequests = t.requests.filter { $0.url?.path.contains("/rest/get") == true }
        #expect(genreRequests.count == 2)
        for r in genreRequests {
            let raw = try #require(r.url?.query(percentEncoded: true))
            #expect(raw.contains("genre=R%26B%20/%20Soul%20%2B%20Funk"), "\(raw)")
            #expect(queryValue(r, "genre") == "R&B / Soul + Funk")
        }
    }

    /// Paging never asks for a negative offset or fewer than one item.
    @Test func pagingClamped() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: ok(#""songsByGenre":{}"#))
        t.stub(pathSuffix: "/rest/getAlbumList2", body: ok(#""albumList2":{}"#))
        _ = try await client.songs(genre: "Ambient", count: 0, offset: -3)
        #expect(queryValue(t.requests.last!, "count") == "1" && queryValue(t.requests.last!, "offset") == "0")
        _ = try await client.albums(genre: "Ambient", size: -2, offset: -1)
        #expect(queryValue(t.requests.last!, "size") == "1" && queryValue(t.requests.last!, "offset") == "0")
        _ = try await client.albumList(.newest, size: 0, offset: -9)
        #expect(queryValue(t.requests.last!, "size") == "1" && queryValue(t.requests.last!, "offset") == "0")
        #expect(queryValue(t.requests.last!, "type") == "newest")
    }

    @Test func songWithoutReplayGain() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSong", body: ok(#""song":{"id":"s1","title":"One"}"#))
        let song = try await client.song(id: "s1")
        #expect(song.replayGain == nil && song.genre == nil)
    }

    @Test func partialReplayGain() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getSong", body: ok(#""song":{"id":"s1","title":"One","replayGain":{"albumGain":-4.5}}"#))
        let song = try await client.song(id: "s1")
        #expect(song.replayGain == ReplayGain(trackGain: nil, albumGain: -4.5, trackPeak: nil, albumPeak: nil))
    }

    @Test func genreRowWithoutCounts() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getGenres", body: ok(#""genres":{"genre":[{"value":"Chanson"}]}"#))
        #expect(try await client.genres() == [Genre(name: "Chanson", songCount: 0, albumCount: 0)])
    }
}
