import AVFoundation
import AVKit
import DesignSystem
import Foundation
import MagpieCore
import MediaPlayer
import Playback
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Round 21 (owner, 2026-11-06): "ensure Magpie can connect to bluetooth and all airplay features are available".
/// Now Playing has the system's output picker in every look (D167); the audio session suits AirPlay 2 and Bluetooth
/// (D168); losing the output in use pauses and nothing resumes on its own, a new output keeps playing (D168); iOS 26's
/// interruption notification reaches the engines like iOS 27's (D166); the lock screen, car and AirPlay receivers get
/// the song, its times and its rate (D169; the transport commands are pinned in PlaybackFlowsVerifyTests).
@MainActor @Suite(.serialized) struct AirPlayBluetoothTests {

    // MARK: - The output picker (D167)

    @Test(arguments: [DesignSystem.Character.signature, .classic, .immersive])
    func nowPlayingHasTheOutputPicker(_ character: DesignSystem.Character) async throws {
        let name = "np-output-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        model.player.play([Song(id: "s1", title: "North by Northwest", artist: "The Midnight Cartographers",
                                album: "Atlas of Small Hours", duration: 200)], startAt: 0)
        var theme = model.theme
        theme.character = character

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: NowPlayingView().environment(model).magpieTheme(theme))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        var picker: AVRoutePickerView?
        for _ in 0..<50 where picker == nil {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
            picker = Self.find(AVRoutePickerView.self, in: host.view)
        }
        let found = try #require(picker, "no output picker in Now Playing (\(character))")
        #expect(!found.prioritizesVideoDevices, "audio outputs first")
        #expect(found.isAccessibilityElement)
        #expect(found.accessibilityLabel == "Play on\u{2026}")
        #expect(found.accessibilityTraits.contains(.button))
        #expect(found.accessibilityValue?.isEmpty == false, "says where the sound plays now")
        #expect(found.bounds.width >= 44 && found.bounds.height >= 44, "44 pt target: \(found.bounds)")
        let accent = theme.colors(for: host.traitCollection.userInterfaceStyle == .dark ? .dark : .light).accentInkColor
        #expect(found.activeTintColor == UIColor(accent), "an output in use shows in the theme's accent")
    }

    /// The text that goes with the picker's colour (state is never colour alone): nothing for the phone itself, the
    /// output's own name and a symbol for anything else.
    @Test func outputDescriptionNamesOnlyOtherOutputs() {
        #expect(OutputRoute.describe([]) == nil)
        #expect(OutputRoute.describe([(.builtInSpeaker, "Speaker")]) == nil)
        #expect(OutputRoute.describe([(.builtInReceiver, "Receiver")]) == nil)
        #expect(OutputRoute.describe([(.airPlay, "Kitchen")]) == OutputRoute.Output(name: "Kitchen", symbol: "airplayaudio"))
        #expect(OutputRoute.describe([(.bluetoothA2DP, "Jordan's Headphones")])
                == OutputRoute.Output(name: "Jordan's Headphones", symbol: "headphones"))
        #expect(OutputRoute.describe([(.carAudio, "Car")]) == OutputRoute.Output(name: "Car", symbol: "car"))
        #expect(OutputRoute.describe([(.headphones, "Headphones")])?.symbol == "headphones")
        #expect(OutputRoute.describe([(.HDMI, "TV")])?.symbol == "hifispeaker")
        #expect(OutputRoute.describe([(.airPlay, "  ")]) == nil, "a nameless output says nothing")
        #expect(OutputRoute.spoken(nil, device: "iPhone") == "This iPhone")
        #expect(OutputRoute.spoken(OutputRoute.Output(name: "Kitchen", symbol: "airplayaudio"), device: "iPhone") == "Kitchen")
    }

    // MARK: - Route changes (D168)

    /// The output in use goes away (headphones out, Bluetooth or the car gone): playback pauses and stays paused.
    /// A new output (Bluetooth connects, an AirPlay speaker picked) keeps it playing.
    @Test func losingTheOutputPausesAndANewOneKeepsPlaying() async throws {
        let wav = try AVQueueEngineTests.silentWAV(seconds: 30)
        defer { try? FileManager.default.removeItem(at: wav) }
        let engine = AVQueueEngine(activateSession: {})
        let events = Events()
        let collector = Task { @MainActor in
            for await e in engine.events {
                if case .time = e { continue }
                events.log.append(e)
            }
        }
        defer { collector.cancel() }
        engine.setItems([(UUID(), wav)], startAt: 0)
        engine.play()
        try await Self.until { engine.playerRate > 0 }
        #expect(engine.playerRate > 0, "playing")

        Self.postRouteChange(.newDeviceAvailable)
        Self.postRouteChange(.categoryChange)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.playerRate > 0, "a new output keeps playing")
        #expect(!events.log.contains(.playing(false)), "\(events.log)")

        Self.postRouteChange(.oldDeviceUnavailable)
        try await Self.until { events.log.contains(.playing(false)) }
        #expect(events.log.contains(.playing(false)), "\(events.log)")
        #expect(engine.playerRate == 0, "paused")

        // Another output turning up later doesn't start it again on its own.
        Self.postRouteChange(.newDeviceAvailable)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.playerRate == 0, "no resume on its own")
        #expect(!events.log.contains(.playing(true)), "\(events.log)")
    }

    @Test func onlyALostOutputPauses() {
        func info(_ reason: AVAudioSession.RouteChangeReason) -> [AnyHashable: Any] {
            [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        }
        #expect(AudioSessionEvents.pausesPlayback(info(.oldDeviceUnavailable)))
        for reason in [AVAudioSession.RouteChangeReason.newDeviceAvailable, .categoryChange, .override, .wakeFromSleep,
                       .noSuitableRouteForCategory, .routeConfigurationChange, .unknown] {
            #expect(!AudioSessionEvents.pausesPlayback(info(reason)), "\(reason.rawValue)")
        }
        #expect(!AudioSessionEvents.pausesPlayback(nil))
    }

    // MARK: - Interruptions on iOS 26 (D166)

    @Test func classicInterruptionsReadLikeIOS27s() {
        typealias T = AVAudioSession.InterruptionType
        #expect(AudioSessionEvents.classicInterruption([AVAudioSessionInterruptionTypeKey: T.began.rawValue]) == .began)
        #expect(AudioSessionEvents.classicInterruption([
            AVAudioSessionInterruptionTypeKey: T.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]) == .ended(shouldResume: true))
        #expect(AudioSessionEvents.classicInterruption([AVAudioSessionInterruptionTypeKey: T.ended.rawValue])
                == .ended(shouldResume: false))
        #expect(AudioSessionEvents.classicInterruption([:]) == nil)
        #expect(AudioSessionEvents.classicInterruption(nil) == nil)
    }

    // MARK: - What receivers show, and the commands they send (D169)

    /// AirPlay receivers and car displays show the song, its album, its length, where it is and whether it plays;
    /// pausing and seeking keep the rate and the elapsed time current.
    @Test func nowPlayingInfoKeepsRateAndTimeCurrent() async throws {
        let player = Player(engine: FakeEngine(), scrobbler: FakeScrobbler(), urls: FakeURLs())
        let bridge = NowPlayingBridge(player: player, artworkURL: { _ in nil }, onLike: { _ in })
        defer { bridge.invalidate() }
        player.play([Song(id: "1", title: "Song One", artist: "Artist", album: "Album", duration: 180, libraryId: 1)], startAt: 0)
        let center = MPNowPlayingInfoCenter.default()
        try await Self.until { center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Song One" }
        var info = try #require(center.nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)

        player.toggle()
        try await Self.until { center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 }
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0, "paused shows as paused")

        player.seek(42)
        try await Self.until { center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 42 }
        info = try #require(center.nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 42)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 180)
    }

    // MARK: - Helpers

    @MainActor final class Events { var log: [EngineEvent] = [] }

    private static func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    private static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private static func find<V: UIView>(_ type: V.Type, in view: UIView) -> V? {
        if let v = view as? V { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }
}
