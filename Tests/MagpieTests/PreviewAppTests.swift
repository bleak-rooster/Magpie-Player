import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import Playback
import Testing
@testable import Magpie

/// Round 14 A2 (D85–D89): previews in the app. They show only with an Aurral that can preview (2.13 with Discover or
/// Trending), resolve through Aurral's open preview route with no login just before each play, hand off with the main
/// player, and never reach the scrobbler.
@MainActor
final class RecordingPreviewEngine: PreviewEngine {
    let events: AsyncStream<PreviewEngineEvent>
    private(set) var loads: [(url: URL, token: Int, at: TimeInterval)] = []
    private(set) var stops = 0
    init() { events = AsyncStream { $0.finish() } }
    func load(_ url: URL, token: Int, at: TimeInterval) { loads.append((url, token, at)) }
    func pause() {}
    func resume() {}
    func stop() { stops += 1 }
}

extension DiscoverAppTests {
    func previewModel(aurral213: Bool = true, aurralSetUp: Bool = true) async throws -> (AppModel, RecordingPreviewEngine) {
        if aurral213 { aurral.useAurral213() }
        nav.install(on: transport.navidrome)
        let engine = RecordingPreviewEngine()
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewEngine: engine,
                             previewTransport: transport, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return (model, engine)
    }

    static let previewSong = PreviewItem(id: "trending-3135556", previewId: "3135556", title: "Harbour Lights", artist: "Stub Arrows")

    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    private var previewAsks: [URLRequest] { aurral.requests.filter { $0.url?.path.hasPrefix("/api/deezer/preview/") == true } }

    // MARK: - Setups (owner answer 9)

    @Test func noAurralMeansNoPreviewControls() async throws {
        let (model, engine) = try await previewModel(aurralSetUp: false)
        defer { model.signOut() }
        #expect(!model.previewsAvailable)
        model.togglePreview(Self.previewSong)
        model.playPreviews([Self.previewSong])
        await settle { false == true }
        #expect(model.previewPlayer.phase == .idle)
        #expect(engine.loads.isEmpty && previewAsks.isEmpty)
    }

    @Test func aurral210MeansNoPreviewControls() async throws {
        let (model, engine) = try await previewModel(aurral213: false)
        defer { model.signOut() }
        #expect(model.aurralSetUp)
        #expect(!model.previewsAvailable)
        model.togglePreview(Self.previewSong)
        #expect(engine.loads.isEmpty && previewAsks.isEmpty)
    }

    @Test func anAurralWithoutDiscoverOrTrendingMeansNoPreviewControls() async throws {
        aurral.useAurral213()
        aurral.setFeatures(["flows"])
        let (model, _) = try await previewModel(aurral213: false)
        defer { model.signOut() }
        #expect(model.aurralSetUp && !model.aurralCapabilities.artistPreview && !model.aurralCapabilities.trending)
        #expect(!model.previewsAvailable)
    }

