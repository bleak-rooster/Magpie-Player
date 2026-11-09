import AurralKit
import DesignSystem
import Observation
import SwiftUI

/// Round 24 C (D213): the page's state: the board, read every `songsStillComingInterval` while the page is on screen
/// and the app is active, and the one action under way.
@MainActor @Observable final class SongsStillComingScreen {
    private(set) var board: SongsStillComing.Board?
    private(set) var unreachable = false
    private(set) var working = false
    var message: String?

    func refresh(_ model: AppModel) async {
        guard !model.isOffline else { return }
        do {
            board = try await model.readSongsStillComing()
            unreachable = false
        } catch {
            unreachable = AppModel.isCancellation(error) ? unreachable : true   // a read cut short says nothing
        }
    }

    /// Reads every interval until the page goes away or the app leaves the foreground (its `.task` is cancelled).
    func follow(_ model: AppModel) async {
        while !Task.isCancelled {
            await refresh(model)
            do { try await Task.sleep(for: AppModel.songsStillComingInterval) } catch { return }
        }
    }

    /// One action, sent once; the board read again after it (or a plain line saying why not).
    func act(_ model: AppModel, _ send: () async throws -> SongsStillComing.Board) async {
        working = true
        defer { working = false }
        do { board = try await send() } catch {
            message = SongsStillComingCopy.message(for: error)
            await refresh(model)
        }
    }

    func searchNowAll(_ model: AppModel, _ board: SongsStillComing.Board) async {
        working = true
        defer { working = false }
        do { _ = try await model.searchNowAll(board) } catch { message = SongsStillComingCopy.message(for: error) }
        await refresh(model)
    }
}

/// Round 24 C (owner, 2026-11-08, item 6; D213, D214; ruling Q5): "Songs still coming", reached from Settings › Aurral
/// and Home's banner while a song is held for review. Sections by Aurral's state, each a heading with a symbol; rows
/// name the song, the artist, the flow or playlist, the state (text and symbol) and, with "Show everyone's flows" on,
/// whose it is. Approve / Try another source / Search now only on the user's own songs, online, with `canManage`;
/// "Search now for N" at the top. No Cancel.
struct AurralDownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = SongsStillComingScreen()
    @State private var approving: SongsStillComing.Row?
    @State private var denying: SongsStillComing.Row?
    @State private var confirmsAll = false
    @State private var pendingAll: SongsStillComing.Board?
    @State private var showsDone = false

    var body: some View {
        List {
            if model.isOffline {
                Section { OfflineNotice() }
            }
            if screen.unreachable {
                Section {
                    Label(SongsStillComingCopy.unreachable, systemImage: "exclamationmark.icloud")
                        .accessibilityIdentifier("aurral-downloads-unreachable")
                }
            }
            if let message = screen.message {
                Section { Text(message).accessibilityIdentifier("aurral-downloads-message") }
            }
            if let board = screen.board {
                if board.isEmpty {
                    ContentUnavailableView(SongsStillComingCopy.empty, systemImage: "checkmark.circle",
                                           description: Text(SongsStillComingCopy.noneHeld))
                        .accessibilityIdentifier("aurral-downloads-empty")
                } else {
                    searchNowAllSection(board)
                    section(.held, board.held, footer: board.held.isEmpty ? nil : SongsStillComingCopy.heldNote)
                    section(.notFound, board.notFound)
                    section(.looking, board.looking)
                    section(.downloading, board.downloading)
                    if board.held.isEmpty {
                        Section {
                            Text(SongsStillComingCopy.noneHeld).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                doneSection(board.doneRecently)
            } else if !screen.unreachable, !model.isOffline {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(SongsStillComingCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase == .active) {   // paused while the app isn't in front
            guard scenePhase == .active else { return }
            await screen.follow(model)
        }
        .refreshable { await RefreshSafety.run { await screen.refresh(model) } }
        .confirmationDialog(SongsStillComingCopy.approveTitle, isPresented: Binding(
            get: { approving != nil }, set: { if !$0 { approving = nil } }), titleVisibility: .visible,
                            presenting: approving) { row in
            Button(SongsStillComingCopy.approve) { Task { await screen.act(model) { try await model.approve(row) } } }
                .accessibilityIdentifier("aurral-downloads-approve-confirm")
            Button(DiscoverPagesCopy.cancel, role: .cancel) {}
        } message: { row in
            Text("\(row.job.trackName) \u{00B7} \(row.job.artistName)")
        }
        .confirmationDialog(SongsStillComingCopy.tryAnotherSourceTitle, isPresented: Binding(
            get: { denying != nil }, set: { if !$0 { denying = nil } }), titleVisibility: .visible,
                            presenting: denying) { row in
            Button(SongsStillComingCopy.tryAnotherSource, role: .destructive) {
                Task { await screen.act(model) { try await model.tryAnotherSource(row) } }
            }
            .accessibilityIdentifier("aurral-downloads-deny-confirm")
            Button(DiscoverPagesCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(SongsStillComingCopy.tryAnotherSourceMessage)
        }
        .confirmationDialog(SearchAgainCopy.confirmTitle(pendingAll.map { model.searchNowBatch($0).count } ?? 0),
                            isPresented: $confirmsAll, titleVisibility: .visible) {
            Button(SongsStillComingCopy.searchNow) {
                if let board = pendingAll { Task { await screen.searchNowAll(model, board) } }
            }
            .accessibilityIdentifier("aurral-downloads-search-all-confirm")
            Button(DiscoverPagesCopy.cancel, role: .cancel) {}
        } message: {
            Text(SearchAgainCopy.confirmMessage)
        }
    }

    @ViewBuilder private func searchNowAllSection(_ board: SongsStillComing.Board) -> some View {
        let count = model.searchNowBatch(board).count
        if count > 0 {
            Section {
                Button {
                    pendingAll = board
                    confirmsAll = true
                } label: {
                    Label(SongsStillComingCopy.searchNowAll(count), systemImage: SongsStillComingCopy.symbol(.notFound))
                        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                }
                .disabled(screen.working)
                .accessibilityIdentifier("aurral-downloads-search-all")
            }
        }
    }

    @ViewBuilder private func section(_ section: SongsStillComing.Section, _ rows: [SongsStillComing.Row],
                                      footer: String? = nil) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    SongStillComingRow(row: row, everyone: model.showEveryonesFlows, actions: model.actions(for: row),
                                       working: screen.working) { action in tap(action, row) }
                }
            } header: {
                Label(SongsStillComingCopy.heading(section), systemImage: SongsStillComingCopy.symbol(section))
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                if let footer { Text(footer) }
            }
            .accessibilityIdentifier("aurral-downloads-\(section.rawValue)")
        }
    }

    /// Done recently, collapsed (the last 10 Aurral lists).
    @ViewBuilder private func doneSection(_ rows: [SongsStillComing.Row]) -> some View {
        if !rows.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsDone) {
                    ForEach(rows) { row in
                        SongStillComingRow(row: row, everyone: model.showEveryonesFlows, actions: [], working: false) { _ in }
                    }
                } label: {
                    Label(SongsStillComingCopy.heading(.doneRecently), systemImage: SongsStillComingCopy.symbol(.doneRecently))
                        .frame(minHeight: Tokens.minHitSize)
                }
                .accessibilityIdentifier("aurral-downloads-done")
            }
        }
    }

    private func tap(_ action: SongsStillComingAction, _ row: SongsStillComing.Row) {
        switch action {
        case .approve: approving = row
        case .tryAnotherSource: denying = row
        case .searchNow: Task { await screen.act(model) { try await model.searchNow(row) } }
        }
    }
}

