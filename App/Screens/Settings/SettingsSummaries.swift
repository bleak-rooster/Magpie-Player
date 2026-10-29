import DesignSystem
import SwiftUI

/// A Settings row's one-line summary; a warning carries its symbol too (D3).
struct SettingsSummary: Equatable {
    var text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }
}

/// The summaries of the top-level rows whose pages don't own one (T21b). Row titles name no service (§5).
enum SettingsSummaries {
    /// "homeserver · jordan"; a Local Network that is off, or a plain-http public address, shows instead.
    static func account(bases: [URL], username: String?, localNetworkDenied: Bool) -> SettingsSummary {
        guard let username, let first = bases.first else { return SettingsSummary("Not signed in") }
        if localNetworkDenied { return SettingsSummary("Local network access is off", symbol: "network.slash") }
        if bases.contains(where: ServerAddress.isUnencryptedPublic) {
            return SettingsSummary(ConnectErrorCopy.notEncrypted, symbol: "lock.open")
        }
        return SettingsSummary("\(first.host ?? first.absoluteString) · \(username)")
    }

    @MainActor static func account(_ model: AppModel) -> SettingsSummary {
        account(bases: model.session?.endpoint.bases ?? [], username: model.session?.username,
                localNetworkDenied: model.localNetwork.state == .denied)
    }

    /// "Connected · Finds on", "Not connected", the address waiting for the owner's OK (T2), or "You're offline"
    /// while offline (Task 14 disables the page).
    static func requests(connected: Bool, awaitingConsent: Bool, finds: FindsStatus, offline: Bool = false) -> SettingsSummary {
        if offline { return SettingsSummary(AppModel.offlineCopy, symbol: "wifi.slash") }
        guard connected else { return SettingsSummary("Not connected") }
        if awaitingConsent { return SettingsSummary("\(LidarrConnectCopy.allowAddress) needed", symbol: "lock.open") }
        return SettingsSummary("Connected · Finds \(finds.summary.lowercased())")
    }

    @MainActor static func requests(_ model: AppModel) -> SettingsSummary {
        requests(connected: model.lidarr != nil, awaitingConsent: model.lidarrAwaitingConsent, finds: model.findsStatus,
                 offline: model.isOffline)
    }

    /// The character and the accent, "Signature · Sheen".
    static func appearance(_ theme: Theme) -> String {
        "\(CharacterCopy.title(theme.character)) · \(AccentSwatch.name(theme.accent))"
    }
}

/// A top-level Settings row: the page's symbol, its title, and the summary under it.
struct SettingsRow: View {
    let title: String
    let symbol: String
    let summary: SettingsSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Group {
                    if let warning = summary.symbol {
                        // Not a Label: inside the row's Label it would take the row's wide icon column.
                        HStack(spacing: 4) {
                            Image(systemName: warning).accessibilityHidden(true)
                            Text(summary.text)
                        }
                    } else {
                        Text(summary.text)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)   // never wraps, so the top level keeps its height (controller ruling)
                .truncationMode(.tail)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// T2 (D3): a row's value, with "Not encrypted" under it when `base` is plain http outside home and Tailscale.
struct AddressValue: View {
    let value: String
    let base: URL?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).multilineTextAlignment(.trailing)
            if let base, ServerAddress.isUnencryptedPublic(base) {
                Label(ConnectErrorCopy.notEncrypted, systemImage: "lock.open")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
