import DesignSystem
import LidarrKit
import Observation
import Requests
import SwiftUI

/// Round 12 item 6 (D49): the words of Settings › Downloads in Lidarr (a top-level row while Lidarr is connected; fix
/// round 1 I3).
enum LidarrDownloadsCopy {
    static let title = "Downloads in Lidarr"
    static let empty = "Nothing downloading"
    static let emptyDetail = "Everything Lidarr is downloading shows here, whoever asked for it."
    static let unreachable = "Couldn't reach Lidarr. Trying again\u{2026}"
    static let changesOff = "Turn on \u{201C}Allow Magpie to change your library\u{201D} on the Lidarr page to restart downloads."
    static let restart = "Restart"
    /// Round 13 (D63): stalled, failed and couldn't-import copies (what "need attention" counts).
    static let restartAll = "Restart all that need attention"
    static let footer = "Restart drops the copy, stops Lidarr picking that same copy again, and looks for another. "
        + "It never touches music already in your library."
    /// Fix round 2: finished copies Lidarr couldn't import; restarted after their own confirmation, or by Restart all
    /// (round 13, D63).
    static let couldntImportSection = "Couldn't import"
    static let couldntImportFooter = "These finished downloading, but Lidarr couldn't file them."
    static let couldntImportConfirm = "Removes this copy so it isn't picked again, and looks for another."
    /// Fix round 2 N1 (round 3: the glossary's words): transfers Lidarr lists but never grabbed. Round 13 (D63): they
    /// may be restarted, after the flagged confirmation.
    static let notStartedSection = "Started by another app"
    static let notStartedFooter = "Another app started these in your download app. Restart asks first."
    /// Round 13 (D63): the flagged confirmation, in the owner's plan's words. The only place a restart of another
    /// app's download is allowed (`allowForeign`).
    static let foreignConfirm = "This download wasn't started by your library \u{2014} it may belong to another app. "
        + "Restart anyway?"
    static let stillGoingConfirm = "This download is still going. Restart drops it and looks for another copy."

    /// What a row's Restart asks first; nil: it restarts at once (stalled or failed). Z4 fix M5: a copy that isn't
    /// moving on purpose or can't be reached says what it's doing, not "still going".
    static func confirmOne(_ ask: LidarrDownloads.Ask, phase: LidarrDownloads.Phase = .downloading) -> String? {
        switch ask {
        case .none: nil
        case .stillGoing:
            switch phase {
            case .paused: "Paused. Restart drops it and looks for another copy."
            case .queued: "Waiting to start. Restart drops it and looks for another copy."
            case .clientUnavailable: "Can't reach the download app. Restart drops it and looks for another copy."
            default: stillGoingConfirm
            }
        case .couldntImport: couldntImportConfirm
        case .foreign: foreignConfirm
        }
    }

    static func confirmButton(_ ask: LidarrDownloads.Ask) -> String { ask == .foreign ? "Restart anyway" : restart }

    /// Z4 fix M2: Restart all does at most `maxPerTap`, Lidarr's own first; this many of another app's fit after them.
    static func foreignBatch(own: Int, foreign: Int) -> Int {
        min(foreign, max(0, LidarrDownloadRestarter.maxPerTap - own))
    }

    /// Restart all's second choice: also `count` of another app's stalled, failed or couldn't-import downloads (already
    /// capped by `foreignBatch`). `alone` (fix M3): nothing of Lidarr's own is listed, so it's the only choice.
    static func includeForeign(_ count: Int, alone: Bool = false) -> String {
        (alone ? "Restart \(count)" : "Also restart \(count)") + " started by another app"
    }

    /// The Settings row's summary: how many need attention at the page's last read.
    static func attention(_ count: Int?) -> SettingsSummary {
        switch count {
        case nil: SettingsSummary("Stalled and failed downloads")
        case 0?: SettingsSummary("Nothing stalled or failed")
        case let n?: SettingsSummary("\(n) need attention", symbol: "exclamationmark.triangle")
        }
    }

