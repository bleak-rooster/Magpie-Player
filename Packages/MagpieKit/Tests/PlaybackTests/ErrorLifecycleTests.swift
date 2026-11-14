import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Playback

/// Round 27 P (owner item 10, 2026-11-14): Now Playing's error belongs to the song it was raised for (D276). Every path
/// to a new current entry clears `lastError`, and so does a retry of the same one; the "connection dropped" state
/// (`reconnectingSongId`) only ever names the current song. And the current song's URL is never re-sent by a change of
/// where the songs after it come from (D282).
@MainActor
@Suite struct ErrorLifecycleTests {
    typealias Fuzz = PlayerChaosFuzzTests
    typealias Skip = RemoteSkipTests
    typealias Converted = ConvertedStreamTests

    /// No original to fall back to: a failure stops on the song with its message.
    @MainActor final class NoFallbackURLs: StreamURLProvider {
        var local: Set<String> = []
        var format = "aac"
        func streamURL(for song: Song) -> URL {
            if local.contains(song.id) { return URL(filePath: "/tmp/magpie-r27/\(song.id).flac") }
            return URL(string: "https://music.example/rest/stream?id=\(song.id)&maxBitRate=160&format=\(format)")!
        }
    }

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    enum Path: String, CaseIterable, CustomTestStringConvertible {
        case nextLoads, previous, jump, gaplessItemChanged, removeCurrent, play, skipToNextPlayable,
             continueAfterWindow, retryAfterFailure, stopOnNext
        var testDescription: String { rawValue }
    }

