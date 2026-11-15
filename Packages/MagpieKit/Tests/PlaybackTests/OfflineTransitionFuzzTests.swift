import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Playback

/// Round 28 O4 (owner, 2026-11-15): the player at an offline switch (D349), as `AppModel.offlineInputsChanged` applies
/// it: offline only songs on the phone are playable and the upcoming list is sent again; manual offline also stops a
/// stream (`stopUnplayableCurrent`); either way a failed song is retried or moved past (`retryAfterFailure`).
@MainActor
@Suite struct OfflineTransitionTests {
    typealias Engine = PlayerChaosFuzzTests.ChaosEngine

    /// What's on the phone, read live (a download can land or go while offline).
    final class Phone: @unchecked Sendable {
        var local: Set<String>
        init(_ local: Set<String>) { self.local = local }
    }

    @MainActor struct Rig {
        let player: Player
        let engine: Engine
        let urls: PlayerChaosFuzzTests.ChaosURLs
        let phone: Phone

        /// The switch, as the app applies it. `manual`: Offline mode on (a stream stops).
        func goOffline(manual: Bool) {
            urls.offline = true
            let phone = phone
            player.isPlayable = { phone.local.contains($0.id) }
            player.upcomingURLsChanged()
            if manual { player.stopUnplayableCurrent(message: "You're offline") }
            player.retryAfterFailure()
        }

        func goOnline() {
            urls.offline = false
            player.isPlayable = { _ in true }
            player.upcomingURLsChanged()
            player.retryAfterFailure()
        }

        /// The engine reports `event` (it stops wanting to play first, as `AVQueueEngine` does).
        func report(_ event: EngineEvent) {
            engine.willReport(event)
            player.handle(event)
        }

        var currentId: String? { player.queue.current?.song.id }
        /// The URL the engine holds for the current entry.
        var currentURL: URL? { player.queue.current.flatMap { c in engine.items.first { $0.0 == c.id }?.1 } }
    }

    func rig(local: Set<String>) -> Rig {
        let engine = Engine()
        let urls = PlayerChaosFuzzTests.ChaosURLs()
        urls.local = local
        let player = Player(engine: engine, scrobbler: PlayerChaosFuzzTests.CountingScrobbler(), urls: urls,
                            sleep: { _ in })
        player.canReachServer = { [urls] in !urls.offline }   // as the app wires it: offline, no server
        return Rig(player: player, engine: engine, urls: urls, phone: Phone(local))
    }

    func songs(_ ids: [String]) -> [Song] {
        ids.map { Song(id: $0, title: $0, artist: "A", album: "B", duration: 200) }
    }

    // MARK: D349

    /// Automatic offline (the tunnel): a stream plays on until it fails, then the next song on the phone plays; the
    /// songs passed over stay in the queue.
    @Test func playback_automaticSwitchMidStream() {
        let r = rig(local: ["s3"])
        r.player.play(songs(["s1", "s2", "s3", "s4"]), startAt: 0)
        r.goOffline(manual: false)
        #expect(r.currentId == "s1" && r.player.isPlaying, "the stream plays on")
        #expect(r.currentURL?.isFileURL == false)
        #expect(r.engine.items.dropFirst().allSatisfy { $0.1.isFileURL }, "only songs on the phone come after it")
        // The buffer runs out.
        r.report(.failed(r.player.queue.current!.id, "The network connection was lost.", undecodable: false))
        #expect(r.currentId == "s3" && r.player.isPlaying)
        #expect(r.currentURL?.isFileURL == true)
        #expect(r.player.queue.main.map(\.song.id) == ["s1", "s2", "s3", "s4"], "no queue is lost")
        // Back online after the tunnel: s4 streams again next; s1 and s2 are a Previous away.
        r.goOnline()
        #expect(r.currentId == "s3" && r.player.isPlaying)
        #expect(r.player.queue.upcoming.map(\.song.id) == ["s4"])
        #expect(r.engine.items.last?.1.isFileURL == false, "s4 is sent again as a stream")
    }

