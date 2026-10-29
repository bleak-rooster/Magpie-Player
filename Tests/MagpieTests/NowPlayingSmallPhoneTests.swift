import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// T10b (D43): on the smallest iOS 27 phone (375 × 667 pt) every Now Playing part lies inside the screen, top to
/// bottom without overlap, and there is no page scroll view at the default text size; at accessibility sizes the
/// page scrolls instead (D15). Hosted in a real 375 × 667 window so the measuring pass settles (ImageRenderer draws
/// a single pass); the parts report their frames through `nowPlayingFrameProbe`. Hittability is the UI test's job.
@MainActor @Suite(.serialized) struct NowPlayingSmallPhoneTests {
    @MainActor final class Frames { var byPart: [String: CGRect] = [:] }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play([
            Song(id: "s1", title: "North by Northwest", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 200),
            Song(id: "s2", title: "Compass Rose", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 180),
        ], startAt: 0)
        return model
    }

    @Test func smallestPhoneFitsWithoutScrolling() async throws {
        let name = "now-playing-small-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults)
        #expect(model.player.queue.current?.song.id == "s1")

        let frames = Frames()
        let (window, host) = try await Self.host(model, frames)
        defer { window.isHidden = true }
        #expect(!Self.containsScrollView(host.view), "the page scrolls at the default text size")
        Self.expectFits(frames, in: window.bounds, order: ["top", "art", "meta", "scrubber", "transport", "upNext", "bottom"])
        try Self.render(window, "now-playing-375x667.png")

        // At accessibility sizes the page scrolls instead, so no text is clipped (D15).
        let (axWindow, axHost) = try await Self.host(model, Frames(), typeSize: .accessibility2)
        defer { axWindow.isHidden = true }
        #expect(Self.containsScrollView(axHost.view), "accessibility sizes must scroll")
    }

    /// The worst case: the playback hint and the error line both show. Up next makes way; everything else fits.
    @Test func smallestPhoneFitsWithHintAndError() async throws {
        let name = "now-playing-small-hint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults)
        model.playbackHint = AppModel.transcodeHint
        let entry = try #require(model.player.queue.current?.id)
        model.player.handle(.failed(entry, "The server stopped answering."))
        #expect(model.player.lastError != nil)

        let frames = Frames()
        let (window, host) = try await Self.host(model, frames)
        defer { window.isHidden = true }
        #expect(!Self.containsScrollView(host.view))
        Self.expectFits(frames, in: window.bounds, order: ["top", "art", "meta", "scrubber", "hint", "error", "transport", "bottom"])
        try Self.render(window, "now-playing-375x667-hint-error.png")
    }

    /// Every part in `order` laid out, inside `bounds`, each below the one before; the art at least 120 pt.
    private static func expectFits(_ frames: Frames, in bounds: CGRect, order: [String]) {
        var previous: (String, CGRect)?
        for key in order {
            guard let frame = frames.byPart[key] else { Issue.record("\(key) never laid out: \(frames.byPart.keys.sorted())"); continue }
            #expect(bounds.contains(frame), "\(key) at \(frame) is off the 375 × 667 screen")
            if let (prevKey, prev) = previous {
                #expect(frame.minY >= prev.maxY - 0.5, "\(key) \(frame) overlaps \(prevKey) \(prev)")
            }
            previous = (key, frame)
        }
        if let art = frames.byPart["art"] { #expect(art.height >= 119.5, "art \(art.height) pt") }
    }

    /// A 375 × 667 window, given time for the parts to measure themselves and the art to take what is left.
    private static func host(_ model: AppModel, _ frames: Frames,
                             typeSize: DynamicTypeSize = .large) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        let view = NowPlayingView().environment(model).magpieTheme(model.theme)
            .environment(\.dynamicTypeSize, typeSize)
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

    /// Draws the window to a PNG in the app's tmp folder, for the report.
    private static func render(_ window: UIWindow, _ file: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        #expect(image.size == CGSize(width: 375, height: 667))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        try image.pngData()?.write(to: out)
        print("T10b small-phone render: \(out.path)")
    }

    private static func containsScrollView(_ view: UIView) -> Bool {
        view is UIScrollView || view.subviews.contains(where: containsScrollView)
    }
}
