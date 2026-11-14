import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 27 A fix round 1 (design M5, D307): a builder's songs added while the queue is shuffled land at seeded random
/// places after the current song, never before it or in Up Next, and shuffle-off puts them back at the end in order.
@MainActor
@Suite struct ShuffledFillTests {
    typealias Fuzz = PlayerChaosFuzzTests
    typealias Skip = RemoteSkipTests

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    func player() -> Player {
        let player = Player(engine: Skip.SkipEngine(), scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 3
        return player
    }

    @Test func shuffledFill_landsAfterCurrentAtRandomPlaces() {
        let player = player()
        player.play((1...6).map { Self.song("k\($0)") }, startAt: 0)
        player.playNext([Self.song("pn")])
        player.setShuffled(true, seed: 3)
        let current = player.queue.current?.id
        let fill = (1...12).map { Self.song("f\($0)") }
        player.addToEnd(fill, shuffleSeed: 9)
        let main = player.queue.main.map(\.song.id)
        #expect(player.queue.current?.id == current && main.first == player.queue.current?.song.id, "current stays first")
        #expect(Set(main) == Set((1...6).map { "k\($0)" } + fill.map(\.id)))
        #expect(main.suffix(12) != fill.map(\.id), "not all bunched at the end in order")
        #expect(player.queue.upNext.map(\.song.id) == ["pn"], "never into Up Next")
        player.setShuffled(false)
        #expect(player.queue.main.map(\.song.id) == (1...6).map { "k\($0)" } + fill.map(\.id), "shuffle-off: the fill at the end, in order")
    }

    @Test func unshuffledFill_isAnAppend() {
        let player = player()
        player.play([Self.song("a"), Self.song("b")], startAt: 0)
        player.addToEnd([Self.song("c"), Self.song("d")], shuffleSeed: 1)
        #expect(player.queue.main.map(\.song.id) == ["a", "b", "c", "d"])
    }
}
