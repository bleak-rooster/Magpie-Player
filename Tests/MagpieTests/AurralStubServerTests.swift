import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Round 14 A1 fix round 1: the localhost stub Aurral (`dev/aurral-stub`, for XCUITests) through the real network
/// stack (URLSessionTransport, the preview's own session). It answers as the in-process StubAurral does, so UI tests
/// and unit tests see the same Aurral. Runs when `MAGPIE_IT=1 scripts/test-app.sh` started the stub; otherwise skipped.
/// Guard G0: 127.0.0.1 / localhost only.
@Suite struct AurralStubServerTests {
    static var stubURL: URL? {
        guard let text = ProcessInfo.processInfo.environment["MAGPIE_AURRAL_STUB_URL"], let url = URL(string: text),
              let host = url.host()?.lowercased(), ["127.0.0.1", "localhost"].contains(host) else { return nil }
        return url
    }

    static func client(_ base: URL) async throws -> AurralClient {
        let transport = URLSessionTransport()
        let login = try await AurralClient.signIn(base: base, username: StubAurral.defaultUsername,
                                                  password: StubAurral.defaultPassword, transport: transport)
        let session = AurralSession(username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, login: login)
        return AurralClient(base: base, session: session, transport: transport)
    }

    @Test(.enabled(if: stubURL != nil, "set MAGPIE_IT=1 (scripts/test-app.sh starts dev/aurral-stub)"))
    func signInBootstrapAndTrendingOverTheNetwork() async throws {
        let root = try #require(Self.stubURL)
        let client = try await Self.client(root.appending(path: "s/default"))
        let bootstrap = try await client.bootstrap()
        #expect(bootstrap.capabilities.trending && bootstrap.capabilities.editorialPlaylists)
        #expect(bootstrap.user?.canAddFlow == true && bootstrap.hasDownloader == true)
        let trending = try await client.trending()
        // The same Aurral as the in-process stub.
        let inProcess = StubAurral()
        inProcess.useAurral213()
        let reference = try await AurralClient(base: inProcess.base, session: inProcess.signedInSession(), transport: inProcess)
            .trending()
        #expect(trending == reference)
        #expect(trending.region == "AU" && trending.songs?.items.count == 5)
        let shelf = try await client.editorialShelf()
        #expect(shelf.forYou.map(\.id) == ["908622995", "1479458365"])
        _ = try? await client.logout()
    }

    /// Fix I1, over the real network: an Aurral address with capital letters still resolves previews.
    @Test(.enabled(if: stubURL != nil, "set MAGPIE_IT=1 (scripts/test-app.sh starts dev/aurral-stub)"))
    func previewResolvesOnAMixedCaseAddress() async throws {
        let root = try #require(Self.stubURL)
        var parts = try #require(URLComponents(url: root.appending(path: "s/default"), resolvingAgainstBaseURL: false))
        parts.host = parts.host == "127.0.0.1" ? "LocalHost" : parts.host?.uppercased()
        let base = try #require(parts.url)
        let resolver = PreviewResolver(base: base)
        let result = try await resolver.resolve(AurralPreview(trackId: "3135556")!)
        guard case .playable(let url) = result else { Issue.record("\(result)"); return }
        #expect(url.host() == "cdnt-preview.dzcdn.net")
        #expect(try await resolver.resolve(AurralPreview(trackId: "3135560")!) == .noPreview)
    }

    /// The scenarios UI tests pick by address: no accessFlow (flows 403), and 2.10 (no capabilities).
    @Test(.enabled(if: stubURL != nil, "set MAGPIE_IT=1 (scripts/test-app.sh starts dev/aurral-stub)"))
    func scenariosByAddress() async throws {
        let root = try #require(Self.stubURL)
        let limited = try await Self.client(root.appending(path: "s/no-access-flow"))
        await #expect(throws: AurralError.notPermitted) { _ = try await limited.status() }
        #expect(try await limited.bootstrap().user?.canAddFlow == false)
        let old = try await Self.client(root.appending(path: "s/aurral210"))
        #expect(try await old.bootstrap().capabilities == .none)
    }
}
