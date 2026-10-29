import CarPlayUI
import Foundation
import MagpieCore
import Playback
import Testing
@testable import Magpie

/// Net crash hunt, hardening: `Int(_:)` traps on NaN and infinity. A time or length that isn't a number (a stream that
/// lost its clock, a seek past a broken length) must never reach the places that make whole seconds of it: the lock
/// screen's republish check, the scrubber's clock, album footers and CarPlay track rows.
@MainActor
@Suite struct NonFiniteTimeTests {
    let engine = FakeEngine()

    private func makePlayer() -> Player {
        Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func playerKeepsAFinitePosition(_ bad: Double) throws {
        let player = makePlayer()
        player.play([PlayerTests.song("1", duration: 0), PlayerTests.song("2")], startAt: 0)
        let id = try #require(player.queue.current?.id)
        player.handle(.time(id, 42, duration: 180))
        player.handle(.time(id, bad, duration: bad))
        #expect(player.position == 42, "a non-number time keeps the last position")
        #expect(player.duration == 180, "a non-number length keeps the last one")
        player.seek(bad)
        #expect(player.position == 42)
        #expect(!engine.seeks.contains { !$0.isFinite }, "no non-number seek reaches the engine: \(engine.seeks)")
    }

    @Test func playerClampsANegativeTick() {
        let player = makePlayer()
        player.play([PlayerTests.song("1")], startAt: 0)
        player.handle(.time(player.queue.current!.id, -0.02, duration: 200))
        #expect(player.position == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e300, -1e300])
    func lockScreenSecondsNeverTrap(_ bad: Double) {
        _ = NowPlayingBridge.wholeSeconds(bad)
        #expect(NowPlayingBridge.wholeSeconds(.nan) == 0)
        #expect(NowPlayingBridge.wholeSeconds(61.9) == 61)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e300, -1e300])
    func clocksNeverTrap(_ bad: Double) {
        #expect(!DurationText.clock(bad).isEmpty)
        _ = DurationText.minutes(bad)
        #expect(DurationText.clock(.nan) == "0:00")
        #expect(DurationText.clock(238.9) == "3:58")
    }

    @Test(arguments: [Double.nan, .infinity, 1e300])
    func carPlayTrackRowsNeverTrap(_ bad: Double) {
        let album = Album(id: "a", name: "A", artist: "B", songCount: 1, duration: 0,
                          songs: [Song(id: "s", title: "S", artist: "B", album: "A", duration: bad)])
        let rows = CarPlayRows.album(album, playingId: nil).flatMap(\.rows)
        #expect(rows.contains { $0.id.hasPrefix("track.") })
    }
}
