import Foundation
import MagpieCore
import MagpieTestSupport
import SlskdKit
import Testing
@testable import Magpie

/// Round 23 (owner, 2026-11-07, D192): the optional slskd connection in Settings › Lidarr › Soulseek (slskd). Test and
/// Connect reads only; the key lives in the Keychain store and goes only in `X-API-Key`; plain http to a public address
/// asks first; "Allow Magpie to change Soulseek" starts off for every slskd; Disconnect forgets it all.
@MainActor
@Suite(.serialized) struct SlskdSettingsAppTests {
    let transport = HostSwitchTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "SlskdSettingsAppTests.\(UUID().uuidString)")!
    let slskdStore = InMemorySlskdStore()
    static let base = URL(string: "https://nas.local/slskd")!

    func makeModel() -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                             notifications: false)
        model.slskdStore = slskdStore
        model.readSlskdConnection()
        return model
    }

    func stubDownloads(status: Int = 200) {
        transport.inner.stub(pathSuffix: "/api/v0/transfers/downloads", status: status, body: Data("[]".utf8))
    }

    var slskdRequests: [URLRequest] { transport.inner.requests.filter { $0.url?.path.contains("/api/v0/") == true } }

    @Test func notSetUpByDefault() {
        let model = makeModel()
        #expect(model.slskd == nil && !model.slskdChangesAllowed && model.slskdAccess == nil)
        #expect(SettingsPage.topLevel.contains(.slskd), "round 24 (D216): its own row, no longer a page of Lidarr's")
    }

    @Test func testAndConnectReadsOnlyAndStartsWithChangesOff() async throws {
        stubDownloads()
        let model = makeModel()
        try await model.connectSlskd(base: Self.base, apiKey: " test-slskd-key ")
        #expect(model.slskd == SlskdConnection(base: Self.base, apiKey: "test-slskd-key"))
        #expect(slskdStore.load() == model.slskd, "saved in the Keychain store")
        #expect(!model.slskdChangesAllowed)
        #expect(slskdRequests.map { $0.httpMethod ?? "GET" } == ["GET"])
        let request = try #require(slskdRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-slskd-key")
        #expect(request.url?.absoluteString.contains("test-slskd-key") == false)
        #expect(String(describing: model.slskd!).contains("test-slskd-key") == false, "never printed")
        #expect(model.slskdAccess != nil)
    }

    @Test func aWrongKeyIsSaidAndNothingSaved() async throws {
        stubDownloads(status: 401)
        let model = makeModel()
        var thrown: Error?
        do { try await model.connectSlskd(base: Self.base, apiKey: "nope") } catch { thrown = error }
        #expect(SlskdCopy.message(for: try #require(thrown), url: Self.base) == SlskdCopy.badKey)
        #expect(model.slskd == nil && slskdStore.load() == nil)
    }

    @Test func plainHTTPToAPublicAddressAsksFirst() async throws {
        stubDownloads()
        let model = makeModel()
        let open = URL(string: "http://music.example.com:5030")!
        await #expect(throws: PlainHTTPConsentRequired.self) { try await model.connectSlskd(base: open, apiKey: "k") }
        #expect(slskdRequests.isEmpty, "the key wasn't sent")
        model.allowPlainHTTP([open])
        try await model.connectSlskd(base: open, apiKey: "k")
        #expect(model.slskd?.base == open)
    }

    @Test func theSwitchIsPerSlskdAndDisconnectForgetsIt() async throws {
        stubDownloads()
        let model = makeModel()
        try await model.connectSlskd(base: Self.base, apiKey: "k1")
        model.setSlskdChangesAllowed(true)
        #expect(model.slskdChangesAllowed)
        #expect(await model.slskdAccess?.gate.enabled == true)
        // Another key: starts off again.
        try await model.connectSlskd(base: Self.base, apiKey: "k2")
        #expect(!model.slskdChangesAllowed)
        #expect(await model.slskdAccess?.gate.enabled == false)
        model.setSlskdChangesAllowed(true)
        model.disconnectSlskd()
        #expect(model.slskd == nil && slskdStore.load() == nil && !model.slskdChangesAllowed && model.slskdAccess == nil)
        try await model.connectSlskd(base: Self.base, apiKey: "k2")
        #expect(!model.slskdChangesAllowed, "a reconnect starts off")
    }

    /// The copy rule: "Soulseek" and "slskd" only on this settings page; plain words about music elsewhere.
    @Test func copy() {
        #expect(SlskdCopy.title == "Soulseek (slskd)")
        #expect(SlskdCopy.allowChanges == "Allow Magpie to change Soulseek")
        #expect(SettingsView.identifier(.slskd) == "settings-slskd")
    }
}