    /// A player stopped on song "a" with an error; lookahead 1, so the engine holds "a" and "b".
    func failed() -> (Player, Skip.SkipEngine, NoFallbackURLs) {
        let engine = Skip.SkipEngine(), urls = NoFallbackURLs()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: urls)
        player.lookahead = 1
        player.play(["a", "b", "c", "d"].map(Self.song), startAt: 0)
        let id = player.queue.current!.id
        player.handle(.time(id, 20, duration: nil))
        player.handle(.failed(id, "This song didn't play."))
        return (player, engine, urls)
    }

    @Test(arguments: Path.allCases)
    func lastError_clearedOnEveryPathToANewSong(_ path: Path) {
        let (player, engine, urls) = failed()
        #expect(player.lastError == "This song didn't play.")
        var before = player.queue.current!.id
        switch path {
        case .nextLoads: player.next()
        case .previous:
            player.next()
            before = player.queue.current!.id
            player.handle(.failed(before, "This song didn't play."))
            #expect(player.lastError != nil)
            player.previous()
        case .jump: player.jump(to: player.queue.upcoming[1].id)
        case .gaplessItemChanged:
            // While stopped on a failure the engine's moves are ignored (the song didn't change); once it plays again,
            // a gapless move to the next song is a new current entry.
            player.handle(.itemChanged(engine.items[1].0))
            #expect(player.queue.current!.id == before && player.lastError != nil, "ignored while stopped")
            player.retryAfterFailure()
            player.handle(.itemChanged(engine.items[1].0))
        case .removeCurrent: player.remove(id: before)
        case .play: player.play([Self.song("z")], startAt: 0)
        case .skipToNextPlayable:
            player.isPlayable = { $0.id != "a" }
            player.retryAfterFailure()
        case .continueAfterWindow:
            // The end of the engine's list arrives (a missing `.itemChanged`): the next song that can play does.
            player.handle(.ended(engine.items.last!.0))
        case .retryAfterFailure:
            player.retryAfterFailure()
            #expect(player.queue.current!.id == before)
        case .stopOnNext:
            player.stopsAfterCurrent = true
            player.handle(.ended(engine.items.last!.0))
        }
        _ = urls
        #expect(player.lastError == nil, "\(path): the error went with its song")
        if path != .retryAfterFailure { #expect(player.queue.current!.id != before, "\(path) reached a new song") }
    }

    /// The engine-held branch of `next()` (no reload) also starts a new entry with no error: reached from a song that
    /// plays (an error always stops the player, so it never meets this branch holding one), it must not invent one.
    @Test func nextEngineBranch_startsClean() {
        let engine = Skip.SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: NoFallbackURLs())
        player.lookahead = 2
        player.play(["a", "b"].map(Self.song), startAt: 0)
        player.next()
        #expect(engine.nextCount == 1 && player.lastError == nil && player.queue.current?.song.id == "b")
    }

    // MARK: - D282: the current song's URL is never re-sent

    enum SourceChange: String, CaseIterable, CustomTestStringConvertible {
        case preDownloadLanding, cacheSwap, qualityChange, downloadFinished
        var testDescription: String { rawValue }
    }

    /// Each change makes the URL provider answer differently for the current song, then re-sends the upcoming songs
    /// the way the app does (`upcomingURLsChanged`). The engine keeps the current item only when it is sent the same
    /// id and URL: a different URL would reload the song from 0 (cause 4 of plan §2.7).
    @Test(arguments: SourceChange.allCases)
    func currentURL_neverResent(_ change: SourceChange) {
        let engine = Skip.SkipEngine(), urls = NoFallbackURLs()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: urls)
        player.lookahead = 2
        if change == .cacheSwap { urls.local = ["a"] }   // playing from a cached copy that is then replaced
        player.play(["a", "b", "c"].map(Self.song), startAt: 0)
        let id = player.queue.current!.id
        let first = engine.items.first!.1
        player.handle(.time(id, 42, duration: nil))
        switch change {
        case .preDownloadLanding, .downloadFinished: urls.local = ["a", "b"]   // the current song is on the phone now
        case .cacheSwap: urls.local = []; urls.local = ["a"]; urls.format = "mp3"
        case .qualityChange: urls.format = "opus"   // Wi-Fi to mobile data
        }
        player.upcomingURLsChanged()
        #expect(engine.items.first?.0 == id && engine.items.first?.1 == first, "\(change): the same URL")
        #expect(engine.loadsFromStart == [id], "\(change): not reloaded")
        #expect(player.position == 42 && player.currentURL == first)
    }

    // MARK: - Seeded fuzz

    /// 500 seeded sequences of failures (each cause), ticks, skips, seeks, edits and pick-up waits: nothing traps, an
    /// error only ever stands for the song it was raised on, and "picking up" only ever names the current song.
    @Test func player_randomEventsNeverTrapAndErrorFollowsSong() async {
        for seed in 0..<UInt64(500) { await runSequence(seed: seed) }
    }

    func runSequence(seed: UInt64) async {
        var rng = SeededRNG(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ 7)
        let engine = Converted.RetryEngine()
        let urls = Converted.StreamURLs()
        var partWay = Bool.random(using: &rng), online = true
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: urls, sleep: { _ in await Task.yield() })
        player.startsConversionsPartWay = { partWay }
        player.canReachServer = { online }
        player.lookahead = Int.random(in: 1...3, using: &rng)
        let causes: [PlaybackFailure.Cause] = [.network, .network, .serverError, .undecodable, .unknown]
        for step in 0..<60 {
            let current = player.queue.current
            switch Int.random(in: 0...15, using: &rng) {
            case 0: player.play((0..<Int.random(in: 0...6, using: &rng)).map { Self.song("s\($0)") },
                                startAt: Int.random(in: -1...6, using: &rng))
            case 1, 2:
                if let current {
                    engine.causes[current.id] = causes.randomElement(using: &rng)!
                    player.handle(.failed(current.id, "failed \(step)", undecodable: Bool.random(using: &rng)))
                }
            case 3, 4:
                if let current {
                    player.handle(.time(current.id, [0.4, 0.5, 2, 30, 199, .nan, -3, 1e300].randomElement(using: &rng)!,
                                        duration: nil))
                }
            case 5: player.next()
            case 6: player.previous()
            case 7: player.seek([0, 5.5, 60, 1e300, -1e9, .nan].randomElement(using: &rng)!)
            case 8: player.toggle()
            case 9: player.retryAfterFailure()
            case 10: online.toggle()
            case 11: partWay.toggle()
            case 12: if let id = player.queue.upcoming.randomElement(using: &rng)?.id { player.jump(to: id) }
            case 13: if let id = engine.setItemsCalls.last?.dropFirst().first?.0 { player.handle(.itemChanged(id)) }
            case 14: player.handle(.stalled)
            default: for _ in 0..<Int.random(in: 1...20, using: &rng) { await Task.yield() }   // let waits run
            }
            let now = player.queue.current
            // No single step both moves to a new song and fails it: a new current song never shows an error.
            if now?.id != current?.id {
                #expect(player.lastError == nil, "seed \(seed) step \(step): an error outlived its song")
            }
            if let r = player.reconnectingSongId {
                #expect(r == now?.song.id, "seed \(seed) step \(step): picking up names another song")
                #expect(player.lastError == nil, "seed \(seed) step \(step): picking up and an error at once")
            }
            #expect(player.position.isFinite, "seed \(seed) step \(step): position \(player.position)")
        }
    }
}
