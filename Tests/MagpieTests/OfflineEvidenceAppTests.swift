import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let albums = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8)
private let subsonicError = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8)
private let portal = Data("<html><body>Sign in to the café Wi-Fi</body></html>".utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let away = URL(string: "https://music.example.com/navidrome")!

/// Round 28 O1 (owner, 2026-11-15): what counts as no answer (D325). A proxy whose library has stopped, a captive
/// portal, a refused redirect: fail over and probe like a connection error; `requestOnce` never resends. A library
/// that answers in any way is never offline.
@MainActor @Suite(.serialized) final class OfflineEvidenceAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineEvidenceAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "OfflineEvidenceAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    /// What stands between Magpie and the library (nil: nothing, the library answers).
    enum Front: Sendable { case status(Int), bare(Int), portal, redirect, subsonicError, slowPages, subsonic500 }
    let front = OSAllocatedUnfairLock<Front?>(initialState: nil)
    /// Fix round 1 (L4): what the login answers instead, with a JSON body (nil: as `front` says).
    let loginStatus = OSAllocatedUnfairLock<Int?>(initialState: nil)

    init() {
        let front = self.front
        @Sendable func answer(_ normal: Data, page: Bool) -> @Sendable (URLRequest) throws -> MockTransport.Response {
            { _ in
                switch front.withLock({ $0 }) {
                case .status(let code)?: return .init(status: code, body: Data("<html>Bad gateway</html>".utf8))
                case .bare(let code)?: return .init(status: code)
                case .subsonic500? where page: return .init(status: 500, body: subsonicError)
                case .portal?: return .init(status: 200, body: portal, headers: ["Content-Type": "text/html"])
                case .redirect?: return .init(status: 302, headers: ["Location": "http://portal.example/login"])
                case .subsonicError? where page: return .init(status: 200, body: subsonicError)
                case .slowPages? where page: throw URLError(.timedOut)
                default: return .init(status: 200, body: normal)
                }
            }
        }
        transport.inner.stub(pathSuffix: "/rest/ping", handler: answer(ok, page: false))
        let loginStatus = self.loginStatus, login = answer(loginJSON, page: false)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login") { r in
            if let code = loginStatus.withLock({ $0 }) { return .init(status: code, body: Data(#"{"error":"Too many requests"}"#.utf8)) }
            return try login(r)
        }
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", handler: answer(albums, page: true))
        transport.inner.stub(pathSuffix: "/rest/createPlaylist", handler: answer(ok, page: true))
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedIn(_ urls: [URL] = [home]) async throws -> (AppModel, ManualReachabilityClock) {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(nil),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: urls, username: "jordan", password: "pw")
        await model.matchIndexSettled()
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        return (model, clock)
    }

    func page(_ model: AppModel) async throws { _ = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) } }

    func count(_ suffix: String) -> Int { transport.inner.requests.filter { $0.url?.path.hasSuffix(suffix) == true }.count }

    @Test func request_proxy502FailsOverAndProbes() async throws {
        let (model, clock) = try await signedIn()
        front.withLock { $0 = .status(502) }
        let pings = count("/rest/ping")
        await #expect(throws: NavidromeError.unexpectedResponse) { try await self.page(model) }
        #expect(count("/rest/ping") > pings, "a probe, as for a connection error")
        #expect(model.reachability.isSuspect && !model.isOffline)
        #expect(await model.advanceReachability(clock, to: 30))
        #expect(model.isOffline, "a stopped library behind a proxy goes offline at 30 s")
        for code in [502, 503, 504, 407, 511, 520, 525, 530] { #expect(AppModel.isServerPathFailure(NavidromeError.http(status: code)), "\(code)") }
    }

    @Test func request_captivePortalHTMLCountsTowardsOffline() async throws {
        let (model, clock) = try await signedIn()
        front.withLock { $0 = .portal }
        await #expect(throws: NavidromeError.unexpectedResponse) { try await self.page(model) }
        #expect(model.reachability.isSuspect)
        #expect(await model.advanceReachability(clock, to: 30))
        #expect(model.isOffline)
        #expect(!transport.inner.requests.contains { $0.url?.path.hasSuffix("/auth/login") == true && $0.url?.host == "portal.example" })
    }

    /// A redirect `SameOriginRedirects` refuses hands back the 3xx itself, which the client surfaces as
    /// `NavidromeError.http(status: 3xx)`: no answer from the library.
    @Test func request_refusedRedirectCountsAsNoAnswer() async throws {
        let (model, _) = try await signedIn()
        front.withLock { $0 = .redirect }
        await #expect(throws: NavidromeError.http(status: 302)) { try await self.page(model) }
        #expect(model.reachability.isSuspect)
        #expect(AppModel.isServerPathFailure(NavidromeError.http(status: 307)))
        #expect(!AppModel.isServerPathFailure(NavidromeError.http(status: 500)), "a 500 is the library answering")
        #expect(!AppModel.isServerPathFailure(NavidromeError.unexpectedData))
    }

    @Test func requestOnce_neverResendsOnProxyError() async throws {
        let (model, _) = try await signedIn()
        front.withLock { $0 = .status(503) }
        let before = count("/rest/createPlaylist")
        await #expect(throws: NavidromeError.unexpectedResponse) {
            _ = try await model.requestOnce { try await $0.createPlaylist(name: "Road trip", songIds: []) }
        }
        #expect(count("/rest/createPlaylist") == before + 1, "sent once, never again")
        #expect(model.reachability.isSuspect, "but probed, for what comes next")
    }

    @Test func request_successWhileSuspectEndsSuspect() async throws {
        let (model, _) = try await signedIn()
        model.noteUnreachable()
        #expect(model.reachability.isSuspect && model.reachability.hasScheduledWake)
        try await page(model)
        #expect(!model.reachability.isSuspect && model.reachability.machine.state == .online)
        #expect(model.reachability.machine.nextWake == nil, "probes cancelled")
    }

    @Test func slowServerAnsweringPingStaysOnline() async throws {
        let (model, clock) = try await signedIn()
        front.withLock { $0 = .slowPages }
        await #expect(throws: URLError.self) { try await self.page(model) }
        #expect(!model.reachability.isSuspect, "the ping answered: the library is there, only slow")
        #expect(await model.advanceReachability(clock, to: 31))
        #expect(!model.isOffline)
    }

    @Test func secondAddressAnsweringIsNotOffline() async throws {
        let (model, clock) = try await signedIn([home, away])
        transport.setDown(["192.168.1.2"])
        try await page(model)
        #expect(model.session?.activeBase == away && !model.reachability.isSuspect)
        #expect(await model.advanceReachability(clock, to: 31))
        #expect(!model.isOffline)
    }

    @Test func subsonicErrorIsAnAnswer() async throws {
        let (model, clock) = try await signedIn()
        model.noteUnreachable()
        front.withLock { $0 = .subsonicError }
        await #expect(throws: NavidromeError.api(code: 70, message: "not found")) { try await self.page(model) }
        #expect(!model.reachability.isSuspect && model.reachability.machine.state == .online)
        #expect(await model.advanceReachability(clock, to: 31))
        #expect(!model.isOffline)
        #expect(AppModel.isLibraryAnswer(NavidromeError.http(status: 500)) && AppModel.isLibraryAnswer(NavidromeError.badCredentials))
    }

    /// Fix round 1 (security M3): Cloudflare's 530 page, and a portal's 403 page, are not the library; a bare 530 or
    /// 407 isn't either; a 500 carrying a Subsonic body is the library answering.
    @Test func request_cloudflare530AndPortal403AreNoAnswer() async throws {
        for front in [Front.status(530), .status(403), .bare(530), .bare(407)] {
            let (model, _) = try await signedIn()
            self.front.withLock { $0 = front }
            await #expect(throws: (any Error).self) { try await self.page(model) }
            #expect(model.reachability.isSuspect, "\(front)")
            #expect(!model.reachability.authRejected, "\(front): never the sign-in error")
            self.front.withLock { $0 = nil }
            model.signOut()
        }
    }

    @Test func request_500WithSubsonicBodyIsAnAnswer() async throws {
        let (model, clock) = try await signedIn()
        model.noteUnreachable()
        front.withLock { $0 = .subsonic500 }
        await #expect(throws: NavidromeError.http(status: 500)) { try await self.page(model) }
        #expect(!model.reachability.isSuspect)
        #expect(await model.advanceReachability(clock, to: 31))
        #expect(!model.isOffline)
    }

    /// Security M2: a ping that never finishes (a trickling answer) ends at the probe's deadline on the reachability
    /// clock, so the probe always finishes and the schedule goes on.
    @Test func probe_tricklingPingEndsAtItsDeadline() async throws {
        let (model, clock) = try await signedIn()
        transport.setDown(["192.168.1.2"])
        model.noteUnreachable()   // suspect at 0; first check at 5
        transport.setDown([])
        let hold = Hold()
        transport.setHook { r in if r.url?.path == "/rest/ping" { await hold.wait() } }
        clock.set(5)
        #expect(await eventually { model.reachability.probeTask != nil && model.reachability.checking })
        clock.set(5 + AppModel.probeDeadline - 0.1)
        #expect(await eventually(0.3) { model.reachability.probeTask == nil } == false, "still waiting before the deadline")
        clock.set(5 + AppModel.probeDeadline)
        #expect(await eventually { model.reachability.probeTask == nil && !model.reachability.checking })
        #expect(model.reachability.machine.nextProbeAt != nil, "the schedule goes on")
        transport.setHook(nil)
        hold.release()
    }

    /// Security L4: a login answered with 429 (or a 5xx carrying the library's JSON) is the library answering: online,
    /// never offline; and no login is tried again for 60 s after a 429.
    @Test func login429CountsAsAnsweredAndHoldsLogins() async throws {
        let (model, clock) = try await signedIn()
        loginStatus.withLock { $0 = 429 }
        let logins = { self.transport.inner.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count }
        model.noteUnreachable()
        #expect(model.reachability.isSuspect)
        let before = logins()
        await model.checkReachability()   // ping answers; the login is refused for now
        #expect(!model.reachability.machine.isDown && !model.isOffline, "a 429 is an answer")
        #expect(logins() == before + 1)
        model.noteUnreachable()
        await model.checkReachability()
        #expect(logins() == before + 1, "held for 60 s after a 429")
        #expect(!model.reachability.machine.isDown)
        #expect(await model.advanceReachability(clock, to: 61))
        loginStatus.withLock { $0 = nil }
        model.noteUnreachable()
        await model.checkReachability()
        #expect(logins() == before + 2, "tried again after the hold")
        #expect(AppModel.isLoginAnswer(NavidromeError.http(status: 503)) == false, "a bare gateway 503 is no answer")
        #expect(AppModel.isLoginAnswer(NavidromeError.http(status: 500)) && AppModel.isLoginAnswer(NavidromeError.http(status: 429)))
    }

    /// Fix round 2 (security SN5): signing in ends by the login deadline whatever the transport does.
    @Test func signIn_tricklingLoginEndsAtItsDeadline() async throws {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(nil),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        let hold = Hold()
        transport.setHook { r in if r.url?.path.hasSuffix("/auth/login") == true { await hold.wait() } }
        let signing = Task { try await model.signIn(urls: [home], username: "jordan", password: "pw") }
        #expect(await eventually { self.transport.inner.requests.contains { $0.url?.path.hasSuffix("/rest/ping") == true } })
        try await Task.yield()
        clock.set(AppModel.loginDeadline - 0.1)
        #expect(await eventually(0.3) { model.session != nil } == false)
        clock.set(AppModel.loginDeadline + 1)
        await #expect(throws: URLError.self) { try await signing.value }
        #expect(model.session == nil)
        transport.setHook(nil)
        hold.release()
    }

    /// Fix round 2 (security SN6): while logins are held after a 429, a check counts as an answer only if its ping just
    /// answered as the library; otherwise nothing changes.
    @Test func heldLoginNeedsAServerPing() async throws {
        let (model, clock) = try await signedIn()
        model.noteUnreachable()
        model.reachability.loginHeldUntil = clock.now() + 60
        model.reachability.serverPingAt = nil
        let client = try #require(model.session?.client)
        _ = await model.reconnectLogin(client, replacing: client)
        #expect(model.reachability.isSuspect, "no ping proved the library: not an answer")
        model.reachability.serverPingAt = clock.now()
        _ = await model.reconnectLogin(client, replacing: client)
        #expect(!model.reachability.machine.isDown, "the ping just answered as the library: held, but there")
        // The app's probe records a server ping.
        model.reachability.serverPingAt = nil
        #expect(await model.probe(home) == nil && model.reachability.serverPingAt != nil)
    }

    /// Automatically offline, `request` asks nothing (D328): a screen's read fails at once; the machine's checks bring
    /// Magpie back.
    @Test func automaticOfflineRequestFailsAtOnce() async throws {
        let (model, clock) = try await signedIn()
        transport.setDown(["192.168.1.2"])
        model.noteUnreachable()
        #expect(await model.advanceReachability(clock, to: 30))
        #expect(model.isOffline)
        transport.setDown([])
        let sent = transport.inner.requests.count
        await #expect(throws: URLError.self) { try await self.page(model) }
        #expect(transport.inner.requests.count == sent, "nothing asked")
    }
}
