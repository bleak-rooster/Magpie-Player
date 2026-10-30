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
                StreamQualityPicker(title: "Wi-Fi", selection: binding(\.wifi))
                StreamQualityPicker(title: "Mobile data", selection: binding(\.cellular))
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

    /// The Settings row's value: the Wi-Fi quality, then mobile data's when it differs ("Original · AAC 160 kbps on mobile").
    static func summary(_ prefs: PlaybackPreferences) -> String {
        let wifi = DownloadsSettingsView.formatTitle(prefs.wifi)
        return prefs.cellular == prefs.wifi ? wifi : "\(wifi) · \(DownloadsSettingsView.formatTitle(prefs.cellular)) on mobile"
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
