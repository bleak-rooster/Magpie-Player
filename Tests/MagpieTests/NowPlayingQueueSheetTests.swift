import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// QC (crash report #5): Now Playing measures its parts and lays out again when a stored height changes (T10b). With
/// the Queue sheet open over it (medium, then large) and the song playing, the stores reach a bound and stop: no
/// layout loop behind the sheet. Hosted like the app: Now Playing a sheet over the root, Queue a sheet over that.
@MainActor @Suite(.serialized) struct NowPlayingQueueSheetTests {
    @MainActor final class Writes { var log: [(String, CGFloat)] = [] }

    @Test(arguments: [DesignSystem.Character.signature, .classic, .immersive])
    func heightStoresStopWithTheQueueOpen(_ character: DesignSystem.Character) async throws {
        let name = "np-queue-sheet-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play((0..<600).map { i in
            Song(id: "s\(i % 7)", title: "Song \(i % 7) with a title long enough to wrap onto a second line",
                 artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: 200)
        }, startAt: 0)
        var theme = model.theme
        theme.character = character

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let writes = Writes()
        let nowPlaying = UIHostingController(rootView: NowPlayingView().environment(model).magpieTheme(theme)
            .environment(\.nowPlayingHeightProbe) { key, height in writes.log.append((key, height)) })
        root.present(nowPlaying, animated: false)
        try await play(model, for: .seconds(1))
        let measured = writes.log.count
        #expect(measured > 0, "Now Playing measured its parts")

        let queue = UIHostingController(rootView: QueueView().environment(model).magpieTheme(theme))
        if let sheet = queue.sheetPresentationController { sheet.detents = [.medium(), .large()] }
        nowPlaying.present(queue, animated: true)
        try await play(model, for: .seconds(1))
        queue.sheetPresentationController?.animateChanges {
            queue.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        try await play(model, for: .seconds(1))
        let settled = writes.log.count
        try await play(model, for: .seconds(1))

        let afterQueue = writes.log.dropFirst(measured)
        #expect(afterQueue.count <= 6, "stores behind the Queue sheet: \(afterQueue.map { "\($0.0)=\($0.1)" })")
        #expect(writes.log.count == settled, "still storing heights after 2 s: \(writes.log.dropFirst(settled).map { "\($0.0)=\($0.1)" })")
        queue.dismiss(animated: false)
        nowPlaying.dismiss(animated: false)
    }

    /// Lets the page lay out for `duration` while the song plays on (a time tick every 100 ms).
    private func play(_ model: AppModel, for duration: Duration) async throws {
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            if let id = model.player.queue.current?.id {
                model.player.handle(.time(id, model.player.position + 0.1, duration: 200))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
