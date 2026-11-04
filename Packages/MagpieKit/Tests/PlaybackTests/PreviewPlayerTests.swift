import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 14 A2 (D85–D88): the preview player. Its own engine, never the main queue; starting a preview pauses the main
/// player and nothing resumes it by itself; every play resolves the preview again; a failed play re-resolves once.
@MainActor
@Suite struct PreviewPlayerTests {
    typealias Fuzz = PlayerChaosFuzzTests

    /// Records what the preview player asked of its engine.
    @MainActor final class FakePreviewEngine: PreviewEngine {
        let events: AsyncStream<PreviewEngineEvent>
        private(set) var loads: [(url: URL, token: Int, at: TimeInterval)] = []
        private(set) var pauses = 0, resumes = 0, stops = 0
        init() { events = AsyncStream { $0.finish() } }
        func load(_ url: URL, token: Int, at: TimeInterval) { loads.append((url, token, at)) }
        func pause() { pauses += 1 }
        func resume() { resumes += 1 }
        func stop() { stops += 1 }
        var lastToken: Int { loads.last?.token ?? -1 }
    }

    /// Answers each preview id from a script; counts the asks per id.
    @MainActor final class Lookups {
        var answers: [String: PreviewLookup] = [:]
        private(set) var asked: [String] = []
        var serial = 0
        func lookup(_ id: String) async -> PreviewLookup {
            asked.append(id)
            if let answer = answers[id] { return answer }
            serial += 1
            return .playable(URL(string: "https://cdnt-preview.dzcdn.net/\(id).mp3?hdnea=exp~\(serial)")!)
        }
    }

    static func item(_ id: String, preview: Bool = true) -> PreviewItem {
        PreviewItem(id: "song-\(id)", previewId: preview ? id : nil, title: "Title \(id)", artist: "Artist \(id)")
    }

    func make(main: Player? = nil) -> (PreviewPlayer, FakePreviewEngine, Lookups) {
        let engine = FakePreviewEngine()
        let lookups = Lookups()
        let preview = PreviewPlayer(engine: engine, mainPlayer: main)
        preview.lookup = { await lookups.lookup($0) }
        return (preview, engine, lookups)
    }

