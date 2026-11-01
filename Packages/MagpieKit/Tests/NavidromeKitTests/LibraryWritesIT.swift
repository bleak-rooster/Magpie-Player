import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

/// G0: runs only against the local dev stack (`DevStack`). Owner-data rule: it creates its own playlist (a unique
/// "Magpie IT" name) and deletes only that one, and it unstars only what it starred.
@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"), .serialized)
struct LibraryWritesIT {
    private func client() async throws -> NavidromeClient {
        let cfg = try DevStack.load()
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [cfg.url]),
                                     credentials: NavidromeCredentials(username: cfg.user, password: cfg.password),
                                     transport: SharedLoginTransport())
        _ = try await client.connect()
        return client
    }

    @Test func aPlaylistIsCreatedChangedAndDeleted() async throws {
        let client = try await client()
        let cfg = try DevStack.load()
        let songs = try await client.albumList(.alphabeticalByName, size: 1, offset: 0)
        let album = try await client.album(id: try #require(songs.first).id)
        let ids = try #require(album.songs?.prefix(2).map(\.id))
        try #require(ids.count == 2)
        let name = "Magpie IT \(UUID().uuidString.prefix(8))"
        let made = try #require(try await client.createPlaylist(name: name, songIds: [ids[0]]))
        do {
            try await change(made, name: name, ids: ids, client: client, user: cfg.user)
        } catch {
            try? await client.deletePlaylist(id: made.id)   // only the playlist this test made
            throw error
        }
    }

    private func change(_ made: Playlist, name: String, ids: [String], client: NavidromeClient, user: String) async throws {
        #expect(made.name == name && made.isEditable(by: user))
        let listed = try #require(try await client.playlists().first { $0.id == made.id })
        #expect(listed.owner?.caseInsensitiveCompare(user) == .orderedSame && listed.readOnly == false)

        // Duplicates are allowed: the server keeps both.
        try await client.updatePlaylist(id: made.id, name: nil, adding: [ids[1], ids[1]], removingIndexes: [])
        try await client.updatePlaylist(id: made.id, name: name + " renamed", adding: [], removingIndexes: [])
        var (playlist, entries) = try await client.playlist(id: made.id)
        #expect(playlist.name == name + " renamed")
        #expect(entries.map(\.id) == [ids[0], ids[1], ids[1]])

        try await client.updatePlaylist(id: made.id, name: nil, adding: [], removingIndexes: [1])
        (playlist, entries) = try await client.playlist(id: made.id)
        #expect(entries.map(\.id) == [ids[0], ids[1]])

        try await client.deletePlaylist(id: made.id)
        #expect(try await !client.playlists().contains { $0.id == made.id })
    }

    @Test func albumsAndArtistsCanBeStarred() async throws {
        let client = try await client()
        let before = try await client.starred()
        let album = try #require(try await client.albumList(.alphabeticalByName, size: 50, offset: 0)
            .first { a in !before.albums.contains { $0.id == a.id } })
        let artist = try #require(try await client.artists().first { a in !before.artists.contains { $0.id == a.id } })

        try await client.star(albumId: album.id)
        try await client.star(artistId: artist.id)
        let after = try await client.starred()
        try await client.unstar(albumId: album.id)
        try await client.unstar(artistId: artist.id)

        #expect(after.albums.contains { $0.id == album.id && $0.starred })
        #expect(after.artists.contains { $0.id == artist.id && $0.starred })
        #expect(try await client.album(id: album.id).starred == false)
        let restored = try await client.starred()
        #expect(restored.albums.map(\.id) == before.albums.map(\.id))
        #expect(restored.artists.map(\.id) == before.artists.map(\.id))
    }

    /// R11: `getArtists` is the album artists; `/api/artist` adds track-only artists (the fixture's "Static Choir").
    @Test func everyArtistIncludesTrackOnlyArtists() async throws {
        let client = try await client()
        let albumArtists = Set(try await client.artists().map(\.id))
        let every = try await client.allArtists()
        #expect(albumArtists.isSubset(of: Set(every.map(\.id))))
        #expect(every.count > albumArtists.count)
        let trackOnly = try #require(every.first { $0.name == "Static Choir" })
        #expect(!albumArtists.contains(trackOnly.id))
    }
}
