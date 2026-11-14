import MagpieCore
import SwiftUI

/// Settings › Playback: streaming quality per network, volume levelling, the sleep timer's default, swipe actions and
/// asking before replacing the queue (R12).
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
            Section {
                swipePicker("Swipe right", binding(\.swipeRight))
                swipePicker("Swipe left", binding(\.swipeLeft))
            } header: {
                Text("Swipe actions")
            } footer: {
                Text("On a song. Where a row has its own Remove, swipe left shows both, and Remove always takes a second tap.")
            }
            Section {
                Toggle("Ask before replacing the queue", isOn: binding(\.askBeforeReplacingQueue))
                    .accessibilityIdentifier("ask-before-replacing")
            } footer: {
                Text("When you tap a song to play while other songs are queued. Never in the car.")
            }
            lyricsSection
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Round 27 L (owner, 2026-11-14, item 15, Q1 yes): Find lyrics online, off by default, the phone's own (D311).
    static let findOnlineFooter = "When your library has no lyrics for a song, Magpie looks them up on LRCLIB, a free lyrics site. It sends only the song\u{2019}s title, artist, album and length."

    private var lyricsSection: some View {
        @Bindable var keeper = model.lyricsKeeper
        return Section {
            Toggle("Find lyrics online", isOn: $keeper.findOnline)
                .accessibilityIdentifier("find-lyrics-online")
        } header: {
            Text("Lyrics")
        } footer: {
            Text(Self.findOnlineFooter)
        }
    }

    private func swipePicker(_ title: String, _ selection: Binding<SwipeAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(SwipeAction.allCases, id: \.self) { Text(QueueCopy.title($0)).tag($0) }
        }
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
