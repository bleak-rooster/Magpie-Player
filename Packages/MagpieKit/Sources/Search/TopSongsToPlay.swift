import Foundation
import MagpieCore

/// Round 27 A (owner item 1, 2026-11-14: "When you go into an artist, there should be an option to play the top songs. It
/// should start in sequence, but in the queue there should be maximum 15 of the top songs so you can then select to
/// shuffle them."; D304): the list Play top songs queues. Pure: the app gathers the tiers in order (an artist Lidarr has:
/// their saved fifteen, D303; any other: the shown rows' library songs, Navidrome's top songs, then the source's further
/// library rows) and this joins them.
public enum TopSongsToPlay {
    /// "maximum 15 of the top songs".
    public static let limit = LidarrTopSongs.playLimit

    /// The tiers in order, joined: a song already in (by id, or by its strict title, `TopSongIdentity`: two copies of one
    /// song) is skipped, as is a Discover copy (`discoverSongIds`, or a song in one of `discoverLibraries`), a find
    /// (`isFind`) and, offline (`onPhone`), a song not on the phone. Cut at fifteen.
    public static func list(_ tiers: [[Song]], discoverSongIds: Set<String> = [], discoverLibraries: Set<Int> = [],
                            onPhone: Set<String>? = nil, isFind: (Song) -> Bool = { _ in false }) -> [Song] {
        var picked: [Song] = []
        var ids = Set<String>(), titles = Set<String>()
        for song in tiers.joined() where picked.count < limit {
            guard !discoverSongIds.contains(song.id), song.libraryId.map(discoverLibraries.contains) != true,
                  onPhone?.contains(song.id) ?? true, !isFind(song) else { continue }
            guard admit(song, ids: &ids, titles: &titles) else { continue }
            picked.append(song)
        }
        return picked
    }

    /// What the fill adds behind `queued` (what Play top songs started with): the songs of `full` (already through
    /// `list`) not queued, in order, so the queue holds at most fifteen top songs in all.
    public static func fill(queued: [Song], full: [Song]) -> [Song] {
        var ids = Set<String>(), titles = Set<String>()
        for song in queued { _ = admit(song, ids: &ids, titles: &titles) }
        let room = max(limit - queued.count, 0)
        var added: [Song] = []
        for song in full where added.count < room {
            if admit(song, ids: &ids, titles: &titles) { added.append(song) }
        }
        return added
    }

    /// Notes `song` and says whether it is new (by id, and by its strict title when it has one).
    private static func admit(_ song: Song, ids: inout Set<String>, titles: inout Set<String>) -> Bool {
        let title = TopSongIdentity.titleKey(song.title)
        guard !ids.contains(song.id), title.isEmpty || !titles.contains(title) else { return false }
        ids.insert(song.id)
        if !title.isEmpty { titles.insert(title) }
        return true
    }
}
