import SwiftUI

/// Round 28 O1 (owner, 2026-11-15, D323): Settings' first section, above Accounts & Servers: the **Offline mode**
/// switch, with a line under its title saying what is happening (plan §8). On: only music on this phone plays and
/// nothing is sent. Go offline automatically lives in Downloads & Storage.
struct OfflineModeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let line = OfflineModeCopy.stateLine(model.offlineState, automatic: model.goesOfflineAutomatically)
        let on = model.offlineModeOn
        Section {
            Toggle(isOn: Binding(get: { model.offlineModeOn }, set: { model.setOfflineMode(on: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(OfflineModeCopy.title)
                    HStack(spacing: 4) {
                        Image(systemName: line.symbol ?? "wifi").accessibilityHidden(true)
                        Text(line.text)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(OfflineModeCopy.title)
            .accessibilityValue("\(on ? "On" : "Off"), \(line.text)")
            .accessibilityIdentifier("settings-offline-mode")
        }
    }
}

/// Round 28 O1 (D323): the switches' words (plan §8; no service named).
enum OfflineModeCopy {
    static let title = "Offline mode"
    static let manual = "Only music on this phone plays"
    static let offlineNow = "Offline for now: your library is out of reach"
    static let automaticOn = "Goes offline by itself if your library is out of reach"
    static let automaticOff = "Stays online"
    static let automaticTitle = "Go offline automatically"
    static let automaticFooter = "When your library can’t be reached for 30 seconds, Magpie plays what’s on this phone and keeps trying to reconnect. It switches back by itself."

    /// The line under the switch, with its symbol (D3).
    static func stateLine(_ state: OfflineState, automatic: Bool) -> SettingsSummary {
        switch state {
        case .manual: SettingsSummary(manual, symbol: "wifi.slash")
        case .automatic: SettingsSummary(offlineNow, symbol: "wifi.exclamationmark")
        case .online, .suspect: SettingsSummary(automatic ? automaticOn : automaticOff, symbol: "wifi")
        }
    }
}
