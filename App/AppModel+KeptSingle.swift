import Foundation
import MagpieCore
import NavidromeKit
import Requests

/// Round 22 (owner, 2026-11-06, D171–D173): the kept single after Bring in more. The runner decides and writes Lidarr
/// (RequestRunner+KeptSingle.swift); the app changes the choice from the request page and, before the single's files
/// go, points the owner's own playlists that hold its song at the album's copy, in place (D173). The queue follows the
/// request's new song through `onRelinked` (`keptSongRelinked`), as after a Keep.
extension AppModel {
    /// The request page's Keep it / Remove it once the album is here, while the bring-in is under way.
    func setKeptSingle(_ id: RequestID, remove: Bool) async {
        guard let runner else { return }
        _ = await runner.setKeptSingle(id, remove: remove)
        pollRequests()
    }

    /// Every one of the user's own playlists that holds `from` holds `to` there instead, in the same places, each in one
    /// checked send (as "Use your library's copy"). True: done, or none held it. False: a playlist couldn't be read or
    /// changed safely (its listing hides entries, it's too long, offline): the single waits.
    func repointEverywhere(from: String, to: Song) async -> Bool {
        guard !isOffline, let lists = try? await editablePlaylists() else { return false }
        var changed = 0
        for list in lists {
            do {
                let done: Bool? = try await libraryEdits.playlistLocks.run(list.id) {
                    let (fresh, songs) = try await ownPlaylist(list)
                    let ids = songs.map(\.id)
                    guard ids.contains(from) else { return false }
                    guard fresh.songCount == ids.count, ids.count <= Self.libraryCopySwapLimit else { return nil }
                    let expected = Self.repointed(ids, from: from, to: to.id)
                    try await sendOnce({ [id = fresh.id, all = Array(ids.indices)] in
                        try await $0.updatePlaylist(id: id, name: nil, adding: expected, removingIndexes: all)
                    }, landed: { [expected] in try await self.songIds(in: fresh) == expected })
                    return true
                }
                switch done {
                case true?: changed += 1
                case false?: break
                case nil: return false
                }
            } catch {
                return false
            }
        }
        if changed > 0 { playlistsChanged(nil) }
        return true
    }

    /// `ids` with every `from` replaced by `to`, in place. Pure (tested).
    nonisolated static func repointed(_ ids: [String], from: String, to: String) -> [String] {
        ids.map { $0 == from ? to : $0 }
    }
}
