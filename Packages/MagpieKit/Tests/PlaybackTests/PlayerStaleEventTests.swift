import Foundation
import Testing
import MagpieCore
@testable import Playback

/// Crash hunt 1, found by `PlayerChaosFuzzTests`: engine events are buffered (an `AsyncStream`), so one can arrive
/// after the player has already sent the engine a new list.
@MainActor
@Suite struct PlayerStaleEventTests {
    typealias Fuzz = PlayerChaosFuzzTests

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    /// The engine moved on to `b` by itself, but before its `.itemChanged(b)` was handled the listener moved `b` to the
    /// end of the queue. The player re-sent `[a, c]` (the engine reloads `a`), so the late `.itemChanged(b)` is about a
    /// list the engine no longer holds: the player must stay on `a`, the entry the engine plays, not jump to `b` (which
    /// left the lock screen naming a song that wasn't playing, its ticks dropped as stale and the window never topped up).
    @Test func lateItemChangedForAnEntryNoLongerSentIsIgnored() throws {
        let engine = Fuzz.ChaosEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 1
        player.play(["a", "b", "c", "d"].map(Self.song), startAt: 0)
        let a = try #require(player.queue.current?.id)
        let b = player.queue.upcoming[0].id
        #expect(engine.items.map(\.0) == [a, b])

        player.move(id: b, to: 10)   // b goes to the end; the engine is sent [a, c]
        #expect(!engine.items.map(\.0).contains(b))
        player.handle(.itemChanged(b))   // the late event about the old list

        #expect(player.queue.current?.id == a, "the player stays on the entry the engine was told to play")
        #expect(engine.items.map(\.0).contains(player.queue.current!.id))
    }

    /// A late `.itemChanged` for an entry the engine still holds is a real advance and is followed.
    @Test func itemChangedForASentEntryAdvances() throws {
        let engine = Fuzz.ChaosEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 2
        player.play(["a", "b", "c"].map(Self.song), startAt: 0)
        let b = player.queue.upcoming[0].id
        player.handle(.itemChanged(b))
        #expect(player.queue.current?.id == b)
        #expect(engine.items.map(\.0).first { $0 == b } != nil)
    }
}
