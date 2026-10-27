import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

// Task 8.2 security fixes in the app: H2 (plain-http consent, ping validation), M3 (write switch and setup
// per Lidarr instance), M5 (no credentials in addresses).

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let publicHTTP = URL(string: "http://music.example.com:4533")!
private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let publicLidarr = URL(string: "http://lidarr.example.com:8686")!

@MainActor
@Suite(.serialized) struct SecurityAppTests {
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
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
    }

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                 engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    private var gateDefaults: UserDefaults { UserDefaults(suiteName: gateSuite)! }

    private func scope(_ base: URL, _ key: String) -> String {
        LidarrClient(base: base, apiKey: key, transport: MockTransport()).instanceScope
    }

    private func cleanUp(_ model: AppModel) {
        model.signOut()
        gateDefaults.removePersistentDomain(forName: gateSuite)
    }

    // MARK: H2

    /// Plain http to a public address: nothing at all is sent (no ping, no password) until the owner agrees.
    @Test func plainHTTPToAPublicAddressNeedsConsent() async throws {
        let model = makeModel()
        await #expect(throws: PlainHTTPConsentRequired(urls: [publicHTTP])) {
            try await model.signIn(urls: [home, publicHTTP], username: "admin", password: "pw")
        }
        #expect(transport.inner.requests.isEmpty)
        #expect(model.session == nil)

        model.allowPlainHTTP([publicHTTP])
        #expect(makeModel().plainHTTPConsent.allows(publicHTTP), "remembered per address")
        try await model.signIn(urls: [home, publicHTTP], username: "admin", password: "pw")
        #expect(model.session != nil)
        #expect(!model.plainHTTPConsent.allows(URL(string: "http://music.example.com:8080")!), "another port asks again")
        cleanUp(model)
    }

    @Test func privateAndEncryptedAddressesNeedNoConsent() async throws {
        let consent = makeModel().plainHTTPConsent
        for s in ["http://192.168.1.2:4533", "http://127.0.0.1:4533", "http://localhost:4533", "http://nas.local",
                  "http://100.101.2.3:4533", "https://music.example.com", "http://[fd12::1]:4533"] {
            #expect(consent.allows(URL(string: s)!), "\(s)")
        }
        for s in ["http://music.example.com", "http://8.8.8.8:4533", "http://100.128.0.1", "http://[2001:db8::1]"] {
            #expect(!consent.allows(URL(string: s)!), "\(s)")
        }
    }

    /// The Lidarr API key follows the same rule.
    @Test func plainHTTPLidarrNeedsConsent() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        let before = transport.inner.requests.count
        await #expect(throws: PlainHTTPConsentRequired(urls: [publicLidarr])) {
            _ = try await model.connectLidarr(base: publicLidarr, apiKey: "key")
        }
        #expect(transport.inner.requests.count == before, "the key was not sent")
        #expect(model.lidarr == nil)
        model.allowPlainHTTP([publicLidarr])
        _ = try await model.connectLidarr(base: publicLidarr, apiKey: "key")
        #expect(model.lidarr?.base == publicLidarr)
        cleanUp(model)
    }

    /// Something answering 200 with a page that isn't a Subsonic answer never gets the password.
    @Test func a200ThatIsNotSubsonicGetsNoPassword() async throws {
        let t = HostSwitchTransport()
        t.inner.stub(pathSuffix: "/rest/ping", body: Data("<html>Router</html>".utf8))
        t.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: t,
                             probeTransport: t, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                             notifications: false)
        var thrown: Error?
        do { try await model.signIn(urls: [home], username: "admin", password: "pw") } catch { thrown = error }
        #expect(ConnectErrorCopy.message(for: try #require(thrown)) == ConnectErrorCopy.notAMusicServer)
        #expect(!t.inner.requests.contains { $0.httpMethod == "POST" })
    }

    // MARK: M3

    /// The switch and the setup belong to one Lidarr: disconnect forgets both, and reconnecting starts off.
    @Test func disconnectForgetsTheSwitchAndSetup() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        #expect(model.lidarrSetup?.rootFolderPath == "/music")
        let key = LidarrWriteGate.enabledKey(scope: scope(lidarrBase, "key"))
        #expect(gateDefaults.bool(forKey: key))

        model.disconnectLidarr()
        #expect(model.changesAllowed == false)
        #expect(gateDefaults.object(forKey: key) == nil)
        #expect(LidarrSetupStore(defaults: defaults).load(base: lidarrBase, scope: scope(lidarrBase, "key")).rootFolderPath == nil)

        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.changesAllowed == false, "a newly connected Lidarr starts with writes off")
        #expect(await model.gate?.enabled == false)
        cleanUp(model)
    }

    @Test func signOutForgetsTheSwitch() async throws {
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        await model.setChangesAllowed(true)
        let key = LidarrWriteGate.enabledKey(scope: scope(lidarrBase, "key"))
        model.signOut()
        #expect(model.changesAllowed == false)
        #expect(gateDefaults.object(forKey: key) == nil)
        cleanUp(model)
    }

    /// Another Lidarr (or a new key) never inherits the switch, even one left on by an older build.
    @Test func anotherLidarrStartsWithWritesOff() async throws {
        gateDefaults.set(true, forKey: LidarrWriteGate.enabledDefaultsKey)   // the unscoped switch of older builds
        let model = makeModel()
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        _ = try await model.connectLidarr(base: lidarrBase, apiKey: "key")
        #expect(model.changesAllowed == false)
        #expect(await model.gate?.enabled == false)
        await model.setChangesAllowed(true)

        let other = URL(string: "http://192.168.1.3:8686")!
        _ = try await model.connectLidarr(base: other, apiKey: "other")
        #expect(model.changesAllowed == false)
        #expect(await model.gate?.enabled == false)
        #expect(gateDefaults.object(forKey: LidarrWriteGate.enabledKey(scope: scope(lidarrBase, "key"))) == nil,
                "the replaced Lidarr's switch is forgotten too")
        #expect(makeModel().changesAllowed == false)
        cleanUp(model)
    }
}

