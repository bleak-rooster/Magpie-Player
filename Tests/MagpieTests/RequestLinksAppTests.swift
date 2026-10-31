import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Requests
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
private let songMBID = MBID("00000000-0000-0000-0000-000000000100")!
private let otherMBID = MBID("00000000-0000-0000-0000-000000000200")!
private let rgMBID = MBID("00000000-0000-0000-0000-000000000010")!
private let artistMBID = MBID("00000000-0000-0000-0000-000000000001")!

/// R17 (with R20's rulings): back to a request from wherever its item shows, Ready rows in place, stalled copies and
/// Find another copy, the stuck-copy setting, and the car's live-request rows.
@MainActor
@Suite(.serialized) struct RequestLinksAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/rest/getSong", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","song":{"id":"landed","title":"Paper Planes","artist":"Aurora Field","album":"Lowlands","duration":200}}}
        """#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    static func recording(_ mbid: MBID? = songMBID, title: String = "Paper Planes") -> ExternalRecording {
        ExternalRecording(recordingMBID: mbid, title: title, artist: "Aurora Field", source: .listenBrainz)
    }

    static func request(_ state: RequestState, recording: ExternalRecording = recording(), tier: Tier = .standard)
        -> MagpieRequest {
        var r = MagpieRequest(recording: recording, tier: tier, createdAt: t0)
        r.state = state
        r.albumId = 31
        r.lidarrArtistId = 7
        r.plan = Plan(recordingMBID: songMBID, releaseGroupMBID: rgMBID, artistMBID: artistMBID, lidarrArtistId: 7,
                      mode: .fallback)
        return r
    }

    // MARK: - Back to a request (search, Made for you, Try, Activity)

    /// A not-yet song with a live request is that request's row (status, opens its page), never a second Try; one
    /// that stopped or failed can be tried again.
    @Test func liveRequestRowOpensTheRequest() {
        let live = Self.request(.searching)
        #expect(RequestLinks.songRow(for: Self.recording(), in: [live], readySongs: [:]) == .request(live.id))
        // Matched by recording MBID, else title and artist.
        let noMBID = Self.recording(nil)
        #expect(RequestLinks.songRow(for: noMBID, in: [Self.request(.downloading(progress: 0.4), recording: noMBID)],
                                     readySongs: [:]) != .tryIt)
        #expect(RequestLinks.songRow(for: Self.recording(otherMBID, title: "Other"), in: [live], readySongs: [:]) == .tryIt)
        for done in [RequestState.cancelled, .failed(reason: .noRelease), .dismissed] {
            #expect(RequestLinks.songRow(for: Self.recording(), in: [Self.request(done)], readySongs: [:]) == .tryIt)
        }
        // The newest live one wins.
        let newer = Self.request(.downloading(progress: 0.2))
        #expect(RequestLinks.songRow(for: Self.recording(), in: [live, newer], readySongs: [:]) == .request(newer.id))
    }

    /// The Try sheet, opened anyway (a context menu, the car's alert, a stale row): the request's page, not a Try.
    @Test func trySheetOpensTheExistingRequest() {
        let live = Self.request(.searching)
        #expect(TrySheet.existingPhase(for: Self.recording(), in: [live]) == .waiting(live.id))
        let patient = Self.request(.searching, tier: .patient)
        #expect(TrySheet.existingPhase(for: Self.recording(), in: [patient]) == .asked(patient.id))
        #expect(TrySheet.existingPhase(for: Self.recording(), in: [Self.request(.cancelled)]) == nil)
        #expect(TrySheet.existingPhase(for: Self.recording(), in: []) == nil)
    }

    /// Album and artist rows from outside the library lead to the request bringing them in.
    @Test func albumAndArtistRowsLeadToTheirRequest() {
        let live = Self.request(.downloading(progress: 0.4))
        #expect(RequestLinks.request(releaseGroup: rgMBID, in: [live])?.id == live.id)
        #expect(RequestLinks.request(releaseGroup: otherMBID, in: [live]) == nil)
        #expect(RequestLinks.request(releaseGroup: nil, in: [live]) == nil)
        #expect(RequestLinks.request(artist: artistMBID, in: [live])?.id == live.id)
        #expect(RequestLinks.request(artist: otherMBID, in: [live]) == nil)
        #expect(RequestLinks.request(releaseGroup: rgMBID, in: [Self.request(.cancelled)]) == nil)
    }

    // MARK: - Ready, in place

    /// The runner's ready event reads the library song once; the search row showing the request becomes that song
    /// (a library row, playable) without leaving search, and the open request page offers Play.
    @Test func readyEventTurnsTheRowIntoTheLibrarySong() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        var request = Self.request(.downloading(progress: 0.9))
        model.requests = [request]
        #expect(RequestLinks.songRow(for: Self.recording(), in: model.requests, readySongs: model.readySongs)
                == .request(request.id))

        request.state = .ready
        request.songId = "landed"
        model.requests = [request]
        model.requestBecameReady(request)
        for _ in 0..<200 where model.readySongs[request.id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        let row = RequestLinks.songRow(for: Self.recording(), in: model.requests, readySongs: model.readySongs)
        guard case .library(let song, let id) = row else { Issue.record("not a library row: \(row)"); return }
        #expect(song.id == "landed" && id == request.id)
        #expect(RequestPageAction.actions(for: request).first == .play)
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    // MARK: - Stalled copies and Find another copy (R20's words)

    @Test func stalledCopyAndStillLookingCopy() {
        var stalled = Self.request(.searching)
        stalled.sourceStalledAt = t0
        stalled.stallRetries = 1
        #expect(RequestCopy.status(stalled) == "That copy stopped coming. Looking for another…")
        #expect(RequestCopy.phrase(stalled) == "That copy stopped coming. Looking for another…")

        var usedUp = Self.request(.waiting(reason: WaitReason(.stillLooking, since: t0), retryAt: t0))
        usedUp.stallRetries = RequestRunner.maxStallRetries
        #expect(RequestCopy.status(usedUp) == "Still looking…")
        #expect(RequestPageAction.actions(for: usedUp).contains(.findAnotherCopy))

        #expect(RequestCopy.status(.resolving) == "Looking…")
        #expect(RequestCopy.findAnotherCopy == "Find another copy")
        #expect(RequestCopy.findAnotherTitle == "Look for another copy?")
        #expect(RequestCopy.findAnotherMessage == "Magpie drops the copy it's getting now and won't pick that one again.")
        #expect(RequestCopy.stuckCopySetting == "Give up on a stuck copy after")
        for text in [RequestCopy.sourceStalled, RequestCopy.findAnotherCopy, RequestCopy.findAnotherTitle,
                     RequestCopy.findAnotherMessage, RequestCopy.askAgainSoon, RequestCopy.findAnotherFailed,
                     RequestCopy.stuckCopySetting, RequestsSettingsView.stuckCopyFooter] {
            for word in ["Lidarr", "Soulseek", "slskd", "blocklist", "Search again", "download", "stalled"] {
                #expect(!text.localizedCaseInsensitiveContains(word), "§9: \(word) in \(text)")
            }
        }
    }

    /// Find another copy is on the page while it's on its way and not yet imported, and only then.
    @Test func findAnotherCopyOnlyWhileLooking() {
        for state in [RequestState.searching, .downloading(progress: 0.3),
                      .waiting(reason: WaitReason(.stillLooking, since: t0), retryAt: t0)] {
            #expect(RequestPageAction.actions(for: Self.request(state)).contains(.findAnotherCopy), "\(state)")
        }
        for state in [RequestState.pending, .resolving, .adding, .importing, .ready, .cancelled, .kept] {
            #expect(!RequestPageAction.actions(for: Self.request(state)).contains(.findAnotherCopy), "\(state)")
        }
        var joined = Self.request(.searching)
        joined.joinedTo = RequestID()
        #expect(!RequestPageAction.actions(for: joined).contains(.findAnotherCopy), "the request it follows searches")
    }

    /// Once per 30 s: held back for 29 s, free again at 30.
    @Test func findAnotherCopyRateLimit() {
        let model = makeModel()
        var r = Self.request(.searching)
        #expect(!model.findAnotherCopyWaits(r, now: t0))
        r.searchAgainAt = t0
        #expect(model.findAnotherCopyWaits(r, now: t0.addingTimeInterval(29)))
        #expect(!model.findAnotherCopyWaits(r, now: t0.addingTimeInterval(30)))
    }

    /// Find another copy without a runner says so calmly; nothing is sent.
    @Test func findAnotherCopyWithoutLidarr() async {
        let model = makeModel()
        #expect(await model.findAnotherCopy(RequestID(), removingCopy: false) == .failed(RequestCopy.findAnotherFailed))
    }

    // MARK: - The setting

    /// Settings › New music "Give up on a stuck copy after": 1, 2, 5, 10 min; 1 min unless changed; kept.
    @Test func stuckCopySettingValues() {
        #expect(StallLimit.allCases.map(\.title) == ["1 min", "2 min", "5 min", "10 min"])
        #expect(StallLimit.allCases.map(\.seconds) == [60, 120, 300, 600])
        let model = makeModel()
        #expect(model.stallLimit == .oneMinute)
        model.setStallLimit(.fiveMinutes)
        #expect(makeModel().stallLimit == .fiveMinutes, "kept across launches")
        defaults.set(42.0, forKey: AppModel.stallLimitKey)
        #expect(makeModel().stallLimit == .oneMinute, "an unknown value reads as the default")
    }

    // MARK: - The car (R20 §7)

    /// A not-yet song already on its way shows its status and a tap says "On its way"; never a second Try.
    @Test func carShowsLiveRequestsAndNeverASecondTry() {
        let model = makeModel()
        let live = Self.request(.downloading(progress: 0.4))
        model.requests = [live]
        let songs = [Self.recording(), Self.recording(otherMBID, title: "Other")]
        let statuses = model.carPlayOnTheirWay(songs)
        #expect(statuses == [0: RequestCopy.status(live, context: model.waitContext)])

        let rows = CarPlayRows.searchItems(LibrarySearchResult(songs: [], albums: []), notYet: songs, offer: .next,
                                           onTheirWay: statuses)
        #expect(rows.count == 2)
        #expect(rows[0].action == .onItsWay)
        #expect(rows[0].detail?.hasPrefix(statuses[0]!) == true)
        #expect(rows[0].detail?.contains("Try") == false)
        #expect(rows[1].action == .tryNext(songs[1]))
        #expect(CPOnItsWay.title == "On its way" && CPOnItsWay.message == "It goes next when it's here.")
    }
}
