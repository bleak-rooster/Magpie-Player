import Foundation
import Testing
import MagpieCore
import Playback
import MediaPlayer
import UIKit

@MainActor
final class FakeEngine: PlaybackEngine {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private(set) var setItemsCalls: [(items: [(UUID, URL)], startAt: Int)] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var nextCount = 0

    init() { (events, continuation) = AsyncStream.makeStream() }

    func setItems(_ urls: [(UUID, URL)], startAt: Int) { setItemsCalls.append((urls, startAt)) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to t: TimeInterval) { seeks.append(t) }
    func next() { nextCount += 1 }
}

actor FakeScrobbler: Scrobbler {
    struct Call: Equatable { var songId: String; var submission: Bool }
    private(set) var calls: [Call] = []
    func scrobble(songId: String, submission: Bool, at: Date?) async throws {
        calls.append(Call(songId: songId, submission: submission))
    }
}

@MainActor
final class FakeURLs: StreamURLProvider {
    var base = URL(string: "http://192.168.1.2:4533")!
    func streamURL(for song: Song) -> URL {
        base.appending(path: "rest/stream").appending(queryItems: [URLQueryItem(name: "id", value: song.id)])
    }
}

@MainActor
@Suite struct PlayerTests {
    static func song(_ id: String, duration: TimeInterval = 200, libraryId: Int? = 1) -> Song {
        Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: duration, libraryId: libraryId)
    }

    let engine = FakeEngine()
    let scrobbler = FakeScrobbler()
    let urls = FakeURLs()

    func makePlayer(isFind: @escaping (Song) -> Bool = { _ in false }) -> Player {
        Player(engine: engine, scrobbler: scrobbler, urls: urls, isFind: isFind)
    }

    @Test func scrobblesAtHalf() async {
        let player = makePlayer()
        player.play([Self.song("1", duration: 200), Self.song("2", duration: 1000)], startAt: 0)
        player.handle(.time(player.queue.current!.id, 10, duration: 200))
        player.handle(.time(player.queue.current!.id, 99, duration: 200))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "1", submission: false)])

        player.handle(.time(player.queue.current!.id, 100, duration: 200))
        player.handle(.time(player.queue.current!.id, 150, duration: 200))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "1", submission: false),
                                          .init(songId: "1", submission: true)],
                "submitted once, at 50%")

        // Long track: 240 s cap comes before 50%.
        let second = player.queue.upcoming[0].id
        player.handle(.itemChanged(second))
        player.handle(.time(player.queue.current!.id, 239, duration: 1000))
        player.handle(.time(player.queue.current!.id, 240, duration: 1000))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls.suffix(2) == [.init(songId: "2", submission: false),
                                                    .init(songId: "2", submission: true)])
        #expect(player.queue.current?.song.id == "2")
    }

    @Test func noScrobbleForFinds() async {
        let findsLibraryId = 2
        let player = makePlayer(isFind: { $0.libraryId == findsLibraryId })
        player.play([Self.song("f", libraryId: findsLibraryId), Self.song("k", libraryId: 1)], startAt: 0)
        player.handle(.time(player.queue.current!.id, 150, duration: 200))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls.isEmpty)

        player.next()
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "k", submission: false)])
    }

    @Test func rebuildsURLsAfterFailover() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2"), Self.song("3")], startAt: 1)
        player.handle(.time(player.queue.current!.id, 42, duration: 200))
        let before = engine.setItemsCalls.last!.items
        #expect(before.map(\.1.host) == ["192.168.1.2", "192.168.1.2"])

        urls.base = URL(string: "https://music.example.net/navidrome")!
        player.urlsInvalidated()

        let after = engine.setItemsCalls.last!
        #expect(after.startAt == 0)
        #expect(after.items.map(\.0) == before.map(\.0), "same entries: current + not yet played")
        #expect(after.items.map(\.1.absoluteString) == [
            "https://music.example.net/navidrome/rest/stream?id=2",
            "https://music.example.net/navidrome/rest/stream?id=3",
        ])
        #expect(engine.seeks.last == 42, "resumes where it was")
    }

    /// Task 6.2b: after Keep the queue holds the library song, so it is scrobbled again (D29 only blocks finds).
    /// The same id (Navidrome keeps it across the move) leaves the engine alone; a new id rebuilds the URLs and
    /// resumes where it was.
    @Test func replaceSongAfterKeep() async {
        let player = makePlayer(isFind: { $0.libraryId == 2 })
        player.play([Self.song("f", libraryId: 2), Self.song("g", libraryId: 2)], startAt: 0)
        player.handle(.time(player.queue.current!.id, 30, duration: 200))
        let loads = engine.setItemsCalls.count

        player.replaceSong(id: "f", with: Self.song("f", libraryId: 1))
        #expect(engine.setItemsCalls.count == loads, "same id: nothing to reload")
        player.handle(.time(player.queue.current!.id, 120, duration: 200))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "f", submission: true)])

        player.replaceSong(id: "g", with: Self.song("g2", libraryId: 1))
        #expect(engine.setItemsCalls.count == loads + 1)
        #expect(engine.setItemsCalls.last!.items.map(\.1.absoluteString).last == "http://192.168.1.2:4533/rest/stream?id=g2")
        #expect(engine.seeks.last == 120)
    }

    @Test func backRestartsBefore3s() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 1)
        player.handle(.time(player.queue.current!.id, 3.5, duration: 200))
        player.previous()
        #expect(player.queue.current?.song.id == "2", "past 3 s: restart the song")
        #expect(engine.seeks.last == 0)
        #expect(player.position == 0)

        player.handle(.time(player.queue.current!.id, 2, duration: 200))
        player.previous()
        #expect(player.queue.current?.song.id == "1", "within 3 s: go to the previous song")
        #expect(engine.setItemsCalls.last!.items.first!.0 == player.queue.current!.id)
    }

    @Test func nextUsesEngineNext() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        player.next()
        #expect(engine.nextCount == 1)
        #expect(player.queue.current?.song.id == "2")
        #expect(player.isPlaying)
    }

    @Test func queueEditsResyncEngine() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        let current = player.queue.current!.id
        player.playNext([Self.song("x")])
        let last = engine.setItemsCalls.last!
        #expect(last.items.map(\.0) == [current] + player.queue.upcoming.map(\.id))
        #expect(player.queue.upcoming.map(\.song.id) == ["x", "2"])
        player.addToEnd([Self.song("z")])
        #expect(engine.setItemsCalls.last!.items.count == 4)
    }

    @Test func togglePausesAndResumes() {
        let player = makePlayer()
        player.play([Self.song("1")], startAt: 0)
        #expect(player.isPlaying)
        player.toggle()
        #expect(!player.isPlaying && engine.pauseCount == 1)
        player.toggle()
        #expect(player.isPlaying && engine.playCount == 2)
        player.handle(.playing(false))
        #expect(!player.isPlaying, "engine-side pause (interruption) is reflected")
    }
}

