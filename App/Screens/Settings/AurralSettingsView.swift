import AurralKit
import DesignSystem
import SwiftUI

/// Round 13 items 1 and 14: Settings › Accounts & Servers › Aurral. Off until set up: the address, a username and a
/// password (Aurral's playlists are per user, so Magpie signs in as one; the API key is gone). The session and the
/// password stay in the Keychain and are never shown or logged. Signed in: who, the version, Test connection, and
/// Sign out. Plain http to a public address waits for the owner's OK, as Lidarr does; a Tailscale or home address
/// needs none.
struct AurralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: String?
    @State private var unencrypted: URL?
    @State private var asksConsent = false
    @State private var signsInAgain = false

    var body: some View {
        Form {
            if model.isOffline {
                Section { OfflineNotice() }
            }
            Group {
                if let connection = model.discover.connection, !signsInAgain {
                    connected(connection)
                } else {
                    signInForm
                }
            }
            .disabled(model.isOffline)
        }
        .navigationTitle("Aurral")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefill)
        .alert(LidarrConnectCopy.plainHTTPTitle, isPresented: Binding(
            get: { unencrypted != nil }, set: { if !$0 { unencrypted = nil } })
        ) {
            Button(LidarrConnectCopy.plainHTTPConfirm, role: .destructive) {
                if let url = unencrypted { model.allowAurralPassword(url) }
                unencrypted = nil
                Task { await signIn() }
            }
            Button("Cancel", role: .cancel) { unencrypted = nil }
        } message: {
            Text(AurralCopy.plainHTTPMessage + "\n\n" + (unencrypted.map { $0.host ?? $0.absoluteString } ?? ""))
        }
        .alert(LidarrConnectCopy.plainHTTPTitle, isPresented: $asksConsent) {
            Button(LidarrConnectCopy.plainHTTPConfirm, role: .destructive) { model.allowAurralAddress() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AurralCopy.plainHTTPMessage)
        }
    }

    /// The address and user of the saved (or upgraded) connection, so signing in again is only the password.
    private func prefill() {
        if address.isEmpty {
            address = (model.discover.connection?.base ?? model.discover.upgradedAddress)?.absoluteString ?? ""
        }
        if username.isEmpty { username = model.discover.connection?.username ?? "" }
    }

    @ViewBuilder private var signInForm: some View {
        if model.discover.upgradedAddress != nil, model.discover.connection == nil {
            Section {
                Label(AurralCopy.upgraded, systemImage: "person.crop.circle.badge.exclamationmark")
                    .accessibilityIdentifier("aurral-upgraded")
            }
        }
        Section {
            TextField("http://192.168.1.20:3001", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Aurral address")
                .accessibilityIdentifier("aurral-address")
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("aurral-username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("aurral-password")
        } footer: {
            Text(AurralCopy.signInFooter)
        }
        if let warning = AurralCopy.plainHTTPWarning(ServerAddress.check(address).url) {   // fix M1: always said
            Section {
                Label(warning, systemImage: "lock.open").accessibilityIdentifier("aurral-plain-http")
            }
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("aurral-error")
            }
        }
        Section {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Text("Sign In")
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .disabled(isWorking || address.trimmingCharacters(in: .whitespaces).isEmpty
                      || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            .accessibilityIdentifier("aurral-sign-in")
            if signsInAgain {
                Button("Cancel") { signsInAgain = false; error = nil; password = "" }
                    .accessibilityIdentifier("aurral-sign-in-cancel")
            }
        }
    }

    @ViewBuilder private func connected(_ connection: AurralConnection) -> some View {
        Section {
            LabeledContent("Address") { AddressValue(value: connection.base.absoluteString, base: connection.base) }
            LabeledContent("Signed in as", value: connection.login?.user.username ?? connection.username)
                .accessibilityIdentifier("aurral-user")
            LabeledContent("Version", value: AurralCopy.version(model.discover.health))
            LabeledContent("Flows", value: "\(model.discover.playlists.count)")
        } header: {
            Text(DiscoverCopy.title)
        } footer: {
            Text(AurralCopy.compatibilityNote(model.discover.health) ?? AurralCopy.connectedFooter)
        }
        if model.aurralAwaitingConsent {
            Section {
                Button {
                    asksConsent = true
                } label: {
                    Label(LidarrConnectCopy.allowAddress, systemImage: "lock.open")
                }
                .accessibilityIdentifier("settings-aurral-allow")
            } footer: {
                Text(AurralCopy.needsConsent)
            }
        }
        if model.discover.needsSignIn {
            Section {
                Label(AurralCopy.signedOut, systemImage: "person.crop.circle.badge.exclamationmark")
                    .accessibilityIdentifier("aurral-signed-out")
                Button("Sign In Again") {
                    error = nil
                    password = ""
                    address = connection.base.absoluteString
                    username = connection.username
                    signsInAgain = true
                }
                .accessibilityIdentifier("aurral-sign-in-again")
            }
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
            Button("Sign Out of Aurral", role: .destructive) {
                error = nil
                result = nil
                password = ""
                model.disconnectAurral()
            }
            .accessibilityIdentifier("aurral-disconnect")
        } footer: {
            Text(AurralCopy.signOutFooter)
        }
    }

    private func signIn() async {
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
            _ = try await model.connectAurral(base: url, username: username, password: password)
            password = ""
            signsInAgain = false
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
    static let signInFooter = "Sign in with your Aurral account: Discover shows your own flows. Your password stays on this iPhone so Magpie can sign in again when Aurral asks. Magpie only reads Aurral, except when you tap Refresh Flow. Use an https:// address for anything outside your home."
    static let connectedFooter = "Magpie reads your flows and never changes Aurral, except when you tap Refresh Flow."
    static let signOutFooter = "Signs out of Aurral and forgets the address, your account and your password on this iPhone. Nothing else in Aurral changes."
    static let needsConsent = "This Aurral address isn\u{2019}t encrypted, so Magpie waits for your OK before sending your password."
    static let plainHTTPMessage = "Your Aurral password, and the session Magpie keeps for 30 days, will be sent in the clear. Use an https:// address when you can."

    /// Z1 fix M1: said on the sign-in form whenever the address is plain http outside home, whatever was allowed before.
    static func plainHTTPWarning(_ url: URL?) -> String? {
        guard let url, ServerAddress.isUnencryptedPublic(url) else { return nil }
        return "Not encrypted: your password, and the session Magpie keeps for 30 days, would be sent in the clear."
    }
    static let badLogin = "That username or password didn\u{2019}t work."
    static let rateLimited = "Too many tries. Wait a few minutes, then try again."
    static let signedOut = "Aurral signed you out. Sign in again to keep Discover up to date."
    static let upgraded = "Aurral now signs in with your username and password. Sign in to see Discover again."
    static let notAurral = "That address answered, but it doesn\u{2019}t look like Aurral."

    /// The Accounts & Servers row's value: "Off", "Waiting for your OK", "Sign in again", or "jordan · 2.10.0".
    @MainActor static func summary(_ model: AppModel) -> String {
        guard let connection = model.discover.connection else {
            return model.discover.upgradedAddress != nil ? "Sign in again" : "Off"
        }
        if model.aurralAwaitingConsent { return "Waiting for your OK" }
        if model.discover.needsSignIn { return "Sign in again" }
        let user = connection.login?.user.username ?? connection.username
        return version(model.discover.health) == "Unknown" ? user : user + " \u{00B7} " + version(model.discover.health)
    }

    static func version(_ health: AurralHealth?) -> String {
        health?.appVersion ?? "Unknown"
    }

    /// Said only when the server isn't the version Magpie is built for (2.10).
    static func compatibilityNote(_ health: AurralHealth?) -> String? {
        switch health?.compatibility {
        case .newer(let v)?: "Magpie is built for Aurral 2.10; this one runs \(v). Discover still works, though something new may not show."
        case .older(let v)?: "Magpie is built for Aurral 2.10; this one runs \(v). Some of Discover may not show."
        case .unknown?: "Aurral didn\u{2019}t say its version. Magpie is built for 2.10."
        default: nil
        }
    }

    static func message(for error: Error) -> String {
        switch error as? AurralError {
        case .badLogin?: badLogin
        case .rateLimited?: rateLimited
        case .signInNeeded?: signedOut
        case .notFound?, .decoding?: notAurral
        default: DiscoverCopy.message(for: error)
        }
    }
}
