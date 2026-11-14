import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 27 D1 fix round 2 (N2, D285/D282): `Player.replaceUpcomingSongs(_:)`, the Discover page's late library copies:
/// each song still to come that has a copy becomes it in its own slot (same entry id); every other slot, the current
/// song and Play next songs stay as they are, so the engine is never handed an unchanged next item again.
@MainActor
@Suite struct ReplaceUpcomingSongsTests {
    typealias Fuzz = PlayerChaosFuzzTests
    typealias Skip = RemoteSkipTests

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    func player() -> (Player, Skip.SkipEngine) {
        let engine = Skip.SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 3
        return (player, engine)
    }

    @Test func copiesKeepEverySlotAndTheCurrentSong() {
        let (player, engine) = player()
        player.play(["h1", "c", "r1", "a1", "a2"].map(Self.song), startAt: 1)
        player.playNext([Self.song("a3")])
        let before = player.queue.upcoming.map(\.id)
        let current = player.queue.current
        let next = engine.items.dropFirst().first
        let loads = engine.loadsFromStart.count
        player.replaceUpcomingSongs(["a1": Self.song("m1"), "a2": Self.song("m2"), "a3": Self.song("m3"), "c": Self.song("mc")])

        #expect(player.queue.current == current, "the song playing is never swapped")
        #expect(player.queue.upcoming.map(\.song.id) == ["a3", "r1", "m1", "m2"], "Play next stays as chosen")
        #expect(player.queue.upcoming.map(\.id) == before, "every slot keeps its id")
        #expect(engine.loadsFromStart.count == loads, "the current song isn't reloaded")
        #expect(engine.items.dropFirst().first?.0 == next?.0 && engine.items.dropFirst().first?.1 == next?.1,
                "the unchanged next item is the same item")
    }

    @Test func nothingToSwapSendsNothing() {
        let (player, engine) = player()
        player.play(["c", "r1"].map(Self.song), startAt: 0)
        let sends = engine.items
        player.replaceUpcomingSongs(["zz": Self.song("m1")])
        #expect(engine.items.map(\.0) == sends.map(\.0))
        player.play([], startAt: 0)
        player.replaceUpcomingSongs(["c": Self.song("m1")])
        #expect(player.queue.current == nil, "idle: nothing starts")
    }
}
