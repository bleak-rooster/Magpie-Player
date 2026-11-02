import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import NavidromeKit

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 12 Y3 (plan item 5): Home, Library, Search and CarPlay read the main library only. Once the client is scoped
/// to a library, every list and search call carries it (`musicFolderId` on the Subsonic API, `library_id` on the
/// native one); unscoped (a single library, or no main library known) nothing is added. Lookups by id, playlists, the
/// Finds library read and recording lookups are never scoped.
@Suite struct LibraryScopeTests {
    private func stubAll(_ t: MockTransport) {
        t.stub(pathSuffix: "/rest/getAlbumList2", body: ok(#""albumList2":{"album":[]}"#))
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: ok(#""songsByGenre":{"song":[]}"#))
        t.stub(pathSuffix: "/rest/getGenres", body: ok(#""genres":{"genre":[]}"#))
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{}"#))
        t.stub(pathSuffix: "/rest/getArtists", body: ok(#""artists":{"index":[]}"#))
        t.stub(pathSuffix: "/rest/search3", body: ok(#""searchResult3":{}"#))
        t.stub(pathSuffix: "/rest/getRandomSongs", body: ok(#""randomSongs":{"song":[]}"#))
        t.stub(pathSuffix: "/rest/getPlaylists", body: ok(#""playlists":{"playlist":[]}"#))
        t.stub(pathSuffix: "/rest/getAlbum", body: ok(#""album":{"id":"a1","name":"A"}"#))
        t.stub(pathSuffix: "/rest/getMusicFolders",
               body: ok(#""musicFolders":{"musicFolder":[{"id":1,"name":"Music Library"},{"id":2,"name":"Aurral Playlists"},{"id":3,"name":"Finds"}]}"#))
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/artist", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/album", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
    }

    /// Every list call the app's lists use, by the endpoint it hits.
    private func everyListCall(_ client: NavidromeClient) async throws {
        _ = try await client.albumList(.newest, size: 12, offset: 0)
        _ = try await client.albums(genre: "Rock", size: 12, offset: 0)
        _ = try await client.songs(genre: "Rock", count: 10, offset: 0)
        _ = try await client.genres()
        _ = try await client.starred()
        _ = try await client.artists()
        _ = try await client.search("north")
        _ = try await client.randomSongs(size: 10)
        _ = try await client.songsPage(start: 0, end: 100, sort: "title")
        _ = try await client.songTitle(at: 0)
        _ = try await client.allArtists()
    }

    private static let listPaths = ["getAlbumList2", "getSongsByGenre", "getGenres", "getStarred2", "getArtists", "search3",
                                    "getRandomSongs", "api/song", "api/artist", "api/album"]

    @Test func everyListCallCarriesTheMainLibrary() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        client.setLibraryScope(1)
        #expect(client.libraryScope == 1)
        try await everyListCall(client)
        let lists = t.requests.filter { r in Self.listPaths.contains { r.url!.path.hasSuffix($0) } }
        #expect(lists.count == 14, "11 calls, plus Favourites' three native starred reads")
        for r in lists {
            let name = r.url!.path.contains("/api/") ? "library_id" : "musicFolderId"
            #expect(queryValue(r, name) == "1", "\(r.url!.path) carries the main library")
        }
    }

    @Test func unscopedSendsNoLibrary() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        try await everyListCall(client)
        client.setLibraryScope(1)
        client.setLibraryScope(nil)   // a single library again: nothing is sent
        _ = try await client.albumList(.random, size: 12, offset: 0)
        for r in t.requests {
            #expect(queryValue(r, "musicFolderId") == nil && queryValue(r, "library_id") == nil)
        }
    }

    /// Lookups by id, playlists, the Finds library read (its own library) and recording lookups are never scoped.
    @Test func lookupsAndFindsAreNeverScoped() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        client.setLibraryScope(1)
        _ = try await client.album(id: "a1")
        _ = try await client.playlists()
        _ = try await client.songs(inLibrary: 3)
        _ = try await client.songs(recordingMBID: MBID("8f3b1c5e-3c1a-4f7e-9a8b-1f2e3d4c5b6a")!, excludingLibrary: nil)
        let sent = t.requests.filter { !$0.url!.path.hasSuffix("ping") && !$0.url!.path.hasSuffix("login") }
        #expect(sent.count == 4)
        for r in sent { #expect(queryValue(r, "musicFolderId") == nil) }
        #expect(sent.filter { queryValue($0, "library_id") != nil }.map { queryValue($0, "library_id") } == ["3"],
                "only the Finds read names a library, and it names its own")
    }

    /// The match index names its libraries explicitly (Y3 fix: main + Finds, never Aurral's); `.all` reads every one.
    @Test func explicitLibrariesAndAll() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        client.setLibraryScope(1)
        _ = try await client.songsPage(start: 0, end: 100, libraries: .only([1, 3]))
        #expect(queryItems(try #require(t.requests.last)).filter { $0.name == "library_id" }.map(\.value) == ["1", "3"])
        _ = try await client.songsPage(start: 0, end: 100, libraries: .all)
        #expect(queryValue(try #require(t.requests.last), "library_id") == nil)
    }

    /// Y3 fix: getStarred2 ignores musicFolderId, so a scoped read keeps only what the native API lists as starred
    /// in the main library.
    @Test func favouritesFollowTheScope() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{"song":[{"id":"s-main"},{"id":"s-aurral"}],"album":[{"id":"al-main","name":"M"},{"id":"al-find","name":"F"}],"artist":[{"id":"ar-main","name":"M"},{"id":"ar-aurral","name":"A"}]}"#))
        t.stub(pathSuffix: "/api/song") { r in
            MockTransport.Response(status: 200, body: Data(
                (queryValue(r, "starred") == "true" && queryValue(r, "library_id") == "1" ? #"[{"id":"s-main"}]"# : "[]").utf8))
        }
        t.stub(pathSuffix: "/api/album") { _ in MockTransport.Response(status: 200, body: Data(#"[{"id":"al-main"}]"#.utf8)) }
        t.stub(pathSuffix: "/api/artist") { _ in MockTransport.Response(status: 200, body: Data(#"[{"id":"ar-main"}]"#.utf8)) }
        let (client, _) = makeClient(transport: t)
        let unscoped = try await client.starred()
        #expect(unscoped.songs.count == 2, "unscoped: everything starred")
        client.setLibraryScope(1)
        let scoped = try await client.starred()
        #expect(scoped.songs.map(\.id) == ["s-main"] && scoped.albums.map(\.id) == ["al-main"] && scoped.artists.map(\.id) == ["ar-main"])
    }

    /// Y3 fix: a library's album count (the fallback pick of the main library), from the native API's total.
    @Test func albumCountPerLibrary() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/album") { r in
            MockTransport.Response(status: 200, body: Data("[]".utf8),
                                   headers: ["X-Total-Count": queryValue(r, "library_id") == "1" ? "312" : "40"])
        }
        let (client, _) = makeClient(transport: t)
        #expect(try await client.albumCount(inLibrary: 1) == 312)
        #expect(try await client.albumCount(inLibrary: 2) == 40)
    }

    /// Y3 fix: native song rows carry sample rate and bit depth too.
    @Test func nativeSongsCarrySampleRateAndBitDepth() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/song", body: Data(#"[{"id":"s1","title":"T","suffix":"flac","sampleRate":96000,"bitDepth":24}]"#.utf8),
               headers: ["X-Total-Count": "1"])
        let (client, _) = makeClient(transport: t)
        let song = try #require(try await client.songsPage(start: 0, end: 1).songs.first)
        #expect(song.samplingRate == 96000 && song.bitDepth == 24)
    }

    /// The music folders every account can read (`getMusicFolders`), for picking the main library without an admin.
    @Test func musicFoldersAreRead() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        let folders = try await client.musicFolders()
        #expect(folders.map(\.id) == [1, 2, 3] && folders.map(\.name) == ["Music Library", "Aurral Playlists", "Finds"])
    }
}