    static func confirmTitle(_ count: Int) -> String {
        count == 1 ? "Restart 1 download?" : "Restart \(min(count, LidarrDownloadRestarter.maxPerTap)) downloads?"
    }

    static func confirmMessage(_ count: Int, foreign: Int = 0) -> String {
        let cap = LidarrDownloadRestarter.maxPerTap
        var text = "Each one is dropped and looked for again."
        if count > cap { text += " The first \(cap) now; the rest next time." }
        if foreign > 0 { text += " Downloads another app started are left alone unless you include them." }
        return text
    }

    /// The status line for a row (always text, with `symbol`, D3).
    static func status(_ row: LidarrDownloads.Row, limit: StallLimit) -> String {
        if row.phase == .downloading {
            let percent = row.progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading"
            guard let speed = row.speed, speed > 0 else { return percent }
            return percent + " \u{00B7} " + ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .decimal) + "/s"
        }
        return switch row.phase {
        case .downloading: "Downloading"
        case .queued: "Waiting to start"
        case .paused: "Paused"
        case .clientUnavailable: "Can't reach the download app"
        case .waitingToImport: "Waiting to import"
        case .importing: "Importing"
        case .stalled: row.stall == .lidarr ? "Stalled" : "No progress for \(limit.title) or more"
        case .failed: "Failed"
        case .couldntImport: "Couldn't import"
        case .notStarted: "Started by another app"
        }
    }

    static func symbol(_ phase: LidarrDownloads.Phase) -> String {
        switch phase {
        case .downloading: "arrow.down.circle.dotted"
        case .queued: "clock"
        case .paused: "pause"
        case .clientUnavailable: "bolt.horizontal.circle"
        case .waitingToImport: "tray"
        case .importing: "tray.and.arrow.down"
        case .stalled: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .couldntImport: "tray.full"
        case .notStarted: "arrow.triangle.branch"
        }
    }

    /// One line after a tap: what happened, plainly.
    static func summary(_ outcomes: [LidarrDownloadRestarter.Outcome]) -> String? {
        guard !outcomes.isEmpty else { return nil }
        if outcomes.contains(.changesOff) { return changesOff }
        func count(_ match: (LidarrDownloadRestarter.Outcome) -> Bool) -> Int { outcomes.filter(match).count }
        func some(_ n: Int, one: String, many: (Int) -> String) -> String? { n == 0 ? nil : n == 1 ? one : many(n) }
        let restarted = count { $0 == .restarted || $0 == .removedNotSearched }
        let refused = count { if case .refused = $0 { true } else { false } }
        let parts: [String?] = [
            restarted == 0 ? nil : outcomes.count == 1 ? "Restarted." : "Restarted \(restarted).",
            count { $0 == .removedNotSearched } > 0 ? "Lidarr will look again on its own schedule." : nil,
            // Z4 fix M1: removed, but no album to look for (another app's transfer Lidarr couldn't match).
            outcomes == [.removedNothingToLookFor] ? "Removed. There was no album to look for."
                : some(count { $0 == .removedNothingToLookFor }, one: "Removed 1; there was no album to look for.",
                       many: { "Removed \($0); there were no albums to look for." }),
            some(count { $0 == .skipped }, one: outcomes.count == 1 ? "It started moving again, so it was left alone."
                                                                     : "One started moving again, so it was left alone.",
                 many: { "\($0) started moving again, so they were left alone." }),
            count { $0 == .limitReached } > 0 ? "Magpie has already tried five copies of that request." : nil,
            count { $0 == .magpieBusy } > 0 ? "Magpie is bringing that album home right now, so it was left alone." : nil,
            some(count { $0 == .notStartedByLidarr }, one: "Another app started that download, so it was left alone.",
                 many: { "Another app started \($0) of them, so they were left alone." }),
            some(count { $0 == .gone }, one: "One had already left the list.", many: { "\($0) had already left the list." }),
            some(count { $0 == .importingOrDone }, one: "One is importing or done, so it was left alone.",
                 many: { "\($0) are importing or done, so they were left alone." }),
            count { $0 == .unnamed } > 0 ? "Lidarr doesn't say which download one belongs to, so it was left alone." : nil,
            some(refused, one: "Lidarr's list changed, so one was left alone.",
                 many: { "Lidarr's list changed, so \($0) were left alone." }),
            count { $0 == .logUnavailable } > 0 ? "The change log couldn't be saved, so nothing was sent." : nil,
            some(count { $0 == .unavailable }, one: "Couldn't reach Lidarr for one. Try again in a moment.",
                 many: { "Couldn't reach Lidarr for \($0). Try again in a moment." }),
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
    }
}

