import Foundation
import MagpieCore
import Playback

// Round 13 item 9: Now Playing's Up Next button (top right) opens the queue as a list.

extension CarPlayRows {
    /// The button's title and the list's.
    public static let upNextTitle = "Up Next"

    /// The queue: the song playing (marked), then what plays after it in order (Play Next's songs first), each a tap
    /// away from playing. The mark follows `playingId` in place (the first row of that song). Round 24 (D231): the whole
    /// queue; past the car's ceiling the controller pages it with "More…", so it never says "Showing N of M".
    public static func upNext(current: QueueEntry?, upcoming: [QueueEntry], playingId: String?) -> [CPSectionModel] {
        guard let current else { return state(.empty) }
        var marked = false
        func row(_ entry: QueueEntry) -> CPRowModel {
            let playing = !marked && entry.song.id == playingId
            if playing { marked = true }
            return CPRowModel(id: "queue.\(entry.id.uuidString)", title: display(entry.song.title, untitled),
                              detail: entry.song.artist, artworkKey: entry.song.coverArtId, playing: playing,
                              action: .queueEntry(entry.id))
        }
        var sections = [CPSectionModel(header: "Now playing", rows: [row(current)])]
        let next = upcoming.map(row)
        if !next.isEmpty { sections.append(CPSectionModel(header: "Up next", rows: next)) }
        return sections
    }
}