extension PlayerTests {
    @Test func replayAfterQueueEndedStartsCurrentOver() async {
        let player = makePlayer()
        player.play([Self.song("1")], startAt: 0)
        player.handle(.time(player.queue.current!.id, 150, duration: 200))
        player.handle(.ended)
        #expect(!player.isPlaying)
        let loads = engine.setItemsCalls.count
        player.toggle()
        #expect(player.isPlaying)
        #expect(engine.setItemsCalls.count == loads + 1, "current entry reloaded")
        #expect(player.position == 0)
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls.filter { !$0.submission }.count == 2, "now playing sent again")
    }

    /// Task 6.2c: Not for me takes the find out of the queue. Playing it: the next song loads; nothing else
    /// queued: the engine stops. A find only later in the queue leaves the current song playing.
    @Test func removeSongsAfterNotForMe() {
        let player = makePlayer()
        player.play([Self.song("f"), Self.song("1"), Self.song("f")], startAt: 0)
        player.removeSongs(["f"])
        #expect(player.queue.current?.song.id == "1" && player.queue.upcoming.isEmpty)
        #expect(engine.setItemsCalls.last!.items.map(\.1.absoluteString) == ["http://192.168.1.2:4533/rest/stream?id=1"])

        player.play([Self.song("1"), Self.song("f")], startAt: 0)
        let current = player.queue.current?.id
        player.removeSongs(["f"])
        #expect(player.queue.current?.id == current && player.queue.upcoming.isEmpty)

        player.play([Self.song("f")], startAt: 0)
        player.removeSongs(["f"])
        #expect(player.queue.current == nil && !player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.isEmpty)
    }

    @Test func removingLastEntryStopsEngine() {
        let player = makePlayer()
        player.play([Self.song("1")], startAt: 0)
        player.remove(id: player.queue.current!.id)
        #expect(player.queue.current == nil)
        #expect(!player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.isEmpty)
        #expect(engine.pauseCount == 1)
    }
}