    func mainPlayer() -> (Player, Fuzz.ChaosEngine, Fuzz.CountingScrobbler) {
        let engine = Fuzz.ChaosEngine()
        let scrobbler = Fuzz.CountingScrobbler()
        let player = Player(engine: engine, scrobbler: scrobbler, urls: Fuzz.ChaosURLs())
        return (player, engine, scrobbler)
    }

    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200) }

    /// Waits (briefly) for the preview player's resolve task to land.
    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    // MARK: - Hand-off with the main player

    @Test func startingAPreviewPausesTheMainPlayerAndStoppingDoesNotResumeIt() async throws {
        let (main, mainEngine, _) = mainPlayer()
        main.play(["a", "b"].map(Self.song), startAt: 0)
        #expect(main.isPlaying && mainEngine.wantsToPlay)
        let (preview, engine, _) = make(main: main)

        preview.play([Self.item("1")])
        #expect(!main.isPlaying && !mainEngine.wantsToPlay, "the main player pauses as the preview starts")
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        #expect(preview.phase == .playing)
        #expect(main.queue.current?.song.id == "a", "the main queue is untouched")

        preview.stop()
        #expect(preview.phase == .idle)
        #expect(!main.isPlaying, "stopping a preview never resumes the main player")
        #expect(preview.offersResume, "the mini player offers Resume")

        preview.resumeMain()
        #expect(main.isPlaying && mainEngine.wantsToPlay)
        #expect(!preview.offersResume)
    }

    @Test func aPreviewRunningToItsEndLeavesTheMainPlayerPaused() async throws {
        let (main, _, _) = mainPlayer()
        main.play([Self.song("a")], startAt: 0)
        let (preview, engine, _) = make(main: main)
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.ended(token: engine.lastToken))
        #expect(preview.phase == .idle)
        #expect(!main.isPlaying)
        #expect(preview.offersResume)
    }

    /// A main player that was already paused isn't "paused by a preview": no Resume is offered for it.
    @Test func aPausedMainPlayerIsNotClaimed() async throws {
        let (main, _, _) = mainPlayer()
        main.play([Self.song("a")], startAt: 0)
        main.toggle()
        let (preview, engine, _) = make(main: main)
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.stop()
        #expect(!preview.offersResume)
        #expect(!main.isPlaying)
    }

    /// The main player starting (Now Playing, CarPlay, a song tapped) stops the preview; no two sounds at once.
    @Test func theMainPlayerStartingStopsThePreview() async throws {
        let (main, _, _) = mainPlayer()
        main.play([Self.song("a")], startAt: 0)
        let (preview, engine, _) = make(main: main)
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        main.toggle()   // the owner presses play on the main player
        await settle { preview.phase == .idle }
        #expect(preview.phase == .idle)
        #expect(engine.stops >= 1)
        #expect(!preview.offersResume, "the main player is playing again")
    }

    /// Previews never reach the scrobbler: no now-playing, no counted play, however long they play.
    @Test func previewsNeverScrobbleOrCountAPlay() async throws {
        let (main, _, scrobbler) = mainPlayer()
        main.play([Self.song("a")], startAt: 0)
        await main.waitForPendingScrobbles()
        let before = scrobbler.counts
        let (preview, engine, _) = make(main: main)
        preview.play([Self.item("1"), Self.item("2")])
        for _ in 0..<2 {
            await settle { engine.loads.count > 0 }
            let token = engine.lastToken
            preview.handle(.started(token: token))
            for t in stride(from: 0.0, through: 30, by: 1) { preview.handle(.time(token: token, t, duration: 30)) }
            await settle { engine.loads.count == 2 || preview.phase == .idle }
        }
        await main.waitForPendingScrobbles()
        #expect(scrobbler.counts == before)
        #expect(main.position == 0)
    }

    // MARK: - Sequence

    @Test func playPreviewsPlaysTheListInOrder() async throws {
        let (preview, engine, lookups) = make()
        let items = ["1", "2", "3"].map { Self.item($0) }
        preview.play(items)
        await settle { engine.loads.count == 1 }
        #expect(preview.current?.id == "song-1")
        preview.handle(.started(token: engine.lastToken))
        preview.handle(.ended(token: engine.lastToken))
        await settle { engine.loads.count == 2 }
        #expect(preview.current?.id == "song-2")
        preview.next()
        await settle { engine.loads.count == 3 }
        #expect(preview.current?.id == "song-3")
        preview.previous()   // at the start of a preview: back one
        await settle { engine.loads.count == 4 }
        #expect(preview.current?.id == "song-2")
        preview.handle(.ended(token: engine.lastToken))
        await settle { engine.loads.count == 5 }
        preview.handle(.ended(token: engine.lastToken))
        #expect(preview.phase == .idle, "the end of the list stops")
        #expect(preview.current == nil)
        #expect(lookups.asked == ["1", "2", "3", "2", "3"], "each play resolves again; nothing is kept")
    }

    /// 30 seconds each: a clip that runs on is cut at 30 s, and the ring's progress follows the clip.
    @Test func eachPreviewIsThirtySeconds() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1"), Self.item("2")])
        await settle { engine.loads.count == 1 }
        let token = engine.lastToken
        preview.handle(.started(token: token))
        preview.handle(.time(token: token, 15, duration: 60))
        #expect(preview.progress == 0.5)
        #expect(preview.remaining == 15)
        preview.handle(.time(token: token, 30.2, duration: 60))
        await settle { engine.loads.count == 2 }
        #expect(preview.current?.id == "song-2")
        #expect(preview.progress == 0)
    }

    /// A shorter clip (Deezer's can be) fills the ring by its own length.
    @Test func aShortClipFillsTheRingByItsLength() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        preview.handle(.time(token: engine.lastToken, 10, duration: 20))
        #expect(preview.progress == 0.5)
    }

    @Test func staleEngineEventsAreIgnored() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1"), Self.item("2")])
        await settle { engine.loads.count == 1 }
        let first = engine.lastToken
        preview.next()
        await settle { engine.loads.count == 2 }
        preview.handle(.ended(token: first))
        preview.handle(.failed(token: first))
        preview.handle(.time(token: first, 29, duration: 30))
        #expect(preview.current?.id == "song-2")
        #expect(preview.position == 0)
        #expect(engine.loads.count == 2)
    }

    @Test func nonFiniteTimesKeepTheLastPosition() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        let token = engine.lastToken
        preview.handle(.started(token: token))
        preview.handle(.time(token: token, 5, duration: nil))
        for t in [Double.nan, .infinity, -.infinity] { preview.handle(.time(token: token, t, duration: t)) }
        #expect(preview.position == 5)
        #expect(preview.progress.isFinite)
    }

    // MARK: - Resolving

    /// A signed link that expired (or any failed play) is resolved again once and played from where it was.
    @Test func aFailedPlayReResolvesOnce() async throws {
        let (preview, engine, lookups) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        let token = engine.lastToken
        preview.handle(.started(token: token))
        preview.handle(.time(token: token, 12, duration: 30))
        preview.handle(.failed(token: token))
        await settle { engine.loads.count == 2 }
        #expect(lookups.asked == ["1", "1"])
        #expect(engine.loads[1].url != engine.loads[0].url, "a fresh signed link")
        #expect(engine.loads[1].at == 12, "from where it was")
        #expect(preview.phase == .loading)
        // A second failure is final: "Preview unavailable right now".
        preview.handle(.failed(token: engine.lastToken))
        await settle { preview.phase == .unavailable }
        #expect(preview.phase == .unavailable)
        #expect(lookups.asked.count == 2)
        #expect(preview.state(for: Self.item("1")) == .unavailable)
    }

    @Test func aPreviewThatDoesNotExistShowsNoPreviewAvailable() async throws {
        let (preview, engine, lookups) = make()
        lookups.answers["1"] = .noPreview
        preview.play([Self.item("1")])
        await settle { preview.phase == .noPreview }
        #expect(preview.phase == .noPreview)
        #expect(engine.loads.isEmpty)
        #expect(preview.state(for: Self.item("1")) == .noPreview)
        #expect(!preview.isActive)
    }

    /// An item with no preview at all isn't asked about.
    @Test func anItemWithoutAPreviewIsNeverResolved() async throws {
        let (preview, engine, lookups) = make()
        let none = Self.item("9", preview: false)
        #expect(preview.state(for: none) == .noPreview)
        preview.play([none])
        await settle { preview.phase == .noPreview }
        #expect(lookups.asked.isEmpty && engine.loads.isEmpty)
    }

    /// In a sequence, a song without a preview is skipped; Aurral being unreachable stops the run.
    @Test func aSequenceSkipsSongsWithoutAPreviewAndStopsWhenUnavailable() async throws {
        let (preview, engine, lookups) = make()
        lookups.answers["2"] = .noPreview
        lookups.answers["4"] = .unavailable
        preview.play(["1", "2", "3", "4", "5"].map { Self.item($0) })
        await settle { engine.loads.count == 1 }
        preview.handle(.ended(token: engine.lastToken))
        await settle { engine.loads.count == 2 }
        #expect(preview.current?.id == "song-3")
        #expect(preview.state(for: Self.item("2")) == .noPreview)
        preview.handle(.ended(token: engine.lastToken))
        await settle { preview.phase == .unavailable }
        #expect(preview.phase == .unavailable)
        #expect(preview.current?.id == "song-4")
        #expect(engine.loads.count == 2, "song 5 isn't tried")
    }

    /// Tapping the playing preview's button stops it; tapping another plays that one alone.
    @Test func toggleStopsTheSameItemAndSwitchesToAnother() async throws {
        let (preview, engine, _) = make()
        preview.toggle(Self.item("1"))
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        #expect(preview.state(for: Self.item("1")) == .playing(progress: 0))
        preview.toggle(Self.item("2"))
        await settle { engine.loads.count == 2 }
        #expect(preview.current?.id == "song-2")
        #expect(preview.state(for: Self.item("1")) == .ready)
        preview.toggle(Self.item("2"))
        #expect(preview.phase == .idle)
    }

    /// A resolve that lands after Stop plays nothing.
    @Test func aResolveLandingAfterStopIsDropped() async throws {
        let engine = FakePreviewEngine()
        let preview = PreviewPlayer(engine: engine, mainPlayer: nil)
        let gate = AsyncStream<Void>.makeStream()
        preview.lookup = { id in
            for await _ in gate.stream { break }
            return .playable(URL(string: "https://cdnt-preview.dzcdn.net/\(id).mp3")!)
        }
        preview.play([Self.item("1")])
        #expect(preview.phase == .loading)
        preview.stop()
        gate.continuation.yield(())
        for _ in 0..<100 { await Task.yield() }
        #expect(engine.loads.isEmpty)
        #expect(preview.phase == .idle)
    }

    /// A link that isn't https is never handed to the engine.
    @Test func onlyHTTPSLinksPlay() async throws {
        let (preview, engine, lookups) = make()
        lookups.answers["1"] = .playable(URL(string: "http://cdnt-preview.dzcdn.net/1.mp3")!)
        preview.play([Self.item("1")])
        await settle { preview.phase == .unavailable }
        #expect(preview.phase == .unavailable)
        #expect(engine.loads.isEmpty)
    }

    // MARK: - Pause, interruptions, remote commands

    @Test func pauseAndResume() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        preview.pause()
        #expect(preview.phase == .paused && engine.pauses == 1)
        #expect(preview.isActive)
        preview.resume()
        #expect(preview.phase == .playing && engine.resumes == 1)
    }

    @Test func aCallPausesThePreviewAndItResumesWhenTheSystemSaysSo() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        preview.handle(.interrupted)
        #expect(preview.phase == .paused)
        preview.handle(.resumption(shouldResume: true))
        #expect(preview.phase == .playing && engine.resumes == 1)

        preview.handle(.interrupted)
        preview.handle(.resumption(shouldResume: false))
        #expect(preview.phase == .paused, "no recommendation: stays paused")

        // Paused by the owner before the call: the call ending doesn't start it.
        preview.resume()
        preview.pause()
        preview.handle(.interrupted)
        preview.handle(.resumption(shouldResume: true))
        #expect(preview.phase == .paused)
    }

    @Test func remoteCommandsGoToThePreviewWhileItPlays() async throws {
        let (main, _, _) = mainPlayer()
        main.play(["a", "b"].map(Self.song), startAt: 0)
        let (preview, engine, _) = make(main: main)
        #expect(!preview.handleRemote(.togglePlayPause), "nothing previewing: the main player takes it")
        preview.play([Self.item("1"), Self.item("2")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        #expect(preview.handleRemote(.pause) && preview.phase == .paused)
        #expect(preview.handleRemote(.play) && preview.phase == .playing)
        #expect(preview.handleRemote(.togglePlayPause) && preview.phase == .paused)
        #expect(preview.handleRemote(.nextTrack))
        await settle { engine.loads.count == 2 }
        #expect(preview.current?.id == "song-2")
        #expect(preview.handleRemote(.seek(10)), "seeking a preview is swallowed")
        #expect(preview.handleRemote(.like), "a preview can't be favourited")
        #expect(main.queue.current?.song.id == "a" && !main.isPlaying)
    }

    // MARK: - Fix round 1

    /// I2: a pause (lock screen, headphones, CarPlay) while the preview loads holds: the clip that then starts is paused
    /// at once, and its ticks don't move the ring until it plays.
    @Test func aPauseWhileLoadingHolds() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        #expect(preview.phase == .loading)
        #expect(preview.handleRemote(.pause))
        #expect(preview.phase == .paused)
        await settle { engine.loads.count == 1 }
        let token = engine.lastToken
        let pausesBefore = engine.pauses
        preview.handle(.started(token: token))
        #expect(preview.phase == .paused)
        #expect(engine.pauses == pausesBefore + 1, "the clip that just started is paused")
        preview.handle(.time(token: token, 4, duration: 30))
        #expect(preview.position == 0, "no ticks while paused")
        preview.resume()
        #expect(preview.phase == .playing && engine.resumes == 1)
        preview.handle(.time(token: token, 4, duration: 30))
        #expect(preview.position == 4)
    }

    /// A call while the preview loads: it starts paused, and resumes when the system says so.
    @Test func aCallWhileLoadingHolds() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        preview.handle(.interrupted)
        #expect(preview.phase == .paused)
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        #expect(preview.phase == .paused && engine.pauses == 1)
        preview.handle(.resumption(shouldResume: true))
        #expect(preview.phase == .playing && engine.resumes == 1)
    }

    /// Headphones unplugged pause the preview; it isn't a call, so nothing later resumes it out of the speaker.
    @Test func headphonesUnpluggedPauseForGood() async throws {
        let (preview, engine, _) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        preview.handle(.started(token: engine.lastToken))
        preview.handle(.routeLost)
        #expect(preview.phase == .paused)
        preview.handle(.interrupted)
        preview.handle(.resumption(shouldResume: true))
        #expect(preview.phase == .paused, "a recommendation after another interruption doesn't resume it")
        #expect(engine.resumes == 0)
    }

    /// Media services reset: the engine's player is gone. A playing preview is loaded again from where it was (resolved
    /// afresh); a paused one comes back paused.
    @Test func mediaServicesResetReloads() async throws {
        let (preview, engine, lookups) = make()
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        var token = engine.lastToken
        preview.handle(.started(token: token))
        preview.handle(.time(token: token, 7, duration: 30))
        preview.handle(.mediaServicesReset)
        await settle { engine.loads.count == 2 }
        #expect(engine.loads[1].at == 7 && lookups.asked.count == 2)
        token = engine.lastToken
        preview.handle(.started(token: token))
        #expect(preview.phase == .playing)
        preview.pause()
        preview.handle(.mediaServicesReset)
        #expect(preview.phase == .paused)
        await settle { engine.loads.count == 3 }
        let pauses = engine.pauses
        preview.handle(.started(token: engine.lastToken))
        #expect(preview.phase == .paused && engine.pauses == pauses + 1)
    }

    /// Shuffle and repeat don't reach the hidden main queue while a preview plays.
    @Test func shuffleAndRepeatAreIgnoredDuringAPreview() async throws {
        let (preview, engine, _) = make()
        #expect(!preview.handleRemote(.shuffle) && !preview.handleRemote(.repeatMode))
        preview.play([Self.item("1")])
        await settle { engine.loads.count == 1 }
        #expect(preview.handleRemote(.shuffle) && preview.handleRemote(.repeatMode))
        #expect(preview.phase == .loading)
    }

    /// The sleep timer firing calls its hook (the app stops a preview with it).
    @Test func theSleepTimerFiringCallsItsHook() async throws {
        let (main, _, _) = mainPlayer()
        main.play([Self.song("a")], startAt: 0)
        var clock = Date()
        let timer = SleepTimer(player: main, now: { clock }, sleep: { _ in })
        var fired = 0
        timer.onFire = { fired += 1 }
        timer.start(.m15)
        clock = clock.addingTimeInterval(16 * 60)
        await timer.settled()
        #expect(fired == 1)
        #expect(!main.isPlaying)
    }
}
