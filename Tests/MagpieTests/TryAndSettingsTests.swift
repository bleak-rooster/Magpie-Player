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
private let artistMBID = "64db764c-2251-4f95-aa40-10fc91d509d8"
private let recordingMBID = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!
private let rg = "01a340b4-1d99-4083-ad92-fa2803368bed"

final class MemoryTokenStore: ListenBrainzTokenStoring, @unchecked Sendable {
    private let saved = OSAllocatedUnfairLock<String?>(initialState: nil)
    func save(_ token: String) throws { saved.withLock { $0 = token } }
    func load() -> String? { saved.withLock { $0 } }
    func clear() { saved.withLock { $0 = nil } }
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
        LidarrSetupStore(defaults: defaults).save(LidarrSetup(base: lidarrBase, fastStartProfileId: 4,
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
