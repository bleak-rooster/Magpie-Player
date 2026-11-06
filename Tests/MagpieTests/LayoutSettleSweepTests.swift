import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Crash hunt 3, item 3: every view that writes state from its own geometry (`onGeometryChange`: Now Playing's part
/// heights and Up next's height, the album grid's width) must settle. The build 3 watchdog kills (0x8BADF00D) were a
/// layout feedback loop of this kind. Each is hosted in a real window across phone and iPad sizes and text sizes up to
/// AX5, then resized (a rotation or a split view), and the writes are counted: bounded while laying out, none once
/// settled. (`ImmersiveBackdrop` and `Hallmark` read a `GeometryReader` without writing state, so they can't loop; no
/// view in the app uses a preference key.)
@MainActor @Suite(.serialized) struct LayoutSettleSweepTests {
    @MainActor final class Log { var writes: [String] = [] }

    nonisolated static let sizes: [CGSize] = [
        CGSize(width: 320, height: 568), CGSize(width: 375, height: 667), CGSize(width: 402, height: 874),
        CGSize(width: 440, height: 956), CGSize(width: 744, height: 1133), CGSize(width: 1032, height: 1376),
    ]
    nonisolated static let typeSizes: [DynamicTypeSize] = [.xSmall, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]

    private func window(_ size: CGSize) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        return window
    }

    /// Waits `seconds`, then returns how many writes came in meanwhile.
    private func writes(during seconds: Double, _ log: Log) async throws -> Int {
        let before = log.writes.count
        try await Task.sleep(for: .seconds(seconds))
        return log.writes.count - before
    }

    // MARK: - Now Playing

    @Test(arguments: sizes.indices, typeSizes)
    func nowPlayingHeightsSettle(sizeIndex: Int, typeSize: DynamicTypeSize) async throws {
        let size = Self.sizes[sizeIndex]
        let name = "settle-np-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play((0..<6).map {
            Song(id: "s\($0)", title: "A song title long enough to wrap onto a second line, number \($0)",
                 artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 200)
        }, startAt: 0)
        model.playbackHint = AppModel.transcodeHint   // the optional parts too
        let log = Log()
        let window = try window(size)
        defer { window.isHidden = true }
        window.rootViewController = UIHostingController(rootView: NowPlayingView().environment(model)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.nowPlayingHeightProbe) { key, height in log.writes.append("\(key)=\(height)") })
        try await Task.sleep(for: .seconds(0.8))
        let first = log.writes.count
        #expect(try await writes(during: 0.6, log) == 0, "\(size) \(typeSize): still storing: \(log.writes.suffix(8))")
        #expect(first <= 24, "\(size) \(typeSize): \(first) stores to lay out: \(log.writes.prefix(30))")

        // A rotation (width and height swapped), then back.
        for frame in [CGSize(width: size.height, height: size.width), size] {
            window.frame = CGRect(origin: .zero, size: frame)
            try await Task.sleep(for: .seconds(0.6))
            #expect(try await writes(during: 0.5, log) == 0, "\(frame) \(typeSize): no settle after resize: \(log.writes.suffix(8))")
        }
        #expect(log.writes.count <= 3 * 24, "\(size) \(typeSize): \(log.writes.count) stores in all")
    }

    // MARK: - Album grid

    enum GridHost: CaseIterable, Sendable { case verticalScroll, horizontalScroll, unconstrained }

    @Test(arguments: GridHost.allCases, typeSizes)
    func albumGridWidthSettles(host: GridHost, typeSize: DynamicTypeSize) async throws {
        let albums = (0..<30).map { Album(id: "a\($0)", name: "Album \($0) with a longer name", artist: "Artist", songCount: 1, duration: 0) }
        let name = "settle-grid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        let log = Log()
        let grid = AlbumGrid(albums: albums) { $0.artist }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { log.writes.append("\($0)") }
        let root: AnyView = switch host {
        case .verticalScroll: AnyView(ScrollView { grid })
        case .horizontalScroll: AnyView(ScrollView(.horizontal) { grid })
        case .unconstrained: AnyView(grid.fixedSize())
        }
        for size in Self.sizes {
            let window = try window(size)
            defer { window.isHidden = true }
            log.writes = []
            window.rootViewController = UIHostingController(rootView: NavigationStack { root }
                .environment(model).environment(\.dynamicTypeSize, typeSize))
            try await Task.sleep(for: .seconds(0.3))
            let first = log.writes.count
            #expect(try await writes(during: 0.3, log) == 0, "\(host) \(size) \(typeSize): still resizing: \(log.writes.suffix(6))")
            // R21 (D166): iOS 26's SwiftUI measures the grid's text at xSmall a few more times before it settles
            // (measured 7–10 sizes, the same every run); the settle check above holds there as on iOS 27.
            let budget = if #available(iOS 27, *) { 6 } else { 12 }
            #expect(first <= budget, "\(host) \(size) \(typeSize): \(first) sizes to lay out: \(log.writes)")
        }
    }
}
