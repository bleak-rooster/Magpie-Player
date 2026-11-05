import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import MediaPlayer
import Playback
import Testing
import UIKit
@testable import Magpie

private let c1Artist = MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711")!
private let c1Harbour = MBID("5e0c3c2a-1111-4a6e-9d2c-7b1a2f3e4d51")!
/// ListenBrainz's `release_mbid` (no front in the Cover Art Archive) and `caa_release_mbid` (the release it has art for).
private let c1Release = MBID("b5cdfb5f-35a5-4bc5-bbca-57839a71813a")!
private let c1CAARelease = MBID("59c3d6a7-6fdb-4d99-9135-ade798449106")!

private let c1PNG: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
    UIColor.orange.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
}

/// Round 15 C1 (owner items 3 and 4, D126–D127): an outside artist page's Top songs show each song's cover, and a
/// 30-second preview shows its row's cover in the mini player and on the Lock Screen. Stub Aurral 2.13 (plain http, its
/// own host name), a mock Navidrome and ListenBrainz, and a stub for the Cover Art Archive: nothing reaches the internet.
extension Round14ActionsTests {
    private func stubListenBrainzTopSongs() {
        transport.navidrome.stub(pathSuffix: "/1/popularity/top-recordings-for-artist/\(c1Artist.rawValue)",
                                 body: Data(#"""
            [{"artist_mbids":["\#(c1Artist.rawValue)"],"artist_name":"Stub Arrows","recording_mbid":"\#(c1Harbour.rawValue)",
              "recording_name":"Harbour Lights","release_mbid":"\#(c1Release.rawValue)","release_name":"Harbour Lights",
              "caa_release_mbid":"\#(c1CAARelease.rawValue)","caa_id":42,"length":197000}]
            """#.utf8))
    }

    // MARK: - Owner item 3: Top songs on an outside artist page

    /// The server's top songs (Automatic): each names its cover, shown through the server's image proxy.
    @Test func c1ServerTopSongsShowTheirCovers() async throws {
        let model = try await model()
        defer { model.signOut() }
        let result = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: c1Artist))
        #expect(result.provider == .aurral && !result.rows.isEmpty)
        for row in result.rows {
            #expect(row.library == nil)
            #expect(row.artwork != nil, "row \(row.id) names its cover")
            #expect(await model.topSongArtwork(row, side: 48) != nil, "row \(row.id) shows it")
        }
        #expect(aurral.imageProxySources.count == result.rows.count, "each through the image proxy")
    }

    /// ListenBrainz's top songs: the release ListenBrainz has art for (`caa_release_mbid`).
    @Test func c1ListenBrainzTopSongsShowTheirReleasesCover() async throws {
        let model = try await model(listenBrainzToken: "tok")
        defer { model.signOut() }
        let outside = MockTransport()
        outside.stub(pathSuffix: "/release/\(c1CAARelease.rawValue)/front-250", body: c1PNG, headers: ["Content-Type": "image/png"])
        AppModel.outsideArtTransportForTesting = outside
        defer { AppModel.outsideArtTransportForTesting = nil }
        stubListenBrainzTopSongs()
        model.updatePreferences { $0.layout.artistTopSongs = .listenBrainz }
        let result = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: c1Artist))
        let row = try #require(result.rows.first)
        #expect(result.provider == .listenBrainz && row.library == nil)
        #expect(row.cover == .release(c1CAARelease))
        #expect(await model.topSongArtwork(row, side: 48) != nil)
        #expect(outside.requests.map { $0.url?.path } == ["/release/\(c1CAARelease.rawValue)/front-250"])
    }

    /// No front anywhere public: the picture the server names for its matched preview, then the placeholder.
    @Test func c1AListenBrainzTopSongWithoutAFrontTakesItsPreviewsPicture() async throws {
        let model = try await model(listenBrainzToken: "tok")
        defer { model.signOut() }
        let outside = MockTransport()   // every Cover Art Archive answer is a 404
        AppModel.outsideArtTransportForTesting = outside
        defer { AppModel.outsideArtTransportForTesting = nil }
        stubListenBrainzTopSongs()
        model.updatePreferences { $0.layout.artistTopSongs = .listenBrainz }
        let row = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: c1Artist)?.rows.first)
        #expect(row.artwork != nil, "the matched preview's picture")
        #expect(await model.topSongArtwork(row, side: 48) != nil)
        #expect(aurral.imageProxySources.count == 1)
    }

    // MARK: - Owner item 4: a preview's cover in the mini player and on the Lock Screen

    /// The preview carries its row's picture; the mini player shows it.
    @Test func c1APreviewCarriesItsRowsCoverIntoThePlayer() async throws {
        let model = try await model()
        defer { model.signOut() }
        let song = try #require(await model.artistTopSongs(name: "Stub Arrows", mbid: c1Artist)?.rows.first?.preview)
        let item = model.previewItem(for: song)
        #expect(item.artworkKey == song.artwork?.raw)
        #expect(await model.previewArtwork(item, side: 36) != nil)
        // Nothing named: the placeholder, and nothing asked.
        let asked = aurral.requests.count
        let bare = PreviewItem(id: "x", previewId: "1", title: "T", artist: "A")
        #expect(await model.previewArtwork(bare, side: 36) == nil)
        #expect(aurral.requests.count == asked)
    }

    /// The Lock Screen (Now Playing) shows the preview's cover while it plays, and drops it when the main song is back.
    @Test func c1TheLockScreenShowsThePreviewsCover() async throws {
        let engine = C1SilentEngine()
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        let preview = PreviewPlayer(engine: engine, mainPlayer: player)
        preview.lookup = { _ in .playable(Data("clip".utf8)) }
        let picture = try #require(UIImage(data: c1PNG))
        var asked: [String] = []
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in },
                                      previewArtwork: { item in asked.append(item.id); return picture }, preview: preview)
        defer { bridge.invalidate() }
        preview.play([PreviewItem(id: "a", previewId: "1", title: "Harbour Lights", artist: "Stub Arrows",
                                  artworkKey: "https://cdn-images.dzcdn.net/images/cover/3135556/250x250-000000-80-0-0.jpg")])
        for _ in 0..<200 where engine.loads.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let token = try #require(engine.loads.last)
        preview.handle(.started(token: token))
        let center = MPNowPlayingInfoCenter.default()
        for _ in 0..<250 where center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Harbour Lights")
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil, "the preview's cover on the Lock Screen")
        #expect(asked == ["a"])
    }

    /// Fix round (review minor 2): the cover follows the preview. The next preview shows none until its own cover
    /// arrives (never the last one's), and when previews stop the main song comes back without the preview's cover.
    @Test func c1TheLockScreenCoverFollowsThePreviewAndGoesWithIt() async throws {
        let engine = C1SilentEngine()
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        player.play([Song(id: "1", title: "Song One", artist: "Artist", album: "Album", duration: 180, libraryId: 1)], startAt: 0)
        let preview = PreviewPlayer(engine: engine, mainPlayer: player)
        preview.lookup = { _ in .playable(Data("clip".utf8)) }
        let picture = try #require(UIImage(data: c1PNG))
        let gate = C1Gate()
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in },
                                      previewArtwork: { item in
                                          gate.asked.append(item.id)
                                          while item.id == "b", !gate.releaseB { try? await Task.sleep(for: .milliseconds(10)) }
                                          return picture
                                      }, preview: preview)
        defer { bridge.invalidate() }
        let center = MPNowPlayingInfoCenter.default()
        func info(_ key: String) -> Any? { center.nowPlayingInfo?[key] }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        }
        func start() async throws {
            let before = engine.loads.count
            for _ in 0..<200 where engine.loads.count == before { try await Task.sleep(for: .milliseconds(10)) }
            preview.handle(.started(token: try #require(engine.loads.last)))
        }
        let link = "https://cdn-images.dzcdn.net/images/cover/1/250x250-000000-80-0-0.jpg"
        preview.play([PreviewItem(id: "a", previewId: "1", title: "Harbour Lights", artist: "Stub Arrows", artworkKey: link),
                      PreviewItem(id: "b", previewId: "2", title: "Paper Moon", artist: "Stub Arrows", artworkKey: link)])
        try await start()
        try await waitFor { info(MPMediaItemPropertyTitle) as? String == "Harbour Lights" && info(MPMediaItemPropertyArtwork) != nil }
        #expect(info(MPMediaItemPropertyArtwork) != nil, "A's cover")

        preview.next()
        try await start()
        try await waitFor { info(MPMediaItemPropertyTitle) as? String == "Paper Moon" && gate.asked.contains("b") }
        #expect(info(MPMediaItemPropertyTitle) as? String == "Paper Moon")
        #expect(info(MPMediaItemPropertyArtwork) == nil, "never A's cover while B's loads")
        gate.releaseB = true
        try await waitFor { info(MPMediaItemPropertyArtwork) != nil }
        #expect(info(MPMediaItemPropertyArtwork) != nil, "B's cover once it arrives")
        #expect(gate.asked == ["a", "b"])

        preview.stop()
        try await waitFor { info(MPMediaItemPropertyTitle) as? String == "Song One" }
        #expect(info(MPMediaItemPropertyTitle) as? String == "Song One", "the main song is back")
        #expect(info(MPMediaItemPropertyArtwork) == nil, "without the preview's cover")
    }
}

/// What the Lock Screen test's cover source was asked, and when B's cover may arrive.
@MainActor final class C1Gate {
    var asked: [String] = []
    var releaseB = false
}

/// A preview engine that plays nothing and reports nothing.
@MainActor final class C1SilentEngine: PreviewEngine {
    let events = AsyncStream<PreviewEngineEvent> { $0.finish() }
    var loads: [Int] = []
    func load(_ clip: Data, token: Int, at: TimeInterval) { loads.append(token) }
    func pause() {}
    func resume() {}
    func stop() {}
}
