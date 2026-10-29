import Foundation
import MagpieCore
import Playback
import Testing

/// Counts the stream URLs and ReplayGain volumes the player asks for.
@MainActor
final class CountingURLs: StreamURLProvider {
    var urls = 0
    var gains = 0
    func streamURL(for song: Song) -> URL {
        urls += 1
        return URL(string: "http://192.168.1.2:4533/rest/stream?id=\(song.id)")!
    }
}

/// QC (crash report #1): on a library-sized queue every edit resolves URLs and volumes only for the window the
/// engine can use (the current entry plus K), so the main actor never does per-song work for the whole queue.
@MainActor
@Suite struct PlayerWindowTests {
    static let k = EngineWindow.size()

    static func songs(_ n: Int, from start: Int = 0) -> [Song] {
        (start..<(start + n)).map { Song(id: "s\($0)", title: "T\($0)", artist: "A", album: "B", duration: 200) }
    }

    let engine = FakeEngine()
    let counting = CountingURLs()

    func makePlayer() -> Player {
        let counting = self.counting
        return Player(engine: engine, scrobbler: FakeScrobbler(), urls: counting,
                      gain: { _ in counting.gains += 1; return 1 })
    }

    /// What the engine should hold: the current entry, then the next K playable ones.
    func expectWindow(_ player: Player, _ note: String) {
        guard let current = player.queue.current, let sent = engine.setItemsCalls.last else {
            Issue.record("\(note): nothing sent")
            return
        }
        let wanted = [current.id] + player.queue.upcoming.prefix(Self.k).map(\.id)
        #expect(sent.items.map(\.0) == wanted, "\(note): the engine holds the current entry plus \(Self.k)")
        #expect(sent.startAt == 0)
    }

    @Test func longQueueEditsResolveOnlyTheWindow() {
        let player = makePlayer()
        player.play(Self.songs(5000), startAt: 0)
        #expect(counting.urls == Self.k + 1 && counting.gains == Self.k + 1, "starting resolves the window only")
        expectWindow(player, "play")

        let far = player.queue.upcoming[2500].id, farther = player.queue.upcoming[4000].id
        let extra = Self.songs(1, from: 9000)
        let edits: [(String, () -> Void)] = [
            ("Play Next", { player.playNext(extra) }),
            ("Add to Queue", { player.addToEnd(extra) }),
            ("move", { player.move(id: far, to: 1) }),
            ("remove", { player.remove(id: farther) }),
            ("shuffle on", { player.setShuffled(true, seed: 7) }),
            ("shuffle off", { player.setShuffled(false) }),
            ("quality change", { player.upcomingURLsChanged() }),
            ("failover", { player.urlsInvalidated() }),
            ("Keep", { player.replaceSong(id: "s3000", with: Song(id: "lib-3000", title: "T", artist: "A", album: "B", duration: 200)) }),
            ("tick", { player.handle(.time(player.queue.current!.id, 12, duration: 200)) }),
            ("gapless advance", { player.handle(.itemChanged(player.queue.upcoming[0].id)) }),
            ("skip", { player.next() }),
            ("repeat one", { player.repeatMode = .one }),
            ("repeat off", { player.repeatMode = .off }),
        ]
        for (name, edit) in edits {
            counting.urls = 0
            counting.gains = 0
            let clock = ContinuousClock()
            let elapsed = clock.measure { edit() }
            #expect(counting.urls <= Self.k + 1, "\(name): \(counting.urls) stream URLs built")
            #expect(counting.gains <= Self.k + 1, "\(name): \(counting.gains) volumes worked out")
            #expect(elapsed < .milliseconds(50), "\(name) took \(elapsed)")
            if player.repeatMode == .off { expectWindow(player, name) }
        }
    }

    /// Gapless (T7) holds: when the engine moves on, the window is topped back up, the new current entry keeps the
    /// URL the engine enqueued it on, and a skip after that still uses the engine's own next item.
    @Test func advanceTopsUpTheWindowAndKeepsTheEnqueuedURL() {
        let player = makePlayer()
        player.play(Self.songs(20), startAt: 0)
        let first = engine.setItemsCalls.last!.items
        let second = first[1]
        let enqueuedOn = URL(string: "http://10.0.0.9:4533/rest/stream?id=s1")!
        engine.enqueuedURLs[second.0] = enqueuedOn

        player.handle(.itemChanged(second.0))
        expectWindow(player, "after the engine moved on")
        #expect(engine.setItemsCalls.last!.items[0].1 == enqueuedOn, "the playing song keeps its enqueued URL")

        let third = player.queue.upcoming[0].id
        player.next()
        #expect(engine.nextCount == 1, "the engine held song 3 next")
        #expect(player.queue.current?.id == third)
        expectWindow(player, "after a skip")
    }

    /// QC fix 1: the engine ran out of its window because an `.itemChanged` went missing. With songs still to come,
    /// playback carries on with the first one after the window instead of ending.
    @Test func endedWithSongsBeyondTheWindowCarriesOn() {
        let player = makePlayer()
        player.play(Self.songs(10), startAt: 0)
        let plays = engine.playCount
        #expect(engine.setItemsCalls.last!.items.map(\.1.query) == ["id=s0", "id=s1", "id=s2", "id=s3"])
        player.handle(.ended)                               // s1 to s3 played, their item changes were lost
        #expect(player.queue.current?.song.id == "s4")
        #expect(player.isPlaying && !player.hasEnded)
        #expect(engine.playCount == plays + 1)
        expectWindow(player, "after a missed advance")
    }

    /// Only playable songs fill the window (offline); one far down the queue is still found.
    @Test func windowSkipsUnplayableSongs() {
        let player = makePlayer()
        player.isPlayable = { $0.id == "s0" || $0.id == "s4000" || $0.id == "s4001" }
        player.play(Self.songs(5000), startAt: 0)
        #expect(engine.setItemsCalls.last!.items.map(\.1.query) == ["id=s0", "id=s4000", "id=s4001"])
    }
}
