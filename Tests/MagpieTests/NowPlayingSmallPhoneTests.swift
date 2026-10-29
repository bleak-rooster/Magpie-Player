import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// T10b (D43): on the smallest iOS 27 phone (375 × 667 pt) Now Playing has no page scroll view at the default text
/// size, and has one at accessibility sizes (D15). Hosted in a real 375 × 667 window so the measuring pass settles
/// (ImageRenderer draws a single pass), then drawn to a PNG for the report. Hittability is the UI test's job.
@MainActor @Suite(.serialized) struct NowPlayingSmallPhoneTests {
    @Test func smallestPhoneFitsWithoutScrolling() async throws {
        let name = "now-playing-small-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        let songs = [
            Song(id: "s1", title: "North by Northwest", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 200),
            Song(id: "s2", title: "Compass Rose", artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 180),
        ]
        model.player.play(songs, startAt: 0)
        #expect(model.player.queue.current?.song.id == "s1")

        let (window, host) = try await Self.host(NowPlayingView().environment(model).magpieTheme(model.theme))
        defer { window.isHidden = true }
        #expect(!Self.containsScrollView(host.view), "the page scrolls at the default text size")

        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        #expect(image.size == CGSize(width: 375, height: 667))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("now-playing-375x667.png")
        try image.pngData()?.write(to: out)
        print("T10b small-phone render: \(out.path)")

        // At accessibility sizes the page scrolls instead, so no text is clipped (D15).
        let (axWindow, axHost) = try await Self.host(NowPlayingView().environment(model).magpieTheme(model.theme)
            .environment(\.dynamicTypeSize, .accessibility2))
        defer { axWindow.isHidden = true }
        #expect(Self.containsScrollView(axHost.view), "accessibility sizes must scroll")
    }

    /// A 375 × 667 window, given time for the parts to measure themselves and the art to take what is left.
    private static func host(_ view: some View) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        return (window, host)
    }

    private static func containsScrollView(_ view: UIView) -> Bool {
        view is UIScrollView || view.subviews.contains(where: containsScrollView)
    }
}
