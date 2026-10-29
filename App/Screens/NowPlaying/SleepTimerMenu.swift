import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// The moon button: pick a sleep timer, or turn the running one off. Its VoiceOver value says what is set.
struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.sleepTimer
        let defaultOption = model.preferences.playback.sleepTimer
        Menu {
            ForEach(SleepTimerOption.allCases, id: \.self) { option in
                Button { timer.start(option) } label: {
                    Text(option == defaultOption
                         ? "\(PlaybackSettingsView.title(option)) (default)"
                         : PlaybackSettingsView.title(option))
                }
            }
            if timer.mode != .off {
                Divider()
                Button("Off", role: .destructive) { timer.cancel() }
            }
        } label: {
            // Re-read once a minute so the remaining time stays current.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let remaining = timer.remaining(at: context.date)
                VStack(spacing: 0) {
                    Image(systemName: timer.mode == .off ? "moon" : "moon.fill").font(.title3)
                    if let remaining {
                        Text("\(Self.minutes(remaining))")
                            .font(.system(.caption2, design: .rounded).monospacedDigit())
                    }
                }
                .frame(width: Tokens.minHitSize, height: Tokens.minHitSize)
                .contentShape(Rectangle())
                .accessibilityLabel("Sleep timer")
                .accessibilityValue(Self.value(timer.mode, remaining: remaining))
            }
        }
    }

    static func minutes(_ remaining: TimeInterval) -> Int { max(1, Int((remaining / 60).rounded(.up))) }

    static func value(_ mode: SleepTimer.Mode, remaining: TimeInterval?) -> String {
        switch mode {
        case .off: return "Off"
        case .endOfSong: return "End of song"
        case .at:
            let m = minutes(remaining ?? 0)
            return "Sleeping in \(m) \(m == 1 ? "minute" : "minutes")"
        }
    }
}
