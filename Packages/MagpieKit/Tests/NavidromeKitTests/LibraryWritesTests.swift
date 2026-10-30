import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

private func ok(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}

/// Round 11 (R7, R8, R11): stars for albums and artists, playlist writes and who owns a playlist, and every artist
/// (the native API) for "Album artists only" off. Shapes as the dev Navidrome 0.64.2 answers them.
@Suite struct LibraryWritesTests {
    @Test func starAndUnstarAlbumAndArtistUseTheirOwnParameters() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/star", body: ok())
        t.stub(pathSuffix: "/rest/unstar", body: ok())
        try await client.star(albumId: "al1")
        #expect(queryValue(t.requests.last!, "albumId") == "al1" && queryValue(t.requests.last!, "id") == nil)
        try await client.unstar(artistId: "ar1")
        #expect(t.requests.last!.url!.path.hasSuffix("/rest/unstar"))
        #expect(queryValue(t.requests.last!, "artistId") == "ar1" && queryValue(t.requests.last!, "id") == nil)
        try await client.star(artistId: "ar2")
        try await client.unstar(albumId: "al2")
        #expect(queryValue(t.requests.last!, "albumId") == "al2")
    }

    @Test func starredStateIsReadForAlbumsAndArtists() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getAlbum", body: ok(#""album":{"id":"al1","name":"A","starred":"2026-10-30T14:13:34Z","song":[]}"#))
        t.stub(pathSuffix: "/rest/getArtist", body: ok(#""artist":{"id":"ar1","name":"B","album":[{"id":"al2","name":"C"}]}"#))
        #expect(try await client.album(id: "al1").starred)
        let (artist, albums) = try await client.artist(id: "ar1")
        #expect(!artist.starred && !albums[0].starred)
        t.stub(pathSuffix: "/rest/getStarred2", body: ok(#""starred2":{"artist":[{"id":"ar1","name":"B","starred":"2026-10-30T14:13:34Z"}],"album":[{"id":"al1","name":"A","starred":"2026-10-30T14:13:34Z"}],"song":[{"id":"s1","title":"S","starred":"2026-10-30T14:13:34Z"}]}"#))
        let starred = try await client.starred()
        #expect(starred.artists.map(\.id) == ["ar1"] && starred.artists[0].starred)
        #expect(starred.albums.map(\.starred) == [true] && starred.songs.map(\.starred) == [true])
    }

    @Test func playlistsCarryTheirOwnerAndWhetherTheyAreReadOnly() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/getPlaylists", body: ok(#""playlists":{"playlist":[{"id":"p1","name":"Mine","owner":"admin","readonly":false,"songCount":2,"changed":"2026-10-30T14:13:33.930667213Z"},{"id":"p2","name":"Theirs","owner":"listener","readonly":true},{"id":"p3","name":"Old server","owner":"Admin"},{"id":"p4","name":"No owner"}]}"#))
        let lists = try await client.playlists()
        #expect(lists.map(\.owner) == ["admin", "listener", "Admin", nil])
        #expect(lists.map(\.readOnly) == [false, true, nil, nil])
        #expect(lists[0].changed.map { Int($0.timeIntervalSince1970) } == 1_793_369_613 && lists[1].changed == nil)
        // Editable: the server's `readonly` when it sends one; otherwise owned by the user (case aside).
        #expect(lists.map { $0.isEditable(by: "admin") } == [true, false, true, false])
    }

    @Test func createPlaylistSendsTheNameAndSongsAndReturnsTheNewId() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/createPlaylist", body: ok(#""playlist":{"id":"p9","name":"Road trip","owner":"admin","readonly":false,"songCount":2}"#))
        let made = try await client.createPlaylist(name: "Road trip", songIds: ["s1", "s2"])
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "name") == "Road trip")
        #expect(queryItems(r).filter { $0.name == "songId" }.map(\.value) == ["s1", "s2"])
        #expect(made?.id == "p9")
    }

    @Test func updatePlaylistAddsRenamesAndRemovesByIndex() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/updatePlaylist", body: ok())
        try await client.updatePlaylist(id: "p1", name: nil, adding: ["s1", "s1"], removingIndexes: [])
        var r = try #require(t.requests.last)
        #expect(queryValue(r, "playlistId") == "p1" && queryValue(r, "name") == nil)
        #expect(queryItems(r).filter { $0.name == "songIdToAdd" }.map(\.value) == ["s1", "s1"])
        try await client.updatePlaylist(id: "p1", name: "New name", adding: [], removingIndexes: [3, 0])
        r = try #require(t.requests.last)
        #expect(queryValue(r, "name") == "New name")
        #expect(queryItems(r).filter { $0.name == "songIndexToRemove" }.map(\.value) == ["3", "0"])
    }

    @Test func deletePlaylistSendsItsId() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/rest/deletePlaylist", body: ok())
        try await client.deletePlaylist(id: "p1")
        #expect(queryValue(t.requests.last!, "id") == "p1")
    }

    @Test func allArtistsReadsEveryRoleSkippingMissingRows() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/artist", body: Data(#"""
        [{"id":"a1","name":"Aurora Field","albumCount":3,"mbzArtistId":"cbe813de-4d71-41e4-94a8-45aead0e87b4","imageAbsent":true,"missing":false},
         {"id":"a2","name":"Static Choir","albumCount":0,"missing":false},
         {"id":"a3","name":"Gone","albumCount":1,"missing":true}]
        """#.utf8), headers: ["X-Total-Count": "3"])
        let artists = try await client.allArtists()
        #expect(artists.map(\.id) == ["a1", "a2"])
        #expect(artists[0].albumCount == 3 && artists[0].mbid?.rawValue == "cbe813de-4d71-41e4-94a8-45aead0e87b4")
        #expect(artists[0].coverArtId == nil && artists[1].coverArtId == "ar-a2")
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "role") == nil && queryValue(r, "_sort") == "name")
    }

    @Test func allArtistsPagesUntilTheTotal() async throws {
        let (client, t) = makeClient()
        t.stub(pathSuffix: "/api/artist") { request in
            let start = Int(queryValue(request, "_start") ?? "0")!
            let end = Int(queryValue(request, "_end") ?? "0")!
            let rows = (start..<min(end, 5)).map { #"{"id":"a\#($0)","name":"N\#($0)","albumCount":1}"# }
            return MockTransport.Response(status: 200, body: Data("[\(rows.joined(separator: ","))]".utf8),
                                          headers: ["X-Total-Count": "5"])
        }
        let artists = try await client.allArtists(pageSize: 2)
        #expect(artists.map(\.id) == ["a0", "a1", "a2", "a3", "a4"])
    }
}
