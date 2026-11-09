import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 24 G (owner item 11, D234): CarPlay Now Playing's next and previous. The car's skip buttons are the system's
/// remote commands, which go to a preview when one owns them (D86) and otherwise to `Player.next()` / `previous()`.
/// One test (or a few) per hypothesis of plan §6 G, in the plan's order; a test that passes rules its hypothesis out and
/// stays as a guard.
@MainActor
@Suite struct RemoteSkipTests {
    typealias Fuzz = PlayerChaosFuzzTests
    typealias Previews = PreviewPlayerTests

    /// Records what the player asked of its engine, including `next()` and seeks (the chaos engine drops both).
    @MainActor final class SkipEngine: PlaybackEngine {
        let events: AsyncStream<EngineEvent>
        private(set) var items: [(UUID, URL)] = []
        private(set) var wantsToPlay = false
        private(set) var nextCount = 0
        private(set) var seeks: [TimeInterval] = []
        /// Entries the engine loaded from the start. Like `AVQueueEngine`, a list whose first entry is the one it holds,
        /// on the same URL, keeps that item playing where it is (no reload); an empty list drops it.
        private(set) var loadsFromStart: [UUID] = []
        private var holding: (UUID, URL)?
        init() { events = AsyncStream { $0.finish() } }
        func setItems(_ urls: [(UUID, URL)], startAt: Int) {
            items = urls
            guard urls.indices.contains(startAt) else { return holding = nil }
            let first = urls[startAt]
            if let holding, holding.0 == first.0, holding.1 == first.1 { return }
            holding = first
            loadsFromStart.append(first.0)
        }
        func play() { wantsToPlay = true }
        func pause() { wantsToPlay = false }
        func seek(to t: TimeInterval) { seeks.append(t) }
        func next() { nextCount += 1 }
        /// What `AVQueueEngine` does when its list ends or its current item fails: it stops wanting to play.
        func stopWanting() { wantsToPlay = false }
    }

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    func player(_ ids: [String] = ["a", "b", "c"], startAt: Int = 0) -> (Player, SkipEngine) {
        let engine = SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.lookahead = 2
        player.play(ids.map(Self.song), startAt: startAt)
        return (player, engine)
    }

    func preview(main: Player) -> (PreviewPlayer, Previews.FakePreviewEngine) {
        let engine = Previews.FakePreviewEngine()
        let preview = PreviewPlayer(engine: engine, mainPlayer: main)
        let lookups = Previews.Lookups()
        preview.lookup = { await lookups.lookup($0) }
        return (preview, engine)
    }

    /// What the bridge's next / previous handlers do (`NowPlayingBridge.registerCommands`), without MediaPlayer.
    func remoteNext(_ player: Player, _ preview: PreviewPlayer?) {
        if !(preview?.handleRemote(.nextTrack) ?? false) { player.next() }
    }

    func remotePrevious(_ player: Player, _ preview: PreviewPlayer?) {
        if !(preview?.handleRemote(.previousTrack) ?? false) { player.previous() }
    }

    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    // MARK: - Hypothesis 1: a stale preview swallows the command

    /// A preview that ran to its end, was stopped, had no clip or couldn't play no longer owns the skip buttons.
    @Test(arguments: ["ended", "stopped", "noPreview", "unavailable"])
    func remoteNext_afterPreviewEnded_advancesMainQueue(_ how: String) async throws {
        let (main, _) = player()
        let (preview, engine) = preview(main: main)
        let item = how == "noPreview" ? Previews.item("1", preview: false) : Previews.item("1")
        preview.play([item])
        await settle { engine.loads.count == 1 || preview.phase == .noPreview }
        switch how {
        case "ended": preview.handle(.ended(token: engine.lastToken))
        case "stopped": preview.stop()
        case "unavailable":
            preview.handle(.failed(token: engine.lastToken))
            await settle { engine.loads.count == 2 }
            preview.handle(.failed(token: engine.lastToken))
        default: break
        }
        #expect(!preview.isActive, "\(how): \(preview.phase)")
        remoteNext(main, preview)
        #expect(main.queue.current?.song.id == "b", "\(how): the main queue moves on")
        remotePrevious(main, preview)
        #expect(main.queue.current?.song.id == "a", "\(how): and back")
    }

