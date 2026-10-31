import Foundation
import MagpieCore

// X2 stub of X3's shared interface (round11-common.md): same names and signatures, same path, so the merge with X3
// replaces this file. Songs only, through Now Playing's existing star.

enum FavouriteTarget: Hashable {
    case song(String), album(String), artist(String)
}

extension AppModel {
    func isFavourite(_ t: FavouriteTarget) -> Bool {
        guard let song = queuedSong(t) else { return false }
        return isStarred(song)
    }

    func setFavourite(_ t: FavouriteTarget, _ on: Bool) async {
        guard let song = queuedSong(t), isStarred(song) != on else { return }
        await toggleStar(song)
    }

    private func queuedSong(_ t: FavouriteTarget) -> Song? {
        guard case .song(let id) = t else { return nil }
        let queue = player.queue
        return (queue.main + queue.upNext).first { $0.song.id == id }?.song
    }
}
