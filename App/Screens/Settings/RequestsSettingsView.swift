import DesignSystem
import LidarrKit
import Requests
import SwiftUI

/// Settings › Accounts & Servers › Lidarr (round 13 item 14; was Settings › New music, R20, and before that
/// Requests): the address and API key (Connect Lidarr), the T2 "Allow This Address" step, the G1 switch, Magpie's
/// set-up and the change log, the main root folder, Finds set-up, the stuck-copy limit, Add with my defaults (R18/R20)
/// and the link to Downloads in Lidarr (Y4, no longer a top-level row). Offline (Task 14) every Lidarr action is
/// disabled, under "You're offline". Aurral moved to its own page (Accounts & Servers › Aurral).
struct RequestsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsConnect = false
    @State private var provisioning = false
    @State private var provisionMessage: String?
    @State private var asksLidarrConsent = false
    @State private var stuckCopyLimit = StallLimit.standard

    /// Only Soulseek copies are given up on (R17); the footer says so without naming the service (§5).
    static let stuckCopyFooter = "Copies shared by other listeners can stop coming. When one hasn't moved for this long, Magpie drops it and finds another."

    var body: some View {
        Form {
            if model.isOffline {
                Section { OfflineNotice() }   // just above the Lidarr sections it disables
            }
            Group { lidarrSections }.disabled(model.isOffline)
            if model.lidarr != nil {
                NewMusicDefaultsSection()   // R18 + R20
                ForEach(Self.pageLinks, id: \.self) { page in
                    Section { pageLink(page) }
                }
            }
        }
        .navigationTitle(SettingsCopy.lidarr)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    /// The pages this one opens while Lidarr is connected. Round 24 (D216): slskd left for its own row under Accounts &
    /// Servers.
    static let pageLinks: [SettingsPage] = [.lidarrDownloads]

    @ViewBuilder private func pageLink(_ page: SettingsPage) -> some View {
        if page == .lidarrDownloads {   // Y4: was a top-level row while Lidarr is connected
            NavigationLink(value: SettingsPage.lidarrDownloads) {
                LabeledContent(LidarrDownloadsCopy.title, value: model.lidarrDownloadsAttention.map { LidarrDownloadsCopy.attention($0).text } ?? "")
            }
            .accessibilityIdentifier("settings-lidarr-downloads")
        }
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
                        AddressValue(value: summary, base: model.lidarr?.base)
                    }
                    .accessibilityElement(children: .combine)
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("settings-lidarr")
                rootPicker
                LabeledContent("Speed", value: model.speedTier.title)
                    .accessibilityIdentifier("settings-speed")
                NavigationLink(value: SettingsPage.findsSetup) {   // a page Finish setting up can open directly
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
                Toggle("Allow Magpie to change your library", isOn: Binding(
                    get: { model.changesAllowed },
                    set: { on in Task { await model.setChangesAllowed(on) } }))
                    .accessibilityIdentifier("settings-allow-changes")
            } footer: {
                Text("Turn on to bring songs home. Every change is logged.")
            }
            LidarrMonitoringToggle()   // Round 24 (Q10, D237): what Lidarr monitors for the owner's artists
            Section {   // R17 (R20's words)
                Picker(RequestCopy.stuckCopySetting, selection: Binding(
                    get: { stuckCopyLimit },
                    set: { stuckCopyLimit = $0; model.setStallLimit($0) })) {
                    ForEach(StallLimit.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings-stuck-copy")
                .onAppear { stuckCopyLimit = model.stallLimit }
            } footer: {
                Text(Self.stuckCopyFooter)
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
                     : "Turn on \u{201C}Allow Magpie to change your library\u{201D} first.")
            }
        }
    }

    private var summary: String { LidarrSummary.status(model.lidarrStatus) }

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
        case WriteGateError.disabled: "Turn on \u{201C}Allow Magpie to change your library\u{201D} first."
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
    @State private var undoMessage: String?
    /// Artists whose finished singles switch can be undone (the journal's, not the capped log's).
    @State private var undoable: Set<Int> = []
    /// Re-review m3: artists whose switch journal was lost: their newest line offers "Put back".
    @State private var lost: Set<Int> = []
    @State private var scope: String?

    /// The artist of a singles-switch note (`LidarrWriteGate.singlesNote`).
    static func singlesArtist(_ entry: ChangeLogEntry) -> Int? {
        guard entry.method == "NOTE", entry.bodySummary.hasPrefix("singles switch: artist ") else { return nil }
        return entry.bodySummary.dropFirst("singles switch: artist ".count).split(separator: " ").first.flatMap { Int($0) }
    }

    /// Re-review m3: what a singles-switch line saved ("singles switch: artist N metadataProfileId P monitorNewItems V").
    static func singlesSaved(_ entry: ChangeLogEntry) -> (artistId: Int, profileId: Int, follow: String, instance: String?)? {
        guard let artist = singlesArtist(entry) else { return nil }
        let words = entry.bodySummary.split(separator: " ").map(String.init)
        func after(_ key: String) -> String? { words.firstIndex(of: key).flatMap { $0 + 1 < words.count ? words[$0 + 1] : nil } }
        guard let profile = after("metadataProfileId").flatMap(Int.init), let follow = after("monitorNewItems"), follow != "-" else {
            return nil
        }
        return (artist, profile, follow, after("instance"))
    }

    var body: some View {
        List {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("No changes yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Every change Magpie makes in Lidarr is listed here."))
                        .accessibilityIdentifier("change-log-empty")
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    // Review I3: Undo only on the newest switch line of an artist whose switch can be undone.
                    // Re-review 2 N1: only this Lidarr's lines get actions.
                    let artist = ChangeLogView.singlesSaved(entry).flatMap { $0.instance == scope ? $0.artistId : nil }
                    let newest = artist.map { a in !entries.prefix(index).contains { ChangeLogView.singlesArtist($0) == a } } ?? false
                    ChangeLogRow(entry: entry, showsUndo: newest && artist.map(undoable.contains) == true,
                                 showsPutBack: newest && artist.map(lost.contains) == true) { artistId in
                        undoMessage = await model.undoSingles(artistId: artistId)
                        await reload()
                    } putBack: {
                        undoMessage = await model.restoreSinglesFromNote(entry)
                        await reload()
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .alert(undoMessage ?? "", isPresented: Binding(get: { undoMessage != nil }, set: { if !$0 { undoMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .navigationTitle("Lidarr change log")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        entries = await model.changeLog()
        undoable = await model.undoableSinglesSwitches()
        lost = await model.singlesPutBackArtists(entries ?? [])
        scope = model.lidarrScope
    }
}

/// One change-log line; a singles switch's saved line offers its undo (round 15 C3, D146: the profile back).
private struct ChangeLogRow: View {
    let entry: ChangeLogEntry
    let showsUndo: Bool
    var showsPutBack = false
    let undo: (Int) async -> Void
    var putBack: () async -> Void = {}

    var body: some View {
        let answered = entry.status.map { "answered \($0)" } ?? "no answer"
        let when = entry.date.formatted(date: .abbreviated, time: .standard)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.method).font(.caption.monospaced().weight(.semibold))
                Text(entry.path).font(.caption.monospaced()).lineLimit(2)
            }
            Text("\(when) \u{00B7} \(answered)").font(.caption2).foregroundStyle(.secondary)
            if !entry.bodySummary.isEmpty {
                Text(entry.bodySummary).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4)
            }
            if showsUndo, let artistId = ChangeLogView.singlesArtist(entry) {
                Button(LibraryFindsCopy.undo) { Task { await undo(artistId) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("change-log-undo-singles")
            }
            if showsPutBack {
                Button(LibraryFindsCopy.putBack) { Task { await putBack() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("change-log-put-back-singles")
            }
        }
    }
}