/// The screen's state: the queue read every 5 s while it's open, and the restarter (one per gate). The no-progress
/// clock lives in `AppModel` (fix round 1 I2), so leaving the page doesn't start it over.
@MainActor @Observable final class LidarrDownloadsScreen {
    static let refreshInterval: Duration = .seconds(5)

    private(set) var board: LidarrDownloads?
    private(set) var unreachable = false
    private(set) var restarting = false
    private(set) var message: String?
    @ObservationIgnored private var restarter: (gate: ObjectIdentifier, restarter: LidarrDownloadRestarter)?

    /// One read of the queue and the download clients.
    func refresh(_ model: AppModel, now: Date = Date()) async {
        guard let client = model.lidarrClient, !model.isOffline else { return }
        do {
            async let queue = client.queueDetailsNamed()
            async let clients = client.downloadClients()
            let (items, setup) = try await (queue, clients)
            let soulseek = Set(setup.filter(\.isSoulseek).map { $0.name.lowercased() })
            let scope = client.instanceScope
            var watch = model.lidarrDownloadsWatch.flatMap { $0.scope == scope ? $0.watch : nil } ?? QueueStallWatch()
            watch.observe(items, soulseekClients: soulseek, at: now)
            model.lidarrDownloadsWatch = (scope, watch)
            // N2: the grab history of rows that could be restarted, a few at a time, cached per download.
            var grabs = model.lidarrDownloadsGrabs.flatMap { $0.scope == scope ? $0.grabs : nil } ?? GrabCache()
            await grabs.lookUp(items, soulseekClients: soulseek, lidarr: client, now: now, watch: watch,
                               stallLimit: model.stallLimit.seconds)
            model.lidarrDownloadsGrabs = (scope, grabs)
            let board = LidarrDownloads(items, soulseekClients: soulseek, watch: watch, grabs: grabs,
                                        stallLimit: model.stallLimit.seconds, now: now)
            self.board = board
            model.lidarrDownloadsAttention = board.attention
            unreachable = false
        } catch is CancellationError {
            return
        } catch {
            unreachable = true
        }
    }