    /// The tunnel with nothing on the phone: the stream fails, the player pauses on it, and plays it again from where
    /// it was once the library answers.
    @Test func playback_tunnelWithNothingOnThePhoneComesBack() {
        let r = rig(local: [])
        r.player.play(songs(["s1", "s2"]), startAt: 0)
        r.player.handle(.time(r.player.queue.current!.id, 42, duration: 200))
        r.goOffline(manual: false)
        r.report(.failed(r.player.queue.current!.id, "The network connection was lost.", undecodable: false))
        #expect(r.currentId == "s1" && !r.player.isPlaying, "paused on the song, never spinning through the queue")
        #expect(r.player.queue.main.count == 2)
        r.goOnline()
        #expect(r.currentId == "s1" && r.player.isPlaying, "the same song comes back")
        #expect(r.player.position == 42, "from where it was")
    }

    /// Manual offline mid-stream: the stream stops at once; the next song on the phone plays, or it pauses with
    /// "You're offline" and nothing loaded (security M1).
    @Test func playback_manualSwitchMidStream() {
        let r = rig(local: ["s3"])
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        r.goOffline(manual: true)
        #expect(r.currentId == "s3" && r.player.isPlaying && r.currentURL?.isFileURL == true)

        let none = rig(local: [])
        none.player.play(songs(["s1", "s2"]), startAt: 0)
        none.goOffline(manual: true)
        #expect(!none.player.isPlaying && none.player.lastError == "You're offline")
        #expect(none.engine.items.isEmpty, "no stream stays loaded")
        #expect(none.player.queue.main.count == 2)
    }

    /// A song that landed on the phone while it streamed: Offline mode on carries on from the file, where it was, and
    /// the next song enqueued as a stream before it landed plays from the phone too.
    @Test func playback_landedWhileStreamingPlaysFromThePhoneOffline() {
        let r = rig(local: [])
        r.player.play(songs(["s1", "s2"]), startAt: 0)
        r.player.handle(.time(r.player.queue.current!.id, 50, duration: 200))
        r.phone.local = ["s1", "s2"]
        r.urls.local = ["s1", "s2"]
        r.player.upcomingURLsChanged()
        #expect(r.currentURL?.isFileURL == false, "online the current song keeps the stream it has")
        r.goOffline(manual: true)
        #expect(r.currentId == "s1" && r.player.isPlaying && r.currentURL?.isFileURL == true)
        #expect(r.player.position == 50)
        r.player.next()
        #expect(r.currentId == "s2" && r.currentURL?.isFileURL == true, "never the stream the engine enqueued first")
    }

    /// Back online while a song plays from the phone: the file isn't reloaded (D282); the rest is sent again.
    @Test func playback_backOnlineKeepsTheLocalFile() {
        let r = rig(local: ["s1"])
        r.player.play(songs(["s1", "s2"]), startAt: 0)
        r.goOffline(manual: true)
        r.player.handle(.time(r.player.queue.current!.id, 30, duration: 200))
        let file = r.currentURL
        #expect(file?.isFileURL == true)
        r.goOnline()
        #expect(r.currentId == "s1" && r.player.isPlaying && r.currentURL == file && r.player.position == 30)
        #expect(r.engine.enqueued[r.player.queue.current!.id] == file, "the engine kept the item it had")
        #expect(r.player.queue.upcoming.map(\.song.id) == ["s2"] && r.engine.items.count == 2)
    }

