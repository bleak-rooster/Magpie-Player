import LidarrKit
import Observation
import Requests
import SwiftUI

/// Round 12 item 6 (D49): the words of Settings › New music › Downloads in Lidarr. This page sits under the Lidarr
/// section, which names the service already.
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
        switch row.phase {
        case .downloading: row.progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading"
        case .queued: "Waiting to start"
        case .waitingToImport: "Waiting to import"
        case .importing: "Importing"
        case .stalled: "No progress for \(limit.title) or more"
        case .failed: "Failed"
        }
    }

    static func symbol(_ phase: LidarrDownloads.Phase) -> String {
        switch phase {
        case .downloading: "arrow.down.circle.dotted"
        case .queued: "clock"
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
        let restarted = outcomes.filter { $0 == .restarted || $0 == .removedNotSearched }.count
        let unsearched = outcomes.filter { $0 == .removedNotSearched }.count
        let limited = outcomes.filter { $0 == .limitReached }.count
        let gone = outcomes.filter { $0 == .gone }.count
        let unavailable = outcomes.filter { $0 == .unavailable }.count
        let refused = outcomes.count - restarted - limited - gone - unavailable
        var parts: [String] = []
        if restarted > 0 { parts.append(outcomes.count == 1 ? "Restarted." : "Restarted \(restarted).") }
        if unsearched > 0 { parts.append("Lidarr will look again on its own schedule.") }
        if limited > 0 { parts.append("Magpie has already tried five copies of that request.") }
        if gone > 0 { parts.append(gone == 1 ? "One had already left the list." : "\(gone) had already left the list.") }
        if refused > 0 { parts.append(refused == 1 ? "One is importing or done, so it was left alone." : "\(refused) are importing or done, so they were left alone.") }
        if unavailable > 0 { parts.append("Couldn't reach Lidarr for \(unavailable == 1 ? "one" : String(unavailable)). Try again in a moment.") }
        return parts.joined(separator: " ")
    }
}

/// The screen's state: the queue read every 5 s while it's open, the stall watch, and the restarter (one per gate).
@MainActor @Observable final class LidarrDownloadsScreen {
    static let refreshInterval: Duration = .seconds(5)

    private(set) var board: LidarrDownloads?
    private(set) var unreachable = false
    private(set) var restarting = false
    private(set) var message: String?
    @ObservationIgnored private var watch = QueueStallWatch()
    @ObservationIgnored private var restarter: (gate: ObjectIdentifier, restarter: LidarrDownloadRestarter)?

    /// One read of the queue and the download clients.
    func refresh(_ model: AppModel, now: Date = Date()) async {
        guard let client = model.lidarrClient, !model.isOffline else { return }
        do {
            async let queue = client.queueDetailsNamed()
            async let clients = client.downloadClients()
            let (items, setup) = try await (queue, clients)
            watch.observe(items, at: now)
            board = LidarrDownloads(items, soulseekClients: Set(setup.filter(\.isSoulseek).map { $0.name.lowercased() }),
                                    watch: watch, stallLimit: model.stallLimit.seconds, now: now)
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

    func restart(_ ids: [Int], model: AppModel) async {
        guard !ids.isEmpty, let restarter = restarter(model) else { return }
        restarting = true
        defer { restarting = false }
        let outcomes = ids.count == 1 ? [await restarter.restart(ids[0])] : await restarter.restartAll(ids)
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

/// Settings › New music › Downloads in Lidarr: everything in Lidarr's queue, whoever asked for it (D49), as Active,
/// Stalled and Failed, with Restart on the stalled and failed ones and Restart all (one confirmation, 25 at a time).
struct LidarrDownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var screen = LidarrDownloadsScreen()
    @State private var confirmsAll = false

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
        .confirmationDialog(LidarrDownloadsCopy.confirmTitle(screen.board?.restartable.count ?? 0),
                            isPresented: $confirmsAll, titleVisibility: .visible) {
            Button(LidarrDownloadsCopy.restartAll, role: .destructive) {
                let ids = screen.board?.restartable.map(\.id) ?? []
                Task { await screen.restart(ids, model: model) }
            }
            .accessibilityIdentifier("lidarr-downloads-restart-all-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LidarrDownloadsCopy.confirmMessage(screen.board?.restartable.count ?? 0))
        }
    }

    private var canChange: Bool { model.changesAllowed && !model.isOffline && !screen.restarting }

    @ViewBuilder private func restartAllSection(_ board: LidarrDownloads) -> some View {
        if !board.restartable.isEmpty || !model.changesAllowed {
            Section {
                if !board.restartable.isEmpty {
                    Button(role: .destructive) {
                        confirmsAll = true
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
                        Task { await screen.restart([row.id], model: model) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {   // §10.7: never a full swipe
                        if row.canRestart {
                            Button(LidarrDownloadsCopy.restart) { Task { await screen.restart([row.id], model: model) } }
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
