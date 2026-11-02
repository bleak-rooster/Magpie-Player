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
                                    "getRandomSongs", "api/song", "api/artist"]

    @Test func everyListCallCarriesTheMainLibrary() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        client.setLibraryScope(1)
        #expect(client.libraryScope == 1)
        try await everyListCall(client)
        let lists = t.requests.filter { r in Self.listPaths.contains { r.url!.path.hasSuffix($0) } }
        #expect(lists.count == 11)
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

    /// The match index (what counts as "in your library" for outside results) keeps reading the whole server.
    @Test func wholeServerPagesStayUnscoped() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        client.setLibraryScope(1)
        _ = try await client.songsPage(start: 0, end: 100, wholeServer: true)
        #expect(queryValue(try #require(t.requests.last), "library_id") == nil)
    }

    /// The music folders every account can read (`getMusicFolders`), for picking the main library without an admin.
    @Test func musicFoldersAreRead() async throws {
        let (client, t) = makeClient()
        stubAll(t)
        let folders = try await client.musicFolders()
        #expect(folders.map(\.id) == [1, 2, 3] && folders.map(\.name) == ["Music Library", "Aurral Playlists", "Finds"])
    }
}