    /// A preview left paused (the sheet closed under it) gives the buttons back once the main player plays again.
    @Test func remoteNext_previewLeftPaused_mainPlaysAgain_advancesMainQueue() async throws {
        let (main, _) = player()
        let (preview, engine) = preview(main: main)
        preview.play([Previews.item("1"), Previews.item("2")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        preview.pause()
        #expect(!main.isPlaying)
        main.toggle()   // the owner plays the main queue (the phone, the car's list)
        await settle { !preview.isActive }
        remoteNext(main, preview)
        #expect(main.queue.current?.song.id == "b")
        #expect(preview.items.isEmpty, "the preview list didn't take the skip")
    }

    // MARK: - Hypothesis 2: no playable upcoming song

    /// Queue of three, the second can't play: next goes to the third.
    @Test func remoteNext_skipsUnplayableToNextPlayable() {
        let engine = SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.isPlayable = { $0.id != "b" }
        player.play(["a", "b", "c"].map(Self.song), startAt: 0)
        remoteNext(player, nil)
        #expect(player.queue.current?.song.id == "c")
        #expect(player.isPlaying && engine.wantsToPlay)
        #expect(engine.items.first?.0 == player.queue.current?.id || engine.nextCount == 1, "the engine plays it")
    }

    /// After a gapless advance the engine's list no longer starts at the current entry: next still goes on.
    @Test func remoteNext_afterGaplessAdvance_goesToTheFollowingSong() throws {
        let (player, engine) = player(["a", "b", "c", "d"])
        let b = try #require(player.queue.upcoming.first?.id)
        player.handle(.itemChanged(b))
        remoteNext(player, nil)
        #expect(player.queue.current?.song.id == "c")
        #expect(player.isPlaying && engine.wantsToPlay)
    }

    /// After the current song failed (a dropout in the car), next moves on and plays: the owner skipped, so the next
    /// song is heard, not left loaded and silent.
    @Test func remoteNext_afterAFailure_playsTheNextSong() throws {
        let (player, engine) = player()
        let a = try #require(player.queue.current?.id)
        player.handle(.failed(a, "server gone"))   // the converted stream fails: the original is tried once
        engine.stopWanting()
        player.handle(.failed(a, "server gone"))   // and fails too: the player stops on it
        #expect(!player.isPlaying)
        remoteNext(player, nil)
        #expect(player.queue.current?.song.id == "b")
        #expect(player.isPlaying, "the skip plays the next song")
        #expect(engine.wantsToPlay, "the engine is asked to play it")
    }

    /// Nothing playable after the current song (repeat off): next leaves the current song playing.
    @Test func remoteNext_nothingPlayableLeft_keepsPlayingTheCurrentSong() {
        let engine = SkipEngine()
        let player = Player(engine: engine, scrobbler: Fuzz.CountingScrobbler(), urls: Fuzz.ChaosURLs())
        player.isPlayable = { $0.id == "a" }
        player.play(["a", "b"].map(Self.song), startAt: 0)
        remoteNext(player, nil)
        #expect(player.queue.current?.song.id == "a")
        #expect(player.isPlaying && engine.wantsToPlay)
    }

    // MARK: - Hypothesis 3: previous restarts

    /// Within the first seconds, previous goes back a song (it doesn't restart this one).
    @Test func remotePrevious_nearStart_goesBackNotRestart() throws {
        let (player, engine) = player(startAt: 1)
        let b = try #require(player.queue.current?.id)
        player.handle(.time(b, 2, duration: 200))
        remotePrevious(player, nil)
        #expect(player.queue.current?.song.id == "a")
        #expect(engine.items.first?.0 == player.queue.current?.id, "the engine loads the previous song")
        #expect(engine.seeks.isEmpty, "no restart")
        #expect(player.isPlaying && engine.wantsToPlay)
    }

    /// After the end of the queue, previous within the first seconds goes back and plays (the owner pressed it).
    @Test func remotePrevious_afterTheQueueEnded_playsThePreviousSong() throws {
        let (player, engine) = player(startAt: 2)
        let c = try #require(player.queue.current?.id)
        engine.stopWanting()
        player.handle(.ended(c))
        #expect(!player.isPlaying && player.hasEnded)
        remotePrevious(player, nil)
        #expect(player.queue.current?.song.id == "b")
        #expect(player.isPlaying && engine.wantsToPlay)
    }

    /// Past 3 s, previous starts the song again from a fresh load, not a seek: a converted stream comes chunked, with no
    /// byte ranges (D42, D45), so a seek to 0 can leave the sound where it was while the screen shows 0:00.
    @Test func remotePrevious_pastThreeSeconds_restartsFromAFreshLoad() throws {
        let (player, engine) = player(startAt: 1)
        let b = try #require(player.queue.current?.id)
        #expect(engine.loadsFromStart.last == b)
        let loadsBefore = engine.loadsFromStart.count
        player.handle(.time(b, 95, duration: 200))
        remotePrevious(player, nil)
        #expect(player.queue.current?.id == b, "past 3 s: the same song")
        #expect(engine.loadsFromStart.count == loadsBefore + 1 && engine.loadsFromStart.last == b,
                "the engine loads the song again from the start")
        #expect(player.position == 0)
        #expect(player.isPlaying && engine.wantsToPlay, "and it plays on")
    }

    /// Paused past 3 s: previous puts the song back to the start and it stays paused.
    @Test func remotePrevious_pausedPastThreeSeconds_restartsPaused() throws {
        let (player, engine) = player(startAt: 1)
        let b = try #require(player.queue.current?.id)
        player.handle(.time(b, 95, duration: 200))
        player.toggle()
        let loadsBefore = engine.loadsFromStart.count
        remotePrevious(player, nil)
        #expect(player.queue.current?.id == b)
        #expect(engine.loadsFromStart.count == loadsBefore + 1 && engine.loadsFromStart.last == b)
        #expect(player.position == 0)
        #expect(!player.isPlaying && !engine.wantsToPlay)
    }

    /// The queue ended on a song (position at its end): previous starts it again and plays.
    @Test func remotePrevious_afterTheQueueEndedPastThreeSeconds_playsItAgain() throws {
        let (player, engine) = player(startAt: 2)
        let c = try #require(player.queue.current?.id)
        player.handle(.time(c, 199, duration: 200))
        engine.stopWanting()
        player.handle(.ended(c))
        remotePrevious(player, nil)
        #expect(player.queue.current?.id == c)
        #expect(player.position == 0)
        #expect(player.isPlaying && engine.wantsToPlay)
    }

    /// A restart shows 0, and a tick the engine sent before the restart landed doesn't put the old position back (the
    /// screen and the sound agree).
    @Test func seekZero_duringLoadCurrent_neverLeavesAudioPlaying() throws {
        let (player, _) = player(startAt: 1)
        let b = try #require(player.queue.current?.id)
        player.handle(.time(b, 95, duration: 200))
        remotePrevious(player, nil)
        #expect(player.queue.current?.id == b, "past 3 s: the same song")
        #expect(player.position == 0)
        player.handle(.time(b, 95.5, duration: 200))   // in flight before the seek
        #expect(player.position < 3, "a stale tick from before the restart doesn't undo it")
        player.handle(.time(b, 0.5, duration: 200))
        #expect(player.position == 0.5)
    }
}
