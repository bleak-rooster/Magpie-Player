import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 13 item 9: CarPlay's Up Next list jumps to a song in the queue.
@MainActor
@Suite struct PlayerJumpTests {
    typealias Fuzz = PlayerChaosFuzzTests

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    func player() -> (Player, Fuzz.ChaosEngine) {
        let engine = Fuzz.ChaosEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 2
        return (player, engine)
    }

    /// The songs before it count as played (history), as skips past each would; the queue's order stays.
    @Test func jumpingPlaysTheEntryAndSkipsTheOnesBefore() throws {
        let (player, engine) = player()
        player.play(["a", "b", "c", "d"].map(Self.song), startAt: 0)
        player.toggle()   // paused: a jump plays
        let c = player.queue.upcoming[1].id
        player.jump(to: c)
        #expect(player.queue.current?.id == c)
        #expect(player.queue.main.map(\.song.id) == ["a", "b", "c", "d"])
        #expect(player.queue.upcoming.map(\.song.id) == ["d"])
        #expect(player.isPlaying)
        #expect(engine.items.first?.0 == c, "the engine plays it")
    }

    /// Up Next entries (Play Next) come first: jumping past one moves it into what has played.
    @Test func jumpingPastUpNextEntries() throws {
        let (player, _) = player()
        player.play(["a", "b"].map(Self.song), startAt: 0)
        player.playNext([Self.song("x")])
        let b = try #require(player.queue.upcoming.last?.id)
        player.jump(to: b)
        #expect(player.queue.current?.song.id == "b")
        #expect(player.queue.main.map(\.song.id) == ["a", "x", "b"])
        #expect(player.queue.upNext.isEmpty)
    }

    /// The current entry, one already played or one gone: nothing changes.
    @Test func jumpingToSomethingNotUpcomingDoesNothing() throws {
        let (player, _) = player()
        player.play(["a", "b", "c"].map(Self.song), startAt: 1)
        let a = player.queue.main[0].id, b = player.queue.main[1].id
        player.jump(to: a)
        player.jump(to: b)
        player.jump(to: UUID())
        #expect(player.queue.current?.id == b)
        #expect(player.queue.upcoming.map(\.song.id) == ["c"])
    }
}