    /// Reads every `refreshInterval` until the view goes away (its `.task` is cancelled).
    func follow(_ model: AppModel) async {
        while !Task.isCancelled {
            await refresh(model)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// One row; re-checked on a fresh read before it's restarted (fix round 1 I1). `allowForeign` (round 13, D63):
    /// only from the flagged confirmation.
    func restart(_ rows: [LidarrDownloads.Row], model: AppModel, allowForeign: Bool = false) async {
        guard let row = rows.first, rows.count == 1, let restarter = restarter(model) else { return }
        restarting = true
        defer { restarting = false }
        message = LidarrDownloadsCopy.summary([await restarter.restart(row, allowForeign: allowForeign)])
        await refresh(model)
    }

    /// Restart all, after its confirmation. `includeForeign` (round 13, D63): the owner chose to include another app's.
    func restartAll(_ rows: [LidarrDownloads.Row], model: AppModel, includeForeign: Bool = false) async {
        guard !rows.isEmpty, let restarter = restarter(model) else { return }
        restarting = true
        defer { restarting = false }
        message = LidarrDownloadsCopy.summary(await restarter.restartAll(rows, includeForeign: includeForeign))
        await refresh(model)
    }

    private func restarter(_ model: AppModel) -> LidarrDownloadRestarter? {
        guard let gate = model.gate, let client = model.lidarrClient else { return nil }
        if let restarter, restarter.gate == ObjectIdentifier(gate) { return restarter.restarter }
        let made = LidarrDownloadRestarter(lidarr: client, gate: gate, runner: model.runner)
        restarter = (ObjectIdentifier(gate), made)
        return made
    }
}

/// Settings › Downloads in Lidarr: everything in Lidarr's queue, whoever asked for it (D49), as Active,
/// Stalled and Failed, with Restart on every row not importing (round 13, D63; some ask first) and Restart all (one
/// confirmation, 25 at a time; another app's only when chosen there).
struct LidarrDownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var screen = LidarrDownloadsScreen()
    @State private var confirmsAll = false
    /// The rows Restart all was tapped for (minor M5: the dialog counts what it will do, not a later read), Lidarr's
    /// own and another app's (round 13, D63: included only when chosen in the dialog).
    @State private var pendingAll: [LidarrDownloads.Row] = []
    @State private var pendingForeign: [LidarrDownloads.Row] = []
    /// A row whose Restart asks first (still going, couldn't import, or another app's: the flagged confirmation).
    @State private var pendingOne: LidarrDownloads.Row?

    var body: some View {
        List {
            if model.isOffline {
                Section { OfflineNotice() }
            }
            if screen.unreachable {
                Section {
                    Label(LidarrDownloadsCopy.unreachable, systemImage: "exclamationmark.icloud")
                        .accessibilityIdentifier("lidarr-downloads-unreachable")
                }
            }
            if let message = screen.message {
                Section { Text(message).accessibilityIdentifier("lidarr-downloads-message") }
            }
            if let board = screen.board {
                if board.active.isEmpty, board.stalled.isEmpty, board.failed.isEmpty, board.couldntImport.isEmpty,
                   board.notStarted.isEmpty {
                    ContentUnavailableView(LidarrDownloadsCopy.empty, systemImage: "arrow.down.circle",
                                           description: Text(LidarrDownloadsCopy.emptyDetail))
                        .accessibilityIdentifier("lidarr-downloads-empty")
                } else {
                    restartAllSection(board)
                    section("Stalled", board.stalled, id: "stalled")
                    section("Failed", board.failed, id: "failed")
                    section(LidarrDownloadsCopy.couldntImportSection, board.couldntImport, id: "couldnt-import",
                            footer: LidarrDownloadsCopy.couldntImportFooter)
                    section("Active", board.active, id: "active")
                    section(LidarrDownloadsCopy.notStartedSection, board.notStarted, id: "not-started",
                            footer: LidarrDownloadsCopy.notStartedFooter)
                }
            } else if !screen.unreachable {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(LidarrDownloadsCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await screen.follow(model) }
        .refreshable { await screen.refresh(model) }
        .confirmationDialog(LidarrDownloadsCopy.confirmTitle(pendingAll.isEmpty ? pendingForeign.count : pendingAll.count),
                            isPresented: $confirmsAll, titleVisibility: .visible) {
            if !pendingAll.isEmpty {
                Button(LidarrDownloadsCopy.restartAll, role: .destructive) {
                    let rows = pendingAll
                    Task { await screen.restartAll(rows, model: model) }
                }
                .accessibilityIdentifier("lidarr-downloads-restart-all-confirm")
            }
            if !pendingForeign.isEmpty {
                // Round 13 (D63): the owner turns another app's on here, and only here.
                Button(LidarrDownloadsCopy.includeForeign(pendingForeign.count, alone: pendingAll.isEmpty), role: .destructive) {
                    let rows = pendingAll + pendingForeign
                    Task { await screen.restartAll(rows, model: model, includeForeign: true) }
                }
                .accessibilityIdentifier("lidarr-downloads-restart-all-foreign-confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LidarrDownloadsCopy.confirmMessage(pendingAll.count, foreign: pendingForeign.count))
        }
        .confirmationDialog(LidarrDownloadsCopy.restart + "?", isPresented: Binding(
            get: { pendingOne != nil }, set: { if !$0 { pendingOne = nil } }), titleVisibility: .visible) {
            if let row = pendingOne {
                if row.ask == .foreign {
                    // The flagged confirmation: the only place a restart of another app's download is allowed.
                    Button(LidarrDownloadsCopy.confirmButton(.foreign), role: .destructive) {
                        Task { await screen.restart([row], model: model, allowForeign: true) }
                        pendingOne = nil
                    }
                    .accessibilityIdentifier("lidarr-downloads-restart-foreign-confirm")
                } else {
                    Button(LidarrDownloadsCopy.confirmButton(row.ask), role: .destructive) {
                        Task { await screen.restart([row], model: model) }
                        pendingOne = nil
                    }
                    .accessibilityIdentifier("lidarr-downloads-restart-one-confirm")
                }
            }
            Button("Cancel", role: .cancel) { pendingOne = nil }
        } message: {
            Text(pendingOne.flatMap { LidarrDownloadsCopy.confirmOne($0.ask, phase: $0.phase) } ?? "")
        }
    }

    /// One row's Restart (round 13, D63): a stalled or failed copy restarts at once; one still going, one that couldn't
    /// import and another app's ask first (the last with the flagged confirmation).
    private func tapRestart(_ row: LidarrDownloads.Row) {
        guard row.canRestart else { return }
        if LidarrDownloadsCopy.confirmOne(row.ask) == nil {
            Task { await screen.restart([row], model: model) }
        } else {
            pendingOne = row
        }
    }

    private var canChange: Bool { model.changesAllowed && !model.isOffline && !screen.restarting }

    @ViewBuilder private func restartAllSection(_ board: LidarrDownloads) -> some View {
        let anyToRestart = !board.restartable.isEmpty || !board.restartableForeign.isEmpty
        if anyToRestart || !model.changesAllowed {
            Section {
                if anyToRestart {
                    Button(role: .destructive) {
                        pendingAll = board.restartable
                        // Fix M2: the cap goes to Lidarr's own first; only another app's that fit are offered.
                        pendingForeign = Array(board.restartableForeign.prefix(LidarrDownloadsCopy.foreignBatch(
                            own: board.restartable.count, foreign: board.restartableForeign.count)))
                        confirmsAll = !pendingAll.isEmpty || !pendingForeign.isEmpty
                    } label: {
                        Label(LidarrDownloadsCopy.restartAll, systemImage: "arrow.clockwise")
                    }
                    .disabled(!canChange)
                    .accessibilityIdentifier("lidarr-downloads-restart-all")
                }
            } footer: {
                Text(model.changesAllowed ? LidarrDownloadsCopy.footer : LidarrDownloadsCopy.changesOff)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [LidarrDownloads.Row], id: String,
                                      footer: String? = nil) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    DownloadRow(row: row, limit: model.stallLimit, canChange: canChange) { tapRestart(row) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {   // §10.7: never a full swipe
                        if row.canRestart {
                            Button(LidarrDownloadsCopy.restart) { tapRestart(row) }
                                .tint(.orange)
                                .disabled(!canChange)
                        }
                    }
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
            .accessibilityIdentifier("lidarr-downloads-\(id)")
        }
    }
}

private struct DownloadRow: View {
    let row: LidarrDownloads.Row
    let limit: StallLimit
    let canChange: Bool
    let restart: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.album.isEmpty ? "Unknown album" : row.album).font(.body).lineLimit(2)
                if !row.artist.isEmpty {
                    Text(row.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Label(LidarrDownloadsCopy.status(row, limit: limit), systemImage: LidarrDownloadsCopy.symbol(row.phase))
                    .font(.footnote)
                    .foregroundStyle([.active, .notStarted].contains(row.section) ? Color.secondary : Color.orange)
                if row.phase == .downloading, let progress = row.progress {
                    ProgressView(value: progress).accessibilityHidden(true)
                }
                if let message = row.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
                if let client = row.client, !client.isEmpty {
                    Text(client).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if row.canRestart {
                // Y7: the design system's tinted capsule (44 pt target), not iOS's bordered style.
                CapsuleButton(LidarrDownloadsCopy.restart, symbol: "arrow.clockwise", action: restart)
                    .disabled(!canChange)
                    .accessibilityIdentifier("lidarr-downloads-restart-\(row.id)")
            }
        }
    }
}
