import SwiftUI

/// Round 23 (owner, 2026-11-07, D192): Settings › Lidarr › Soulseek (slskd). Optional: the address and API key (Test and
/// Connect), the write switch (off until the owner turns it on), and Disconnect. Named only here (the copy rule).
struct SlskdSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var error: String?
    /// A plain-http public address waiting for the owner's yes (as Lidarr's, security H2).
    @State private var unencrypted: URL?

    var body: some View {
        Form {
            Section {
                Text(SlskdCopy.intro).font(.footnote)
            }
            if let connection = model.slskd {
                connected(connection)
            } else {
                connectForm
            }
        }
        .navigationTitle(SlskdCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(LidarrConnectCopy.plainHTTPTitle, isPresented: Binding(
            get: { unencrypted != nil }, set: { if !$0 { unencrypted = nil } })
        ) {
            Button(LidarrConnectCopy.plainHTTPConfirm, role: .destructive) {
                if let url = unencrypted { model.allowPlainHTTP([url]) }
                unencrypted = nil
                Task { await connect() }
            }
            Button("Cancel", role: .cancel) { unencrypted = nil }
        } message: {
            Text(SlskdCopy.plainHTTPMessage + "\n\n" + (unencrypted.map { $0.host ?? $0.absoluteString } ?? ""))
        }
    }

    // MARK: - Not connected

    @ViewBuilder private var connectForm: some View {
        Section {
            TextField("http://192.168.1.20:5030", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("slskd address")
                .accessibilityIdentifier("slskd-address")
            SecureField("API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("slskd-api-key")
        } footer: {
            Text(SlskdCopy.addressFooter)
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("slskd-error")
            }
        }
        Section {
            Button {
                Task { await connect() }
            } label: {
                HStack {
                    Text("Test and Connect")
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .frame(minHeight: 44)
            .disabled(isWorking || address.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.isEmpty)
            .accessibilityIdentifier("slskd-connect")
        }
    }

    private func connect() async {
        let url: URL
        switch ServerAddress.check(address) {
        case .url(let parsed): url = parsed
        case .containsCredentials:
            error = LidarrConnectCopy.credentialsInAddress
            return
        case .invalid:
            error = LidarrConnectCopy.invalidAddress(address)
            return
        }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.connectSlskd(base: url, apiKey: apiKey)
            apiKey = ""
        } catch is PlainHTTPConsentRequired {
            unencrypted = url
        } catch {
            self.error = SlskdCopy.message(for: error, url: url)
        }
    }

    // MARK: - Connected

    @ViewBuilder private func connected(_ connection: SlskdConnection) -> some View {
        Section {
            LabeledContent("Address", value: connection.base.absoluteString)
            Label(SlskdCopy.rowSummaryOn, systemImage: "checkmark.circle")   // state as text and a symbol (D3)
        }
        Section {
            Toggle(SlskdCopy.allowChanges, isOn: Binding(get: { model.slskdChangesAllowed },
                                                       set: { model.setSlskdChangesAllowed($0) }))
                .accessibilityIdentifier("slskd-allow-changes")
        } footer: {
            Text(SlskdCopy.allowFooter)
        }
        Section {
            Button("Disconnect slskd", role: .destructive) { model.disconnectSlskd() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("slskd-disconnect")
        } footer: {
            Text(SlskdCopy.disconnectFooter)
        }
    }
}