extension PlayerTests {
    @Test func failedCurrentPausesEngine() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        player.handle(.failed(player.queue.upcoming[0].id, "upcoming failed"))
        #expect(player.isPlaying && engine.pauseCount == 0, "an upcoming failure is the engine's business")
        player.handle(.failed(player.queue.current!.id, "server gone"))
        #expect(!player.isPlaying)
        #expect(engine.pauseCount == 1)
        #expect(player.lastError == "server gone")
        #expect(player.queue.current?.song.id == "1", "no skipping ahead")
    }

    @Test func staleTickDoesNotScrobbleNewEntry() async {
        let player = makePlayer()
        player.play([Self.song("1", duration: 400), Self.song("2", duration: 400)], startAt: 0)
        let first = player.queue.current!.id
        player.next()
        player.handle(.time(first, 210, duration: 400))
        #expect(player.position == 0, "tick from the previous item ignored")
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "1", submission: false),
                                          .init(songId: "2", submission: false)])
    }
}

@Suite struct NowPlayingArtworkTests {
    @Test func artworkHandlerWorksOffMain() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        nonisolated(unsafe) let artwork = NowPlayingBridge.makeArtwork(image)
        // MediaPlayer asks for artwork on a background queue; do the same.
        let (offMain, gotImage) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: (!Thread.isMainThread,
                                        artwork.image(at: CGSize(width: 4, height: 4)) != nil))
            }
        }
        #expect(offMain)
        #expect(gotImage)
    }
}

extension PlayerTests {
    @Test func itemChangedAfterFailureDoesNotAdvance() async {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        let failed = player.queue.current!.id
        player.handle(.failed(failed, "server gone"))
        player.handle(.itemChanged(player.queue.upcoming[0].id))
        #expect(player.queue.current?.id == failed)
        #expect(player.lastError == "server gone")
        #expect(!player.isPlaying)
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls == [.init(songId: "1", submission: false)], "no now-playing for song 2")

        // The user acts: play retries the failed entry; next moves on.
        player.toggle()
        #expect(player.lastError == nil && player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.first!.0 == failed, "retry reloads the failed entry")
        player.handle(.failed(failed, "still gone"))
        player.next()
        #expect(player.queue.current?.song.id == "2")
        #expect(engine.setItemsCalls.last!.items.first!.0 == player.queue.current!.id,
                "after a failure, next loads the entry rather than relying on the engine's queue")
    }
}

extension PlayerTests {
    @Test func repeatModeCyclesOffAllOne() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }

    @Test func repeatAllWrapsWhenQueueEnds() {
        let player = makePlayer()
        player.repeatMode = .all
        player.play([Self.song("1"), Self.song("2")], startAt: 1)
        player.handle(.ended)
        #expect(player.queue.current?.song.id == "1")
        #expect(player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.first!.0 == player.queue.current!.id)
        #expect(player.position == 0)
    }

    @Test func repeatAllNextAtEndWraps() {
        let player = makePlayer()
        player.repeatMode = .all
        player.play([Self.song("1"), Self.song("2")], startAt: 1)
        player.next()
        #expect(player.queue.current?.song.id == "1")
        #expect(player.isPlaying)
    }

    @Test func repeatOffStopsAtEnd() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 1)
        player.next()
        #expect(player.queue.current?.song.id == "2")
        player.handle(.ended)
        #expect(!player.isPlaying)
        #expect(player.queue.current?.song.id == "2")
    }

    @Test func repeatOneReplaysInsteadOfAdvancing() {
        let player = makePlayer()
        player.repeatMode = .one
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        let current = player.queue.current!.id
        let loads = engine.setItemsCalls.count
        player.handle(.itemChanged(player.queue.upcoming[0].id))   // engine moved on by itself
        #expect(player.queue.current?.id == current)
        #expect(engine.setItemsCalls.count == loads + 1)
        #expect(engine.setItemsCalls.last!.items.first!.0 == current, "current entry reloaded from the start")
        #expect(player.isPlaying)
    }

    @Test func repeatOneReplaysAtEnd() {
        let player = makePlayer()
        player.repeatMode = .one
        player.play([Self.song("1")], startAt: 0)
        player.handle(.ended)
        #expect(player.isPlaying)
        #expect(player.queue.current?.song.id == "1")
    }

    @Test func clearUpcomingKeepsCurrentPlaying() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2"), Self.song("3")], startAt: 0)
        player.playNext([Self.song("x")])
        let current = player.queue.current!.id
        player.clearUpcoming()
        #expect(player.queue.current?.id == current)
        #expect(player.queue.upcoming.isEmpty)
        #expect(player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.map(\.0) == [current])
    }

    @Test func shuffleToggleRestoresOrder() {
        let player = makePlayer()
        player.play((1...6).map { Self.song("\($0)") }, startAt: 0)
        player.setShuffled(true, seed: 3)
        #expect(player.isShuffled)
        #expect(player.queue.current?.song.id == "1")
        player.setShuffled(false)
        #expect(!player.isShuffled)
        #expect(player.queue.main.map(\.song.id) == ["1", "2", "3", "4", "5", "6"])
        #expect(player.queue.current?.song.id == "1")
    }

    @Test func playingNewSongsClearsShuffle() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2")], startAt: 0)
        player.setShuffled(true, seed: 1)
        player.play([Self.song("3")], startAt: 0)
        #expect(!player.isShuffled)
    }
}