    /// Repeat all offline goes round the songs on the phone only, from Next and from the end of the list alike.
    @Test func playback_repeatAllOfflineOnlyPhoneSongs() {
        let r = rig(local: ["s2", "s4"])
        r.player.play(songs(["s1", "s2", "s3", "s4"]), startAt: 1)
        r.player.repeatMode = .all
        r.goOffline(manual: true)
        var heard: [String] = []
        for _ in 0..<6 {
            r.player.next()
            heard.append(r.currentId ?? "-")
            #expect(r.player.isPlaying && r.currentURL?.isFileURL == true, "Next landed on \(heard)")
        }
        #expect(heard == ["s4", "s2", "s4", "s2", "s4", "s2"])
        // The end of the list (the engine played s4 out): round to s2 again, not s1.
        r.player.next()
        #expect(r.currentId == "s4")
        r.report(.ended(r.engine.items.last!.0))
        #expect(r.currentId == "s2" && r.player.isPlaying && r.currentURL?.isFileURL == true)
    }

    /// Shuffle offline plays only songs on the phone.
    @Test func playback_shuffleOfflineOnlyPhoneSongs() {
        let r = rig(local: ["s1", "s3", "s5"])
        r.player.play(songs(["s1", "s2", "s3", "s4", "s5", "s6"]), startAt: 0)
        r.goOffline(manual: true)
        r.player.setShuffled(true, seed: 7)
        while !r.player.queue.upcoming.filter({ r.phone.local.contains($0.song.id) }).isEmpty {
            r.player.next()
            #expect(r.phone.local.contains(r.currentId ?? "") && r.currentURL?.isFileURL == true)
        }
        #expect(r.engine.items.allSatisfy { $0.1.isFileURL })
    }

    /// A queue with nothing on the phone pauses with "You're offline": Next, repeat all and the end of the list never
    /// load a stream or spin.
    @Test func playback_noPhoneSongsPausesNotSpins() {
        let r = rig(local: [])
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        r.player.repeatMode = .all
        r.goOffline(manual: true)
        #expect(!r.player.isPlaying && r.player.lastError == "You're offline")
        for _ in 0..<5 { r.player.next() }
        #expect(!r.player.isPlaying, "Next has nowhere to go")
        #expect(r.engine.items.allSatisfy { $0.1.isFileURL }, "no stream is loaded offline")
        r.player.toggle()   // Play
        #expect(!r.player.isPlaying || r.currentURL?.isFileURL == true, "Play doesn't start a stream offline")
    }
}

/// Round 28 O4 (D349): 500 seeded sequences of offline flips (automatic and manual), skips, repeat and shuffle, engine
/// failures and endings, and downloads landing and going, against `Player`. Invariants after every step: no trap, the
/// chaos suite's queue/engine invariants (one current entry, the engine's list made of queue entries), and while
/// offline nothing plays that isn't on the phone, except the stream an automatic switch let play on until it fails.
/// (The car half of the sweep runs hosted: `CarPlayOfflineAppTests.offline_randomFlipsAndCarPushesKeepTheStack`.)
@MainActor
@Suite struct OfflineTransitionFuzzTests {
    @Test func offline_randomFlipsQueueAndCarNeverTrap() async {
        var offlineSteps = 0
        for seed in 0..<UInt64(500) {
            offlineSteps += await run(seed: seed, ops: 60)
        }
        #expect(offlineSteps > 5_000, "the sweep spends time offline: \(offlineSteps) steps")
    }