@Suite struct ServerAddressSecurityTests {
    @Test func noSchemeMeansHTTPSUnlessPrivate() {
        #expect(ServerAddress.parse("music.example.com") == URL(string: "https://music.example.com"))
        #expect(ServerAddress.parse("music.example.com:4533/navidrome/") == URL(string: "https://music.example.com:4533/navidrome"))
        #expect(ServerAddress.parse("192.168.1.20:4533") == URL(string: "http://192.168.1.20:4533"))
        #expect(ServerAddress.parse("127.0.0.1:4533") == URL(string: "http://127.0.0.1:4533"))
        #expect(ServerAddress.parse("localhost:4533") == URL(string: "http://localhost:4533"))
        #expect(ServerAddress.parse("nas.local:4533") == URL(string: "http://nas.local:4533"))
        #expect(ServerAddress.parse("100.101.2.3:4533") == URL(string: "http://100.101.2.3:4533"), "Tailscale")
        #expect(ServerAddress.parse("http://music.example.com") == URL(string: "http://music.example.com"), "typed http stays")
    }

    /// Security M5: credentials typed into an address are refused, never saved or shown.
    @Test func credentialsInAddressAreRefused() {
        for s in ["http://user:pass@192.168.1.2:4533", "https://user@music.example.com", "user:pass@music.example.com",
                  "https://:pw@music.example.com"] {
            #expect(ServerAddress.check(s) == .containsCredentials, "\(s)")
            #expect(ServerAddress.parse(s) == nil, "\(s)")
        }
        #expect(ServerAddress.check("") == .invalid)
        #expect(ServerAddress.check("ftp://host") == .invalid)
    }

    /// Fix round 1: only a whole-host IPv4/IPv6 address is classified as one; names that merely start or end
    /// like a private address, and numeric single labels (resolved as IPv4), are public.
    @Test func lookalikeHostsArePublic() {
        for s in ["http://10.0.0.1.evil.com", "http://127.0.0.1.evil.com", "http://192.168.1.1.attacker.net",
                  "http://evil.10.0.0.1.com", "http://134744072", "http://0x08080808", "http://100.64.0.1.evil.com",
                  "http://169.254.1.1.evil.com", "http://172.16.0.1.x.y", "http://10.1", "http://1.2.3.4.5",
                  "http://localhost.evil.com", "http://010.0.0.1", "http://192.168.001.1", "http://0127.0.0.1"] {
            let url = URL(string: s)!
            #expect(!ServerAddress.isPrivate(url), "\(s)")
            #expect(!ServerAddress.isLoopback(url), "\(s)")
            #expect(!ServerAddress.isLocalNetwork(url), "\(s)")
            #expect(ServerAddress.isUnencryptedPublic(url), "\(s)")
        }
        #expect(ServerAddress.parse("10.0.0.1.evil.com") == URL(string: "https://10.0.0.1.evil.com"))
        #expect(ServerAddress.parse("134744072:4533") == URL(string: "https://134744072:4533"))
        #expect(ServerAddress.parse("127.0.0.1.evil.com:4533") == URL(string: "https://127.0.0.1.evil.com:4533"))
        // Kept: single-label non-numeric names stay home network (documented residual risk).
        #expect(ServerAddress.isLocalNetwork(URL(string: "http://music")!))
        #expect(ServerAddress.parse("music:4533") == URL(string: "http://music:4533"))
    }

    @Test func privateAddresses() {
        for s in ["http://127.0.0.1", "http://localhost", "http://[::1]", "http://100.64.0.1", "http://100.127.255.255",
                  "http://[fe80::1]", "http://[fd00::1]", "http://10.1.2.3", "http://nas", "http://172.31.0.1",
                  "http://192.168.0.1", "http://169.254.3.4", "http://127.9.9.9", "http://nas.local",
                  "http://[0:0:0:0:0:0:0:1]", "http://[fc00::1]", "http://[febf::1]"] {
            #expect(ServerAddress.isPrivate(URL(string: s)!), "\(s)")
        }
        for s in ["http://100.63.255.255", "http://100.128.0.1", "http://1.1.1.1", "https://music.example.com",
                  "http://[2001:db8::1]", "http://172.32.0.1", "http://[fec0::1]", "http://[::2]",
                  "http://[::ffff:10.0.0.1]"] {
            #expect(!ServerAddress.isPrivate(URL(string: s)!), "\(s)")
        }
    }
}
