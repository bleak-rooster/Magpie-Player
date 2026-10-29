import Foundation
import Testing
import NavidromeKit
import MagpieCore
import MagpieTestSupport
import LidarrKit
@testable import Magpie

@MainActor @Suite(.serialized) struct PreferencesAppTests {
    let defaults = UserDefaults(suiteName: "magpie-tests-prefs-\(UUID().uuidString)")!
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: nil, transport: HostSwitchTransport(), probeTransport: HostSwitchTransport(), engine: FakeEngine(),
                 defaults: defaults, systemNowPlaying: false, notifications: false)
    }

    @Test func savesOneKeyPerChangedAreaAndReloads() {
        let model = makeModel()
        model.updatePreferences { $0.playback.cellular = .mp3_192 }
        #expect(defaults.data(forKey: "magpie.prefs.playback") != nil)
        #expect(defaults.data(forKey: "magpie.prefs.layout") == nil, "unchanged areas aren't written")
        #expect(makeModel().preferences.playback.cellular == .mp3_192)
    }

    @Test func corruptStoredAreaFallsBackWithoutCrashing() {
        defaults.set(Data([0xFF, 0x00]), forKey: "magpie.prefs.downloads")
        #expect(makeModel().preferences.downloads == .defaultValue)
    }

    @Test func extremeStoredIntegersLoadClamped() {
        defaults.set(Data(#"{"concurrent":9223372036854775807,"preDownload":-9223372036854775808}"#.utf8), forKey: "magpie.prefs.downloads")
        defaults.set(Data(#"{"rule":{"percent":9223372036854775807,"minutesCap":-9223372036854775808}}"#.utf8), forKey: "magpie.prefs.scrobbling")
        let model = makeModel()
        #expect(model.preferences.downloads.concurrent == 4 && model.preferences.downloads.preDownload == 0)
        #expect(model.preferences.scrobbling.rule == ScrobbleRule(percent: 90, minutes: 1))
    }

    @Test func extremeIntegersThroughUpdateClamp() {
        let model = makeModel()
        model.updatePreferences {
            $0.downloads.concurrent = Int.max; $0.downloads.preDownload = Int.min
            $0.scrobbling.rule = ScrobbleRule(percent: Int.max, minutes: Int.min)
        }
        #expect(model.preferences.downloads.concurrent == 4 && model.preferences.downloads.preDownload == 0)
        #expect(model.preferences.scrobbling.rule == ScrobbleRule(percent: 90, minutes: 1))
    }
}
