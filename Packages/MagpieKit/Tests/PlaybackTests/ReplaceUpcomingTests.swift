import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 27 P (owner, 2026-11-14): `Player.replaceUpcoming(with:)` for Automix (D282, per Q5): what's coming up is
/// replaced; history, the current song and the songs chosen with Play next stay.
@MainActor
@Suite struct ReplaceUpcomingTests {
    typealias Fuzz = PlayerChaosFuzzTests
    typealias Skip = RemoteSkipTests

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    func player() -> (Player, Skip.SkipEngine) {
        let engine = Skip.SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 3
        return (player, engine)
    }

    @Test func replaceUpcoming_keepsCurrentAndPlayNext() {
        let (player, engine) = player()
        player.play(["h1", "c", "r1", "r2", "r3"].map(Self.song), startAt: 1)
        player.playNext([Self.song("pn")])
        let current = player.queue.current
        let loads = engine.loadsFromStart.count
        player.replaceUpcoming(with: ["m1", "m2"].map(Self.song))

        #expect(player.queue.current == current, "the current song plays on")
        #expect(player.queue.main.prefix(2).map(\.song.id) == ["h1", "c"], "history stays")
        #expect(player.queue.upNext.map(\.song.id) == ["pn"], "Play next songs stay")
        #expect(player.queue.upcoming.map(\.song.id) == ["pn", "m1", "m2"])
        #expect(engine.loadsFromStart.count == loads, "the current song isn't reloaded")
        #expect(engine.items.map(\.0) == [current!.id] + player.queue.upcoming.prefix(3).map(\.id),
                "the engine has the new window")
    }

    @Test func replaceUpcoming_idleStarts() {
        let (player, engine) = player()
        player.replaceUpcoming(with: ["m1", "m2"].map(Self.song))
        #expect(player.queue.current?.song.id == "m1")
        #expect(player.queue.upcoming.map(\.song.id) == ["m2"])
        #expect(engine.items.first?.0 == player.queue.current?.id, "loaded like Add to end on an idle queue")
    }

    @Test func replaceUpcoming_emptyClearsTheRest() {
        let (player, _) = player()
        player.play(["c", "r1"].map(Self.song), startAt: 0)
        player.playNext([Self.song("pn")])
        player.replaceUpcoming(with: [])
        #expect(player.queue.upcoming.map(\.song.id) == ["pn"])
        #expect(player.queue.current?.song.id == "c")
    }

    @Test func queue_replaceUpcomingMain() {
        var q = PlayQueue()
        q.replace(with: ["a", "b", "c"].map(Self.song), startAt: 1)
        q.playNext([Self.song("pn")])
        q.replaceUpcoming(with: ["x"].map(Self.song))
        #expect(q.main.map(\.song.id) == ["a", "b", "x"] && q.currentIndex == 1)
        #expect(q.upNext.map(\.song.id) == ["pn"])
    }
}