/// One song: its title, artist, flow or playlist, state (text and symbol), whose it is when everyone's are shown, and
/// its actions as 44 pt capsules, each also a VoiceOver action.
private struct SongStillComingRow: View {
    let row: SongsStillComing.Row
    let everyone: Bool
    let actions: [SongsStillComingAction]
    let working: Bool
    let perform: (SongsStillComingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.job.trackName).font(.body).lineLimit(2)
            Text(row.job.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(row.item.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            if everyone, !row.own, let owner = row.item.ownerUsername, !owner.isEmpty {
                Text(owner).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(SongsStillComingCopy.madeBy(owner))
            }
            Label(SongsStillComingCopy.state(row), systemImage: SongsStillComingCopy.symbol(row.section))
                .font(.footnote).foregroundStyle(.secondary)
            if !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Spacing.s) { buttons }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) { buttons }
                }
                .padding(.top, Tokens.Spacing.xs)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(Self.title(action)) { perform(action) }
            }
        }
        .accessibilityIdentifier("aurral-downloads-row-\(row.job.id)")
    }

    @ViewBuilder private var buttons: some View {
        ForEach(actions, id: \.self) { action in
            CapsuleButton(Self.title(action), symbol: Self.symbol(action)) { perform(action) }
                .disabled(working)
                .accessibilityIdentifier("aurral-downloads-\(Self.id(action))-\(row.job.id)")
        }
    }

    static func title(_ action: SongsStillComingAction) -> String {
        switch action {
        case .approve: SongsStillComingCopy.approve
        case .tryAnotherSource: SongsStillComingCopy.tryAnotherSource
        case .searchNow: SongsStillComingCopy.searchNow
        }
    }

    static func symbol(_ action: SongsStillComingAction) -> String {
        switch action {
        case .approve: "checkmark"
        case .tryAnotherSource: "arrow.triangle.2.circlepath"
        case .searchNow: "magnifyingglass"
        }
    }

    static func id(_ action: SongsStillComingAction) -> String {
        switch action {
        case .approve: "approve"
        case .tryAnotherSource: "deny"
        case .searchNow: "search"
        }
    }
}

/// Round 24 C (D213): Settings › Aurral's row to the page (absent without what it needs).
struct SongsStillComingLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.songsStillComingAvailable {
            Section {
                NavigationLink {
                    AurralDownloadsView()
                } label: {
                    Label(SongsStillComingCopy.entry, systemImage: "arrow.down.circle.dotted")
                }
                .accessibilityIdentifier("aurral-songs-still-coming")
            } footer: {
                Text(SongsStillComingCopy.entryFooter)
            }
        }
    }
}

/// Round 24 C (D213): Home's banner while Aurral holds one of the user's songs for review; opens the page.
struct HeldSongsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.heldSongsWaiting
        if count > 0, !model.isOffline {
            NavigationLink {
                AurralDownloadsView()
            } label: {
                Label(SongsStillComingCopy.banner(count), systemImage: SongsStillComingCopy.symbol(.held))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(SongsStillComingCopy.bannerHint)
            .accessibilityIdentifier("aurral-held-banner")
        }
    }
}
