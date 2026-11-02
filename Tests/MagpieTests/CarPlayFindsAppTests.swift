import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let lidarrScope = LidarrClient(base: lidarrBase, apiKey: "key", transport: MockTransport()).instanceScope
private let artistMBID = "64db764c-2251-4f95-aa40-10fc91d509d8"
private let recordingMBID = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
private let rg = "01a340b4-1d99-4083-ad92-fa2803368bed"
private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

/// Task 7.1d, the app's side of CarPlay: the Finds tab reads the phone's Finds shelf, Keep goes through the phone's
/// Keep, and "Try it next" uses the phone's Try and lands by the one landing rule (D5, D6, D12, CarPlay H3).
@MainActor
@Suite(.serialized) struct CarPlayFindsAppTests {
    let transport = GatedTransport()
    /// `/api/song` (the Finds library read) answers 503.
    let songsFail = OSAllocatedUnfairLock(initialState: false)
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/scrobble", body: ok)
        let songsFail = self.songsFail
        t.stub(pathSuffix: "/api/song") { _ in
            songsFail.withLock { $0 } ? MockTransport.Response(status: 503)
                : MockTransport.Response(status: 200, body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        }
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music/library"}]"#.utf8))
        // Lidarr already has the artist: Try monitors one album and searches.
        t.stub(pathSuffix: "/ws/2/recording/\(recordingMBID.rawValue)", body: Data(#"""
        {"id":"\#(recordingMBID.rawValue)","title":"Harbour Lights","artist-credit":[{"artist":{"id":"\#(artistMBID)"}}],
         "releases":[{"id":"545b96d6-c867-3053-9548-3e8635390e38","title":"The Cat Is Out","status":"Official",
           "release-group":{"id":"\#(rg)","primary-type":"Album","secondary-types":[]}}]}
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"[{"id":7,"artistName":"Judie Tzuke","foreignArtistId":"\#(artistMBID)","rootFolderPath":"/music/library"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/album", body: Data(#"[{"id":31,"title":"The Cat Is Out","artistId":7,"foreignAlbumId":"\#(rg)","monitored":false}]"#.utf8))
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor", body: Data("[]".utf8))
        t.stub(method: "POST", pathSuffix: "/api/v1/command", body: Data(#"{"id":5,"name":"AlbumSearch","status":"queued"}"#.utf8))
        // The library: two songs by the artist (one tagged with an accent-free spelling), one by someone else, and a
        // random album to top the bridge up from.
        t.stub(pathSuffix: "/rest/search3", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{"song":[
          {"id":"jt-1","title":"Stay With Me Till Dawn","artist":"Judie Tzuke","album":"Welcome to the Cruise","duration":240},
          {"id":"jt-2","title":"For You","artist":"judie tzuke","album":"Welcome to the Cruise","duration":200},
          {"id":"other-1","title":"Judie","artist":"Someone Else","album":"Elsewhere","duration":180}]}}}
        """#.utf8))
        t.stub(pathSuffix: "/rest/getAlbumList2", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"al-9","name":"Night Train","artist":"Ines Morrow","songCount":2,"duration":400}]}}}
        """#.utf8))
        t.stub(pathSuffix: "/rest/getAlbum", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"al-9","name":"Night Train","artist":"Ines Morrow","songCount":2,"duration":400,
          "song":[{"id":"im-1","title":"Platform","artist":"Ines Morrow","album":"Night Train","duration":200},
                  {"id":"im-2","title":"Carriage","artist":"Ines Morrow","album":"Night Train","duration":200}]}}}
        """#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    /// Signed in, Lidarr connected and set up, changes allowed: Try is available (`tubifarry`: Standard, else Patient).
    func ready(tubifarry: Bool) async throws -> AppModel {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1))
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        model.lidarrStatus?.tubifarry = tubifarry
        return model
    }

    func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    static func find(_ id: String, created: Date = t0) -> Song {
        Song(id: id, title: "T\(id)", artist: "Aurora Field", album: "Lowlands", duration: 200, coverArtId: "c-\(id)",
             libraryId: 2, createdAt: created)
    }

    let recording = ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights", artist: "Judie Tzuke",
                                      source: .listenBrainz)

    // MARK: - Finds tab

    /// The Finds tab shows the phone's shelf: New finds (not played yet), then the other finds with their days left.
    /// No Finds library chosen: nothing to show (the tab says Finds aren't set up).
    @Test func findsTabReadsThePhoneShelf() {
        let model = makeModel()
        #expect(model.carPlayFinds == nil)
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: "n",
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        model.findSongs = [Self.find("new", created: Date()), Self.find("old", created: Date().addingTimeInterval(-3 * 24 * 3600 - 60))]
        model.playedFinds = ["old"]
        let shelf = model.findsShelf()
        let finds = model.carPlayFinds
        #expect(finds?.newFinds.map(\.song) == shelf.newFinds.map(\.song))
        #expect(finds?.finds.map(\.song) == shelf.finds.map(\.song))
        #expect(finds?.newFinds.map(\.isNew) == [true])
        #expect(finds?.finds.map(\.daysLeft) == [4])
        #expect(CarPlayRows.finds(finds, playingId: nil).flatMap(\.rows).map(\.detail)
                == ["New find · Aurora Field", "Find · 4 days left · Aurora Field"])
    }

    /// Keep is offered in Now Playing exactly when the phone's Finds row offers it: a find with a ready request and
    /// no Keep under way. A library song never.
    @Test func keepIsOfferedWhenThePhoneOffersIt() async {
        let model = makeModel()
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: "n",
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        model.findSongs = [Self.find("a"), Self.find("b")]
        let ready = FindsShelfTests.readyFindRequest(songId: "a")
        var kept = FindsShelfTests.readyFindRequest(songId: "b")
        kept.state = .kept
        model.requests = [ready, kept]
        #expect(model.carPlayMayKeep(songId: "a"))
        #expect(!model.carPlayMayKeep(songId: "b"), "already kept")
        #expect(!model.carPlayMayKeep(songId: "lib-1"), "not a find")
        for item in model.findsShelf().newFinds {
            #expect(model.carPlayMayKeep(songId: item.song.id) == (item.keepRequest != nil))
        }
        // The phone's Keep path: without a runner it can't keep right now; a song with nothing to keep through is
        // refused before anything runs.
        #expect(await model.carPlayKeep(songId: "a") == .unavailable)
        #expect(await model.carPlayKeep(songId: "lib-1") == .notAFind)
        model.findsSetup = nil
        #expect(!model.carPlayMayKeep(songId: "a"), "no Finds library: nothing is a find here")
    }

    /// The runner's answers, as the car says them.
    @Test func keepResultsMapTheRunner() {
        #expect(CPKeepResult(RequestRunner.KeepOutcome.moved) == .moved)
        #expect(CPKeepResult(RequestRunner.KeepOutcome.keptInPlace) == .keptInPlace)
        #expect(CPKeepResult(RequestRunner.KeepOutcome.stillMoving) == .stillMoving)
        #expect(CPKeepResult(error: RequestRunner.KeepError.changesOff) == .changesOff)
        #expect(CPKeepResult(error: RequestRunner.KeepError.notSetUp) == .notSetUp)
        #expect(CPKeepResult(error: RequestRunner.KeepError.notAFind) == .notAFind)
        #expect(CPKeepResult(error: RequestRunner.KeepError.moveFailed) == .moveFailed)
        #expect(CPKeepResult(error: RequestRunner.KeepError.needsAttention) == .needsAttention)
        #expect(CPKeepResult(error: URLError(.timedOut)) == .unavailable)
    }

    // MARK: - Try it next (D6, CarPlay H3)

    /// Nothing playing: the phone's Try runs, a library mix seeded by the artist starts at once (library songs only,
    /// the artist's first), and when the find is ready it goes next in the queue, never cutting into the mix.
    @Test func tryItNextBridgesThenQueuesTheFindNext() async throws {
        let model = try await ready(tubifarry: true)
        #expect(model.carPlayTryOffer == .next)
        #expect(!model.player.isPlaying)
        let result = await model.tryNext(recording)
        #expect(result == .bridging)
        #expect(model.player.isPlaying)
        let queued = model.player.queue.main.map(\.song.id)
        #expect(Set(queued.prefix(2)) == ["jt-1", "jt-2"], "the artist's library songs first")
        #expect(Set(queued.dropFirst(2)) == ["im-1", "im-2"], "topped up from the library")
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(model.requests.first { $0.recording.recordingMBID == recordingMBID }?.id)

        // The find is ready: it lands by the rule (not on a wait screen, something playing): next, with the banner.
        let current = model.player.queue.current?.id
        model.land(Self.find("harbour"), request: id)
        #expect(model.player.queue.current?.id == current, "never cuts in")
        #expect(model.player.queue.upNext.first?.song.id == "harbour")
        #expect(model.playNowBanner?.request == id)
        cleanUp(model)
    }

    /// Something playing: Try runs and nothing else changes; the find goes next when it's ready.
    @Test func tryItNextWhilePlayingLeavesTheQueue() async throws {
        let model = try await ready(tubifarry: true)
        let mine = [Song(id: "m1", title: "Mine", artist: "Me", album: "X", duration: 100),
                    Song(id: "m2", title: "Mine 2", artist: "Me", album: "X", duration: 100)]
        model.play(mine, startAt: 0)
        #expect(await model.tryNext(recording) == .queued)
        #expect(model.player.queue.main.map(\.song.id) == ["m1", "m2"])
        #expect(model.player.queue.current?.song.id == "m1")
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(model.requests.first?.id)
        model.land(Self.find("harbour"), request: id)
        #expect(model.player.queue.current?.song.id == "m1")
        #expect(model.player.queue.upcoming.map(\.song.id) == ["harbour", "m2"])
        cleanUp(model)
    }

    /// Patient ("Ask for it"): only asked for. No mix starts and it never lands.
    @Test func patientIsOnlyAskedFor() async throws {
        let model = try await ready(tubifarry: false)
        #expect(model.carPlayTryOffer == .ask(intoFinds: false))
        #expect(await model.tryNext(recording) == .asked)
        #expect(!model.player.isPlaying && model.player.queue.current == nil)
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.requests.count == 1)
        cleanUp(model)
    }

    /// Try not possible yet: the car offers nothing to tap, and a stray Try asks for nothing.
    @Test func tryUnavailableAsksForNothing() async {
        let model = makeModel()
        #expect(model.carPlayTryOffer == .unavailable)
        #expect(await model.tryNext(recording) == .failed(.notSetUp))
        #expect(model.requests.isEmpty && model.player.queue.current == nil)
    }

    /// Fix 1: a paused queue is the owner's. Try it next leaves it alone (no mix) and the find lands right after the
    /// paused song, as on the phone (D6, Task 7.1b).
    @Test func tryItNextKeepsAPausedQueue() async throws {
        let model = try await ready(tubifarry: true)
        let mine = [Song(id: "m1", title: "Mine", artist: "Me", album: "X", duration: 100),
                    Song(id: "m2", title: "Mine 2", artist: "Me", album: "X", duration: 100)]
        model.play(mine, startAt: 0)
        model.player.toggle()
        #expect(!model.player.isPlaying)
        #expect(await model.tryNext(recording) == .queued)
        #expect(model.player.queue.main.map(\.song.id) == ["m1", "m2"], "the paused queue survives")
        #expect(!model.player.isPlaying)
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(model.requests.first?.id)
        model.land(Self.find("harbour"), request: id)
        #expect(model.player.queue.current?.song.id == "m1")
        #expect(model.player.queue.upcoming.map(\.song.id) == ["harbour", "m2"], "right after the paused song")
        cleanUp(model)
    }

    /// Fix 2: with a Finds library whose songs were never read, every library song might be a find (fail closed).
    /// The Finds library is read first, so the bridge has library songs to play.
    @Test func tryItNextReadsTheFindsFirst() async throws {
        let model = try await ready(tubifarry: true)
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: try #require(model.navidromeScope),
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        #expect(model.isFind(Song(id: "jt-1", title: "S", artist: "Judie Tzuke", album: "W", duration: 1)),
                "unknown ids: fails closed")
        #expect(await model.tryNext(recording) == .bridging)
        #expect(Set(model.player.queue.main.prefix(2).map(\.song.id)) == ["jt-1", "jt-2"])
        cleanUp(model)
    }

    /// Fix 2: when nothing can be played first (the Finds library can't be read, so no song is known to be from the
    /// library), the result says so instead of leaving the car silent.
    @Test func tryItNextWithNothingToPlayFirstSaysSo() async throws {
        let model = try await ready(tubifarry: true)
        songsFail.withLock { $0 = true }
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: try #require(model.navidromeScope),
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        #expect(await model.tryNext(recording) == .noMix)
        #expect(model.player.queue.current == nil && !model.player.isPlaying)
        cleanUp(model)
    }

    /// Final fix 2 B-M7: nothing to play first in the car, so when the find is here and the queue is still idle, it
    /// starts (there's no banner to tap in the car). Something started meanwhile: it goes next as usual.
    @Test func noMixStartsTheFindWhenItLands() async throws {
        let model = try await ready(tubifarry: true)
        songsFail.withLock { $0 = true }
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: try #require(model.navidromeScope),
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        #expect(await model.tryNext(recording) == .noMix)
        #expect(CPTryResult.noMixMessage == "Nothing from your library to play first. It plays once it's here.")
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(model.requests.first { $0.recording.recordingMBID == recordingMBID }?.id)
        model.land(Self.find("harbour"), request: id)
        #expect(model.player.queue.current?.song.id == "harbour" && model.player.isPlaying)
        #expect(model.playNowBanner == nil)
        cleanUp(model)
    }

    /// V-fix: a car Try waiting to start when it lands is forgotten once the request is cancelled (or fails), so a
    /// later landing of the same id can't start it, and once it has landed, even when it was already playing.
    @Test func startsWhenLandedIsForgottenOnCancelAndOnLanding() async throws {
        let model = try await ready(tubifarry: true)
        songsFail.withLock { $0 = true }
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: try #require(model.navidromeScope),
                                      library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        #expect(await model.tryNext(recording) == .noMix)
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let id = try #require(model.requests.first { $0.recording.recordingMBID == recordingMBID }?.id)
        #expect(model.startsWhenLanded == [id])
        await model.cancelRequest(id)
        for _ in 0..<200 where model.requests.first(where: { $0.id == id })?.state != .cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.startsWhenLanded.isEmpty, "a cancelled request never starts")

        // Landing while that very song already plays still forgets the id.
        model.startsWhenLanded.insert(id)
        model.landedRequests.remove(id)
        model.play([Self.find("harbour")], startAt: 0)
        model.land(Self.find("harbour"), request: id)
        #expect(model.startsWhenLanded.isEmpty)
        cleanUp(model)
    }

    /// Fix 3: the car's search never waits long for outside sources (CPSearchTemplate can't stream): they get a short
    /// deadline; the library keeps its usual one.
    @Test func carSearchDoesNotWaitForOutsideSources() async throws {
        let model = try await ready(tubifarry: true)
        transport.close("recording-search/json")
        let start = ContinuousClock.now
        let result = try await model.carPlaySearch("Judie")
        let waited = ContinuousClock.now - start
        transport.open()
        // Round 12 (Y1) ranking: the song called "Judie" first, then the songs by Judie Tzuke in the server's order.
        #expect(result.library.songs.map(\.id) == ["other-1", "jt-1", "jt-2"])
        #expect(result.notYet.isEmpty)
        #expect(waited < .seconds(3), "outside sources cut off at \(AppModel.carPlaySourceTimeout)")
        #expect(AppModel.carPlaySourceTimeout == .milliseconds(1500))
        #expect(AppModel.carPlayLibraryTimeout == .seconds(60), "the library keeps only the request's own limit")
        cleanUp(model)
    }

    /// Fix 7: the car's Keep copy is the phone's, minus anything that asks the driver to do something.
    @Test func carKeepCopyFollowsThePhone() {
        let same: [(CPKeepResult, String)] = [(.moved, KeepCopy.moved), (.keptInPlace, KeepCopy.keptInPlace),
                                              (.stillMoving, KeepCopy.stillMoving), (.notAFind, KeepCopy.notAFind)]
        for (car, phone) in same { #expect(car.message == phone) }
        // The phone adds what to do next; the car stops after the description.
        let shortened: [(CPKeepResult, String)] = [(.moveFailed, KeepCopy.moveFailed),
                                                   (.needsAttention, KeepCopy.needsAttention),
                                                   (.unavailable, KeepCopy.unavailable)]
        for (car, phone) in shortened {
            #expect(phone.hasPrefix(String(car.message.dropLast())), "\(car.message) vs \(phone)")
        }
        // Only the car's: the phone's versions name Settings ("Turn on…", "Tap…").
        #expect(CPKeepResult.changesOff.message == "Keeping is switched off on this iPhone.")
        #expect(CPKeepResult.notSetUp.message == "Keeping isn't set up on this iPhone yet.")
    }

    /// Try's refusals, as the car says them.
    @Test func tryProblemsMapTheRunner() {
        #expect(CPTryProblem(RequestRunner.TryError.tooMany) == .tooMany)
        #expect(CPTryProblem(RequestRunner.TryError.changesOff) == .notSetUp)
        #expect(CPTryProblem(RequestRunner.TryError.notSetUp) == .notSetUp)
        #expect(CPTryProblem(RequestRunner.TryError.unavailable) == .unavailable)
        #expect(CPTryProblem(URLError(.timedOut)) == .other)
    }
}
