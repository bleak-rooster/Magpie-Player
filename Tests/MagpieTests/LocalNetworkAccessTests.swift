import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
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
