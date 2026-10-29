import SwiftUI

/// Settings › Account & Server: the server's addresses (marked "Not encrypted" when plain http outside home, T2),
/// who is signed in, Local Network access (T3) and Sign out.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var askingLocalNetwork = false
    /// Closes the Settings sheet (this page's own `dismiss` would only go back).
    let dismissSettings: () -> Void

    var body: some View {
        Form {
            Section {
                if let session = model.session {
                    ForEach(Array(session.endpoint.bases.enumerated()), id: \.offset) { index, base in
                        LabeledContent(index == 0 ? "Address" : "Also tries") {
                            AddressValue(value: base.absoluteString, base: base)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    LabeledContent("Signed in as", value: session.username)
                    localNetworkRows
                    Button("Sign out", role: .destructive) {
                        dismissSettings()
                        model.signOut()
                    }
                    .accessibilityIdentifier("settings-sign-out")
                }
            }
        }
        .navigationTitle("Account & Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// T3: Connect's Local Network message and buttons: the message and Open Settings while it is off, and the
    /// button to ask again until it is known to be on.
    @ViewBuilder private var localNetworkRows: some View {
        if model.localNetwork.state == .denied {
            Label(ConnectDiagnosis.localNetworkDenied.message, systemImage: "network.slash")
                .accessibilityIdentifier("settings-local-network-denied")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("settings-open-settings")
        }
        if model.localNetwork.state != .granted {
            Button {
                Task {
                    askingLocalNetwork = true
                    defer { askingLocalNetwork = false }
                    await model.localNetwork.request()
                }
            } label: {
                HStack {
                    Label("Allow local network access", systemImage: "network")
                    if askingLocalNetwork { Spacer(); ProgressView() }
                }
            }
            .disabled(askingLocalNetwork)
            .accessibilityIdentifier("settings-allow-local-network")
        }
    }
}
