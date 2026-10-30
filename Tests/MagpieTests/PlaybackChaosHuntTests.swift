import AVFoundation
import Foundation
import ListenBrainzKit
import MagpieCore
import MagpieTestSupport
import MediaPlayer
import Playback
import Testing
@testable import Magpie

/// Crash hunt 1 (playback under chaos), on the simulator: the real `AVQueueEngine` under odd seeks and a seeded
/// sequence of queue edits with real timing, the lock screen with odd lengths and positions, and the play sent to
/// ListenBrainz with a length no file has.
@MainActor
@Suite(.serialized) struct PlaybackChaosHuntTests {
    /// Lengths and positions as a server or a remote command may send them; each is finite, so it gets past
    /// `isFinite` guards, and the large ones overflow anything that makes whole numbers of them.
    static let oddTimes: [TimeInterval] = [1e300, -1e300, 1e20, 9.3e15, -5, .greatestFiniteMagnitude, 1e15, 0.5]

    /// A ListenBrainz listen carries the length in whole milliseconds. A song length past Int's range in milliseconds
    /// (a broken tag or server: JSON decodes 1e17 or 1e300 fine) trapped in `Int(_:)` on every "now playing" sent.
    @Test(arguments: [1e300, 1e17, 9.3e15, .greatestFiniteMagnitude])
    func listenWithAHugeLengthDoesNotTrap(_ seconds: TimeInterval) {
        let song = Song(id: "s", title: "T", artist: "A", album: "B", duration: seconds)
        let listen = ScrobbleRouter.listen(AudioMetadata(song), at: .now)
        #expect(listen.durationMs == nil, "a length that can't be counted in milliseconds is left out")
        let normal = ScrobbleRouter.listen(AudioMetadata(Song(id: "s", title: "T", artist: "A", album: "B", duration: 200.5)),
                                           at: .now)
        #expect(normal.durationMs == 200_500)
    }

    /// The real engine takes a seek to any finite time a remote command or a scrubber may send, and keeps ticking.
    @Test func realEngineTakesOddSeeks() async throws {
        let file = try AVQueueEngineTests.silentWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVQueueEngine(activateSession: {})
        let id = UUID()
        var ticks: [TimeInterval] = []
        let collector = Task { @MainActor in
            for await e in engine.events { if case .time(_, let t, _) = e { ticks.append(t) } }
        }
        defer { collector.cancel() }
        engine.setItems([(id, file)], startAt: 0)
        engine.play()
        for t in Self.oddTimes + [.nan, .infinity, -.infinity] {
            engine.seek(to: t)
            try await Task.sleep(for: .milliseconds(60))
        }
        engine.seek(to: 0)
        try await Task.sleep(for: .milliseconds(700))
        #expect(ticks.allSatisfy { $0.isFinite }, "\(ticks)")
    }

    /// The player with the real engine: a seeded sequence of edits, skips, seeks, mode changes and network flips,
    /// with real time between them so the engine's own events (ends, item changes) interleave. After every step the
    /// queue is sound and the engine holds only entries of the queue.
    @Test(arguments: [UInt64(1), 2, 3])
    func realEngineChaosSequence(seed: UInt64) async throws {
        let files = try (0..<4).map { _ in try AVQueueEngineTests.silentWAV(seconds: 1) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let engine = AVQueueEngine(activateSession: {})
        let urls = FakeURLs()
        urls.stream = { song in files[Int(song.id.dropFirst())! % files.count] }
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: urls)
        var rng = SeededRNG(seed: seed)
        let songs = (0..<6).map { PlayerTests.song("s\($0)", duration: [1, 0, 1e300][$0 % 3]) }
        player.play(songs, startAt: 0)
        for step in 0..<60 {
            let all = player.queue.main + player.queue.upNext
            switch Int.random(in: 0...13, using: &rng) {
            case 0: player.play(Array(songs.shuffled(using: &rng).prefix(Int.random(in: 0...6, using: &rng))), startAt: 0)
            case 1: player.playNext([songs.randomElement(using: &rng)!])
            case 2: player.addToEnd([songs.randomElement(using: &rng)!])
            case 3: player.move(id: all.randomElement(using: &rng)?.id ?? UUID(), to: Int.random(in: -1...8, using: &rng))
            case 4: player.remove(id: all.randomElement(using: &rng)?.id ?? UUID())
            case 5: player.next()
            case 6: player.previous()
            case 7: player.seek(Self.oddTimes.randomElement(using: &rng)!)
            case 8: player.repeatMode = RepeatMode.allCases.randomElement(using: &rng)!
            case 9: player.setShuffled(Bool.random(using: &rng), seed: rng.next())
            case 10: player.stopsAfterCurrent.toggle()
            case 11: player.urlsInvalidated()
            case 12: player.toggle()
            default: player.upcomingURLsChanged()
            }
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...250, using: &rng)))
            let q = player.queue
            if let i = q.currentIndex { #expect(q.main.indices.contains(i), "seed \(seed) step \(step)") }
            let ids = Set((q.main + q.upNext).map(\.id))
            #expect(ids.count == q.main.count + q.upNext.count, "seed \(seed) step \(step): duplicate ids")
            #expect(Set(engine.enqueuedItems.map(\.id)).isSubset(of: ids), "seed \(seed) step \(step): engine holds a stray entry")
            #expect(player.position.isFinite)
        }
        player.play([], startAt: 0)
    }

    /// The lock screen publishes a song whose length and position are finite but huge.
    @Test func lockScreenTakesHugeLengthsAndPositions() async throws {
        let engine = FakeEngine()
        let player = Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { bridge.invalidate() }
        player.play([PlayerTests.song("1", duration: 1e300), PlayerTests.song("2", duration: 0)], startAt: 0)
        for t in Self.oddTimes {
            player.seek(t)
            try await Task.sleep(for: .milliseconds(20))
        }
        let id = try #require(player.queue.current?.id)
        player.handle(.time(id, 1e300, duration: 1e300))
        try await Task.sleep(for: .milliseconds(50))
        player.next()
        player.handle(.time(player.queue.current!.id, 5, duration: .nan))
        try await Task.sleep(for: .milliseconds(50))
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "T2")
    }
}
