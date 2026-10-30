import Foundation
import MagpieCore
import NavidromeKit

/// Round 11 R8 copy, in the UX appraisal's words (R20: docs/reviews/ux-appraisal-round-11.md §6, §9).
enum PlaylistCopy {
    static let newPlaylist = "New playlist\u{2026}"
    static let newPlaylistTitle = "New playlist"
    static let addToPlaylist = "Add to playlist\u{2026}"
    static func added(to name: String) -> String { "Added to \(name)" }
    static func removed(from name: String) -> String { "Removed from \(name)" }
    /// One song already there: the alert's title and message.
    static func alreadyIn(_ name: String) -> String { "Already in \(name)" }
    static func addAgain(_ song: String) -> String { "Add \(song) again?" }
    /// Several songs, some already there.
    static func someAlreadyIn(_ count: Int, _ name: String) -> String {
        count == 1 ? "1 of these is already in \(name)." : "\(count) of these are already in \(name)."
    }
    static func deleteTitle(_ name: String) -> String { "Delete \u{201C}\(name)\u{201D}?" }
    static let deleteMessage = "It\u{2019}s deleted from your music server for everyone who uses it."
    static func madeBy(_ owner: String) -> String { "Made by \(owner). You can play it but not change it." }
}

/// Playlists (round 11 R8): Add to playlist, create, rename, delete and remove a song, each only on the user's own
/// explicit action (and delete only once confirmed), and only on playlists the user owns. Every change bumps
/// `playlistsRevision` so open lists read again.
extension AppModel {
    /// The playlists the signed-in user may change (their own), the most recently changed first, then A–Z.
    func editablePlaylists() async throws -> [Playlist] {
        let user = session?.username ?? ""
        return try await request { try await $0.playlists() }
            .filter { $0.isEditable(by: user) }
            .sorted { a, b in
                let (x, y) = (a.changed ?? .distantPast, b.changed ?? .distantPast)
                return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Whether the user may change `playlist`.
    func canEdit(_ playlist: Playlist) -> Bool {
        guard let user = session?.username, !isOffline else { return false }
        return playlist.isEditable(by: user)
    }

    /// Which of `songIds` `playlist` holds already, and the first one's title (the "Already in" warning).
    func songsAlreadyIn(_ playlist: Playlist, of songIds: [String]) async throws -> (ids: Set<String>, title: String?) {
        let (_, songs) = try await request { [id = playlist.id] in try await $0.playlist(id: id) }
        let wanted = Set(songIds)
        let there = songs.filter { wanted.contains($0.id) }
        return (Set(there.map(\.id)), there.first?.title)
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
        playlistsChanged(PlaylistCopy.removed(from: playlist.name))
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
