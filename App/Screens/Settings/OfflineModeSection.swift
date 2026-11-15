import SwiftUI

/// Round 28 O1 (owner, 2026-11-15, D323): Settings' first section, above Accounts & Servers: the **Offline mode**
/// switch, with a line under its title saying what is happening (plan §8). On: only music on this phone plays and
/// nothing is sent. Go offline automatically lives in Downloads & Storage.
///
/// Fix round 1: the switch's own change isn't announced (design M5, VoiceOver reads the new value); offline by itself
/// the section offers Try again under the line (design M3); with no connection the line says so (design M2); the
/// symbol sits on the line's first baseline (design L2).
struct OfflineModeSection: View {
    @Environment(AppModel.self) private var model

    /// Design M3: Try again shows only when Magpie went offline by itself.
    static func offersTryAgain(_ state: OfflineState) -> Bool { state == .automatic }

    var body: some View {
        let line = OfflineModeCopy.stateLine(for: model)
        let on = model.offlineModeOn
        Section {
            Toggle(isOn: Binding(get: { model.offlineModeOn }, set: { model.setOfflineMode(on: $0, fromSettings: true) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(OfflineModeCopy.title)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
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
            if Self.offersTryAgain(model.offlineState) {
                let checking = model.reachability.checking
                Button {
                    Task { await model.tryAgain() }
                } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView().accessibilityHidden(true) }
                        Text(checking ? OfflineNoticeCopy.trying : OfflineNoticeCopy.tryAgain)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .disabled(checking)
                .accessibilityIdentifier("settings-offline-try-again")
            }
        }
    }
}

/// Round 28 O1 (D323): the switches' words (plan §8; no service named; fix round 1's approved copy).
enum OfflineModeCopy {
    static let title = "Offline mode"
    static let manual = "Only music on this phone plays"
    static let offlineNow = "Offline for now: your library is out of reach"
    /// Fix round 1 (design M2, approved): no network path at all.
    static let noConnection = "Offline for now: no connection"
    static let automaticOn = "Goes offline by itself if your library is out of reach"
    static let automaticOff = "Stays online"
    static let automaticTitle = "Go offline automatically"
    /// Fix round 1 (design L1): names the no-connection case.
    static let automaticFooter = "When your library can’t be reached for 30 seconds, or at once with no connection, Magpie plays what’s on this phone and keeps trying to reconnect. It switches back by itself."

    /// The line under the switch, with its symbol (D3).
    static func stateLine(_ state: OfflineState, automatic: Bool, noConnection: Bool = false) -> SettingsSummary {
        switch state {
        case .manual: SettingsSummary(manual, symbol: "wifi.slash")
        case .automatic where noConnection: SettingsSummary(Self.noConnection, symbol: "wifi.slash")
        case .automatic: SettingsSummary(offlineNow, symbol: "wifi.exclamationmark")
        case .online, .suspect: SettingsSummary(automatic ? automaticOn : automaticOff, symbol: "wifi")
        }
    }

    @MainActor static func stateLine(for model: AppModel) -> SettingsSummary {
        stateLine(model.offlineState, automatic: model.goesOfflineAutomatically, noConnection: model.offlineNoConnection)
    }
}
