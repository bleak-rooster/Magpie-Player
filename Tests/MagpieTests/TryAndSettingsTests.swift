import DesignSystem
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
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

final class MemoryTokenStore: ListenBrainzTokenStoring, @unchecked Sendable {
    private let saved = OSAllocatedUnfairLock<String?>(initialState: nil)
    func save(_ token: String) throws { saved.withLock { $0 = token } }
    func load() -> String? { saved.withLock { $0 } }
    func clear() { saved.withLock { $0 = nil } }
}

/// A Lidarr store that reads as empty until "unlocked", like the Keychain before first unlock.
final class LockableLidarrStore: LidarrConnectionStoring, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (locked: true, saved: LidarrConnection?.none))
    func unlock(with saved: LidarrConnection?) { state.withLock { $0 = (false, saved) } }
    func save(_ connection: LidarrConnection) throws { state.withLock { $0.saved = connection } }
    func load() -> LidarrConnection? { state.withLock { $0.locked ? nil : $0.saved } }
    func clear() { state.withLock { $0.saved = nil } }
}

final class LockableTokenStore: ListenBrainzTokenStoring, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (locked: true, saved: String?.none))
    func unlock(with saved: String?) { state.withLock { $0 = (false, saved) } }
    func save(_ token: String) throws { state.withLock { $0.saved = token } }
    func load() -> String? { state.withLock { $0.locked ? nil : $0.saved } }
    func clear() { state.withLock { $0.saved = nil } }
}

@MainActor
@Suite(.serialized) struct TryAndSettingsTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    func stubRoots(_ paths: [String]) {
        let rows = paths.enumerated().map { #"{"id":\#($0.offset + 1),"path":"\#($0.element)"}"# }.joined(separator: ",")
        transport.inner.stub(pathSuffix: "/api/v1/rootfolder", body: Data("[\(rows)]".utf8))
    }

