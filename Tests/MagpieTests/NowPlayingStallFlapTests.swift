import DesignSystem
import Foundation
import MagpieCore
import Playback
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Net crash hunt (owner report, builds 3/4: "crashes while a song buffers on a weak connection"; six build-3 logs, all
/// 0x8BADF00D with the main thread in a SwiftUI render, two of them in `NowPlayingPartReport`'s height store and in
/// `NowPlayingView.body`). A weak network makes the engine flap: playing / paused (the art's spring scale), stalls,
/// a failure (the error line comes and goes), the transcode hint, song changes and time ticks, all fast. With Now
/// Playing up, alone and with the Queue sheet over it, the height stores stay bounded and stop when the flapping does:
/// nothing the flapping animates feeds back into the layout.
@MainActor @Suite(.serialized) struct NowPlayingStallFlapTests {
    @MainActor final class Writes { var log: [(String, CGFloat)] = [] }

    @Test(arguments: [false, true], [DesignSystem.Character.signature, .classic, .immersive])
    func flappingPlaybackKeepsHeightStoresBounded(queueOpen: Bool, character: DesignSystem.Character) async throws {
        let name = "np-flap-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let engine = FakeEngine()
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: engine, defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play((0..<40).map { i in
            Song(id: "s\(i)", title: "Song \(i) with a title long enough to wrap onto a second line",
                 artist: "The Midnight Cartographers", album: "Atlas of Small Hours", duration: i % 3 == 0 ? 0 : 200)
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
        try await Task.sleep(for: .seconds(1))
        var queue: UIHostingController<AnyView>?
        if queueOpen {
            let q = UIHostingController(rootView: AnyView(QueueView().environment(model).magpieTheme(theme)))
            if let sheet = q.sheetPresentationController { sheet.detents = [.medium(), .large()] }
            nowPlaying.present(q, animated: true)
            queue = q
            try await Task.sleep(for: .seconds(1))
        }
        let before = writes.log.count

        // Three seconds of a weak network: every 40 ms the next thing a stalling stream does.
        let clock = ContinuousClock()
        let end = clock.now + .seconds(3)
        var step = 0
        while clock.now < end {
            let player = model.player
            guard let id = player.queue.current?.id else { break }
            switch step % 12 {
            case 0, 6: player.handle(.playing(false))
            case 1, 7: player.handle(.stalled)
            case 2, 8: player.handle(.playing(true))
            case 3: player.handle(.time(id, player.position + 0.5, duration: nil))
            case 4: player.handle(.failed(id, "The network connection was lost."))   // the error line shows
            case 5: player.toggle()   // play again: a reload clears the error
            case 9:
                if let next = player.queue.upcoming.first?.id { player.handle(.itemChanged(next)) }
            default: player.handle(.time(id, player.position + 0.5, duration: 200))
            }
            step += 1
            try await Task.sleep(for: .milliseconds(40))
        }
        let flapping = writes.log.dropFirst(before)
        // Let it settle, then nothing more may be stored.
        try await Task.sleep(for: .milliseconds(800))
        let settled = writes.log.count
        try await Task.sleep(for: .seconds(1))

        // The error line and the Up next row may each be measured once; nothing else changes height.
        // Cap 6: each part (error line, hint, Up next) may legitimately settle once per flap phase; a feedback loop blows far past it.
        #expect(flapping.count <= 6, "stores while flapping: \(flapping.map { "\($0.0)=\($0.1)" })")
        #expect(writes.log.count == settled, "still storing after the flapping stopped: \(writes.log.dropFirst(settled).map { "\($0.0)=\($0.1)" })")
        queue?.dismiss(animated: false)
        nowPlaying.dismiss(animated: false)
    }
}
