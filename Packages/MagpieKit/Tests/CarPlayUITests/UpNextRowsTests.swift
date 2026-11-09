import Foundation
import MagpieCore
import Playback
import Testing
@testable import CarPlayUI

/// Round 13 item 9: Now Playing's Up Next button opens the queue: the song playing marked, then what plays after it; a
/// tap jumps there. Paged past the car's ceiling (round 24, D231) and within its template depth (5).
@Suite struct UpNextRowsTests {
    func entries(_ ids: [String]) -> [QueueEntry] {
        ids.map { QueueEntry(song: Song(id: $0, title: "T\($0)", artist: "A\($0)", album: "B", duration: 60, coverArtId: "c\($0)")) }
    }

    @Test func theSongPlayingThenWhatComesNext() {
        let queue = entries(["a", "b", "c"])
        let sections = CarPlayRows.upNext(current: queue[0], upcoming: Array(queue.dropFirst()), playingId: "a")
        #expect(sections.map(\.header) == ["Now playing", "Up next"])
        let rows = sections.flatMap(\.rows)
        #expect(rows.map(\.title) == ["Ta", "Tb", "Tc"])
        #expect(rows.map(\.detail) == ["Aa", "Ab", "Ac"])
        #expect(rows.map(\.playing) == [true, false, false])
        #expect(rows.map(\.artworkKey) == ["ca", "cb", "cc"])
        #expect(rows.map(\.action) == queue.map { .queueEntry($0.id) })
        #expect(Set(rows.map(\.id)).count == 3, "the same song twice is two rows")
    }

    /// When the song changes while the list is open, the mark moves in place (same rows).
    @Test func theMarkFollowsTheSongPlaying() {
        let queue = entries(["a", "b", "b"])
        let rows = CarPlayRows.upNext(current: queue[0], upcoming: Array(queue.dropFirst()), playingId: "b").flatMap(\.rows)
        #expect(rows.map(\.playing) == [false, true, false], "only the first of a repeated song")
    }

    /// Round 24 (D231): the whole queue, for the controller to page past the ceiling; never "Showing N of M".
    @Test func aLongQueueIsWhole() {
        let queue = entries((0..<30).map(String.init))
        let rows = CarPlayRows.upNext(current: queue[0], upcoming: Array(queue.dropFirst()), playingId: "0").flatMap(\.rows)
        #expect(rows.count == 30)
        #expect(!rows.contains { $0.title.hasPrefix("Showing") })
    }

    @Test func anEmptyQueueSaysNothingHere() {
        #expect(CarPlayRows.upNext(current: nil, upcoming: [], playingId: nil) == CarPlayRows.state(.empty))
    }

    /// Up Next is pushed above Now Playing only while that stays within CarPlay's depth of 5; otherwise the car goes
    /// back to the tab first (Now Playing, then Up Next).
    @Test func upNextFitsTheDepth() {
        #expect(CPNavigator.upNextFits(stackDepth: 2))
        #expect(CPNavigator.upNextFits(stackDepth: 4))
        #expect(!CPNavigator.upNextFits(stackDepth: 5))
    }
}