    func saveProvisioned() {
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1))
    }

    @Test func tryAvailabilityFollowsSetup() async throws {
        stubRoots(["/music/library", "/music/samples"])
        saveProvisioned()
        let model = makeModel()
        #expect(model.tryAvailability == .noLidarr)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.tryAvailability == .changesOff)
        #expect(model.changesAllowed == false, "G1: off by default")

        await model.setChangesAllowed(true)
        #expect(model.tryAvailability == .noRoot, "two roots: the owner picks, Magpie never guesses")
        model.chooseRoot("/music/library")
        #expect(model.tryAvailability == .available(.patient), "no Tubifarry: Patient")
        #expect(makeModel().changesAllowed, "the switch is persisted")
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    @Test func notProvisionedAndSingleRoot() async throws {
        stubRoots(["/music"])
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(model.tryAvailability == .notSetUp)
        #expect(model.lidarrSetup?.rootFolderPath == "/music", "exactly one root: used")
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    /// The app wiring end to end on a scripted Lidarr: Try monitors one album and searches, Requests
    /// shows it, Cancel unmonitors.
    @Test func tryThenCancelThroughTheApp() async throws {
        stubRoots(["/music/library"])
        saveProvisioned()
        let t = transport.inner
        t.stub(pathSuffix: "/ws/2/recording/\(recordingMBID.rawValue)", body: Data(#"""
        {"id":"\#(recordingMBID.rawValue)","title":"Harbour Lights","artist-credit":[{"artist":{"id":"\#(artistMBID)"}}],
         "releases":[{"id":"545b96d6-c867-3053-9548-3e8635390e38","title":"The Cat Is Out","status":"Official",
           "release-group":{"id":"\#(rg)","primary-type":"Album","secondary-types":[]}}]}
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"[{"id":7,"artistName":"Judie Tzuke","foreignArtistId":"\#(artistMBID)","rootFolderPath":"/music/library"}]"#.utf8))
        let monitored = OSAllocatedUnfairLock(initialState: false)
        t.stub(pathSuffix: "/api/v1/album") { _ in
            let on = monitored.withLock { $0 }
            return .init(status: 200, body: Data(#"[{"id":31,"title":"The Cat Is Out","artistId":7,"foreignAlbumId":"\#(rg)","monitored":\#(on)}]"#.utf8))
        }
        t.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor") { req in
            let on = String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains(#""monitored":true"#)
            monitored.withLock { $0 = on }
            return .init(status: 200, body: Data("[]".utf8))
        }
        t.stub(method: "POST", pathSuffix: "/api/v1/command", body: Data(#"{"id":5,"name":"AlbumSearch","status":"queued"}"#.utf8))

        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(model.tryAvailability == .available(.patient))

        let id = try await model.tryRecording(ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights",
                                                                artist: "Judie Tzuke", source: .listenBrainz))
        for _ in 0..<200 where model.magpieRequest(id)?.state != .searching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.magpieRequest(id)?.state == .searching)
        #expect(RequestCopy.group(try #require(model.magpieRequest(id)).state) == .inProgress)

        await model.cancelRequest(id)
        for _ in 0..<200 where model.magpieRequest(id)?.state != .cancelled { try await Task.sleep(for: .milliseconds(10)) }
        let writes = t.requests.filter { $0.httpMethod != "GET" && $0.url?.port == 8686 }.map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(writes == ["PUT /api/v1/album/monitor", "POST /api/v1/command", "PUT /api/v1/album/monitor"])
        let log = await model.changeLog()
        #expect(log.count == 3 && log.first?.method == "PUT", "newest first")
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    /// CRITICAL 1: switching to another Lidarr shows none of the first one's requests and writes nothing for them.
    @Test func switchingLidarrScopesRequests() async throws {
        stubRoots(["/music/library"])
        saveProvisioned()
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, scope: lidarrScope, fastStartProfileId: 4,
                                                              findsMetadataProfileId: 3, magpieTagId: 1,
                                                              rootFolderPath: "/music/library"))
        let t = transport.inner
        t.stub(pathSuffix: "/ws/2/recording/\(recordingMBID.rawValue)", body: Data(#"""
        {"id":"\#(recordingMBID.rawValue)","title":"Harbour Lights","artist-credit":[{"artist":{"id":"\#(artistMBID)"}}],
         "releases":[{"id":"545b96d6-c867-3053-9548-3e8635390e38","title":"The Cat Is Out","status":"Official",
           "release-group":{"id":"\#(rg)","primary-type":"Album","secondary-types":[]}}]}
        """#.utf8))
        t.stub(pathSuffix: "/api/v1/artist", body: Data(#"[{"id":7,"artistName":"Judie Tzuke","foreignArtistId":"\#(artistMBID)"}]"#.utf8))
        t.stub(pathSuffix: "/api/v1/album", body: Data(#"[{"id":31,"title":"The Cat Is Out","artistId":7,"foreignAlbumId":"\#(rg)","monitored":true}]"#.utf8))
        t.stub(method: "POST", pathSuffix: "/api/v1/command", body: Data(#"{"id":5}"#.utf8))

        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        let id = try await model.tryRecording(ExternalRecording(recordingMBID: recordingMBID, title: "Harbour Lights",
                                                                artist: "Judie Tzuke", source: .listenBrainz))
        for _ in 0..<200 where model.magpieRequest(id)?.state != .searching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.magpieRequest(id) != nil)

        let other = URL(string: "http://192.168.1.3:8686")!
        _ = try await model.connectLidarr(base: other, apiKey: "other-key")
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.requests.isEmpty, "another Lidarr's requests are not shown")
        #expect(model.ledger?.instance != nil)
        let ledgerEntries = try await model.ledger?.entries ?? []
        #expect(ledgerEntries.isEmpty)
        await model.cancelRequest(id)
        #expect(!t.requests.contains { $0.url?.host == "192.168.1.3" && $0.httpMethod != "GET" })

        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        for _ in 0..<200 where model.magpieRequest(id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.magpieRequest(id) != nil, "back on the first Lidarr, its request is there again")
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    @Test func countPlaysOffSendsNoScrobbles() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/scrobble", body: ok)
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [home]),
                                     credentials: NavidromeCredentials(username: "a", password: "b"), transport: t)
        let box = ClientBox()
        box.set(client)
        let counting = PlayCounting(on: false)
        let scrobbler = NavidromeScrobbler(box: box, counting: counting)
        try await scrobbler.scrobble(songId: "s1", submission: true, at: nil)
        #expect(!t.requests.contains { $0.url?.path.hasSuffix("/rest/scrobble") == true })
        counting.set(true)
        try await scrobbler.scrobble(songId: "s1", submission: true, at: nil)
        #expect(t.requests.contains { $0.url?.path.hasSuffix("/rest/scrobble") == true })

        let model = makeModel()
        #expect(model.countPlays, "G8: on by default")
        model.setCountPlays(false)
        #expect(makeModel().countPlays == false)
    }

    /// Final review I1: Count plays has one switch. Launched with it off, turning it on counts the next play
    /// without a relaunch.
    @Test func countPlaysTurnedOnCountsTheNextPlay() async throws {
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
        defaults.set(false, forKey: AppModel.countPlaysKey)
        let model = makeModel()
        #expect(!model.countPlays)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        model.setCountPlays(true)
        model.player.play([Song(id: "s1", title: "T", artist: "A", album: "B", duration: 200, libraryId: 1)], startAt: 0)
        let entry = try #require(model.player.queue.current?.id)
        model.player.handle(.time(entry, 150, duration: 200))
        await model.player.waitForPendingScrobbles()
        let scrobbles = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/scrobble") == true }
        #expect(scrobbles.contains { $0.url?.query?.contains("submission=true") == true }, "the play is counted")
        model.signOut()
    }

    /// Final review I3: launched before first unlock (CarPlay cold start, prewarming), the Lidarr connection,
    /// its write switch and setup, and the ListenBrainz token all read as absent. When protected data becomes
    /// available they are read again with the session, so Try and Requests work without a relaunch.
    @Test func lockedLaunchReloadsLidarrOnUnlock() async throws {
        let sessionStore = LockableStore()
        let lidarrStore = LockableLidarrStore()
        let tokens = LockableTokenStore()
        saveProvisioned()
        UserDefaults(suiteName: gateSuite)!.set(true, forKey: LidarrWriteGate.enabledKey(scope: lidarrScope))
        let model = AppModel(store: sessionStore, lidarrStore: lidarrStore, tokenStore: tokens, matchIndexDirectory: nil,
                             dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.resumeSavedSession()
        #expect(model.isWaitingForUnlock)
        #expect(model.lidarr == nil && !model.changesAllowed && model.lidarrSetup == nil && !model.hasListenBrainzToken)

        sessionStore.unlock(with: SavedSession(endpoint: ServerEndpoint(bases: [home]),
                                               credentials: NavidromeCredentials(username: "admin", password: "pw")))
        lidarrStore.unlock(with: LidarrConnection(base: lidarrBase, apiKey: "key"))
        tokens.unlock(with: "lb-token")
        model.protectedDataBecameAvailable()
        #expect(model.session != nil)
        #expect(model.lidarr == LidarrConnection(base: lidarrBase, apiKey: "key"))
        #expect(model.changesAllowed, "the persisted write switch is read again")
        #expect(model.lidarrSetup?.magpieTagId == 1)
        #expect(model.hasListenBrainzToken)
        #expect(model.runner != nil, "saved requests are polled again")
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    /// I3: a session restored while the Lidarr item still couldn't be read picks Lidarr up on the next foreground.
    @Test func foregroundReloadsMissingLidarr() async throws {
        let sessionStore = LockableStore()
        sessionStore.unlock(with: SavedSession(endpoint: ServerEndpoint(bases: [home]),
                                               credentials: NavidromeCredentials(username: "admin", password: "pw")))
        let lidarrStore = LockableLidarrStore()
        let model = AppModel(store: sessionStore, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, gateDefaultsSuite: gateSuite,
                             transport: transport, probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.resumeSavedSession()
        #expect(model.session != nil && model.lidarr == nil)
        model.isForeground = false
        lidarrStore.unlock(with: LidarrConnection(base: lidarrBase, apiKey: "key"))
        model.isForeground = true
        #expect(model.lidarr?.base == lidarrBase)
        #expect(model.runner != nil)
        model.signOut()
    }

    /// I3 / ledger 1.5: only "locked" (`errSecInteractionNotAllowed`) waits for unlock. Any other Keychain error
    /// (e.g. -34018, missing entitlement under ad-hoc signing) would never clear, so it shows Connect instead.
    @Test func onlyALockedKeychainWaitsForUnlock() {
        if case .unavailable = SessionStore.loadFailure(KeychainError(status: errSecInteractionNotAllowed)) {} else {
            Issue.record("locked must wait for unlock")
        }
        for status: OSStatus in [-34018, errSecAuthFailed, errSecDecode] {
            if case .none = SessionStore.loadFailure(KeychainError(status: status)) {} else {
                Issue.record("\(status) must not wait for unlock")
            }
        }
    }

    /// I4: the wait context follows Try's availability first, then a rejected key from the last audit.
    @Test func waitContextFollowsSettingsThenKey() async throws {
        stubRoots(["/music/library"])
        saveProvisioned()
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.waitContext == .needsSettings(TryAvailability.changesOff.message!))
        await model.setChangesAllowed(true)
        model.chooseRoot("/music/library")
        #expect(model.waitContext == .unknown)
        model.lidarrStatus = LidarrAudit(keyRejected: true)   // what the audit records on a 401
        #expect(model.waitContext == .keyRejected)
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
    }

    @Test func listenBrainzTokenIsOptional() throws {
        let model = makeModel()
        #expect(!model.hasListenBrainzToken)
        try model.setListenBrainzToken("  abc  ")
        #expect(model.hasListenBrainzToken && model.tokenStore.load() == "abc")
        try model.setListenBrainzToken(nil)
        #expect(!model.hasListenBrainzToken)
    }
}

@Suite struct RequestCopyTests {
    /// Final fix 2 B-M5: a ready find shows as a New find in Search and Made for you, not as a library song; a
    /// ready library request (and a kept find) as library.
    @Test func readyFindRowIsANewFind() {
        let mbid = MBID("00000000-0000-0000-0000-000000000100")!
        let recording = ExternalRecording(recordingMBID: mbid, title: "S", artist: "A", source: .listenBrainz)
        var r = MagpieRequest(recording: recording, tier: .standard, createdAt: .now)
        r.state = .ready
        r.plan = Plan(recordingMBID: mbid, releaseGroupMBID: MBID("00000000-0000-0000-0000-000000000010")!,
                      artistMBID: MBID("00000000-0000-0000-0000-000000000001")!, lidarrArtistId: nil, mode: .finds)
        #expect(RequestCopy.rowState(for: recording, in: [r]) == .newFind)
        r.plan?.mode = .fallback
        #expect(RequestCopy.rowState(for: recording, in: [r]) == .library)
        r.plan?.mode = .finds
        r.state = .kept
        #expect(RequestCopy.rowState(for: recording, in: [r]) == .library)
    }

    /// Final review I4: a request waiting on `.serviceUnavailable` says why, from what the app knows, instead of
    /// blaming "your server" (the music server is playing).
    @Test func waitingSaysWhyWithoutBlamingTheMusicServer() {
        let unavailable = RequestState.waiting(reason: WaitReason(.serviceUnavailable, since: .now), retryAt: .now)
        let plain = RequestCopy.status(unavailable)
        #expect(plain == RequestCopy.cantBringHome)
        #expect(!plain.contains("server"))
        #expect(RequestCopy.status(unavailable, context: .needsSettings(TryAvailability.changesOff.message!))
                == TryAvailability.changesOff.message!, "changes off: say how to turn them on")
        #expect(RequestCopy.status(unavailable, context: .needsSettings(TryAvailability.notSetUp.message!))
                == TryAvailability.notSetUp.message!)
        #expect(RequestCopy.status(unavailable, context: .keyRejected) == RequestCopy.keyRejected)
        for text in [RequestCopy.cantBringHome, RequestCopy.keyRejected] {
            for name in ["Lidarr", "Navidrome", "MusicBrainz", "ListenBrainz"] { #expect(!text.contains(name)) }
        }
        // The context only speaks for serviceUnavailable waits.
        let looking = RequestState.waiting(reason: WaitReason(.stillLooking, since: .now), retryAt: .now)
        #expect(RequestCopy.status(looking, context: .keyRejected) == RequestCopy.status(looking))
        #expect(RequestCopy.status(.searching, context: .keyRejected) == "Looking for the best copy")
    }


    @Test func groupsAndSteps() {
        let wait = RequestState.waiting(reason: WaitReason(.stillLooking, since: .now), retryAt: .now)
        #expect(RequestCopy.group(.searching) == .inProgress)
        #expect(RequestCopy.group(.ready) == .ready)
        #expect(RequestCopy.group(wait) == .attention)
        #expect(RequestCopy.group(.failed(reason: .notFoundYet)) == .attention)
        #expect(RequestCopy.group(.cancelled) == nil)
        #expect(RequestCopy.stage(.searching) == .looking)
        #expect(RequestCopy.stage(.downloading(progress: 0)) == .spotted)
        #expect(RequestCopy.stage(.downloading(progress: 0.4)) == .bringingItHome)
        #expect(RequestCopy.stage(.importing) == .bringingItHome)
        #expect(RequestCopy.stage(.ready) == .ready)
    }

    @Test func honestWordsAndNoServiceNames() {
        let all: [RequestState] = [
            .pending, .resolving, .adding, .searching, .downloading(progress: 0), .downloading(progress: 0.62), .importing,
            .ready, .kept, .dismissed, .cancelled,
            .waiting(reason: WaitReason(.stillLooking, since: .now), retryAt: .now),
            .waiting(reason: WaitReason(.serviceUnavailable, since: .now), retryAt: .now),
            .waiting(reason: WaitReason(.downloadFailed, since: .now), retryAt: .now),
        ] + FailReason.allCases.map { .failed(reason: $0) }
        for s in all {
            let text = RequestCopy.status(s) + RequestCopy.phrase(s, tier: .standard)
            #expect(!text.isEmpty)
            for name in ["Lidarr", "Navidrome", "MusicBrainz", "ListenBrainz", "Tubifarry"] {
                #expect(!text.contains(name), "\(s): \(text)")
            }
        }
        #expect(RequestCopy.status(.downloading(progress: 0.62)) == "Bringing it home · 62%")
        // Final fix 2 B-M11: the owner's own stop, without naming the service (§5).
        #expect(RequestCopy.status(.failed(reason: .stoppedInLidarr)) == "Stopped on your server")
        var stuck = MagpieRequest(recording: ExternalRecording(title: "t", artist: "a", source: .listenBrainz),
                                  tier: .standard, createdAt: .now)
        stuck.state = .importing
        #expect(RequestCopy.group(stuck) == .inProgress)
        stuck.notListedAt = .now
        #expect(RequestCopy.group(stuck) == .attention)
        #expect(RequestCopy.status(stuck) == "Not showing up in your library yet")
        #expect(RequestCopy.phrase(.searching, tier: .patient) == "can take a few hours")
        #expect(RequestCopy.tierLine(.standard) == "Standard · usually a few minutes")
        #expect(RequestCopy.canCancel(.searching) && !RequestCopy.canCancel(.ready) && !RequestCopy.canCancel(.cancelled))
        #expect(TryCopy.fallbackNote == "Finds aren't set up, so this goes straight into your library.")
        #expect(TryCopy.message(for: RequestRunner.TryError.tooMany) == TryCopy.tooMany)
    }

    @Test func provisioningConflictIsExplained() {
        #expect(SettingsView.provisionError(ProvisionError.conflict("Magpie Fast Start")).contains("Magpie won't change it"))
        #expect(SettingsView.provisionError(WriteGateError.disabled).contains("Allow Magpie to change Lidarr"))
    }
}
