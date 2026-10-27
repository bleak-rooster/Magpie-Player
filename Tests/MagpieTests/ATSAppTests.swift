import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

// V-fix (H4 findings 1 and 2): what App Transport Security lets through over plain http, and saying so before trying.
// Release has only `NSAllowsLocalNetworking`: plain http reaches loopback, private and link-local IPv4, `.local`
// and single-label names (`http://nas:4533`); raw IPs elsewhere (Tailscale's 100.64/10 included) and dotted names
// (`*.ts.net`) are blocked. Debug has only `NSAllowsArbitraryLoads` (iOS ignores it when `NSAllowsLocalNetworking`
// is also present).

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)

@MainActor
@Suite(.serialized) struct ATSAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "magpie-tests-ats-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
    }

    /// A model that behaves like a Release build (no arbitrary loads).
    func makeModel() -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
        model.atsAllowsArbitraryLoads = false
        return model
    }

    @Test(arguments: ["http://127.0.0.1:4533", "http://localhost:4533", "http://192.168.1.20:4533", "http://10.0.0.5",
                      "http://172.16.0.9", "http://169.254.1.1", "http://nas:4533", "http://homeserver:4533",
                      "http://music.local:4533", "https://100.64.10.20:4533", "https://music.example.com",
                      "http://[::1]:4533", "http://[fd00::1]:4533", "http://[fe80::1]:4533", "http://jukebox:8080"])
    func plainHTTPThatATSAllows(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(!ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: false))
    }

    @Test(arguments: ["http://100.64.10.20:4533", "http://nas.tail0a1b2c.ts.net:4533", "http://music.example.com",
                      "http://8.8.8.8", "http://134744072", "http://[2001:db8::1]:4533"])
    func plainHTTPThatATSBlocks(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: false))
        #expect(!ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: true), "Debug allows any http")
    }

    /// A Tailscale IP over http: no consent prompt and nothing sent; the owner is told to use HTTPS or the short name.
    @Test func blockedAddressIsNamedBeforeTrying() async throws {
        let model = makeModel()
        let tailscale = URL(string: "http://100.64.10.20:4533")!, magicDNS = URL(string: "http://nas.tail0a1b2c.ts.net:4533")!
        do {
            try await model.signIn(urls: [tailscale, magicDNS], username: "admin", password: "pw")
            Issue.record("signed in")
        } catch {
            #expect(error is SignInError, "not a consent prompt: \(error)")
            #expect(ConnectErrorCopy.message(for: error) == ConnectErrorCopy.needsHTTPS)
        }
        #expect(transport.inner.requests.isEmpty, "nothing was tried")
        #expect(ConnectErrorCopy.needsHTTPS.contains("short name"))
    }

    /// One blocked address among others: the others are still tried.
    @Test func otherAddressesAreStillTried() async throws {
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://100.64.10.20:4533")!, URL(string: "http://nas:4533")!],
                               username: "admin", password: "pw")
        #expect(model.session?.activeBase == URL(string: "http://nas:4533")!)
        #expect(!transport.inner.requests.contains { $0.url?.host == "100.64.10.20" })
        model.signOut()
    }

    /// Lidarr too: nothing sent, the same advice.
    @Test func blockedLidarrIsNamedBeforeTrying() async throws {
        let model = makeModel()
        let base = URL(string: "http://100.64.10.20:8686")!
        do {
            _ = try await model.connectLidarr(base: base, apiKey: "key")
            Issue.record("connected")
        } catch {
            #expect(LidarrConnectCopy.message(for: error, url: base) == ConnectErrorCopy.needsHTTPS)
        }
        #expect(transport.inner.requests.isEmpty)
    }

    #if DEBUG
    /// The Debug build's ATS dictionary really allows plain http anywhere: arbitrary loads, and no
    /// `NSAllowsLocalNetworking` (whose presence makes iOS ignore arbitrary loads).
    @Test func debugBuildAllowsArbitraryLoads() throws {
        let ats = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)
        #expect(ats["NSAllowsLocalNetworking"] == nil)
        #expect(AppModel.bundleAllowsArbitraryLoads())
    }
    #endif
}
