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
    static let changedMeanwhile = "That playlist changed, so nothing was removed. Here it is again."
}

/// Why a playlist edit didn't go through (review fixes I1, I4).
enum PlaylistEditError: Error, Equatable {
    /// Someone else's playlist (or read-only): nothing was sent.
    case notYours
    /// The connection dropped, and reading back showed the change didn't happen.
    case notChanged
    /// The connection dropped, and the playlist couldn't be read back either.
    case outcomeUnknown

    var message: String {
        switch self {
        case .notYours: "That playlist isn\u{2019}t yours, so Magpie can\u{2019}t change it."
        case .notChanged: "Your music server didn\u{2019}t answer, so the playlist hasn\u{2019}t changed."
        case .outcomeUnknown:
            "Your music server stopped answering, so Magpie can\u{2019}t tell whether the playlist changed. Look again when it\u{2019}s back."
        }
    }

    /// What to say about a failed playlist edit.
    static func message(for error: Error) -> String {
        (error as? PlaylistEditError)?.message ?? BrowseErrorCopy.message(for: error)
    }
}

/// One at a time per key (a playlist's edits, one item's favourite): each `run` waits for the ones before it.
@MainActor final class KeyedLock<Key: Hashable> {
    private var busy: Set<Key> = []
    private var waiting: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func run<T>(_ key: Key, _ body: () async throws -> T) async throws -> T {
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    private func acquire(_ key: Key) async {
        guard busy.contains(key) else { busy.insert(key); return }
        await withCheckedContinuation { waiting[key, default: []].append($0) }   // handed over by `release`
    }

    private func release(_ key: Key) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            next.resume()   // `key` stays busy: it passes to the next in line
        } else {
            busy.remove(key)
        }
    }
}

