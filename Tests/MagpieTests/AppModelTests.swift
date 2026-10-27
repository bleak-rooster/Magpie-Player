import CarPlayUI
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
import UIKit
@testable import Magpie

/// Routes to a MockTransport, except hosts marked down, which fail like an unplugged server.
final class HostSwitchTransport: HTTPTransport {
    let inner = MockTransport()
    private let down = OSAllocatedUnfairLock(initialState: Set<String>())
    private let failure = OSAllocatedUnfairLock(initialState: URLError.Code.cannotConnectToHost)

    func setDown(_ hosts: Set<String>, with code: URLError.Code = .cannotConnectToHost) {
        down.withLock { $0 = hosts }
        failure.withLock { $0 = code }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let host = request.url?.host, down.withLock({ $0.contains(host) }) {
            throw URLError(failure.withLock { $0 }, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any])
        }
        return try await inner.send(request)
    }
}

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let albumListJSON = Data(#"""
{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"al1","name":"Glasshouse","artist":"Juniper","songCount":1,"duration":200}]}}}
"""#.utf8)

private let home = URL(string: "http://192.168.1.2:4533")!
private let away = URL(string: "https://music.example.com/navidrome")!

@MainActor
@Suite(.serialized) struct AppModelTests {
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "AppModelTests.\(UUID().uuidString)")!

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2", body: albumListJSON)
        transport.inner.stub(pathSuffix: "/rest/star", body: ok)
        transport.inner.stub(pathSuffix: "/rest/scrobble", body: ok)
    }

    @Test func asksForExtensionsOncePerSession() async throws {
        transport.inner.stub(pathSuffix: "/rest/getOpenSubsonicExtensions", body: Data(
            #"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":[{"name":"songLyrics","versions":[1]}]}}"#.utf8))
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        #expect(try await model.serverAdvertises("songLyrics"))
        #expect(try await !model.serverAdvertises("formPost"))
        let asked = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/getOpenSubsonicExtensions") == true }
        #expect(asked.count == 1)
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport, engine: engine,
                 defaults: defaults, systemNowPlaying: false)
    }

    @Test func signInSavesToKeychainAndSignOutClears() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        #expect(model.session?.activeBase == home)
        #expect(model.session?.isAdmin == true)
        let saved = try #require(store.load().saved)
        #expect(saved.endpoint.bases == [home, away])
        #expect(saved.credentials.username == "admin")

        model.play([Song(id: "s1", title: "T", artist: "A", album: "B", duration: 100)], startAt: 0)
        model.signOut()
        #expect(model.session == nil)
        #expect(store.load().saved == nil)
        #expect(model.player.queue.current == nil)
    }

    @Test func restoreResumesSavedSession() async throws {
        try store.save(endpoint: ServerEndpoint(bases: [home]),
                       credentials: NavidromeCredentials(username: "admin", password: "pw"))
        let model = makeModel()
        model.resumeSavedSession()
        #expect(model.session?.username == "admin")
        #expect(await model.reconnect(rebuildAlways: true))
        #expect(model.session?.isAdmin == true)
        store.clear()
    }

    /// Final fix 2 C-I1 (G0): hosted tests launch the real app, whose `AppModel.shared` would resume the
    /// simulator's saved session (maybe a real server) and rebuild its runner. As a test host it resumes nothing,
    /// unless a test opts in with `MAGPIE_TEST_HOST_RESTORE=1`.
    @Test func testHostNeverResumesTheSavedSession() throws {
        try store.save(endpoint: ServerEndpoint(bases: [home]),
                       credentials: NavidromeCredentials(username: "admin", password: "pw"))
        let host = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        #expect(!AppModel.resumesSavedSession(environment: host))
        #expect(AppModel.resumesSavedSession(environment: host.merging(["MAGPIE_TEST_HOST_RESTORE": "1"]) { $1 }))
        #expect(AppModel.resumesSavedSession(environment: [:]), "the app itself resumes as before")
        let model = AppModel.restore(store: store, defaults: defaults, environment: host)
        #expect(model.session == nil && model.runner == nil)
        #expect(store.load().saved != nil, "nothing signed out either")
        store.clear()
    }

    @Test func signInPicksFirstAnsweringAddress() async throws {
        transport.setDown([home.host!])
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        #expect(model.session?.activeBase == away)
        store.clear()
    }

    @Test func signInReportsEachUnreachableAddress() async throws {
        transport.setDown([home.host!, away.host!], with: .timedOut)
        let model = makeModel()
        do {
            try await model.signIn(urls: [home, away], username: "admin", password: "pw")
            Issue.record("expected failure")
        } catch SignInError.unreachable(let failures) {
            #expect(failures.map(\.url) == [home, away])
        }
        #expect(model.session == nil)
        #expect(store.load().saved == nil)
    }

    @Test func badCredentialsDoNotSave() async throws {
        let t = HostSwitchTransport()
        t.inner.stub(pathSuffix: "/rest/ping", body: ok)
        t.inner.stub(method: "POST", pathSuffix: "/auth/login", status: 401)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: t, probeTransport: t, engine: engine,
                             defaults: defaults, systemNowPlaying: false)
        await #expect(throws: NavidromeError.badCredentials) {
            try await model.signIn(urls: [home], username: "admin", password: "wrong")
        }
        #expect(model.session == nil)
        #expect(store.load().saved == nil)
    }

    /// Review focus 3: the home address dies mid-session; the next request moves to the away address,
    /// rebuilds the client, and the player's queued URLs are rebuilt from the new base.
    @Test func connectionErrorFailsOverAndRebuildsPlayerURLs() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        let songs = [Song(id: "s1", title: "T1", artist: "A", album: "B", duration: 100),
                     Song(id: "s2", title: "T2", artist: "A", album: "B", duration: 100)]
        model.play(songs, startAt: 0)
        #expect(engine.setItemsCalls.last?.items.first?.1.host == home.host)
        let oldClient = try #require(model.session?.client)

        transport.setDown([home.host!])
        let albums = try await model.request { try await $0.albumList(.newest, size: 1, offset: 0) }

        #expect(albums.map(\.id) == ["al1"])
        #expect(model.session?.activeBase == away)
        #expect(model.session?.client !== oldClient)
        let rebuilt = try #require(engine.setItemsCalls.last?.items)
        #expect(rebuilt.count == 2)
        #expect(rebuilt.allSatisfy { $0.1.host == away.host && $0.1.path.hasPrefix("/navidrome/rest/stream") })
        #expect(engine.seeks.last == 0)
        // The saved order is what the user entered, not the failover order.
        #expect(store.load().saved?.endpoint.bases == [home, away])
        store.clear()
    }

    @Test func nonConnectionErrorsDoNotFailOver() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        let probesBefore = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true }.count
        await #expect(throws: NavidromeError.self) {
            _ = try await model.request { try await $0.album(id: "missing") }   // 404 from the mock
        }
        let probesAfter = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true }.count
        #expect(probesAfter == probesBefore)
        #expect(model.session?.activeBase == home)
        store.clear()
    }

    @Test func toggleStarCallsServerAndRevertsOnFailure() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let song = Song(id: "s9", title: "T", artist: "A", album: "B", duration: 100)
        await model.toggleStar(song)
        #expect(model.isStarred(song))
        let star = try #require(transport.inner.requests.last { $0.url?.path.hasSuffix("/rest/star") == true })
        #expect(URLComponents(url: star.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "id" }?.value == "s9")

        await model.toggleStar(song)   // unstar isn't stubbed: 404 → reverts to starred
        #expect(model.isStarred(song))
        store.clear()
    }
}

/// A store whose Keychain can be "locked" (unreadable) and later unlocked.
final class LockableStore: SessionStoring {
    private let state = OSAllocatedUnfairLock(initialState: (locked: true, saved: SavedSession?.none))
    func unlock(with saved: SavedSession?) { state.withLock { $0 = (false, saved) } }
    func save(endpoint: ServerEndpoint, credentials: NavidromeCredentials) throws {
        state.withLock { $0.saved = SavedSession(endpoint: endpoint, credentials: credentials) }
    }
    func load() -> SessionLoad {
        state.withLock { s in s.locked ? .unavailable : (s.saved.map(SessionLoad.session) ?? SessionLoad.none) }
    }
    func clear() { state.withLock { $0.saved = nil } }
}

@MainActor
@Suite(.serialized) struct AppModelLockAndArtworkTests {
    let transport = HostSwitchTransport()
    let defaults = UserDefaults(suiteName: "AppModelLockTests.\(UUID().uuidString)")!

    init() {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
    }

    /// Before first unlock the Keychain can't be read: that is not "signed out". Once protected data
    /// becomes available the saved session is restored.
    @Test func lockedKeychainWaitsThenRestoresOnUnlock() async throws {
        let store = LockableStore()
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: defaults, systemNowPlaying: false)
        model.resumeSavedSession()
        #expect(model.session == nil)
        #expect(model.isWaitingForUnlock)

        store.unlock(with: SavedSession(endpoint: ServerEndpoint(bases: [home]),
                                        credentials: NavidromeCredentials(username: "admin", password: "pw")))
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(!model.isWaitingForUnlock)
        #expect(model.session?.username == "admin")
    }

    @Test func emptyKeychainIsSignedOutNotWaiting() {
        let store = LockableStore()
        store.unlock(with: nil)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: defaults, systemNowPlaying: false)
        model.resumeSavedSession()
        #expect(model.session == nil)
        #expect(!model.isWaitingForUnlock)
    }

    /// Cold launch from the car: the CarPlay scene shows "locked" until first unlock, then the
    /// library; signed out shows "not set up".
    @Test func carPlayFollowsSessionState() {
        let store = LockableStore()
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: defaults, systemNowPlaying: false)
        model.resumeSavedSession()
        #expect(CarPlaySceneDelegate.availability(model) == .locked)

        store.unlock(with: SavedSession(endpoint: ServerEndpoint(bases: [home]),
                                        credentials: NavidromeCredentials(username: "admin", password: "pw")))
        model.protectedDataBecameAvailable()
        #expect(CarPlaySceneDelegate.availability(model) == .ready(account: model.artworkScope ?? "?"))

        model.signOut()
        #expect(CarPlaySceneDelegate.availability(model) == .notSetUp)
    }

    @Test func signOutClearsArtworkCacheAndScopeSeparatesAccounts() async throws {
        let store = LockableStore()
        store.unlock(with: nil)
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: defaults, systemNowPlaying: false)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let adminScope = try #require(model.artworkScope)
        let key = ArtworkCache.key(scope: adminScope, coverArtId: "al-1", size: 300)
        ArtworkCache.shared.store(UIImage(systemName: "star")!, for: key)
        #expect(ArtworkCache.shared.cached(key) != nil)

        model.signOut()
        #expect(ArtworkCache.shared.cached(key) == nil)
        #expect(model.artworkScope == nil)

        try await model.signIn(urls: [home], username: "listener", password: "pw")
        #expect(model.artworkScope != adminScope)
    }

    @Test func artworkIsNeverCachedOnDisk() {
        let config = ArtworkCache.sessionConfiguration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(NowPlayingBridge.artworkSession.configuration.urlCache == nil)
    }
}

@Suite struct ConnectErrorCopyTests {
    @Test func badCredentials() {
        #expect(ConnectErrorCopy.message(for: NavidromeError.badCredentials) == "That username or password didn't work.")
    }

    @Test func untrustedCertificateGivesB3Instructions() {
        let failures = [ProbeFailure(url: URL(string: "https://music.example.com")!,
                                     error: URLError(.serverCertificateUntrusted))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(failures)) == ConnectErrorCopy.untrustedCertificate)
        #expect(ConnectErrorCopy.untrustedCertificate.contains("add-root-cert"))
    }

    @Test func lanTimeoutGivesB4Hint() {
        let failures = [ProbeFailure(url: URL(string: "http://192.168.1.20:4533")!, error: URLError(.timedOut))]
        let message = ConnectErrorCopy.message(for: SignInError.unreachable(failures))
        #expect(message.contains("192.168.1.20"))
        #expect(message.contains("Local Network"))
    }

    @Test func remoteTimeoutIsPlainUnreachable() {
        let failures = [ProbeFailure(url: URL(string: "https://music.example.com")!, error: URLError(.timedOut))]
        let message = ConnectErrorCopy.message(for: SignInError.unreachable(failures))
        #expect(message == ConnectErrorCopy.unreachable("music.example.com"))
    }

    @Test func plainHTTPOutsideHomeAsksForHTTPS() {
        let failures = [ProbeFailure(url: URL(string: "http://music.example.com")!,
                                     error: URLError(.appTransportSecurityRequiresSecureConnection))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(failures)) == ConnectErrorCopy.needsHTTPS)
    }

    /// Final review I2: a MagicDNS name typed without a scheme becomes https; a plain-http server then fails
    /// the TLS handshake. Say so, instead of "check that the server is running".
    @Test func tlsFailureOverHTTPSSuggestsPlainHTTP() {
        let url = URL(string: "https://nas.tail1234.ts.net:4533")!
        for code in [URLError.Code.secureConnectionFailed, .cannotParseResponse, .badServerResponse] {
            let failures = [ProbeFailure(url: url, error: URLError(code))]
            #expect(ConnectErrorCopy.message(for: SignInError.unreachable(failures)) == ConnectErrorCopy.httpsNotAnswering,
                    "\(code)")
            let direct = URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url])
            #expect(ConnectErrorCopy.message(for: direct) == ConnectErrorCopy.httpsNotAnswering, "\(code)")
        }
        #expect(ConnectErrorCopy.httpsNotAnswering.contains("http://"))
    }

    @Test func badResponseOverPlainHTTPIsStillUnreachable() {
        let failures = [ProbeFailure(url: URL(string: "http://192.168.1.20:4533")!, error: URLError(.badServerResponse))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(failures)) == ConnectErrorCopy.unreachable("192.168.1.20:4533"))
    }

    @Test func certificateTroubleStillComesFirst() {
        let url = URL(string: "https://nas.tail1234.ts.net:4533")!
        let failures = [ProbeFailure(url: url, error: URLError(.secureConnectionFailed)),
                        ProbeFailure(url: url, error: URLError(.serverCertificateUntrusted))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(failures)) == ConnectErrorCopy.untrustedCertificate)
    }

    @Test func copyNeverNamesServicesOutsideTheServiceLine() {
        // Connect may name Navidrome in its subtitle; error messages talk about "your music server".
        for message in [ConnectErrorCopy.badCredentials, ConnectErrorCopy.generic, ConnectErrorCopy.untrustedCertificate,
                        ConnectErrorCopy.localNetworkHint("x"), ConnectErrorCopy.unreachable("x"),
                        ConnectErrorCopy.httpsNotAnswering] {
            #expect(!message.contains("Navidrome"))
        }
    }
}

@Suite struct ServerAddressTests {
    @Test func addsSchemeAndTrimsSlash() {
        #expect(ServerAddress.parse(" 192.168.1.20:4533/ ") == URL(string: "http://192.168.1.20:4533"))
        #expect(ServerAddress.parse("https://host/navidrome") == URL(string: "https://host/navidrome"))
        #expect(ServerAddress.parse("ftp://host") == nil)
        #expect(ServerAddress.parse("") == nil)
    }

    @Test func localNetwork() {
        for s in ["http://192.168.1.2", "http://10.0.0.5:4533", "http://172.20.1.1", "http://nas.local", "http://nas"] {
            #expect(ServerAddress.isLocalNetwork(URL(string: s)!), "\(s)")
        }
        for s in ["https://music.example.com", "http://100.64.1.2", "http://172.40.1.1", "http://localhost"] {
            #expect(!ServerAddress.isLocalNetwork(URL(string: s)!), "\(s)")
        }
    }
}