extension PlayerTests {
    @Test func repeatOneSendsOnlyCurrentAndOffRestoresPrefetch() {
        let player = makePlayer()
        player.play([Self.song("1"), Self.song("2"), Self.song("3")], startAt: 0)
        let current = player.queue.current!.id
        player.repeatMode = .one
        #expect(engine.setItemsCalls.last!.items.map(\.0) == [current], "no prefetch of the next song")
        player.playNext([Self.song("x")])
        #expect(engine.setItemsCalls.last!.items.map(\.0) == [current], "edits keep it that way")
        player.repeatMode = .off
        #expect(engine.setItemsCalls.last!.items.map(\.0) == [current] + player.queue.upcoming.map(\.id))
        #expect(engine.setItemsCalls.last!.items.count == 4)
    }
}

/// Shuffle and repeat from the lock screen or the car (CarPlay's buttons call the same functions).
@MainActor
@Suite(.serialized) struct NowPlayingModeCommandTests {
    private func makePlayer() -> Player {
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        player.play((1...5).map { Song(id: "\($0)", title: "S\($0)", artist: "A", album: "B", duration: 100) },
                    startAt: 0)
        return player
    }

    @Test func shuffleCommandChangesPlayerAndCurrentType() {
        let player = makePlayer()
        let command = MPRemoteCommandCenter.shared().changeShuffleModeCommand
        NowPlayingBridge.shuffleCommandAction(player, .shuffle(.items))
        #expect(player.isShuffled)
        #expect(command.currentShuffleType == .items)
        NowPlayingBridge.shuffleCommandAction(player, .shuffle(.off))
        #expect(!player.isShuffled)
        #expect(command.currentShuffleType == .off)
        NowPlayingBridge.shuffleCommandAction(player, .shuffle(.collections))
        #expect(player.isShuffled, "any shuffle type but off turns shuffle on")
    }

    @Test func repeatCommandChangesPlayerAndCurrentType() {
        let player = makePlayer()
        let command = MPRemoteCommandCenter.shared().changeRepeatModeCommand
        for (type, mode) in [(MPRepeatType.all, RepeatMode.all), (.one, .one), (.off, .off)] {
            NowPlayingBridge.repeatCommandAction(player, .repeatMode(type))
            #expect(player.repeatMode == mode)
            #expect(command.currentRepeatType == type)
        }
    }

    @Test func bridgeRegistersShuffleAndRepeatAndFollowsPlayer() async throws {
        let player = makePlayer()
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { bridge.invalidate() }
        let center = MPRemoteCommandCenter.shared()
        #expect(center.changeShuffleModeCommand.isEnabled)
        #expect(center.changeRepeatModeCommand.isEnabled)
        // A change made elsewhere (the phone's queue screen) reaches the system's current types.
        player.setShuffled(true)
        player.repeatMode = .one
        for _ in 0..<100 where center.changeRepeatModeCommand.currentRepeatType != .one {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.changeShuffleModeCommand.currentShuffleType == .items)
        #expect(center.changeRepeatModeCommand.currentRepeatType == .one)
    }
}
