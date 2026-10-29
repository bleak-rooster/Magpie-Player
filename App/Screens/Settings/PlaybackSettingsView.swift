import MagpieCore
import SwiftUI

/// Settings › Playback: streaming quality per network, volume levelling and the sleep timer's default.
struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model

    private func binding<V>(_ keyPath: WritableKeyPath<PlaybackPreferences, V>) -> Binding<V> {
        Binding(get: { model.preferences.playback[keyPath: keyPath] },
                set: { value in model.updatePreferences { $0.playback[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section {
                Picker("Wi-Fi", selection: binding(\.wifi)) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Mobile data", selection: binding(\.cellular)) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Gapless works best with Original")
            }
            Section("Volume levelling") {
                Picker("ReplayGain", selection: binding(\.replayGain)) {
                    Text("Off").tag(ReplayGainMode.off)
                    Text("Same song volume").tag(ReplayGainMode.track)
                    Text("Same album volume").tag(ReplayGainMode.album)
                }
            }
            Section("Sleep timer") {
                Picker("Default", selection: binding(\.sleepTimer)) {
                    ForEach(SleepTimerOption.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func title(_ option: SleepTimerOption) -> String {
        switch option {
        case .m15: "15 min"
        case .m30: "30 min"
        case .m45: "45 min"
        case .m60: "60 min"
        case .m90: "90 min"
        case .endOfSong: "End of song"
        }
    }
}
