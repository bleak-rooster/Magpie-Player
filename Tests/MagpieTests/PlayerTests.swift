import Foundation
import Testing
import MagpieCore
import Playback
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
    let defaults = UserDefaults(suiteName: "PlayerTests-\(UUID().uuidString)")!

    func makePlayer(isFind: @escaping (Song) -> Bool = { _ in false }) -> Player {
        Player(engine: engine, scrobbler: scrobbler, urls: urls, isFind: isFind, defaults: defaults)
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

    @Test func noScrobbleWhenCountPlaysOff() async {
        let player = makePlayer()
        player.countPlays = false
        player.play([Self.song("1")], startAt: 0)
        player.handle(.time(player.queue.current!.id, 150, duration: 200))
        await player.waitForPendingScrobbles()
        #expect(await scrobbler.calls.isEmpty)

        let reloaded = makePlayer()
        #expect(reloaded.countPlays == false, "setting is persisted")
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