    /// Returns the steps that ended offline with something playing.
    func run(seed: UInt64, ops: Int) async -> Int {
        var rng = SeededRNG(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ 3)
        let engine = PlayerChaosFuzzTests.ChaosEngine()
        let urls = PlayerChaosFuzzTests.ChaosURLs()
        let phone = OfflineTransitionTests.Phone(Set((0..<8).map { "s\($0)" }.filter { _ in Bool.random(using: &rng) }))
        urls.local = phone.local
        let player = Player(engine: engine, scrobbler: PlayerChaosFuzzTests.CountingScrobbler(), urls: urls, sleep: { _ in })
        player.canReachServer = { [urls] in !urls.offline }
        var offline = false, manual = false
        /// The entry an automatic switch found streaming: it may play on until it fails (D330).
        var playsOn: UUID?
        var log: [String] = []
        var playingOffline = 0

        func songs() -> [Song] {
            (0..<Int.random(in: 1...8, using: &rng)).map { _ in
                let id = "s\(Int.random(in: 0...7, using: &rng))"
                return Song(id: id, title: id, artist: "A", album: "B", duration: 200)
            }
        }
        func report(_ event: EngineEvent) {
            engine.willReport(event)
            player.handle(event)
        }
        func currentURL() -> URL? { player.queue.current.flatMap { c in engine.items.first { $0.0 == c.id }?.1 } }

        for step in 0..<ops {
            let op = Int.random(in: 0...13, using: &rng)
            log.append("\(op)")
            switch op {
            case 0: player.play(songs(), startAt: Int.random(in: 0...7, using: &rng))
            case 1:
                // An offline switch, as `offlineInputsChanged` applies it.
                if offline, !manual || Bool.random(using: &rng) {
                    offline = false; manual = false; playsOn = nil
                    urls.offline = false
                    player.isPlayable = { _ in true }
                    player.upcomingURLsChanged()
                    player.retryAfterFailure()
                } else {
                    let wasOffline = offline
                    offline = true
                    manual = Bool.random(using: &rng)
                    urls.offline = true
                    if !wasOffline, !manual, let c = player.queue.current, currentURL()?.isFileURL == false, player.isPlaying {
                        playsOn = c.id
                    }
                    if manual { playsOn = nil }
                    player.isPlayable = { phone.local.contains($0.id) }
                    player.upcomingURLsChanged()
                    if manual { player.stopUnplayableCurrent(message: "You're offline") }
                    player.retryAfterFailure()
                }
            case 2, 3: player.next()
            case 4: player.previous()
            case 5: player.repeatMode = RepeatMode.allCases.randomElement(using: &rng)!
            case 6: player.setShuffled(Bool.random(using: &rng), seed: rng.next())
            case 7:
                // The current item fails (a stream's buffer ran out, or a file went).
                if let c = player.queue.current { report(.failed(c.id, "boom", undecodable: false)) }
            case 8:
                // The engine played its list out.
                if let last = engine.items.last?.0 { report(.ended(last)) }
            case 9:
                // The engine moved on by itself.
                if engine.items.count > 1 { report(.itemChanged(engine.items[1].0)) }
            case 10:
                // A download landed, or was removed (its file is gone: the engine fails it if it is the current one).
                let id = "s\(Int.random(in: 0...7, using: &rng))"
                if phone.local.contains(id) {
                    phone.local.remove(id)
                    urls.local = phone.local
                    player.upcomingURLsChanged()
                    if let c = player.queue.current, c.song.id == id, currentURL()?.isFileURL == true {
                        report(.failed(c.id, "The file is gone", undecodable: false))
                    }
                } else {
                    phone.local.insert(id)
                    urls.local = phone.local
                    player.upcomingURLsChanged()
                }
            case 11: player.toggle()
            case 12:
                if let c = player.queue.current { player.handle(.time(c.id, player.position + 1, duration: nil)) }
            default:
                let all = player.queue.main + player.queue.upNext
                player.remove(id: all.randomElement(using: &rng)?.id ?? UUID())
            }
            if player.queue.current?.id != playsOn { playsOn = nil }
            let ctx = "seed \(seed) step \(step) ops \(log.joined(separator: ","))"
            PlayerChaosFuzzTests().check(player, engine, ctx)
            if offline, player.isPlaying, let c = player.queue.current {
                playingOffline += 1
                #expect(phone.local.contains(c.song.id) || c.id == playsOn,
                        "\(ctx): offline, \(c.song.id) plays but isn't on the phone")
                if c.id != playsOn { #expect(currentURL()?.isFileURL == true, "\(ctx): offline, a stream is loaded") }
            }
        }
        return playingOffline
    }
}
