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
}
