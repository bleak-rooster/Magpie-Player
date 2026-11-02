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
    static let changesOff = "Turn on \u{201C}Allow Magpie to change your library\u{201D} in New music to restart downloads."
    static let restart = "Restart"
    static let restartAll = "Restart all stalled and failed"
    static let footer = "Restart drops the copy, stops Lidarr picking that same copy again, and looks for another. "
        + "It never touches music already in your library."

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

    static func confirmMessage(_ count: Int) -> String {
        let cap = LidarrDownloadRestarter.maxPerTap
        let base = "Each one is dropped and looked for again."
        return count > cap ? base + " The first \(cap) now; the rest next time." : base
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
            some(count { $0 == .skipped }, one: outcomes.count == 1 ? "It started moving again, so it was left alone."
                                                                     : "One started moving again, so it was left alone.",
                 many: { "\($0) started moving again, so they were left alone." }),
            count { $0 == .limitReached } > 0 ? "Magpie has already tried five copies of that request." : nil,
            count { $0 == .magpieBusy } > 0 ? "Magpie is bringing that album home right now, so it was left alone." : nil,
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
            let board = LidarrDownloads(items, soulseekClients: soulseek, watch: watch,
                                        stallLimit: model.stallLimit.seconds, now: now)
            self.board = board
            model.lidarrDownloadsAttention = board.stalled.count + board.failed.count
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

    /// Each row is re-checked on a fresh read before it's restarted (fix round 1 I1).
    func restart(_ rows: [LidarrDownloads.Row], model: AppModel) async {
        guard !rows.isEmpty, let restarter = restarter(model) else { return }
        restarting = true
        defer { restarting = false }
        let outcomes = rows.count == 1 ? [await restarter.restart(rows[0])] : await restarter.restartAll(rows)
        message = LidarrDownloadsCopy.summary(outcomes)
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
/// Stalled and Failed, with Restart on the stalled and failed ones and Restart all (one confirmation, 25 at a time).
struct LidarrDownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var screen = LidarrDownloadsScreen()
    @State private var confirmsAll = false
    /// The rows Restart all was tapped for (minor M5: the dialog counts what it will do, not a later read).
    @State private var pendingAll: [LidarrDownloads.Row] = []

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
                if board.active.isEmpty, board.stalled.isEmpty, board.failed.isEmpty {
                    ContentUnavailableView(LidarrDownloadsCopy.empty, systemImage: "arrow.down.circle",
                                           description: Text(LidarrDownloadsCopy.emptyDetail))
                        .accessibilityIdentifier("lidarr-downloads-empty")
                } else {
                    restartAllSection(board)
                    section("Stalled", board.stalled, id: "stalled")
                    section("Failed", board.failed, id: "failed")
                    section("Active", board.active, id: "active")
                }
            } else if !screen.unreachable {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(LidarrDownloadsCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await screen.follow(model) }
        .refreshable { await screen.refresh(model) }
        .confirmationDialog(LidarrDownloadsCopy.confirmTitle(pendingAll.count),
                            isPresented: $confirmsAll, titleVisibility: .visible) {
            Button(LidarrDownloadsCopy.restartAll, role: .destructive) {
                let rows = pendingAll
                Task { await screen.restart(rows, model: model) }
            }
            .accessibilityIdentifier("lidarr-downloads-restart-all-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LidarrDownloadsCopy.confirmMessage(pendingAll.count))
        }
    }

    private var canChange: Bool { model.changesAllowed && !model.isOffline && !screen.restarting }

    @ViewBuilder private func restartAllSection(_ board: LidarrDownloads) -> some View {
        if !board.restartable.isEmpty || !model.changesAllowed {
            Section {
                if !board.restartable.isEmpty {
                    Button(role: .destructive) {
                        pendingAll = board.restartable
                        confirmsAll = !pendingAll.isEmpty
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

    @ViewBuilder private func section(_ title: String, _ rows: [LidarrDownloads.Row], id: String) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    DownloadRow(row: row, limit: model.stallLimit, canChange: canChange) {
                        Task { await screen.restart([row], model: model) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {   // §10.7: never a full swipe
                        if row.canRestart {
                            Button(LidarrDownloadsCopy.restart) { Task { await screen.restart([row], model: model) } }
                                .tint(.orange)
                                .disabled(!canChange)
                        }
                    }
                }
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
                    .foregroundStyle(row.section == .active ? Color.secondary : Color.orange)
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
                Button(LidarrDownloadsCopy.restart, action: restart)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(!canChange)
                    .accessibilityIdentifier("lidarr-downloads-restart-\(row.id)")
            }
        }
    }
}
