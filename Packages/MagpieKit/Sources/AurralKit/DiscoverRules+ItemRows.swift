import Foundation
import MagpieCore

/// Round 26 L (owner, 2026-11-11): "the changes for picking up the aurral flow/playlist with the same name under
/// different users (two separate flows/playlists) still doesn't work". Their two "Chill" playlists are "only in
/// Aurral, they are not present in Navidrome" (D271, D272).
///
/// Rounds 24 A and 25 J gave a Navidrome playlist its Aurral item by evidence (`DiscoverIdentity`), but Discover's rows
/// were still Navidrome playlists only. An item with no Navidrome playlist had no row at all (only mine: nothing), and
/// a playlist of a shared name that nothing could prove (empty: no songs to go by) was listed under everyone's with no
/// owner, once per playlist. Now an Aurral item no Navidrome playlist is known to be is a row of its own, by its Aurral
/// id, with its owner from Aurral; a Navidrome claim is needed only to open and play songs.
extension DiscoverRules {
    /// What `itemRows` decided.
    public struct ItemRows: Sendable, Equatable {
        /// The Aurral items (ids, in the order given) that are rows of their own.
        public var items: [String]
        /// Aurral's Navidrome playlists (ids) that are never rows: named as an item, claimed by none, and empty.
        public var hidden: Set<String>
    }

    /// `items`: every Aurral item listed (the user's and, as an admin reads them, other users'); `linked`: the items a
    /// Navidrome playlist is known to be (claimed this read, or kept with it, D75); `unclaimed`: Aurral's Navidrome
    /// playlists named as an item that no item claimed (D202's Q1); `empty`: those of them holding no songs.
    /// - An unclaimed **empty** playlist is never a row: there is nothing in it to play and no owner known, and the
    ///   items it may be are rows of their own (D271).
    /// - An unlinked item is a row of its own, unless an unclaimed playlist **with songs** is named as it (any of
    ///   `aurralNames(of:)`, or with a copy number): that playlist may be it (whose is never guessed, D202's Q1) and
    ///   stays its row, so one item is never two rows (D272). The name only ever withholds a row; it never decides
    ///   whose an item or a playlist is.
    public static func itemRows(items: [AurralFlow], linked: Set<String>, unclaimed: [Playlist],
                                empty: Set<String>) -> ItemRows {
        var standing = Set<String>()   // folded names of the unclaimed playlists with songs, and without a copy number
        for playlist in unclaimed where !empty.contains(playlist.id) {
            let name = normalised(playlist.name)
            guard !name.isEmpty else { continue }
            standing.insert(name)
            if let base = withoutCopyNumber(name) { standing.insert(base) }
        }
        var seen = Set<String>()
        let rows = items.filter { item in
            guard !item.id.isEmpty, seen.insert(item.id).inserted, !linked.contains(item.id) else { return false }
            return !aurralNames(of: item).contains(where: standing.contains)
        }
        return ItemRows(items: rows.map(\.id), hidden: Set(unclaimed.map(\.id)).intersection(empty))
    }
}
