import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Testing
@testable import Magpie

// T3 (spec §8): the Local Network permission is asked for at first launch (so Magpie appears in Settings › Privacy &
// Security › Local Network even when its first server address isn't on the LAN), denial is detected and explained,
// and the owner gets a button to ask again and a way to Settings. The system prompt itself is never met here:
// a fake prober stands in for `NWBrowser`/`NWConnection`.

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let lan = URL(string: "http://192.168.1.2:4533")!

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "magpie-tests-ln-\(UUID())")! }

@MainActor final class FakeProber: LocalNetworkProbing {
    var answer: LocalNetworkState = .granted
    var denied = false
    private(set) var requestCalls = 0
    private(set) var deniedChecks: [String] = []
    private(set) var requestsSeenAtCall: [Int] = []
    var onRequest: () -> Int = { 0 }
    func requestAccess() async -> LocalNetworkState { requestCalls += 1; requestsSeenAtCall.append(onRequest()); return answer }
    func isDenied(host: String, port: Int) async -> Bool { deniedChecks.append("\(host):\(port)"); return denied }
}

@MainActor @Suite(.serialized) struct LocalNetworkAccessTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = freshDefaults()

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
    }

    func makeModel(prober: any LocalNetworkProbing) -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                 localNetworkProber: prober)
    }

    @Test(arguments: [("http://192.168.1.20:4533", true), ("http://10.0.0.5", true), ("http://169.254.1.1", true),
                      ("http://nas:4533", true), ("http://nas.local:4533", true), ("http://[fd00::1]:4533", true),
                      ("http://[fe80::1]:4533", true), ("http://127.0.0.1:4533", false), ("http://localhost:4533", false),
                      ("http://100.64.10.20:4533", false), ("http://nas.tail1.ts.net:4533", false), ("https://music.example.com", false)])
    func needsPermission(_ text: String, _ expected: Bool) {
        #expect(ServerAddress.needsLocalNetworkPermission(URL(string: text)!) == expected)
    }

    @Test func firstLaunchAsksExactlyOnce() async {
        let d = freshDefaults(), p = FakeProber()
        let a = LocalNetworkAccess(prober: p, defaults: d)
        await a.requestAtFirstLaunch()
        await a.requestAtFirstLaunch()
        await LocalNetworkAccess(prober: p, defaults: d).requestAtFirstLaunch()   // relaunch
        #expect(p.requestCalls == 1)
        #expect(a.state == .granted && d.string(forKey: LocalNetworkAccess.stateKey) == "granted")
    }

    @Test func launchingTheAppTriggersTheRequestOnce() async throws {
        let p = FakeProber()
        let model = makeModel(prober: p)
        await model.localNetwork.requestAtFirstLaunch()   // what RootView's .task runs
        #expect(p.requestCalls == 1)
        await model.localNetwork.requestAtFirstLaunch()
        #expect(p.requestCalls == 1)
    }

    @Test func buttonAlwaysAsks() async {
        let p = FakeProber(); let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        await a.requestAtFirstLaunch(); _ = await a.request(); _ = await a.request()
        #expect(p.requestCalls == 3)
    }

    @Test func notNeededSkipsProber() async {
        let p = FakeProber(); let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [URL(string: "https://music.example.com")!]) == .notNeeded)
        #expect(p.requestCalls == 0 && p.deniedChecks.isEmpty)
    }

    @Test func grantedPersistsAndIsNotReasked() async {
        let d = freshDefaults(), p = FakeProber()
        #expect(await LocalNetworkAccess(prober: p, defaults: d).ensureAccess(for: [lan]) == .granted)
        let again = LocalNetworkAccess(prober: p, defaults: d)
        #expect(again.state == .granted)
        #expect(await again.ensureAccess(for: [lan]) == .granted)
        #expect(p.requestCalls == 1 && p.deniedChecks.isEmpty)
    }

    @Test func deniedUsesTheQuickCheckNotTheSlowAsk() async {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [lan]) == .denied)
        #expect(await a.ensureAccess(for: [lan]) == .denied)
        #expect(p.requestCalls == 1, "never re-asks while denied")
        #expect(p.deniedChecks == ["192.168.1.2:4533"])
        p.denied = false   // turned on in Settings
        #expect(await a.ensureAccess(for: [lan]) == .granted && p.requestCalls == 1)
    }

    @Test func localSuccessMeansGranted() {
        let d = freshDefaults(); let a = LocalNetworkAccess(prober: FakeProber(), defaults: d)
        #expect(a.state == .unknown)
        a.noteLocalSuccess()
        #expect(a.state == .granted && d.string(forKey: LocalNetworkAccess.stateKey) == "granted")
    }

    @Test func signInAsksBeforeTheFirstRequest() async throws {
        let p = FakeProber(); p.onRequest = { transport.inner.requests.count }
        try await makeModel(prober: p).signIn(urls: [lan], username: "admin", password: "pw")
        #expect(p.requestCalls == 1 && p.requestsSeenAtCall == [0])
    }

    @Test func httpsPublicDoesNotAsk() async throws {
        let p = FakeProber()
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)   // also answers music.example.com
        try await makeModel(prober: p).signIn(urls: [URL(string: "https://music.example.com")!], username: "admin", password: "pw")
        #expect(p.requestCalls == 0 && p.deniedChecks.isEmpty)
    }

    @Test func deniedSignInExplainsAndOffersSettings() async throws {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        transport.setDown(["192.168.1.2"], with: .notConnectedToInternet)
        do {
            try await makeModel(prober: p).signIn(urls: [lan], username: "admin", password: "pw")
            Issue.record("signed in")
        } catch {
            #expect(ConnectErrorCopy.message(for: error) == ConnectDiagnosis.localNetworkDenied.message)
            #expect(ConnectErrorCopy.offersOpenSettings(for: error))
        }
    }

    /// A browse on a LAN address that answers means the setting is on: Settings and the car stop offering to ask.
    @Test func aLocalRequestThatWorksMeansGranted() async throws {
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(
            #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        let p = FakeProber(); p.answer = .unknown
        let model = makeModel(prober: p)
        try await model.signIn(urls: [lan], username: "admin", password: "pw")
        #expect(model.localNetwork.state == .unknown)
        _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
        #expect(model.localNetwork.state == .granted)
        model.signOut()
    }

    /// Fix M4 (risk a): a remembered or wrong "denied" never stops a sign-in to a server that answers.
    @Test func deniedStillSignsInWhenTheServerAnswers() async throws {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        let model = makeModel(prober: p)
        try await model.signIn(urls: [lan], username: "admin", password: "pw")
        #expect(model.session?.activeBase == lan)
        model.signOut()
    }

    /// Fix M1: a single-label name may go over Tailscale, so neither a working request nor a passing quick check on it
    /// proves the setting is on; an IP literal or a `.local` name does.
    @Test func onlyLiteralsAndDotLocalProveAccess() async throws {
        #expect(ServerAddress.provesLocalNetworkAccess(lan))
        #expect(ServerAddress.provesLocalNetworkAccess(URL(string: "http://nas.local:4533")!))
        #expect(ServerAddress.provesLocalNetworkAccess(URL(string: "http://[fd00::1]:4533")!))
        #expect(!ServerAddress.provesLocalNetworkAccess(URL(string: "http://homeserver:4533")!))
        #expect(!ServerAddress.provesLocalNetworkAccess(URL(string: "http://100.64.10.20:4533")!))

        let homebox = URL(string: "http://homeserver:4533")!
        let p = FakeProber(); p.answer = .denied; p.denied = true
        let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        #expect(await a.ensureAccess(for: [homebox]) == .denied)
        p.denied = false
        #expect(await a.ensureAccess(for: [homebox]) == .denied, "a single-label name proves nothing")
        #expect(await a.ensureAccess(for: [homebox, lan]) == .granted, "the LAN literal is the one checked")

        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: Data(
            #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        let q = FakeProber(); q.answer = .unknown
        let model = makeModel(prober: q)
        try await model.signIn(urls: [homebox], username: "admin", password: "pw")
        _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }
        #expect(model.localNetwork.state == .unknown, "a working request to homeserver may have gone over Tailscale")
        model.signOut()
    }

    /// Fix I1: the ask's decision. Granted only when the browse finds Magpie's own service; denied only when
    /// PolicyDenied still stands at the deadline; a browse that is merely ready proves nothing.
    @Test(arguments: [
        ([LocalNetworkBrowseEvent.browserReady, .foundOwnService], LocalNetworkState.granted),
        ([.browserReady, .browserWaitingPolicyDenied], .denied),
        ([.browserReady], .unknown),
        ([.browserWaitingPolicyDenied, .browserReady], .unknown),
        ([.browserWaitingPolicyDenied, .foundOwnService], .granted),
        ([.browserReady, .browserFailed], .unknown),
        ([.listenerFailed], .unknown),
    ])
    func browseDecision(_ events: [LocalNetworkBrowseEvent], _ expected: LocalNetworkState) async {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let answer = await NWBrowserLocalNetworkProber.decide(timeout: 0.2) { emit in
            for event in events { emit(event) }   // then nothing until the timeout
            return { stopped.withLock { $0 = true } }
        }
        #expect(answer == expected)
        #expect(stopped.withLock { $0 }, "listener and browser are always cancelled")
    }

    /// Ready comes first and fast whatever the answer: it must never be taken for granted (fix I1).
    @Test func readyAloneIsNotGranted() {
        var d = LocalNetworkBrowseDecision()
        #expect(d.handle(.browserReady) == nil, "keeps waiting")
        #expect(d.handle(.timeout) == .unknown)
    }

    /// Fix round 2 (1): once decided, the ask ignores later events, so no late timeout is logged or answered.
    @Test func decidedIgnoresTheLateTimeout() async {
        var d = LocalNetworkBrowseDecision()
        #expect(d.handle(.foundOwnService) == .granted && d.isDecided)
        #expect(d.handle(.timeout) == nil, "the timeout after a decision is ignored")
        #expect(d.handle(.browserFailed) == nil)
        var denied = LocalNetworkBrowseDecision()
        _ = denied.handle(.browserWaitingPolicyDenied)
        #expect(!denied.isDecided)
        #expect(denied.handle(.timeout) == .denied && denied.isDecided)

        // Through `decide`: found, then the stream keeps emitting (a timeout among them); still granted, stop once.
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let answer = await NWBrowserLocalNetworkProber.decide(timeout: 0.1) { emit in
            emit(.foundOwnService); emit(.timeout); emit(.browserFailed)
            return { stops.withLock { $0 += 1 } }
        }
        #expect(answer == .granted && stops.withLock { $0 } == 1)
    }

    /// Fix round 2 (2): the car blames Local Network only for an address that needs it.
    @Test func carBlamesLocalNetworkOnlyForAHomeAddress() async throws {
        let p = FakeProber(); p.answer = .denied; p.denied = true
        let away = URL(string: "https://music.example.com")!
        let model = makeModel(prober: p)
        _ = await model.localNetwork.request()
        #expect(model.localNetwork.state == .denied)
        try await model.signIn(urls: [away], username: "admin", password: "pw")
        #expect(model.carPlayLocalNetwork == .fine, "a public address out of reach is just out of reach")
        model.signOut()
        try await model.signIn(urls: [lan], username: "admin", password: "pw")
        #expect(model.carPlayLocalNetwork == .denied)
        model.signOut()

        let fresh = LocalNetworkAccessTests()
        let unknown = FakeProber(); unknown.answer = .unknown
        let other = fresh.makeModel(prober: unknown)
        try await other.signIn(urls: [lan], username: "admin", password: "pw")
        #expect(other.carPlayLocalNetwork == .pending)
        other.signOut()
        #expect(other.carPlayLocalNetwork == .fine, "signed out: nothing to blame")
    }

    /// Fix round 2 (3): becoming active while denied re-runs the silent browse once; a granted answer clears the
    /// stale denial, anything else leaves it. Never asks when not denied, never twice at once.
    @Test func activationRechecksAStaleDenial() async {
        let p = FakeProber(); p.answer = .denied
        let d = freshDefaults()
        let a = LocalNetworkAccess(prober: p, defaults: d)
        await a.recheckIfDenied()
        #expect(p.requestCalls == 0, "unknown: the first-launch ask, not the re-check, asks")
        _ = await a.request()
        #expect(a.state == .denied && p.requestCalls == 1)
        p.answer = .unknown
        await a.recheckIfDenied()
        #expect(a.state == .denied && p.requestCalls == 2, "an undecided browse keeps the denial")
        p.answer = .granted   // turned on in Settings
        async let first: Void = a.recheckIfDenied()
        async let second: Void = a.recheckIfDenied()
        _ = await (first, second)
        #expect(a.state == .granted && d.string(forKey: LocalNetworkAccess.stateKey) == "granted")
        #expect(p.requestCalls == 3, "one browse per activation, never two at once")
        await a.recheckIfDenied()
        #expect(p.requestCalls == 3, "granted: nothing to re-check")
    }

    /// The hosted-test fallback never asks the system: nothing to grant, nothing denied.
    @Test func notNeededProberNeverAsks() async {
        let p = NotNeededProber()
        #expect(await p.requestAccess() == .notNeeded)
        #expect(await !p.isDenied(host: "192.168.1.2", port: 4533))
        let a = LocalNetworkAccess(prober: p, defaults: freshDefaults())
        await a.requestAtFirstLaunch()
        #expect(a.state == .unknown, "notNeeded is never persisted")
    }

    /// Parked from T2: a saved Lidarr waiting for consent can't take a Try, so Try says so instead of failing later.
    @Test func tryWaitsForTheLidarrAddressConsent() throws {
        let lidarrStore = MemoryLidarrStore()
        try lidarrStore.save(LidarrConnection(base: URL(string: "http://lidarr.example.com:8686")!, apiKey: "key"))
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             localNetworkProber: FakeProber())
        #expect(model.lidarrAwaitingConsent)
        #expect(model.tryAvailability == .addressNotAllowed)
        #expect(TryAvailability.addressNotAllowed.message
                == "Bringing songs home is waiting for your OK on an unencrypted address. Choose \u{201C}Allow This Address\u{201D} in Settings.")
        model.allowLidarrAddress()
        #expect(model.tryAvailability != .addressNotAllowed)
    }
}
