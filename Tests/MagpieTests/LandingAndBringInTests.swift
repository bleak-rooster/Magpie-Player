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

    /// Paused queue, still on the wait screen: the find plays now and what was queued stays after it.
    @Test func playingNowKeepsAPausedQueue() {
        let model = makeModel()
        model.play([Self.song("a"), Self.song("b")], startAt: 0)
        model.player.toggle()
        #expect(!model.player.isPlaying)
        model.waitScreenAppeared(request)
        model.land(Self.find, request: request)
        #expect(model.player.queue.current?.song == Self.find && model.player.isPlaying)
        #expect(model.player.queue.upcoming.map(\.song.id) == ["b"])
        #expect(model.playNowBanner == nil)
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

    @Test func doneAndErrorCopy() {
        typealias Result = RequestRunner.BringInResult
        #expect(BringInCopy.done(Result(albums: 3, searching: true, following: true), artist: "Aurora Field")
                == "Bringing in 3 releases from Aurora Field. New releases will come in too.")
        #expect(BringInCopy.done(Result(albums: 1, searching: true, following: false), artist: "Aurora Field")
                == "Bringing in 1 release from Aurora Field.")
        #expect(BringInCopy.done(Result(albums: 0, searching: false, following: true), artist: "Aurora Field")
                == "New releases from Aurora Field will come in as they come out.")
        var texts = [BringInCopy.title("X"), BringInCopy.followNote, BringInCopy.done(Result(albums: 2, searching: false, following: false), artist: "X")]
        for e in [RequestRunner.BringInError.changesOff, .notSetUp, .notKept, .tooMany, .unavailable, .failed] {
            texts.append(BringInCopy.message(for: e))
        }
        for text in texts where !text.contains("in Settings") {   // Settings names its own switches and buttons
            #expect(!text.contains("Lidarr") && !text.contains("Navidrome") && !text.contains("MusicBrainz"),
                    "§5: no service names outside Settings: \(text)")
        }
    }
}
