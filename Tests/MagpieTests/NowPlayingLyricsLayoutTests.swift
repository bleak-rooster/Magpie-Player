import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// P6 (priority round): lyrics mode fills everything between the top bar and the scrubber. The title and artist
/// collapse to one compact line above the scrubber, Up next and the playback hint go, the transport and bottom row
/// stay, and the page still never scrolls at the default size (D43): only the lyrics scroll, inside their area.
/// Hosted in real windows (375 × 667 and 430 × 932) so the measuring pass settles, like `NowPlayingSmallPhoneTests`.
@MainActor @Suite(.serialized) struct NowPlayingLyricsLayoutTests {
    @MainActor final class Frames { var byPart: [String: CGRect] = [:] }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play([
            Song(id: "s1", title: "North by Northwest", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 200),
            Song(id: "s2", title: "Compass Rose", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 180),
        ], startAt: 0)
        model.playbackHint = AppModel.transcodeHint
        return model
    }

    @Test(arguments: [CGSize(width: 375, height: 667), CGSize(width: 430, height: 932)])
    func lyricsFillTheScreenWithoutPageScroll(_ size: CGSize) async throws {
        let name = "now-playing-lyrics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults)

        let art = Frames()
        let (artWindow, _) = try await Self.host(model, art, size: size, lyrics: false)
        artWindow.isHidden = true
        let artSlot = try #require(art.byPart["art"])

        let frames = Frames()
        let (window, host) = try await Self.host(model, frames, size: size, lyrics: true)
        defer { window.isHidden = true }
        let lyrics = try #require(frames.byPart["lyrics"], "lyrics never laid out: \(frames.byPart.keys.sorted())")

        // At least 1.6 × the art slot's height, the full content width.
        #expect(lyrics.height >= 1.6 * artSlot.height, "lyrics \(lyrics.height) pt vs art \(artSlot.height) pt at \(size)")
        #expect(lyrics.width >= size.width - 2 * Tokens.Spacing.xxl - 0.5)
        // Everything fits, top to bottom, without overlap: the compact title line sits right above the scrubber.
        Self.expectFits(frames, in: window.bounds, order: ["top", "lyrics", "metaCompact", "scrubber", "transport", "bottom"])
        // Up next and the hint are gone while lyrics show (their probes only report while laid out).
        #expect(frames.byPart["upNext"] == nil && frames.byPart["hint"] == nil, "\(frames.byPart.keys.sorted())")
        // No page scroll: any scroll view is the lyrics' own, inside their area.
        for scroll in Self.scrollViews(host.view) {
            let frame = scroll.convert(scroll.bounds, to: window)
            #expect(lyrics.insetBy(dx: -0.5, dy: -0.5).contains(frame), "a scroll view at \(frame) outside the lyrics \(lyrics)")
        }
        try Self.render(window, "now-playing-lyrics-\(Int(size.width))x\(Int(size.height)).png")

        // Leaving lyrics mode restores the art layout.
        let back = Frames()
        let (backWindow, _) = try await Self.host(model, back, size: size, lyrics: false)
        defer { backWindow.isHidden = true }
        #expect(back.byPart["art"].map { abs($0.height - artSlot.height) < 1 } == true)
        #expect(back.byPart["meta"] != nil && back.byPart["metaCompact"] == nil)
    }

    @Test func lyricsHeightTakesWhatTheRestLeaves() {
        let parts: CGFloat = 44 + 22 + 50 + 76 + 44 + 32
        let h = NowPlayingLayout.lyricsHeight(available: CGSize(width: 327, height: 667), parts: parts, gaps: 5)
        #expect(h == 667 - parts - 5 * NowPlayingLayout.lyricsSpacing)
        #expect(NowPlayingLayout.lyricsHeight(available: CGSize(width: 327, height: 200), parts: parts, gaps: 5) == 120)
    }

    private static func expectFits(_ frames: Frames, in bounds: CGRect, order: [String]) {
        var previous: (String, CGRect)?
        for key in order {
            guard let frame = frames.byPart[key] else { Issue.record("\(key) never laid out: \(frames.byPart.keys.sorted())"); continue }
            #expect(bounds.contains(frame), "\(key) at \(frame) is off the \(bounds.size) screen")
            if let (prevKey, prev) = previous {
                #expect(frame.minY >= prev.maxY - 0.5, "\(key) \(frame) overlaps \(prevKey) \(prev)")
            }
            previous = (key, frame)
        }
    }

    private static func host(_ model: AppModel, _ frames: Frames, size: CGSize,
                             lyrics: Bool) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let view = NowPlayingView(showingLyrics: lyrics).environment(model).magpieTheme(model.theme)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.nowPlayingFrameProbe) { key, frame in frames.byPart[key] = frame }
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        return (window, host)
    }

    private static func render(_ window: UIWindow, _ file: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        try image.pngData()?.write(to: out)
        print("P6 lyrics render: \(out.path)")
    }

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
