import Foundation
import MagpieCore
import NavidromeKit

enum PlaylistCopy {
    static let newPlaylist = "New playlist…"
    static func added(to name: String) -> String { "Added to \(name)" }
    static func alreadyIn(_ name: String) -> String { "Already in \(name). Add again?" }
    static func deleteTitle(_ name: String) -> String { "Delete \u{2018}\(name)\u{2019}?" }
    static let deleteMessage = "This removes it from Navidrome for everyone using it."
    static let removed = "Removed from the playlist"
}

/// Playlists (round 11 R8): Add to playlist, create, rename, delete and remove a song, each only on the user's own
/// explicit action (and delete only once confirmed), and only on playlists the user owns. Every change bumps
/// `playlistsRevision` so open lists read again.
extension AppModel {
    /// The playlists the signed-in user may change (their own), A–Z.
    func editablePlaylists() async throws -> [Playlist] {
        let user = session?.username ?? ""
        return try await request { try await $0.playlists() }
            .filter { $0.isEditable(by: user) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether the user may change `playlist`.
    func canEdit(_ playlist: Playlist) -> Bool {
        guard let user = session?.username, !isOffline else { return false }
        return playlist.isEditable(by: user)
    }

    /// How many of `songIds` `playlist` holds already (the "Already in" warning).
    func songsAlreadyIn(_ playlist: Playlist, of songIds: [String]) async throws -> Int {
        let (_, songs) = try await request { [id = playlist.id] in try await $0.playlist(id: id) }
        let present = Set(songs.map(\.id))
        return songIds.filter(present.contains).count
    }

    /// Appends `songIds` (repeats kept) to `playlist`.
    func add(_ songIds: [String], to playlist: Playlist) async throws {
        try await request { [id = playlist.id] in
            try await $0.updatePlaylist(id: id, name: nil, adding: songIds, removingIndexes: [])
        }
        playlistsChanged(PlaylistCopy.added(to: playlist.name))
    }

    /// A new playlist called `name` (trimmed) holding `songIds`.
    func createPlaylist(named name: String, songIds: [String]) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = try await request { try await $0.createPlaylist(name: name, songIds: songIds) }
        playlistsChanged(songIds.isEmpty ? nil : PlaylistCopy.added(to: name))
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.name else { return }
        try await request { [id = playlist.id] in try await $0.updatePlaylist(id: id, name: name, adding: [], removingIndexes: []) }
        playlistsChanged(nil)
    }

    /// Deletes `playlist` from the server (after the user confirmed).
    func deletePlaylist(_ playlist: Playlist) async throws {
        try await request { [id = playlist.id] in try await $0.deletePlaylist(id: id) }
        playlistsChanged(nil)
    }

    /// Removes the song at `index` (its position in the playlist as last read).
    func removeSong(at index: Int, from playlist: Playlist) async throws {
        try await request { [id = playlist.id] in
            try await $0.updatePlaylist(id: id, name: nil, adding: [], removingIndexes: [index])
        }
        playlistsChanged(PlaylistCopy.removed)
    }

    /// Opens the Add to playlist sheet for `songIds` (from a menu); offline it says so instead.
    func askToAddToPlaylist(_ songIds: [String]) {
        guard !songIds.isEmpty else { return }
        if isOffline { return libraryEdits.notify(Self.offlineCopy, symbol: "wifi.slash") }
        libraryEdits.addToPlaylist = AddToPlaylistRequest(songIds: songIds)
    }

    /// An album's songs for "Add all to playlist" from a tile's menu (the tile has no songs).
    func askToAddAlbumToPlaylist(_ albumId: String) async {
        do {
            let songs = try await request { try await $0.album(id: albumId) }.songs ?? []
            askToAddToPlaylist(songs.map(\.id))
        } catch {
            libraryEdits.notify(BrowseErrorCopy.message(for: error), symbol: "exclamationmark.triangle")
        }
    }

    private func playlistsChanged(_ notice: String?) {
        libraryEdits.playlistsRevision += 1
        if let notice { libraryEdits.notify(notice, symbol: "checkmark.circle") }
    }
}
