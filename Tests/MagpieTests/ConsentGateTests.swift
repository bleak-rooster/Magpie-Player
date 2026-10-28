import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

// T2 (spec §8, revised; plan Review Focus 2): with arbitrary loads on in every build, ATS lets plain http through
// anywhere, so the consent gate is the only thing between a credential and a public network. "Local" is judged by
// name class only (no DNS): loopback, 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, IPv6 ULA and
// link-local, single-label names, `.local` and `*.ts.net`. Everything else asks first, however it is dressed up.

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)

@MainActor
@Suite(.serialized) struct ConsentGateTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "magpie-tests-consent-\(UUID().uuidString)")!

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr"}"#.utf8))
        t.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
    }

    /// A model that behaves like a Release build now: arbitrary loads, so nothing is pre-refused.
    func makeModel() -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
        model.atsAllowsArbitraryLoads = true
        return model
    }

    private func carriesSecret(_ secret: String) -> Bool {
        transport.inner.requests.contains { request in
            String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains(secret) == true
                || request.url?.absoluteString.contains(secret) == true
                || request.allHTTPHeaderFields?.values.contains { $0.contains(secret) } == true
        }
    }

    @Test func noCredentialBeforeConsent() async throws {
        let model = makeModel()
        await #expect(throws: PlainHTTPConsentRequired.self) {
            try await model.signIn(urls: [URL(string: "http://music.example.com:4533")!], username: "admin", password: "pw-secret")
        }
        #expect(transport.inner.requests.isEmpty, "not even a ping before consent")
    }

    /// The positive control: once the owner says yes to that origin, sign-in goes ahead.
    @Test func consentLetsThatOriginThrough() async throws {
        let model = makeModel()
        let url = URL(string: "http://music.example.com:4533")!
        model.allowPlainHTTP([url])
        try await model.signIn(urls: [url], username: "admin", password: "pw")
        #expect(transport.inner.requests.contains { $0.url?.path.hasSuffix("/auth/login") == true })
        model.signOut()
    }

    @Test func consentIsPerHostAndAHostChangeReasks() async throws {
        let model = makeModel()
        model.allowPlainHTTP([URL(string: "http://a.example.com:4533")!])
        await #expect(throws: PlainHTTPConsentRequired.self) {
            try await model.signIn(urls: [URL(string: "http://b.example.com:4533")!], username: "admin", password: "pw")
        }
        await #expect(throws: PlainHTTPConsentRequired.self) {   // origin includes the port
            try await model.signIn(urls: [URL(string: "http://a.example.com:8080")!], username: "admin", password: "pw")
        }
        #expect(transport.inner.requests.isEmpty)
    }

    @Test func mixedListAsksOnlyForThePublicOne() async throws {
        do {
            try await makeModel().signIn(urls: [URL(string: "http://nas:4533")!, URL(string: "http://music.example.com")!],
                                         username: "admin", password: "pw")
            Issue.record("signed in")
        } catch let e as PlainHTTPConsentRequired {
            #expect(e.urls == [URL(string: "http://music.example.com")!])
        }
        #expect(transport.inner.requests.isEmpty, "the home address isn't tried either until the owner answers")
    }

    @Test func lidarrKeyNeedsConsent() async throws {
        await #expect(throws: PlainHTTPConsentRequired.self) {
            _ = try await makeModel().connectLidarr(base: URL(string: "http://lidarr.example.com:8686")!, apiKey: "key-secret")
        }
        #expect(!transport.inner.requests.contains { $0.value(forHTTPHeaderField: "X-Api-Key") != nil })
        #expect(!carriesSecret("key-secret"))
    }

    @Test(arguments: ["http://100.64.10.20:4533", "http://nas.tail0a1b2c.ts.net:4533", "http://[fd00::1]:4533",
                      "http://[fe80::1]:4533", "http://homeserver:4533", "http://nas.local:4533", "http://192.168.1.20:4533"])
    func localAndTailscaleNeedNoConsent(_ text: String) async throws {
        let model = makeModel()
        try await model.signIn(urls: [URL(string: text)!], username: "admin", password: "pw")
        #expect(transport.inner.requests.contains { $0.url?.path.hasSuffix("/auth/login") == true })
        model.signOut()
    }

    @Test(arguments: ["http://MUSIC.example.com.", "http://nas.:4533", "http://0x7f000001", "http://134744072",
                      "http://10.0.0.1.evil.com", "http://192.168.1.20.nip.io", "http://localhost.evil.com",
                      "http://evil-ts.net", "http://nas.ts.net.evil.com", "http://[2001:db8::1]:4533"])
    func disguisedPublicHostsStillNeedConsent(_ text: String) async throws {   // Review Focus 2
        await #expect(throws: PlainHTTPConsentRequired.self) {
            try await makeModel().signIn(urls: [URL(string: text)!], username: "admin", password: "pw-secret")
        }
        #expect(!transport.inner.requests.contains { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("pw-secret") == true })
    }

    /// More disguises: edges of the private ranges, octal and mapped forms, look-alike suffixes, a trailing dot on
    /// a Tailscale name and an encoded dot. Each asks, and nothing at all is sent.
    @Test(arguments: ["http://100.128.0.1:4533", "http://100.63.255.255", "http://172.32.0.1", "http://172.15.0.1",
                      "http://192.169.0.1", "http://010.0.0.1", "http://0177.0.0.1", "http://[::ffff:192.168.1.20]:4533",
                      "http://[fec0::1]", "http://ts.net.evil.com", "http://nas.ts.net.", "http://nasts.net",
                      "http://nas.local.evil.com", "http://evil.local.", "http://nas%2Eevil.com"])
    func moreDisguisesStillNeedConsent(_ text: String) async throws {
        let url = try #require(URL(string: text))
        #expect(ServerAddress.isUnencryptedPublic(url))
        await #expect(throws: PlainHTTPConsentRequired.self) {
            try await makeModel().signIn(urls: [url], username: "admin", password: "pw-secret")
        }
        #expect(transport.inner.requests.isEmpty)
        #expect(!carriesSecret("pw-secret"))
    }

    @Test func tailscaleNamesOnALabelBoundary() {
        for text in ["http://ts.net", "http://nas.tail0a1b2c.ts.net:4533", "http://NAS.Tail0a1b2c.TS.NET"] {
            #expect(ServerAddress.isTailscaleName(URL(string: text)!), "\(text)")
        }
        // Typed without a scheme, a Tailscale name is private, so it becomes http (Navidrome's own port speaks http).
        #expect(ServerAddress.parse("nas.tail1234.ts.net:4533") == URL(string: "http://nas.tail1234.ts.net:4533")!)
        #expect(ServerAddress.parse("nas.ts.net.evil.com") == URL(string: "https://nas.ts.net.evil.com")!)
        for text in ["http://evil-ts.net", "http://nasts.net", "http://nas.ts.net.evil.com", "http://ts.net.evil.com"] {
            #expect(!ServerAddress.isTailscaleName(URL(string: text)!), "\(text)")
        }
    }

    @Test func settingsLabelsPublicPlainHTTP() {
        #expect(ConnectErrorCopy.notEncrypted == "Not encrypted")
        #expect(ServerAddress.isUnencryptedPublic(URL(string: "http://music.example.com")!))
        #expect(!ServerAddress.isUnencryptedPublic(URL(string: "http://nas.tail0a1b2c.ts.net:4533")!))
        #expect(!ServerAddress.isUnencryptedPublic(URL(string: "https://music.example.com")!))
    }
}
