import DesignSystem
import Foundation
import MagpieCore
import Playback
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Owner report (TestFlight 0.0.1 build 3): a crash on opening Queue while music played. The queue screen stays up
/// while the queue changes under it: a long queue holding the same song many times, Up Next, advances, moves,
/// removes (the current song too), shuffle, repeat, Clear and the end of the queue, in every look, editing or not.
@MainActor @Suite(.serialized) struct QueueStressTests {
    private func makeModel(_ defaults: UserDefaults, songs: Int) -> AppModel {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        // The same song more than once, as in a playlist.
        let list = (0..<songs).map { i in
            Song(id: "s\(i % 7)", title: "Song \(i % 7)", artist: "Artist", album: "Album", duration: 30)
        }
        model.player.play(list, startAt: 0)
        return model
    }

    private func settle(_ host: UIViewController, _ n: Int = 3) async throws {
        for _ in 0..<n {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }
    }

    @Test(arguments: [DesignSystem.Character.signature, .classic, .immersive], [false, true])
    func queueSurvivesChanges(_ character: DesignSystem.Character, editing: Bool) async throws {
        let name = "queue-stress-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults, songs: 600)
        let player = model.player
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        var theme = model.theme
        theme.character = character
        let host = UIHostingController(rootView: QueueView().environment(model).magpieTheme(theme).environment(\.editMode, .constant(editing ? .active : .inactive)))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await settle(host)

        for step in 0..<40 {
            switch step % 10 {
            case 0: player.playNext([Song(id: "s1", title: "Song 1", artist: "Artist", album: "Album", duration: 30)])
            case 1: if let next = player.queue.upcoming.first { player.handle(.itemChanged(next.id)) }
            case 2: player.addToEnd([Song(id: "s2", title: "Song 2", artist: "Artist", album: "Album", duration: 30)])
            case 3: player.setShuffled(!player.isShuffled)
            case 4: if let e = player.queue.upcoming.dropFirst(3).first { player.move(id: e.id, to: 0) }
            case 5: if let e = player.queue.upcoming.last { player.remove(id: e.id) }
            case 6: player.repeatMode = player.repeatMode.next
            case 7: player.next()
            case 8:
                if let c = player.queue.current { player.handle(.time(c.id, 10, duration: 30)) }
                // Keep re-resolves a find to its library song; Not for me takes a song out wherever it is.
                player.replaceSong(id: "s3", with: Song(id: "lib3", title: "Song 3", artist: "Artist", album: "Album", duration: 30))
            default:
                if let c = player.queue.current { player.remove(id: c.id) }
                if step == 39 { player.removeSongs(["s4"]) }
            }
            #expect(host.view.window != nil)
            try await settle(host, 2)
        }
        player.clearUpcoming()
        try await settle(host)
        if let c = player.queue.current { player.handle(.ended(c.id)) }
        try await settle(host)
    }
}
