import Foundation
import MagpieCore
import MagpieTestSupport
import Playback
import Requests
import Testing
@testable import Magpie

/// Task 7.1b. D6: a find that just became ready lands by `LandingRule`; when it doesn't play at once it goes next
/// in the queue (never cutting in) with the in-app "Play now" banner. D5: Bring in more follows a Keep that moved
/// the find (never a Keep that stayed in Finds), and says its size only as "about N hours of music" (A5).
@MainActor
@Suite(.serialized) struct LandingAndBringInTests {
    let defaults = UserDefaults(suiteName: "LandingAndBringInTests.\(UUID().uuidString)")!
    let engine = FakeEngine()

    func makeModel() -> AppModel {
        let t = MockTransport()
        return AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                        lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                        dataDirectory: nil, transport: t, probeTransport: t, engine: engine, defaults: defaults,
                        systemNowPlaying: false, notifications: false)
    }

    static func song(_ id: String) -> Song { Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: 200) }
    static let find = song("find")
    let request = RequestID()

    // MARK: - Landing (D6)

    @Test func playsAtOnceOnItsWaitScreenWhenNothingPlays() {
        let model = makeModel()
        model.waitScreenAppeared(request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find)
        #expect(model.player.isPlaying)
        #expect(model.playNowBanner == nil)
    }

    /// Paused queue, still on the wait screen: the find plays now; the paused song comes right after it (not
    /// dropped into what has played), then the rest.
    @Test func playingNowKeepsAPausedQueue() {
        let model = makeModel()
        model.play([Self.song("a"), Self.song("b")], startAt: 0)
        model.player.toggle()
        #expect(!model.player.isPlaying)
        model.waitScreenAppeared(request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying)
        #expect(model.player.queue.upcoming.map(\.song.id) == ["a", "b"])
        #expect(model.player.queue.main.prefix { $0.song.id != "find" }.isEmpty, "a isn't in what has played")
        #expect(model.playNowBanner == nil)
    }

    /// Final fix 2 B-M3: a song that played to its end isn't put back after the find: it was heard.
    @Test func playingNowDropsASongThatEnded() {
        let model = makeModel()
        model.play([Self.song("a")], startAt: 0)
        model.player.handle(.ended)
        #expect(!model.player.isPlaying && model.player.hasEnded)
        model.waitScreenAppeared(request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying && !model.player.hasEnded)
        #expect(model.player.queue.upcoming.isEmpty, "the song that ended doesn't come back")
    }

    /// Play now from the banner while the queue is paused keeps the paused song too.
    @Test func bannerPlayNowKeepsThePausedSong() throws {
        let model = makeModel()
        model.play([Self.song("a"), Self.song("b")], startAt: 0)
        model.player.toggle()
        model.land(Self.find, request: request)
        model.playNow(try #require(model.playNowBanner))
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying)
        #expect(model.player.queue.upcoming.map(\.song.id) == ["a", "b"])
    }

    /// Fix 3: once the find was reached and played, pausing it later shows the mini player, not the banner.
    @Test func bannerGoesOnceTheFindPlayed() async throws {
        let model = makeModel()
        model.play([Self.song("a")], startAt: 0)
        model.land(Self.find, request: request)
        #expect(model.visibleBanner != nil)
        model.player.next()   // reached normally, playing
        for _ in 0..<200 where model.playNowBanner != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.playNowBanner == nil, "cleared the first time it played")
        model.player.toggle()
        #expect(!model.player.isPlaying && model.visibleBanner == nil)
    }

    /// The idle-queue landing: loaded but never played, the banner shows; once played and paused, it doesn't.
    @Test func idleLandingBannerUntilPlayed() async throws {
        let model = makeModel()
        model.land(Self.find, request: request)
        #expect(model.visibleBanner?.idle == true)
        model.player.toggle()
        for _ in 0..<200 where model.playNowBanner != nil { try await Task.sleep(for: .milliseconds(10)) }
        model.player.toggle()
        #expect(model.playNowBanner == nil && model.visibleBanner == nil)
    }

    /// Something is playing: never cut in. Next in the queue, with the banner; Play now plays it.
    @Test func somethingPlayingQueuesNextWithBanner() throws {
        let model = makeModel()
        model.play([Self.song("a"), Self.song("b")], startAt: 0)
        model.waitScreenAppeared(request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song.id == "a")
        #expect(model.player.queue.upcoming.map(\.song.id) == ["find", "b"])
        let banner = try #require(model.playNowBanner)
        #expect(banner.song == Self.find && model.visibleBanner == banner)

        model.playNow(banner)
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying)
        #expect(model.player.queue.upcoming.map(\.song.id) == ["b"])
        #expect(model.playNowBanner == nil)
    }

    /// Left the wait screen (or the app is in the background): queued with the banner even when nothing plays.
    @Test func leftTheWaitScreenQueuesWithBanner() throws {
        let model = makeModel()
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find && !model.player.isPlaying)
        let banner = try #require(model.playNowBanner)
        model.playNow(banner)
        #expect(model.player.isPlaying && model.playNowBanner == nil)

        let other = RequestID()
        let background = makeModel()
        background.waitScreenAppeared(other)
        background.isForeground = false
        background.land(Self.find, request: other)
        #expect(!background.player.isPlaying && background.playNowBanner != nil)
    }

    @Test func waitScreenGoneMeansNotWaiting() {
        let model = makeModel()
        model.waitScreenAppeared(request)
        model.waitScreenDisappeared(request)
        #expect(!model.isOnWaitScreen(request))
        model.land(Self.find, request: request)
        #expect(!model.player.isPlaying && model.playNowBanner != nil)
    }

    /// The banner goes away when dismissed, and once its song is playing anyway; one landing per request.
    @Test func bannerLifecycle() {
        let model = makeModel()
        model.play([Self.song("a")], startAt: 0)
        model.land(Self.find, request: request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.upcoming.map(\.song.id) == ["find"], "landed once")
        #expect(model.visibleBanner != nil)
        model.player.next()
        #expect(model.visibleBanner == nil, "its song is playing")
        model.dismissBanner()
        #expect(model.playNowBanner == nil)
    }

    /// The wait screen's Play after the find went next: it plays through the banner, never queued twice.
    @Test func waitScreenPlayUsesTheBanner() {
        let model = makeModel()
        model.play([Self.song("a")], startAt: 0)
        model.land(Self.find, request: request)
        model.playReady(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying)
        #expect(model.player.queue.upcoming.isEmpty && model.playNowBanner == nil)
    }

    /// Already the song playing: nothing to land.
    @Test func alreadyPlayingTheFind() {
        let model = makeModel()
        model.play([Self.find], startAt: 0)
        model.land(Self.find, request: request)
        #expect(model.player.queue.upcoming.isEmpty && model.playNowBanner == nil)
    }

    @Test func bannerCopy() {
        #expect(LandingCopy.title(Self.find) == "Tfind is ready")
        #expect(LandingCopy.playNow == "Play now")
    }

    // MARK: - Bring in more (D5)

    @Test func bringInMoreOnlyAfterAMove() {
        #expect(KeepCopy.reply(.moved) == KeepReply(message: KeepCopy.moved, bringsInMore: true))
        #expect(KeepCopy.reply(.keptInPlace) == KeepReply(message: KeepCopy.keptInPlace, bringsInMore: false))
        #expect(KeepCopy.reply(.stillMoving) == KeepReply(message: KeepCopy.stillMoving, bringsInMore: false))
    }

    /// A5: "about N hours of music" from the lengths Lidarr knows; nothing when it doesn't.
    @Test func sizeOnlyAsHours() {
        #expect(BringInCopy.size(6_600) == "about 2 hours of music")
        #expect(BringInCopy.size(2_400) == "about 1 hour of music")
        #expect(BringInCopy.size(600) == "about 1 hour of music")
        #expect(BringInCopy.size(36_000) == "about 10 hours of music")
        #expect(BringInCopy.size(nil) == nil)
        #expect(BringInCopy.size(0) == nil)
    }

    @Test func optionLines() {
        typealias Option = RequestRunner.BringInOption
        #expect(BringInCopy.detail(Option(albumIds: [1, 2, 3], available: 3, duration: 6_600))
                == "3 releases · about 2 hours of music")
        #expect(BringInCopy.detail(Option(albumIds: [1], available: 1, duration: nil)) == "1 release")
        #expect(BringInCopy.detail(Option(albumIds: [1], available: 1, duration: 2_400, title: "Lowlands"))
                == "Lowlands · about 1 hour of music")
        #expect(BringInCopy.detail(Option(albumIds: [], available: 0, duration: nil, title: "Lowlands"))
                == "Lowlands · in your library already")
        #expect(BringInCopy.detail(Option(albumIds: [], available: 0, duration: nil)) == "Nothing more to bring in")
        #expect(BringInCopy.capped(Option(albumIds: Array(0..<20), available: 29, duration: nil))
                == "That's a lot at once, so the newest 20 of 29 come in now.")
        #expect(BringInCopy.capped(Option(albumIds: [1], available: 1, duration: nil)) == nil)
    }

    /// H2b fix 1 (FL4): the limit of five counts songs and releases on their way, and the copy says so: what is
    /// counted, and that a place frees up when one is home or stops. A sheet with no room offers following only;
    /// fewer releases than the sheet said is said, never hidden.
    @Test func limitCopySaysWhatIsCounted() {
        typealias Result = RequestRunner.BringInResult
        typealias Option = RequestRunner.BringInOption
        for text in [TryCopy.tooMany, BringInCopy.message(for: RequestRunner.BringInError.tooMany)] {
            #expect(text.contains("songs and releases") && text.contains("home or has stopped"), "\(text)")
        }
        #expect(BringInCopy.capped(Option(albumIds: [], available: 3, duration: nil))
                == "Five songs and releases are already on their way, so these can come in later. You can still follow new releases.")
        #expect(BringInCopy.done(Result(albums: 2, searching: true, following: false, heldBack: 2), artist: "Aurora Field")
                == "Bringing in 2 releases from Aurora Field. 2 releases more can come in when something on its way is home.")
        #expect(BringInCopy.done(Result(albums: 0, searching: false, following: true, heldBack: 3), artist: "Aurora Field")
                == "New releases from Aurora Field will come in as they come out. 3 releases more can come in when something on its way is home.")
    }

    /// Library's "N on their way" counts releases Bring in more is still bringing in, like the limit does.
    @Test func onTheirWayCountsReleases() {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                             dataDirectory: nil, gateDefaultsSuite: "magpie-tests-gate-\(UUID().uuidString)",
                             transport: MockTransport(), probeTransport: MockTransport(), engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!, systemNowPlaying: false,
                             notifications: false)
        let recording = ExternalRecording(recordingMBID: nil, title: "S", artist: "A", source: .listenBrainz)
        var searching = MagpieRequest(recording: recording, tier: .standard, createdAt: Date())
        searching.state = .searching
        var kept = MagpieRequest(recording: recording, tier: .standard, createdAt: Date())
        kept.state = .kept
        kept.bringingIn = [51, 52]
        model.requests = [searching, kept]
        #expect(model.onTheirWay == 3)
    }

    /// Fix 7: copy that suggests trying again comes with a Try again button; the rest promises no retry.
    @Test func retryOnlyWhereOffered() {
        let all: [RequestRunner.BringInError] = [.changesOff, .notSetUp, .notKept, .tooMany, .unavailable, .failed, .unconfirmed]
        #expect(all.filter(BringInCopy.isRetryable) == [.unavailable, .failed, .unconfirmed])
        for e in all {
            let reply = AppModel.BringInReply(error: e)
            if reply.message.contains("Try again") || reply.message.contains("try again") { #expect(reply.retryable) }
        }
        #expect(!BringInCopy.message(for: RequestRunner.BringInError.failed).contains("Nothing changed"))
    }

    @Test func doneAndErrorCopy() {
        typealias Result = RequestRunner.BringInResult
        #expect(BringInCopy.done(Result(albums: 3, searching: true, following: true), artist: "Aurora Field")
                == "Bringing in 3 releases from Aurora Field. New releases will come in too.")
        #expect(BringInCopy.done(Result(albums: 1, searching: true, following: false), artist: "Aurora Field")
                == "Bringing in 1 release from Aurora Field.")
        #expect(BringInCopy.done(Result(albums: 0, searching: false, following: true), artist: "Aurora Field")
                == "New releases from Aurora Field will come in as they come out.")
        var texts = [BringInCopy.title("X"), BringInCopy.followNote, BringInCopy.done(Result(albums: 2, searching: false, following: false), artist: "X")]
        for e in [RequestRunner.BringInError.changesOff, .notSetUp, .notKept, .tooMany, .unavailable, .failed, .unconfirmed] {
            texts.append(BringInCopy.message(for: e))
        }
        for text in texts {   // H3 I5: even the pointers to Settings name no service
            #expect(!text.contains("Lidarr") && !text.contains("Navidrome") && !text.contains("MusicBrainz"),
                    "§5: no service names outside Settings: \(text)")
        }
    }
}