    @Test func previewsShowWithAurral213AndHideOffline() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        #expect(model.previewsAvailable)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(!model.previewsAvailable)
    }

    // MARK: - Resolving through Aurral

    @Test func aPreviewResolvesThroughAurralWithNoLoginJustBeforeItPlays() async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        model.togglePreview(Self.previewSong)
        await settle { engine.loads.count == 1 }
        let load = try #require(engine.loads.first)
        #expect(load.url.host() == "cdnt-preview.dzcdn.net")
        let ask = try #require(previewAsks.first)
        #expect(ask.url?.path == "/api/deezer/preview/3135556.mp3")
        #expect(ask.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(ask.httpShouldHandleCookies == false)

        // Stopped and played again: Aurral is asked again (the signed link is never kept).
        model.togglePreview(Self.previewSong)
        #expect(model.previewPlayer.phase == .idle)
        model.togglePreview(Self.previewSong)
        await settle { engine.loads.count == 2 }
        #expect(previewAsks.count == 2)
    }

    @Test func aSongAurralHasNoPreviewForShowsNoPreviewAvailable() async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        aurral.setPreviewTarget(nil)   // 404
        model.togglePreview(Self.previewSong)
        await settle { model.previewPlayer.phase == .noPreview }
        #expect(model.previewPlayer.state(for: Self.previewSong) == .noPreview)
        #expect(PreviewCopy.label(for: .noPreview) == "No preview available")
        #expect(engine.loads.isEmpty)
    }

    @Test(arguments: [502, 503])
    func aurralOrDeezerDownShowsPreviewUnavailable(_ status: Int) async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        aurral.setPreviewStatus(status)
        model.togglePreview(Self.previewSong)
        await settle { model.previewPlayer.phase == .unavailable }
        #expect(model.previewPlayer.state(for: Self.previewSong) == .unavailable)
        #expect(PreviewCopy.label(for: .unavailable) == "Preview unavailable right now")
        #expect(engine.loads.isEmpty)
    }

    /// A redirect anywhere but Deezer's https audio hosts is refused: nothing plays.
    @Test func aRedirectOffDeezerIsRefused() async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        aurral.setPreviewTarget("http://cdnt-preview.dzcdn.net/x.mp3")
        model.togglePreview(Self.previewSong)
        await settle { model.previewPlayer.phase == .unavailable }
        #expect(model.previewPlayer.phase == .unavailable)
        #expect(engine.loads.isEmpty)
    }

    // MARK: - Hand-off and no scrobbling

    @Test func aPreviewPausesTheMainPlayerAndNeverResumesItOrScrobbles() async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        model.player.play([Song(id: "s1", title: "Lullaby", artist: "Low", album: "Single", duration: 200)], startAt: 0)
        #expect(model.player.isPlaying)
        try await Task.sleep(for: .milliseconds(50))
        await model.player.waitForPendingScrobbles()
        let scrobbles = { self.transport.navidrome.requests.filter { $0.url?.path.contains("scrobble") == true }.count }
        let before = scrobbles()

        model.togglePreview(Self.previewSong)
        #expect(!model.player.isPlaying, "the main player pauses")
        await settle { engine.loads.count == 1 }
        model.previewPlayer.handle(.started(token: engine.loads[0].token))
        for t in stride(from: 0.0, through: 30, by: 1) {
            model.previewPlayer.handle(.time(token: engine.loads[0].token, t, duration: 30))
        }
        #expect(model.previewPlayer.phase == .idle, "the clip ran out")
        #expect(!model.player.isPlaying, "the main player stays paused")
        #expect(model.previewPlayer.offersResume)
        await model.player.waitForPendingScrobbles()
        #expect(scrobbles() == before, "a preview is never scrobbled or counted")

        model.previewPlayer.resumeMain()
        #expect(model.player.isPlaying)
    }

    /// Signing out of Aurral while a preview plays stops it.
    @Test func losingAurralStopsAPreview() async throws {
        let (model, engine) = try await previewModel()
        defer { model.signOut() }
        model.togglePreview(Self.previewSong)
        await settle { engine.loads.count == 1 }
        model.previewPlayer.handle(.started(token: engine.loads[0].token))
        model.disconnectAurral()
        await settle { model.previewPlayer.phase == .idle }
        #expect(model.previewPlayer.phase == .idle)
    }

    /// Aurral's songs become preview items with their Deezer preview id; a song without one has none.
    @Test func aurralSongsBecomePreviewItems() async throws {
        let (model, _) = try await previewModel()
        defer { model.signOut() }
        let client = try #require(model.aurralClient)
        let trending = try await client.trending()
        let songs = try #require(trending.songs?.items)
        let items = songs.map(model.previewItem(for:))
        #expect(items.first?.previewId == "3135556")
        #expect(items.first?.title == "Harbour Lights" && items.first?.artist == "Stub Arrows")
        #expect(items.first?.artworkURL?.host() == "cdn-images.dzcdn.net")
        #expect(Set(items.map(\.id)).count == items.count)
    }
}
