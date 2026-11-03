import Foundation
import MagpieCore
import Playback

// Round 13 item 9: Now Playing's Up Next button (top right) opens the queue as a list.

extension CarPlayRows {
    /// The queue: the song playing (marked), then what plays after it in order (Play Next's songs first), each a tap
    /// away from playing. Within `maxItems` rows; a longer queue ends with "Showing N of M" (songs shown of the queue's
    /// current and upcoming). The mark follows `playingId` in place (the first row of that song).
    public static func upNext(current: QueueEntry?, upcoming: [QueueEntry], maxItems: Int = .max,
                              playingId: String?) -> [CPSectionModel] {
        guard let current else { return state(.empty) }
        let total = 1 + upcoming.count
        let limit = max(1, maxItems)
        let shownUpcoming = total <= limit ? upcoming : Array(upcoming.prefix(max(0, limit - 2)))
        var marked = false
        func row(_ entry: QueueEntry) -> CPRowModel {
            let playing = !marked && entry.song.id == playingId
            if playing { marked = true }
            return CPRowModel(id: "queue.\(entry.id.uuidString)", title: display(entry.song.title, untitled),
                              detail: entry.song.artist, artworkKey: entry.song.coverArtId, playing: playing,
                              action: .queueEntry(entry.id))
        }
        var sections = [CPSectionModel(header: "Now playing", rows: [row(current)])]
        var next = shownUpcoming.map(row)
        if shownUpcoming.count < upcoming.count, limit > 1 {
            next.append(CPRowModel(id: "queue.more", title: "Showing \(1 + shownUpcoming.count) of \(total)", action: .none))
        }
        if !next.isEmpty { sections.append(CPSectionModel(header: "Up next", rows: next)) }
        return sections
    }
}
