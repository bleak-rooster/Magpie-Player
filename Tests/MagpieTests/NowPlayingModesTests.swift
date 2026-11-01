import CarPlay
import Foundation
import MagpieCore
import MediaPlayer
import Playback
import Testing
@testable import CarPlayUI
@testable import Magpie

/// R6: shuffle and repeat on Now Playing. Repeat one restarts the song at its end while next and previous behave as
/// usual; the phone's buttons drive the same player state the car's do, so CarPlay's buttons mirror them (One too).
@MainActor @Suite(.serialized) struct NowPlayingModesTests {
    let engine = FakeEngine()

    private func makePlayer() -> Player {
        Player(engine: engine, scrobbler: FakeScrobbler(), urls: FakeURLs())
    }

    @Test func repeatOneRestartsTheSongAtItsEndAndSkipsAsUsual() {
        let player = makePlayer()
        player.play([PlayerTests.song("1"), PlayerTests.song("2"), PlayerTests.song("3")], startAt: 0)
        PlayerModeControls.cycleRepeat(player)
        PlayerModeControls.cycleRepeat(player)
        #expect(player.repeatMode == .one)
        let first = player.queue.current!.id
        player.handle(.time(first, 150, duration: 200))
        player.handle(.ended(first))
        #expect(player.queue.current?.id == first, "the same song again")
        #expect(player.position == 0 && player.isPlaying)
        #expect(engine.setItemsCalls.last!.items.map(\.0) == [first], "reloaded from the start, nothing prefetched")

        player.next()
        #expect(player.queue.current?.song.id == "2", "next moves on as usual")
        #expect(player.repeatMode == .one)
        player.previous()
        #expect(player.queue.current?.song.id == "1", "previous goes back as usual")
        player.next(); player.next()
        #expect(player.queue.current?.song.id == "3")
        player.handle(.ended(player.queue.current!.id))
        #expect(player.queue.current?.song.id == "3" && player.isPlaying, "the last song repeats too")
    }

    @Test func buttonsCycleAndSpeakTheirState() {
        let player = makePlayer()
        player.play([PlayerTests.song("1"), PlayerTests.song("2")], startAt: 0)
        #expect(PlayerModeControls.shuffleValue(player) == "Off")
        PlayerModeControls.toggleShuffle(player)
        #expect(player.isShuffled && PlayerModeControls.shuffleValue(player) == "On")
        PlayerModeControls.toggleShuffle(player)
        #expect(!player.isShuffled)

        var seen: [(RepeatMode, String, String)] = []
        for _ in 0..<3 {
            PlayerModeControls.cycleRepeat(player)
            seen.append((player.repeatMode, PlayerModeControls.repeatSymbol(player.repeatMode),
                         PlayerModeControls.repeatValue(player.repeatMode)))
        }
        #expect(seen.map(\.0) == [.all, .one, .off])
        #expect(seen.map(\.1) == ["repeat", "repeat.1", "repeat"])
        #expect(seen.map(\.2) == ["All", "One", "Off"])
        // The system's (lock screen, CarPlay) current types follow at once.
        PlayerModeControls.cycleRepeat(player); PlayerModeControls.cycleRepeat(player)
        #expect(MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType == .one)
        PlayerModeControls.toggleShuffle(player)
        #expect(MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType == .items)
    }

    /// The car's shuffle and repeat buttons are system buttons drawn from the remote command centre's current types
    /// (CarPlay ignores `isSelected` on them outside a car session), and the controller rebuilds them from the player.
    /// So: the phone's taps set the types the car draws (One included), and the car's taps (the same bridge calls)
    /// show on the phone's buttons.
    @Test func carPlayButtonsMirrorThePhone() async throws {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: engine,
                             defaults: UserDefaults(suiteName: "NowPlayingModesTests.\(UUID().uuidString)")!,
                             systemNowPlaying: false, notifications: false)
        let player = model.player
        player.play([PlayerTests.song("1"), PlayerTests.song("2")], startAt: 0)
        let controller = CarPlayController(interfaceController: FakeCarInterface(), library: CarPlayLibraryAdapter(model: model),
                                           player: player)
        defer { controller.disconnect() }
        let commands = MPRemoteCommandCenter.shared()

        // Phone → car.
        PlayerModeControls.toggleShuffle(player)
        #expect(commands.changeShuffleModeCommand.currentShuffleType == .items)
        #expect(CarPlayController.modeSelection(of: player) == .init(shuffle: true, repeating: false))
        PlayerModeControls.cycleRepeat(player)
        #expect(commands.changeRepeatModeCommand.currentRepeatType == .all)
        PlayerModeControls.cycleRepeat(player)
        #expect(commands.changeRepeatModeCommand.currentRepeatType == .one, "the car draws Repeat One from this")
        #expect(CarPlayController.modeSelection(of: player) == .init(shuffle: true, repeating: true))
        #expect(CPNowPlayingTemplate.shared.nowPlayingButtons.contains { $0 is CPNowPlayingRepeatButton })
        #expect(CPNowPlayingTemplate.shared.nowPlayingButtons.contains { $0 is CPNowPlayingShuffleButton })

        // Car → phone: the car's buttons and the remote commands run the same bridge calls.
        NowPlayingBridge.repeatCommandAction(player, .repeatMode(.off))
        NowPlayingBridge.shuffleCommandAction(player, .shuffle(.off))
        #expect(PlayerModeControls.repeatValue(player.repeatMode) == "Off")
        #expect(PlayerModeControls.shuffleValue(player) == "Off")
        #expect(CarPlayController.modeSelection(of: player) == .init(shuffle: false, repeating: false))
        NowPlayingBridge.repeatCommandAction(player, .repeatMode(.one))
        #expect(PlayerModeControls.repeatValue(player.repeatMode) == "One")
        #expect(PlayerModeControls.repeatSymbol(player.repeatMode) == "repeat.1")
        NowPlayingBridge.repeatCommandAction(player, .repeatMode(.off))
    }
}
