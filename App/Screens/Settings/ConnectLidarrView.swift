import DesignSystem
import LidarrKit
import SwiftUI

/// Connect Lidarr (address + API key) and show a calm summary of how it is set up. Read-only: nothing
/// is written to Lidarr here. Opened from Home's "Finish setting up" card and from Settings.
struct ConnectLidarrView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var audit: LidarrAudit?
    /// A plain-http public address waiting for the owner's yes (security H2).
    @State private var unencrypted: URL?

    var body: some View {
        NavigationStack {
            Form {
                if let connection = model.lidarr {
                    connected(connection)
                } else {
                    connectForm
                }
            }
            .navigationTitle("Lidarr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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
                Text(LidarrConnectCopy.plainHTTPMessage + "\n\n" + (unencrypted.map { $0.host ?? $0.absoluteString } ?? ""))
            }
            .task(id: model.lidarr) {
                guard model.lidarr != nil, audit == nil else { return }
                isWorking = true
                audit = await model.lidarrAudit()
                isWorking = false
            }
        }
    }

    // MARK: - Not connected

    @ViewBuilder private var connectForm: some View {
        Section {
            TextField("http://192.168.1.20:8686", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Lidarr address")
                .accessibilityIdentifier("lidarr-address")
            SecureField("API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("lidarr-api-key")
        } header: {
            Text("Lidarr")
        } footer: {
            Text("Lidarr finds music you don't have yet. The API key is in Lidarr under Settings › General › Security. Magpie changes nothing in Lidarr until you allow it in Settings. Use an https:// address for anything outside your home: plain http:// sends the key unencrypted.")
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .accessibilityIdentifier("lidarr-error")
            }
        }
        Section {
            Button {
                Task { await connect() }
            } label: {
                HStack {
                    Text("Connect")
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .disabled(isWorking || address.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.isEmpty)
            .accessibilityIdentifier("lidarr-connect")
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
            audit = try await model.connectLidarr(base: url, apiKey: apiKey)
            apiKey = ""
        } catch is PlainHTTPConsentRequired {
            unencrypted = url
        } catch {
            self.error = LidarrConnectCopy.message(for: error, url: url)
        }
    }

    // MARK: - Connected

    @ViewBuilder private func connected(_ connection: LidarrConnection) -> some View {
        Section {
            LabeledContent("Address", value: connection.base.absoluteString)
        } footer: {
            Text("Magpie can now show music that's not in your library. It changes nothing in Lidarr until you turn on \u{201C}Allow Magpie to change Lidarr\u{201D} in Settings.")
        }
        if let audit {
            Section("Setup") {
                ForEach(LidarrSummary.lines(for: audit), id: \.title) { line in
                    LabeledContent {
                        Text(line.value).multilineTextAlignment(.trailing)
                    } label: {
                        Label(line.title, systemImage: line.symbol)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !audit.roots.isEmpty {
                Section("Root folders") {
                    ForEach(audit.roots, id: \.id) { root in
                        LabeledContent(root.path, value: root.freeSpace.map(LidarrSummary.bytes) ?? "")
                    }
                }
            }
            if !audit.healthIssues.isEmpty {
                Section("Lidarr says") {
                    ForEach(Array(audit.healthIssues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message).font(.footnote)
                    }
                }
            }
        } else if isWorking {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
        Section {
            Button("Disconnect Lidarr", role: .destructive) {
                audit = nil
                model.disconnectLidarr()
            }
        } footer: {
            Text("Forgets the address and key on this iPhone. Nothing in Lidarr changes.")
        }
    }
}

/// The audit as plain lines. Pure, so tests can check the wording.
enum LidarrSummary {
    struct Line: Equatable {
        var title: String
        var value: String
        var symbol: String
    }

    static let keyRejected = "The API key no longer works"

    /// The one-line status under Lidarr in Settings.
    static func status(_ audit: LidarrAudit?) -> String {
        guard let audit else { return "Connected" }
        if audit.keyRejected { return keyRejected }
        return audit.reachable ? (audit.version.isEmpty ? "Connected" : "Version \(audit.version)") : "Not answering"
    }

    static func lines(for a: LidarrAudit) -> [Line] {
        if a.keyRejected { return [Line(title: "Status", value: keyRejected, symbol: "key")] }
        guard a.reachable else {
            return [Line(title: "Status", value: "Not answering right now", symbol: "wifi.exclamationmark")]
        }
        let health = a.healthIssues.isEmpty
            ? "No problems reported"
            : (a.healthIssues.count == 1 ? "1 thing to look at" : "\(a.healthIssues.count) things to look at")
        return [
            Line(title: "Version", value: a.version.isEmpty ? "Unknown" : a.version, symbol: "info.circle"),
            Line(title: "Sign-in", value: a.authEnabled ? "On" : "Off", symbol: a.authEnabled ? "lock" : "lock.open"),
            Line(title: "Root folders", value: a.roots.isEmpty ? "None yet" : String(a.roots.count), symbol: "folder"),
            Line(title: "Tubifarry", value: a.tubifarry ? "Found" : "Not found", symbol: "puzzlepiece.extension"),
            Line(title: "Recycle bin", value: a.recycleBinSet ? "Set" : "Not set: deletes are permanent",
                 symbol: "trash"),
            Line(title: "Health", value: health,
                 symbol: a.healthIssues.isEmpty ? "checkmark.circle" : "exclamationmark.circle"),
        ]
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file) + " free"
    }
}

enum LidarrConnectCopy {
    static let badKey = "That API key didn't work. Copy it again from Lidarr › Settings › General › Security."
    static let notLidarr = "That address answered, but it doesn't look like Lidarr."
    static let credentialsInAddress = "Leave any username and password out of the address."
    static let plainHTTPTitle = "This address isn't encrypted."
    static let plainHTTPMessage = "Your Lidarr API key will be sent in the clear, and it gives full control of Lidarr. Use an https:// address when you can."
    static let plainHTTPConfirm = "Send Anyway"

    static func invalidAddress(_ text: String) -> String {
        "\u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D} doesn't look like a web address."
    }

    static func message(for error: Error, url: URL) -> String {
        switch error {
        case LidarrError.unauthorized: return badKey
        case LidarrError.decoding, LidarrError.http: return notLidarr
        case _ where ConnectErrorCopy.isPlainHTTPAnswer(error, url: url): return ConnectErrorCopy.httpsNotAnswering
        default:
            return "Couldn't reach Lidarr at \(ConnectErrorCopy.hostAndPort(url) ?? url.absoluteString). Check the address and that Lidarr is running."
        }
    }
}
