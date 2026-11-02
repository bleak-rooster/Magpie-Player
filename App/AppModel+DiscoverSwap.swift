import AurralKit
import Foundation
import MagpieCore
import NavidromeKit

/// Round 12 Y6 (plan item 7): "Use your library's copy" in the owner's OWN playlists (never Aurral's). A playlist that
/// holds Aurral's copy of a song keeps Aurral from deleting the file at its weekly run; swapping it for the library's
/// copy, in the same place, lets the flow rotate it out. Sent through X3's checked write: the owner's playlist only (the
/// server's current owner decides), never a Discover playlist, one send, read back if the connection drops.
extension AppModel {
    /// Most songs the swap rewrites in one send (the whole list goes in one request).
    nonisolated static let libraryCopySwapLimit = 500

    /// The positions of `songs` (an own playlist's) that are Aurral copies with a library copy, and that copy. Aurral
    /// copies are the songs in Aurral's library (fix I2: rotated out of every flow too; saved per account) and every flow
    /// song seen (Discover is read first if nothing is known yet).
    func aurralCopiesInOwnPlaylist(_ playlist: Playlist, songs: [Song]) async -> [Int: Song] {
        guard aurralSetUp, !isOffline, canEdit(playlist), !isDiscoverPlaylist(playlist) else { return [:] }
        if knownAurralSongIds.isEmpty { await readFlowSongs() }
        let known = knownAurralSongIds
        let flow = songs.enumerated().filter { known.contains($0.element.id) }
        guard !flow.isEmpty else { return [:] }
        let copies = await libraryCopies(for: flow.map(\.element), flowId: nil)
        var result: [Int: Song] = [:]
        for (index, song) in flow { if let copy = copies[song.id] { result[index] = copy } }
        return result
    }

    /// Reads Discover (its playlists' songs and Aurral's library), best effort.
    func readFlowSongs() async {
        await refreshDiscover(force: true)
    }

    /// "Use your library's copy": every Aurral copy in the owner's playlist that the library has replaced by that copy,
    /// in place, in one checked send. Returns how many were swapped (0: nothing to do, nothing sent).
    @discardableResult
    func useLibraryCopies(in playlist: Playlist) async throws -> Int {
        guard !isDiscoverPlaylist(playlist) else { throw PlaylistEditError.notYours }   // never Aurral's playlists
        return try await libraryEdits.playlistLocks.run(playlist.id) {
            let (fresh, songs) = try await ownPlaylist(playlist)   // ownership (and not Discover's), read fresh
            let copies = await aurralCopiesInOwnPlaylist(fresh, songs: songs)
            guard !copies.isEmpty else { return 0 }
            guard songs.count <= Self.libraryCopySwapLimit else { throw DiscoverSwapError.tooLong }
            let expected = songs.enumerated().map { copies[$0.offset]?.id ?? $0.element.id }
            try await sendOnce({ [id = fresh.id, all = Array(songs.indices)] in
                try await $0.updatePlaylist(id: id, name: nil, adding: expected, removingIndexes: all)
            }, landed: { [expected] in try await self.songIds(in: fresh) == expected })
            playlistsChanged(DiscoverCopy.usedLibraryCopies(copies.count))
            return copies.count
        }
    }
}

enum DiscoverSwapError: Error, Equatable {
    case tooLong

    static func message(for error: Error) -> String {
        if error as? DiscoverSwapError == .tooLong { return DiscoverCopy.tooLong }
        return PlaylistEditError.message(for: error)
    }
}
