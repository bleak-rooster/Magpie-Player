import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import MatchIndex
import NavidromeKit
import Requests
import Security
import Testing
@testable import Magpie

// Verify V1: docs/FLOWS.md §3a (failover order, sign-out), §4 (Keychain class, file protection) against the app model.

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let away = URL(string: "https://music.example.com/navidrome")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!

/// Polls `condition` until it holds or the deadline passes (no fixed sleeps).
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite(.serialized) struct V1FlowsDocAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let lidarrStore = MemoryLidarrStore()
    let tokenStore = MemoryTokenStore()
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "magpie-tests-v1-\(UUID().uuidString)")!
    let dir = FileManager.default.temporaryDirectory.appending(path: "V1FlowsDocAppTests-\(UUID().uuidString)")

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/rest/getAlbumList2", body: Data(
            #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}"#.utf8))
        t.stub(pathSuffix: "/api/song", body: Data(
            #"[{"id":"s1","title":"Harbour Lights","artist":"Judie Tzuke","album":"The Cat Is Out","duration":200}]"#.utf8),
               headers: ["X-Total-Count": "1"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
    }

    func makeModel(files: Bool = false) -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: tokenStore,
                 matchIndexDirectory: files ? dir : nil, dataDirectory: files ? dir : nil, gateDefaultsSuite: gateSuite,
                 transport: transport, probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                 systemNowPlaying: false, notifications: false)
    }

    private func cleanUp(_ model: AppModel) {
        model.signOut()
        UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func pings(_ host: String) -> Int {
        transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true && $0.url?.host == host }.count
    }

    // MARK: §3a Failover

    /// A connection error re-probes the addresses *in order*: when the first (home) answers again after the
    /// session moved away, the session goes back to it and the call is retried once.
    @Test func failoverReprobesInOrderAndReturnsToTheFirstAddress() async throws {
        transport.setDown([home.host!])
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        #expect(model.session?.activeBase == away)

        transport.setDown([])
        let calls = Counter()
        let albums = try await model.request { client in
            if calls.next() == 1 { throw URLError(.timedOut) }
            return try await client.albumList(.newest, size: 1, offset: 0)
        }
        #expect(albums.isEmpty)
        #expect(calls.value == 2, "one retry")
        #expect(model.session?.activeBase == home, "the first address that answers wins")
        cleanUp(model)
    }

    /// A blip: the same address answers the re-probe. The call is retried once on the same client (not rebuilt),
    /// and later addresses are not probed.
    @Test func failoverOnABlipRetriesOnceWithoutRebuilding() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home, away], username: "admin", password: "pw")
        let client = try #require(model.session?.client)
        let awayPings = pings(away.host!)
        let calls = Counter()
        await #expect(throws: URLError.self) {
            _ = try await model.request { _ -> Int in
                _ = calls.next()
                throw URLError(.timedOut)
            }
        }
        #expect(calls.value == 2, "one retry, no loop")
        #expect(model.session?.client === client)
        #expect(pings(away.host!) == awayPings, "home answered first; away was not probed")
        cleanUp(model)
    }

    // MARK: §3a / §4 What the password travels in

    /// The password goes only in `POST /auth/login` bodies, but on every login (sign-in, and again on each launch
    /// that resumes the session), not "once". A resumed launch may log in twice: the provisional client (used at
    /// once by the match-index refresh) and the client `reconnect(rebuildAlways: true)` builds.
    @Test func passwordTravelsOnlyInLoginBodiesOnEveryLogin() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw-v1-secret")
        let relaunched = makeModel()
        relaunched.resumeSavedSession()
        #expect(await relaunched.reconnect(rebuildAlways: true))
        let withPassword = transport.inner.requests.filter {
            String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("pw-v1-secret") == true
        }
        let signInOnly = 1
        #expect(withPassword.count >= signInOnly + 1, "the relaunch logs in with the password again: \(withPassword.count)")
        #expect(withPassword.allSatisfy { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/auth/login") == true })
        #expect(!transport.inner.requests.contains { $0.url?.absoluteString.contains("pw-v1-secret") == true })
        relaunched.signOut()
        cleanUp(model)
    }

    // MARK: §3a Sign-out

    /// Sign-out clears the session, Lidarr connection, write switch, match-index snapshot and requests file, and
    /// keeps the change log, the ledger and the ListenBrainz token.
    @Test func signOutClearsAndKeepsWhatTheDocSays() async throws {
        try tokenStore.save("lb-token")
        let model = makeModel(files: true)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()
        let snapshot = MatchIndexStore.snapshotURL(server: home.absoluteString, user: "admin", in: dir)
        #expect(FileManager.default.fileExists(atPath: snapshot.path), "the match index was saved")

        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        let scope = try #require(model.lidarrScope)
        let requestsURL = RequestStore.defaultURL(in: dir, instance: scope)
        try await #require(model.requestStore).save([])
        #expect(FileManager.default.fileExists(atPath: requestsURL.path))
        // The change log and the ledger as a previous write would have left them.
        let logURL = LidarrWriteGate.defaultLogURL(in: dir), ledgerURL = Ledger.defaultURL(in: dir)
        try Data("[]".utf8).write(to: logURL)
        try Data("[]".utf8).write(to: ledgerURL)

        model.signOut()

        #expect(model.session == nil && store.load().saved == nil, "Keychain session cleared")
        #expect(lidarrStore.load() == nil && model.lidarr == nil, "Lidarr connection cleared")
        #expect(UserDefaults(suiteName: gateSuite)?.object(forKey: LidarrWriteGate.enabledKey(scope: scope)) == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: snapshot.path) }, "snapshot erased")
        #expect(await eventually { !FileManager.default.fileExists(atPath: requestsURL.path) }, "requests file erased")
        #expect(FileManager.default.fileExists(atPath: logURL.path), "change log kept")
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path), "ledger kept")
        #expect(tokenStore.load() == "lb-token" && model.hasListenBrainzToken, "ListenBrainz token kept (security L1)")
        cleanUp(model)
    }

    /// Sign-out erases the requests file of the Lidarr connected *now*. A requests file left by a Lidarr connected
    /// earlier (then replaced) stays on disk (FLOWS.md says "the requests file").
    @Test func signOutErasesOnlyTheCurrentLidarrsRequestsFile() async throws {
        let model = makeModel(files: true)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        let first = RequestStore.defaultURL(in: dir, instance: try #require(model.lidarrScope))
        try await #require(model.requestStore).save([])
        _ = try await model.connectLidarr(base: URL(string: "http://192.168.1.3:8686")!, apiKey: "other")
        let second = RequestStore.defaultURL(in: dir, instance: try #require(model.lidarrScope))
        try await #require(model.requestStore).save([])

        model.signOut()

        #expect(await eventually { !FileManager.default.fileExists(atPath: second.path) })
        #expect(FileManager.default.fileExists(atPath: first.path), "the earlier Lidarr's requests file survives")
        cleanUp(model)
    }

    // MARK: §4 Protection

    /// Keychain items are `AfterFirstUnlockThisDeviceOnly`, and the session, Lidarr connection and ListenBrainz token
    /// share the service `com.bleak-rooster.magpie.session`.
    @Test func keychainItemsAreAfterFirstUnlockThisDeviceOnly() throws {
        let service = "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        try keychain.set(Data("v".utf8), for: "item")
        try keychain.set(Data("w".utf8), for: "item")   // an update keeps the class
        defer { try? keychain.remove("item") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "item", kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)

        #expect(SessionStore.standard.keychain.service == "com.bleak-rooster.magpie.session")
        #expect(LidarrConnectionStore.standard.keychain.service == "com.bleak-rooster.magpie.session")
        #expect(ListenBrainzTokenStore.standard.keychain.service == "com.bleak-rooster.magpie.session")
    }

    /// Application Support files are written with `completeFileProtectionUntilFirstUserAuthentication`, also
    /// after an atomic replace.
    /// The Simulator keeps no data-protection class (it reports none even for `.completeFileProtection`), so this
    /// only asserts where the file system reports one (a device); on the Simulator it is unverifiable.
    @Test func atomicFilesAreProtectedUntilFirstUserAuthentication() throws {
        let control = dir.appending(path: "control.bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: control, options: .completeFileProtection)
        guard try FileManager.default.attributesOfItem(atPath: control.path)[.protectionKey] != nil else {
            try? FileManager.default.removeItem(at: dir)
            return   // no data protection on this platform (Simulator)
        }
        let url = dir.appending(path: "Magpie/protected.json")
        try AtomicFile.write([1], to: url)
        try AtomicFile.write([1, 2], to: url)   // the replace path
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #expect(protection == .completeUntilFirstUserAuthentication, "\(String(describing: protection)) \(attributes)")
        try? FileManager.default.removeItem(at: dir)
    }
}

/// A call counter usable from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
