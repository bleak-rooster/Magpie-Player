import DesignSystem
import LidarrKit
import Requests
import SwiftUI

/// Settings (replaces the Library account menu): Appearance, Servers, Lidarr (connect, set up, the G1 switch,
/// the main root folder, Finds, the change log), one row per area (Playback, Downloads & Storage, Scrobbling, which
/// holds Count plays and the ListenBrainz token), About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showsConnect = false
    @State private var provisioning = false
    @State private var provisionMessage: String?
    @State private var asksLidarrConsent = false
    @State private var askingLocalNetwork = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent("Appearance", value: model.theme.character.rawValue.capitalized)
                    }
                }
                servers
                lidarr
                // One row per area, each opening its own page (T21b collates the rest the same way).
                Section {
                    NavigationLink("Playback") { PlaybackSettingsView() }
                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        LabeledContent("Downloads & Storage", value: DownloadsSettingsView.summary(model.preferences.downloads))
                    }
                    .accessibilityIdentifier("settings-downloads")
                    NavigationLink {
                        ScrobblingSettingsView()
                    } label: {
                        LabeledContent("Scrobbling", value: AppModel.scrobblingSummary(
                            model.preferences.scrobbling, countPlays: model.countPlays, hasToken: model.hasListenBrainzToken))
                    }
                    .accessibilityIdentifier("settings-scrobbling")
                }
                Section("About") {
                    LabeledContent("Magpie", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings-done")
                }
            }
            .sheet(isPresented: $showsConnect) { ConnectLidarrView() }
            .alert(LidarrConnectCopy.plainHTTPTitle, isPresented: $asksLidarrConsent) {
                Button(LidarrConnectCopy.plainHTTPConfirm, role: .destructive) {
                    model.allowLidarrAddress()
                    Task { _ = await model.lidarrAudit() }
                }
                .accessibilityIdentifier("settings-lidarr-allow-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(LidarrConnectCopy.plainHTTPMessage + "\n\n" + (model.lidarr.map { $0.base.host ?? $0.base.absoluteString } ?? ""))
            }
            .task(id: model.lidarr) { if model.lidarr != nil, !model.isOffline { _ = await model.lidarrAudit() } }
        }
    }

    static var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(AppModel.marketingVersion) (\(build))"
    }

    // MARK: - Servers

    @ViewBuilder private var servers: some View {
        Section("Servers") {
            if let session = model.session {
                ForEach(Array(session.endpoint.bases.enumerated()), id: \.offset) { index, base in
                    LabeledContent(index == 0 ? "Address" : "Also tries") {
                        addressValue(base.absoluteString, base: base)
                    }
                    .accessibilityElement(children: .combine)
                }
                LabeledContent("Signed in as", value: session.username)
                localNetworkRows
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
                .accessibilityIdentifier("settings-sign-out")
            }
        }
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

    // MARK: - Lidarr

    /// Offline (Task 14) every Lidarr action is disabled, under "You're offline".
    @ViewBuilder private var lidarr: some View {
        if model.isOffline {
            Section { OfflineNotice() }   // just above the Lidarr sections it disables
        }
        Group { lidarrSections }.disabled(model.isOffline)
    }

    @ViewBuilder private var lidarrSections: some View {
        if model.lidarr == nil {
            Section {
                Button("Connect Lidarr") { showsConnect = true }
                    .accessibilityIdentifier("settings-connect-lidarr")
            } header: {
                Text("Lidarr")
            } footer: {
                Text("Lidarr finds music you don't have yet.")
            }
        } else {
            Section {
                Button {
                    showsConnect = true
                } label: {
                    LabeledContent("Lidarr") {
                        addressValue(summary, base: model.lidarr?.base)
                    }
                    .accessibilityElement(children: .combine)
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("settings-lidarr")
                rootPicker
                LabeledContent("Speed", value: model.speedTier.title)
                    .accessibilityIdentifier("settings-speed")
                NavigationLink { FindsSetupView() } label: {
                    LabeledContent("Finds", value: findsSummary)
                }
                .accessibilityIdentifier("settings-finds")
            } header: {
                Text("Lidarr")
            } footer: {
                Text(model.speedTier == .patient
                     ? "Patient: plain Lidarr can take a few hours, so Try becomes \u{201C}Ask for it\u{201D}."
                     : "Standard: Tubifarry found, so most songs arrive in a few minutes.")
            }
            if model.lidarrAwaitingConsent {   // T2 fix round 2: nothing goes to Lidarr until allowed
                Section {
                    Button {
                        asksLidarrConsent = true
                    } label: {
                        Label(LidarrConnectCopy.allowAddress, systemImage: "lock.open")
                    }
                    .accessibilityIdentifier("settings-lidarr-allow")
                } footer: {
                    Text(LidarrConnectCopy.needsConsent)
                }
            }
            Section {
                Toggle("Allow Magpie to change Lidarr", isOn: Binding(
                    get: { model.changesAllowed },
                    set: { on in Task { await model.setChangesAllowed(on) } }))
                    .accessibilityIdentifier("settings-allow-changes")
            } footer: {
                Text("Turn on to bring songs home. Every change is logged.")
            }
            Section {
                Button {
                    Task { await provision() }
                } label: {
                    HStack {
                        Text("Set up Magpie in Lidarr")
                        Spacer()
                        if provisioning {
                            ProgressView()
                        } else if model.lidarrSetup?.isProvisioned == true {
                            Image(systemName: "checkmark.circle").accessibilityLabel("Done")
                        }
                    }
                }
                .disabled(!model.changesAllowed || provisioning)
                .accessibilityIdentifier("settings-provision")
                if let provisionMessage {
                    Text(provisionMessage).font(.footnote).accessibilityIdentifier("settings-provision-message")
                }
                NavigationLink("Lidarr change log") { ChangeLogView() }
                    .accessibilityIdentifier("settings-change-log")
            } footer: {
                Text(model.changesAllowed
                     ? "Adds Magpie's profiles (Magpie Fast Start, Magpie Finds…) and the magpie tag if they're missing. Nothing you already have is changed."
                     : "Turn on \u{201C}Allow Magpie to change Lidarr\u{201D} first.")
            }
        }
    }

    private var summary: String { LidarrSummary.status(model.lidarrStatus) }

    /// T2 (D3): a row's value, with "Not encrypted" under it when `base` is plain http outside home and Tailscale.
    @ViewBuilder private func addressValue(_ value: String, base: URL?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).multilineTextAlignment(.trailing)
            if let base, ServerAddress.isUnencryptedPublic(base) {
                Label(ConnectErrorCopy.notEncrypted, systemImage: "lock.open")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var findsSummary: String { model.findsStatus.summary }

    @ViewBuilder private var rootPicker: some View {
        // The confirmed Finds folder is never also where new music goes (G2).
        let roots = (model.lidarrStatus?.roots.map(\.path) ?? []).filter { !model.isFindsRoot($0) }
        if roots.count > 1 {
            Picker("New music goes to", selection: Binding(
                get: { model.lidarrSetup?.rootFolderPath ?? "" },
                set: { if !$0.isEmpty { model.chooseRoot($0) } })) {
                if model.lidarrSetup?.rootFolderPath == nil { Text("Choose…").tag("") }
                ForEach(roots, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("settings-root")
        } else if let root = model.lidarrSetup?.rootFolderPath {
            LabeledContent("New music goes to", value: root)
        } else if model.lidarrStatus != nil {
            LabeledContent("New music goes to", value: "No root folder in Lidarr")
        }
    }

    private func provision() async {
        provisioning = true
        defer { provisioning = false }
        do {
            let result = try await model.provisionLidarr()
            provisionMessage = result.created.isEmpty
                ? "Already set up. Nothing needed changing."
                : "Added " + result.created.joined(separator: ", ") + "."
        } catch {
            provisionMessage = Self.provisionError(error)
        }
    }

    nonisolated static func provisionError(_ error: Error) -> String {
        switch error {
        case WriteGateError.disabled: "Turn on \u{201C}Allow Magpie to change Lidarr\u{201D} first."
        case ProvisionError.conflict(let name):
            "Lidarr already has a profile called \u{201C}\(name)\u{201D} set up differently. Magpie won't change it; rename it in Lidarr, then try again."
        case ProvisionError.schemaMissing(let what): "This Lidarr doesn't offer \(what), which Magpie needs."
        case LidarrError.unauthorized: LidarrConnectCopy.badKey
        default: "Couldn't reach Lidarr. Try again in a moment."
        }
    }
}

/// G1: everything Magpie asked Lidarr to change, newest first. The owner's undo map.
struct ChangeLogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ChangeLogEntry]?

    var body: some View {
        List {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("No changes yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Every change Magpie makes in Lidarr is listed here."))
                        .accessibilityIdentifier("change-log-empty")
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.method).font(.caption.monospaced().weight(.semibold))
                            Text(entry.path).font(.caption.monospaced()).lineLimit(2)
                        }
                        Text(entry.date.formatted(date: .abbreviated, time: .standard)
                             + " · " + (entry.status.map { "answered \($0)" } ?? "no answer"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !entry.bodySummary.isEmpty {
                            Text(entry.bodySummary).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Lidarr change log")
        .task { entries = await model.changeLog() }
        .refreshable { entries = await model.changeLog() }
    }
}
