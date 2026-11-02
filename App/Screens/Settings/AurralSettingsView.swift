import AurralKit
import DesignSystem
import SwiftUI

/// Round 12 Y6: Settings › New music › Aurral (the services page, beside Lidarr). Off until set up: address and API key
/// (Keychain only; the key is never shown or logged), Test connection, Disconnect. Plain http to a public address waits
/// for the owner's OK, as Lidarr does; a Tailscale or home address needs none.
struct AurralSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var asksConsent = false

    var body: some View {
        Section {
            NavigationLink {
                AurralSettingsView()
            } label: {
                LabeledContent("Aurral") {
                    AddressValue(value: AurralCopy.summary(model), base: model.discover.connection?.base)
                }
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("settings-aurral")
            if model.aurralAwaitingConsent {
                Button {
                    asksConsent = true
                } label: {
                    Label(LidarrConnectCopy.allowAddress, systemImage: "lock.open")
                }
                .accessibilityIdentifier("settings-aurral-allow")
            }
        } header: {
            Text(DiscoverCopy.title)
        } footer: {
            Text(model.aurralAwaitingConsent ? AurralCopy.needsConsent : AurralCopy.footer)
        }
        .alert(LidarrConnectCopy.plainHTTPTitle, isPresented: $asksConsent) {
            Button(LidarrConnectCopy.plainHTTPConfirm, role: .destructive) { model.allowAurralAddress() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AurralCopy.plainHTTPMessage)
        }
    }
}

/// Settings › New music › Aurral.
struct AurralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: String?
    @State private var unencrypted: URL?

    var body: some View {
        Form {
            if let connection = model.discover.connection {
                connected(connection)
            } else {
                connectForm
            }
        }
        .navigationTitle("Aurral")
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
            Text(AurralCopy.plainHTTPMessage + "\n\n" + (unencrypted.map { $0.host ?? $0.absoluteString } ?? ""))
        }
    }

    @ViewBuilder private var connectForm: some View {
        Section {
            TextField("http://homeserver:3001", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Aurral address")
                .accessibilityIdentifier("aurral-address")
            SecureField("API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("aurral-api-key")
        } footer: {
            Text(AurralCopy.connectFooter)
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("aurral-error")
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
            .disabled(isWorking || address.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.isEmpty)
            .accessibilityIdentifier("aurral-connect")
        }
    }

    @ViewBuilder private func connected(_ connection: AurralConnection) -> some View {
        Section {
            LabeledContent("Address") { AddressValue(value: connection.base.absoluteString, base: connection.base) }
            LabeledContent("Version", value: AurralCopy.version(model.discover.health))
            LabeledContent("Flows", value: "\(model.discover.playlists.count)")
        } footer: {
            Text(AurralCopy.compatibilityNote(model.discover.health) ?? AurralCopy.connectedFooter)
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("aurral-error")
            }
        }
        Section {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if isWorking { ProgressView() } else if let result { Text(result).foregroundStyle(.secondary) }
                }
            }
            .disabled(isWorking || model.aurralAwaitingConsent)
            .accessibilityIdentifier("aurral-test")
        }
        Section {
            Button("Disconnect Aurral", role: .destructive) {
                error = nil
                result = nil
                model.disconnectAurral()
            }
            .accessibilityIdentifier("aurral-disconnect")
        } footer: {
            Text("Forgets the address and key on this iPhone. Nothing in Aurral changes.")
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
            _ = try await model.connectAurral(base: url, apiKey: apiKey)
            apiKey = ""
        } catch is PlainHTTPConsentRequired {
            unencrypted = url
        } catch {
            self.error = AurralCopy.message(for: error)
        }
    }

    private func test() async {
        error = nil
        result = nil
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.testAurral()
            result = "Working"
        } catch {
            self.error = AurralCopy.message(for: error)
        }
    }
}

/// Settings' words about Aurral (the page names its service, as Lidarr's does).
enum AurralCopy {
    static let footer = "Aurral makes Discover playlists for you. Off until you set it up."
    static let connectFooter = "The API key is in Aurral under Settings. It gives full control of Aurral, so it stays on this iPhone and Magpie only reads Aurral, except when you tap Refresh Flow. Use an https:// address for anything outside your home."
    static let connectedFooter = "Magpie reads Aurral's flows and never changes Aurral, except when you tap Refresh Flow."
    static let needsConsent = "This Aurral address isn't encrypted, so Magpie waits for your OK before sending its API key."
    static let plainHTTPMessage = "Your Aurral API key will be sent in the clear, and it gives full control of Aurral. Use an https:// address when you can."
    static let badKey = "That API key didn't work. Copy it again from Aurral's Settings."
    static let notAurral = "That address answered, but it doesn't look like Aurral."

    @MainActor static func summary(_ model: AppModel) -> String {
        guard model.discover.connection != nil else { return "Off" }
        if model.aurralAwaitingConsent { return "Waiting for your OK" }
        return version(model.discover.health) == "Unknown" ? "On" : "On \u{00B7} " + version(model.discover.health)
    }

    static func version(_ health: AurralHealth?) -> String {
        health?.appVersion ?? "Unknown"
    }

    /// Said only when the server isn't the version Magpie is built for (2.10).
    static func compatibilityNote(_ health: AurralHealth?) -> String? {
        switch health?.compatibility {
        case .newer(let v)?: "Magpie is built for Aurral 2.10; this one runs \(v). Discover still works, though something new may not show."
        case .older(let v)?: "Magpie is built for Aurral 2.10; this one runs \(v). Some of Discover may not show."
        case .unknown?: "Aurral didn't say its version. Magpie is built for 2.10."
        default: nil
        }
    }

    static func message(for error: Error) -> String {
        switch error as? AurralError {
        case .unauthorized?: badKey
        case .notFound?, .decoding?: notAurral
        default: DiscoverCopy.message(for: error)
        }
    }
}
