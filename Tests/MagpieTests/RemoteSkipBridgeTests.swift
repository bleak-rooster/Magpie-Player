import CarPlay
import Foundation
import MagpieCore
import MediaPlayer
import Testing
@testable import CarPlayUI
@testable import Magpie
@testable import Playback

/// Round 24 G (owner item 11, D234): the car's next and previous go through the system's remote commands, which the
/// bridge registers. Hypotheses 4 (handler lifecycle) and 5 (the hop to the main actor) of plan §6 G; package tests
/// (`RemoteSkipTests`) hold hypotheses 1 to 3.
@MainActor @Suite(.serialized) struct RemoteSkipBridgeTests {
    static func song(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 200, libraryId: 1) }

    static var allCommands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand,
                c.changePlaybackPositionCommand, c.changeShuffleModeCommand, c.changeRepeatModeCommand, c.likeCommand]
    }

    func player() -> Player {
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        player.play(["a", "b", "c"].map(Self.song), startAt: 0)
        return player
    }

    /// Each command has exactly one handler of this bridge, and it is on.
    func expectOneTargetEach(_ bridge: NowPlayingBridge) {
        let registered = bridge.registeredCommands.map(ObjectIdentifier.init)
        #expect(registered.count == Self.allCommands.count)
        for command in Self.allCommands {
            #expect(registered.filter { $0 == ObjectIdentifier(command) }.count == 1, "\(command)")
            #expect(command.isEnabled, "\(command)")
        }
    }

    // MARK: - Hypothesis 4: handler lifecycle

    /// A bridge registers each command once; invalidating removes them all; a new bridge registers each once again.
    @Test func bridge_reconnect_registersEachCommandOnce() {
        let player = player()
        let first = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        expectOneTargetEach(first)
        first.invalidate()
        #expect(first.registeredCommands.isEmpty)
        let second = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { second.invalidate() }
        expectOneTargetEach(second)
    }

    // MARK: - Hypothesis 5: the hop to the main actor

    /// On the main thread the skip has happened by the time the handler answers.
    @Test func commandHandler_onMain_skipsBeforeAnswering() {
        let player = player()
        let status = NowPlayingBridge.dispatch(.none, player: player) { p, _ in p.next() }
        #expect(status == .success)
        #expect(player.queue.current?.song.id == "b")
    }

    /// Off the main thread the skip still runs, on the main actor, exactly once.
    @Test func commandHandler_offMain_skipsOnceOnTheMainActor() async {
        let player = player()
        let runs = Runs()
        let status = await withCheckedContinuation { (done: CheckedContinuation<MPRemoteCommandHandlerStatus, Never>) in
            DispatchQueue.global().async {
                done.resume(returning: NowPlayingBridge.dispatch(.none, player: player) { p, _ in
                    runs.count += 1
                    runs.onMain = Thread.isMainThread
                    p.next()
                })
            }
        }
        #expect(status == .success)
        #expect(await eventually { runs.count == 1 })
        #expect(runs.onMain)
        #expect(player.queue.current?.song.id == "b")
    }

    @MainActor final class Runs {
        var count = 0
        var onMain = false
    }
}


/// Through the car's controller and the app's adapter (CarPlayRound13Tests' signed-in model and car).
extension CarPlayRound13Tests {
    /// The car connecting, going and connecting again (a CarPlay-only launch included) never touches the bridge's
    /// handlers: the app builds its one bridge with its model, never with a scene (hypothesis 4).
    @Test func carConnectDisconnectConnect_leavesTheHandlersAlone() async throws {
        let model = try await signedInModel()
        let bridge = NowPlayingBridge(player: model.player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { bridge.invalidate() }
        let expected = RemoteSkipBridgeTests.allCommands.map(ObjectIdentifier.init)
        for _ in 0..<2 {
            let (_, controller) = car(model)
            #expect(bridge.registeredCommands.map(ObjectIdentifier.init) == expected)
            controller.disconnect()
            #expect(bridge.registeredCommands.map(ObjectIdentifier.init) == expected)
        }
        #expect(RemoteSkipBridgeTests.allCommands.allSatisfy { $0.isEnabled })
    }

    /// Now Playing's own buttons (moved to CarPlayController+NowPlaying.swift): shuffle, repeat and the star always;
    /// Up Next on while there is a queue and off when it empties.
    @Test func carplay_nowPlayingButtons_enabledMatchQueue() async throws {
        let model = try await signedInModel()
        let (_, controller) = car(model)
        defer { controller.disconnect() }
        #expect(!CPNowPlayingTemplate.shared.isUpNextButtonEnabled, "nothing playing")
        let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
        #expect(buttons.contains { $0 is CPNowPlayingShuffleButton } && buttons.contains { $0 is CPNowPlayingRepeatButton })
        let songs = (0..<3).map { Song(id: "q\($0)", title: "Song \($0)", artist: "A", album: "B", duration: 60) }
        controller.start(songs, at: 0, shuffled: false)
        #expect(await eventually { CPNowPlayingTemplate.shared.isUpNextButtonEnabled })
        model.player.play([], startAt: 0)
        #expect(await eventually { !CPNowPlayingTemplate.shared.isUpNextButtonEnabled })
    }
}