/// Playlists (round 11 R8): Add to playlist, create, rename, delete and remove a song, each only on the user's own
/// explicit action (and delete only once confirmed), and only on playlists the user owns. Every change bumps
/// `playlistsRevision` so open lists read again.
extension AppModel {
    /// The playlists the signed-in user may change (their own), the most recently changed first, then A–Z.
    func editablePlaylists() async throws -> [Playlist] {
        let user = session?.username ?? ""
        return try await request { try await $0.playlists() }
            .filter { Self.isOwn($0, by: user) && !isDiscoverPlaylist($0) }   // Y6: never Aurral's
            .sorted { a, b in
                let (x, y) = (a.changed ?? .distantPast, b.changed ?? .distantPast)
                return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Whether the user may change `playlist`.
    func canEdit(_ playlist: Playlist) -> Bool {
        guard let user = session?.username, !isOffline, !isDiscoverPlaylist(playlist) else { return false }   // Y6
        return Self.isOwn(playlist, by: user)
    }

    /// Which of `songIds` `playlist` holds already, and the first one's title (the "Already in" warning).
    func songsAlreadyIn(_ playlist: Playlist, of songIds: [String]) async throws -> (ids: Set<String>, title: String?) {
        let (_, songs) = try await request { [id = playlist.id] in try await $0.playlist(id: id) }
        let wanted = Set(songIds)
        let there = songs.filter { wanted.contains($0.id) }
        return (Set(there.map(\.id)), there.first?.title)
    }

    /// Appends `songIds` (repeats kept) to `playlist`, if it is the user's.
    func add(_ songIds: [String], to playlist: Playlist) async throws {
        try await libraryEdits.playlistLocks.run(playlist.id) {
            let (fresh, before) = try await ownPlaylist(playlist)
            try await sendOnce({ [id = fresh.id] in
                try await $0.updatePlaylist(id: id, name: nil, adding: songIds, removingIndexes: [])
            }, landed: {
                // Ours went on the end, whatever else changed meanwhile (re-review N2).
                let after = try await self.songIds(in: fresh)
                return after.count == before.count + songIds.count && Array(after.suffix(songIds.count)) == songIds
            })
            playlistsChanged(PlaylistCopy.added(to: fresh.name))
        }
    }

    /// A new playlist called `name` (trimmed) holding `songIds`.
    func createPlaylist(named name: String, songIds: [String]) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // A double tap on Create makes one playlist (re-review N4): a second Create while one is under way does nothing.
        guard !libraryEdits.creatingPlaylist else { return }
        libraryEdits.creatingPlaylist = true
        defer { libraryEdits.creatingPlaylist = false }
        let user = session?.username ?? ""
        let before = Set(try await request { try await $0.playlists() }.map(\.id))
        try await sendOnce({ _ = try await $0.createPlaylist(name: name, songIds: songIds) }, landed: {
            try await self.request { try await $0.playlists() }
                .contains { !before.contains($0.id) && $0.name == name && Self.isOwn($0, by: user) }
        })
        playlistsChanged(songIds.isEmpty ? nil : PlaylistCopy.added(to: name))
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try await libraryEdits.playlistLocks.run(playlist.id) {
            let (fresh, _) = try await ownPlaylist(playlist)
            guard name != fresh.name else { return }
            try await sendOnce({ [id = fresh.id] in
                try await $0.updatePlaylist(id: id, name: name, adding: [], removingIndexes: [])
            }, landed: {
                try await self.request { [id = fresh.id] in try await $0.playlist(id: id) }.0.name == name
            })
            playlistsChanged(nil)
        }
    }

    /// Deletes `playlist` from the server (after the user confirmed), if it is the user's.
    func deletePlaylist(_ playlist: Playlist) async throws {
        try await libraryEdits.playlistLocks.run(playlist.id) {
            let (fresh, _) = try await ownPlaylist(playlist)
            try await sendOnce({ [id = fresh.id] in try await $0.deletePlaylist(id: id) }, landed: {
                try await !self.request { try await $0.playlists() }.contains { $0.id == fresh.id }
            })
            playlistsChanged(nil)
        }
    }

    /// Removes `songId` from `playlist`, at `index` (its position on the page). Subsonic removes by position only, so
    /// the playlist is read first (after any edit to it still under way): if `songId` isn't at `index` any more, the
    /// playlist changed meanwhile, nothing is removed, and the page reads again (review fix I2).
    func removeSong(at index: Int, songId: String, from playlist: Playlist) async throws {
        try await libraryEdits.playlistLocks.run(playlist.id) {
            let (fresh, songs) = try await ownPlaylist(playlist)
            guard songs.indices.contains(index), songs[index].id == songId else {
                return playlistsChanged(PlaylistCopy.changedMeanwhile, symbol: "arrow.clockwise")
            }
            var expected = songs.map(\.id)
            expected.remove(at: index)
            try await sendOnce({ [id = fresh.id] in
                try await $0.updatePlaylist(id: id, name: nil, adding: [], removingIndexes: [index])
            }, landed: { [expected] in try await self.songIds(in: fresh) == expected })
            playlistsChanged(PlaylistCopy.removed(from: fresh.name))
        }
    }

    /// The playlist as the server has it now, if the user may change it. Every write checks here, not only the
    /// screens (review fix I4): Navidrome lets an admin change anyone's playlist, so the server is no backstop. The
    /// server's current owner decides, whatever `playlist` says.
    /// Round 12 Y6: never a Discover playlist (Aurral's), though the server names the owner as its owner.
    func ownPlaylist(_ playlist: Playlist) async throws -> (Playlist, [Song]) {
        let user = session?.username ?? ""
        guard Self.isOwn(playlist, by: user), !isDiscoverPlaylist(playlist) else { throw PlaylistEditError.notYours }
        let (fresh, songs) = try await request { [id = playlist.id] in try await $0.playlist(id: id) }
        guard Self.isOwn(fresh, by: user), !isDiscoverPlaylist(fresh) else { throw PlaylistEditError.notYours }
        return (fresh, songs)
    }

    /// The user's own: the server names them as its owner (an unnamed owner is refused, whatever `readonly` says:
    /// re-review N1) and doesn't call it read-only.
    nonisolated static func isOwn(_ playlist: Playlist, by user: String) -> Bool {
        guard let owner = playlist.owner, !owner.isEmpty, !user.isEmpty else { return false }
        return playlist.isEditable(by: user)
    }

    func songIds(in playlist: Playlist) async throws -> [String] {
        try await request { [id = playlist.id] in try await $0.playlist(id: id) }.1.map(\.id)
    }

    /// Sends a playlist change exactly once (review fix I1: it isn't safe to repeat; a repeated remove-by-position
    /// would take a different song). If the connection drops, `landed` reads back whether it happened: if so, it
    /// counts as done; if not, or if that can't be told, the lists read again and the error says which.
    func sendOnce(_ op: @Sendable (NavidromeClient) async throws -> Void,
                          landed: () async throws -> Bool) async throws {
        do {
            try await requestOnce(op)
        } catch where Self.isConnectionError(error) {
            let happened: Bool
            do { happened = try await landed() } catch {
                playlistsChanged(nil)
                throw PlaylistEditError.outcomeUnknown
            }
            guard happened else {
                playlistsChanged(nil)
                throw PlaylistEditError.notChanged
            }
        }
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

    func playlistsChanged(_ notice: String?, symbol: String = "checkmark.circle") {
        libraryEdits.playlistsRevision += 1
        if let notice { libraryEdits.notify(notice, symbol: symbol) }
    }
}
