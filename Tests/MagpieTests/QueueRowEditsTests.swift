import Foundation
import MagpieCore
import Playback
import Testing
@testable import Magpie

/// QC (crash report #3): a swipe or drag in the queue acts on the entries its rows showed, looked up in the live
/// queue when the gesture lands. A song that started playing or left the queue since is left alone.
@MainActor
@Suite struct QueueRowEditsTests {
    static func songs(_ ids: String...) -> [Song] {
        ids.map { Song(id: $0, title: "T\($0)", artist: "A", album: "B", duration: 200) }
    }

    let engine = FakeEngine()

    func makePlayer(_ ids: String..., upNext: [String] = []) -> Player {
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        player.play(ids.map { Song(id: $0, title: "T\($0)", artist: "A", album: "B", duration: 200) }, startAt: 0)
        if !upNext.isEmpty { player.playNext(upNext.map { Song(id: $0, title: "T\($0)", artist: "A", album: "B", duration: 200) }) }
        return player
    }

    func upcoming(_ player: Player) -> [String] { player.queue.upcoming.map(\.song.id) }
    func rows(_ entries: [QueueEntry]) -> [UUID] { entries.map(\.id) }

    /// With the queue as drawn, a drag lands where it was dropped (the old index math, both sections).
    @Test func dragsLandWhereDropped() {
        let player = makePlayer("now", "a", "b", "c", "d")
        var rest = rows(player.queue.upcoming)
        QueueRowEdits.move(IndexSet(integer: 0), to: 3, in: rest, player: player)      // a below c
        #expect(upcoming(player) == ["b", "c", "a", "d"])
        rest = rows(player.queue.upcoming)
        QueueRowEdits.move(IndexSet(integer: 3), to: 0, in: rest, player: player)      // d to the top
        #expect(upcoming(player) == ["d", "b", "c", "a"])
        rest = rows(player.queue.upcoming)
        QueueRowEdits.move(IndexSet(integer: 1), to: 2, in: rest, player: player)      // dropped where it was
        #expect(upcoming(player) == ["d", "b", "c", "a"])
        rest = rows(player.queue.upcoming)
        QueueRowEdits.move(IndexSet(integer: 0), to: 4, in: rest, player: player)      // d to the end
        #expect(upcoming(player) == ["b", "c", "a", "d"])
    }

    /// Up Next and the rest are separate sections; a drag to either end of Up Next stays in Up Next.
    @Test func upNextSectionKeepsItsEntries() {
        let player = makePlayer("now", "a", "b", upNext: ["x", "y"])
        let upNext = rows(player.queue.upNext)
        QueueRowEdits.move(IndexSet(integer: 0), to: 2, in: upNext, player: player)
        #expect(player.queue.upNext.map(\.song.id) == ["y", "x"])
        #expect(upcoming(player) == ["y", "x", "a", "b"])
        let rest = rows(Array(player.queue.upcoming.dropFirst(player.queue.upNext.count)))
        QueueRowEdits.move(IndexSet(integer: 1), to: 0, in: rest, player: player)
        #expect(player.queue.upNext.map(\.song.id) == ["y", "x"], "a drag in the rest stays out of Up Next")
        #expect(upcoming(player) == ["y", "x", "b", "a"])
    }

    /// The song moved on between drawing the rows and the drag: the dragged row still lands before the row it was
    /// dropped on (the old index math put it one place off).
    @Test func dragAfterAnAdvanceLandsBeforeTheDropRow() {
        let player = makePlayer("now", "a", "b", "c", "d")
        let rest = rows(player.queue.upcoming)                 // drawn: a b c d
        player.handle(.itemChanged(rest[0]))                   // a starts playing
        QueueRowEdits.move(IndexSet(integer: 3), to: 1, in: rest, player: player)   // d dropped on b
        #expect(player.queue.current?.song.id == "a")
        #expect(upcoming(player) == ["d", "b", "c"])
    }

    /// Swiping away an Up Next row whose song has just started playing doesn't remove the playing song.
    @Test func swipeOnASongThatStartedPlayingIsIgnored() {
        let player = makePlayer("now", "a", upNext: ["x", "y"])
        let upNext = rows(player.queue.upNext)                 // drawn: x y
        player.handle(.itemChanged(upNext[0]))                 // x starts playing
        QueueRowEdits.remove(IndexSet(integer: 0), of: upNext, player: player)
        #expect(player.queue.current?.song.id == "x", "the playing song stays")
        #expect(upcoming(player) == ["y", "a"])
        QueueRowEdits.remove(IndexSet(integer: 1), of: upNext, player: player)
        #expect(upcoming(player) == ["a"], "y, still to come, goes")
    }

    /// A row whose entry left the queue meanwhile (Not for me, Clear) is ignored, and a drag onto it does nothing.
    @Test func goneEntriesAreIgnored() {
        let player = makePlayer("now", "a", "b", "c")
        let rest = rows(player.queue.upcoming)
        player.remove(id: rest[1])                             // b goes
        let loads = engine.setItemsCalls.count
        QueueRowEdits.remove(IndexSet(integer: 1), of: rest, player: player)
        QueueRowEdits.move(IndexSet(integer: 1), to: 0, in: rest, player: player)
        QueueRowEdits.move(IndexSet(integer: 2), to: 1, in: rest, player: player)
        #expect(upcoming(player) == ["a", "c"])
        #expect(engine.setItemsCalls.count == loads, "nothing to re-send")
        QueueRowEdits.remove(IndexSet(integer: 9), of: rest, player: player)
        #expect(upcoming(player) == ["a", "c"])
    }
}
