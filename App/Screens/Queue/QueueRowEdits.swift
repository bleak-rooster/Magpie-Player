import Foundation
import Playback

/// Swipes and drags in the queue (QC). SwiftUI reports them as offsets into the rows as they were drawn, and the
/// queue may have moved on since (a song ended, an Up Next song started). So the offsets are turned into the
/// entry ids those rows showed, and the ids are looked up in the live queue when the gesture lands. An entry that
/// has started playing or left the queue meanwhile is left alone.
@MainActor
enum QueueRowEdits {
    /// Removes the rows at `offsets` of `rendered` (one section's entry ids, as drawn) that are still to come.
    static func remove(_ offsets: IndexSet, of rendered: [UUID], player: Player) {
        let ids = offsets.filter(rendered.indices.contains).map { rendered[$0] }
        let live = Set(player.queue.upcoming.map(\.id))
        for id in ids where live.contains(id) { player.remove(id: id) }
    }

    /// VoiceOver's "Remove" on one row.
    static func remove(_ id: UUID, player: Player) {
        remove(IndexSet(integer: 0), of: [id], player: player)
    }

    /// `onMove`: row `from` of `rendered` goes before row `insertBefore` (after the section's last row when that is
    /// the row count). The drop is placed against that neighbour's live position, so it lands where it was dropped
    /// even if the queue moved on.
    static func move(_ from: IndexSet, to insertBefore: Int, in rendered: [UUID], player: Player) {
        guard let i = from.first, rendered.indices.contains(i) else { return }
        let id = rendered[i]
        var live = player.queue.upcoming.map(\.id)
        guard let at = live.firstIndex(of: id) else { return }
        live.remove(at: at)
        let target: Int
        if rendered.indices.contains(insertBefore) {
            guard rendered[insertBefore] != id, let anchor = live.firstIndex(of: rendered[insertBefore]) else { return }
            target = anchor
        } else {
            guard let last = rendered.last(where: { $0 != id }), let anchor = live.firstIndex(of: last) else { return }
            target = anchor + 1
        }
        player.move(id: id, to: target)
    }
}
