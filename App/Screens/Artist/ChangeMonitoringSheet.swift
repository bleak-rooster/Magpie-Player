import DesignSystem
import LidarrKit
import MagpieCore
import Requests
import SwiftUI

/// Round 24 (owner, 2026-11-08, item 10): the words of "Change what's monitored" and "Clean up unmatched songs", as the
/// plan gives them (D237, D240, D242, D244). About music, never about services (§5), except "Custom (set in Lidarr)",
/// which names where that setting lives.
enum MonitoringCopy {
    static let change = "Change what\u{2019}s monitored"
    static let cleanUp = "Clean up unmatched songs"
    static let custom = "Custom (set in Lidarr)"
    static let now = "Now"
    static let albums = "Albums", eps = "EPs", singles = "Singles"
    static let apply = "Change"
    static let changing = "Changing\u{2026}"
    static let chooseOne = "Choose at least one."
    static let footer = "Magpie asks before anything stops being monitored."
    static let deleteThem = "Delete them"
    static let keepThem = "Keep them"
    static let keptFavourite = "Kept because you favourited it"
    static let keptSaved = "Kept because it\u{2019}s in a playlist or on this iPhone"
    static let favouritesStay = "Songs you\u{2019}ve favourited or saved to a playlist stay."
    static let forGood = "They go from your library for good."
    static let done = "Done."
    static let pending = "Almost done. Magpie finishes this when it can."
    static let abandoned = "Something changed since you looked, so Magpie stopped. Nothing more was changed."
    static let nothingToChange = "That\u{2019}s what\u{2019}s monitored already."
    static let nothingToCleanUp = "Nothing to clean up. The songs you kept are monitored again, or changed."
    static let revert = "Put back how it was"
    static let revertMessage = "Goes back to what was monitored before Magpie changed it."
    static let revertConfirm = "Put it back"
    static let busy = "A change for this artist is still finishing. Try again in a moment."
    static let unavailable = "That didn\u{2019}t work. Try again in a moment."
    static let notHere = "Only artists in your main library can be changed here."
    static let switchOff = "Turn on \u{201C}Let Magpie change what Lidarr monitors for my artists\u{201D} in Settings \u{203A} Lidarr."
    static let changesOff = "Turn on \u{201C}Allow Magpie to change your library\u{201D} in Settings \u{203A} Lidarr."
    static let tryUnderWay = "Something you asked for by this artist is still on its way. Try again once it\u{2019}s here."

    /// Settings › Lidarr's switch (Q10), which names the service on its own settings page.
    static let toggle = "Let Magpie change what Lidarr monitors for my artists"
    static let toggleFooter = "Adds \u{201C}Change what\u{2019}s monitored\u{201D} to an artist\u{2019}s \u{22EF} menu. Magpie asks before anything stops being monitored, and never removes a song you\u{2019}ve favourited or saved."
    static let toggleNeedsChanges = "Turn on \u{201C}Allow Magpie to change your library\u{201D} first."

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// D240: "These stop being monitored: 6 albums, 41 songs (1.2 GB). Delete them now, or keep them?"
    static func prompt(albums: Int, songs: Int, bytes: Int64) -> String {
        "These stop being monitored: \(count(albums, "album", "albums")), \(count(songs, "song", "songs")) (\(size(bytes))). Delete them now, or keep them?"
    }

    /// The second confirmation, naming the count.
    static func confirmDelete(_ songs: Int) -> String { "Delete \(count(songs, "song", "songs"))?" }

    static func deleteSongs(_ songs: Int) -> String { "Delete \(count(songs, "song", "songs"))" }

    /// D242: "Removes 41 songs by <artist> that you chose not to keep monitoring. Songs you've favourited or saved to a
    /// playlist stay."
    static func cleanUpMessage(count n: Int, artist: String) -> String {
        "Removes \(count(n, "song", "songs")) by \(artist) that you chose not to keep monitoring. \(favouritesStay)"
    }

    static func confirmCleanUp(_ songs: Int) -> String { "Remove \(count(songs, "song", "songs"))?" }

    static func removeSongs(_ songs: Int) -> String { "Remove \(count(songs, "song", "songs"))" }

    /// "Albums + EPs".
    static func describe(_ t: ReleaseTypes) -> String {
        [(albums, t.albums), (eps, t.eps), (singles, t.singles)].filter(\.1).map(\.0).joined(separator: " + ")
    }

    static func outcome(_ o: MonitoringChanger.Outcome) -> (text: String, symbol: String) {
        switch o {
        case .finished: (done, "checkmark.circle")
        case .pending: (pending, "clock")
        case .abandoned: (abandoned, "exclamationmark.circle")
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case MonitoringChangeError.switchOff: switchOff
        case MonitoringChangeError.changesOff: changesOff
        case MonitoringChangeError.busy: busy
        case MonitoringChangeError.notInMainRoot: notHere
        case MonitoringChangeError.tryUnderWay: tryUnderWay
        case MonitoringChangeError.nothingToRevert: nothingToChange
        default: unavailable
        }
    }
}

/// D240: the delete-or-keep question's preferred (bold) answer is Keep them.
enum ChangeMonitoringFlow {
    static let preferredAnswer = ReduceChoice.default
}

/// Which of the artist's ⋯ items show (no dead buttons, all four setups): only with Lidarr, online, both switches on,
/// for an artist Lidarr has that isn't one of Magpie's finds; the clean-up only when songs were kept (D241).
enum ArtistMonitoringPresentation {
    enum Item: Equatable { case change, cleanUp }

    static func lidarrId(_ state: ArtistLidarrState?) -> Int? {
        switch state {
        case .monitored(let id, _)?, .notMonitored(let id, _)?: id
        default: nil
        }
    }

    static func items(lidarr: Bool, offline: Bool, changesAllowed: Bool, monitoringAllowed: Bool, state: ArtistLidarrState?,
                      hasKept: Bool) -> [Item] {
        guard lidarr, !offline, changesAllowed, monitoringAllowed, lidarrId(state) != nil else { return [] }
        return hasKept ? [.change, .cleanUp] : [.change]
    }
}

/// The artist page's part (one per page): whether songs were kept, which sheet is open. Reading it also carries on a
/// change of the artist that didn't finish (from the ledger, after a lost answer or a relaunch).
@MainActor @Observable final class ArtistMonitoringState {
    var hasKept = false
    var showsChange = false
    var showsCleanUp = false

    func refresh(_ model: AppModel, lidarrId: Int?) async {
        guard let lidarrId, model.monitoringChangesAllowed, model.changesAllowed, !model.isOffline,
              let changer = model.monitoringChanger else {
            hasKept = false
            return
        }
        _ = await changer.resume(artistId: lidarrId)
        hasKept = await changer.hasKept(artistId: lidarrId)
    }
}

/// The ⋯ items (in the page's one `PageMoreMenu`).
struct ArtistMonitoringMenuItems: View {
    @Environment(AppModel.self) private var model
    let state: ArtistMonitoringState
    let line: ArtistLidarrModel?

    var body: some View {
        let items = ArtistMonitoringPresentation.items(
            lidarr: model.lidarr != nil, offline: model.isOffline, changesAllowed: model.changesAllowed,
            monitoringAllowed: model.monitoringChangesAllowed, state: line?.state, hasKept: state.hasKept)
        if items.contains(.change) {
            Button(MonitoringCopy.change, systemImage: "slider.horizontal.3") { state.showsChange = true }
                .accessibilityIdentifier("artist-change-monitoring")
        }
        if items.contains(.cleanUp) {
            Button(MonitoringCopy.cleanUp, systemImage: "trash") { state.showsCleanUp = true }
                .accessibilityIdentifier("artist-clean-up-unmatched")
        }
    }
}

extension View {
    /// Round 24: the two sheets the artist's ⋯ items open, and the page's reading of its kept songs.
    func artistMonitoring(_ state: ArtistMonitoringState, line: ArtistLidarrModel?) -> some View {
        modifier(ArtistMonitoring(state: state, line: line))
    }
}

private struct ArtistMonitoring: ViewModifier {
    @Environment(AppModel.self) private var model
    @Bindable var state: ArtistMonitoringState
    let line: ArtistLidarrModel?

    func body(content: Content) -> some View {
        let id = ArtistMonitoringPresentation.lidarrId(line?.state)
        content
            .task(id: "\(id ?? 0)-\(model.monitoringChangesAllowed)") { await state.refresh(model, lidarrId: id) }
            .sheet(isPresented: $state.showsChange) {
                if let id, let line {
                    ChangeMonitoringSheet(lidarrId: id, artistName: line.name) {
                        Task { await state.refresh(model, lidarrId: id); await line.refresh() }
                    }
                }
            }
            .sheet(isPresented: $state.showsCleanUp) {
                if let id, let line {
                    CleanUpUnmatchedSheet(lidarrId: id, artistName: line.name) {
                        Task { await state.refresh(model, lidarrId: id) }
                    }
                }
            }
    }
}

/// D237: Albums / EPs / Singles (at least one), preset from the artist's profile when it is one of Magpie's, otherwise
/// "Custom (set in Lidarr)" shown as it is. Change reads first: when something falls out with songs, the owner is asked
/// to delete or keep them (Keep by default, D240) before anything is sent; Delete them asks once more, naming the count.
/// D244: "Put back how it was" while the artist is on the profile Magpie's last change set.
struct ChangeMonitoringSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let lidarrId: Int
    let artistName: String
    var onChanged: () -> Void

    @State private var current: MonitoringCurrent?
    @State private var loadError: String?
    @State private var albums = true
    @State private var eps = true
    @State private var singles = false
    @State private var working = false
    @State private var preview: MonitoringPreview?
    @State private var asksDeleteOrKeep = false
    @State private var confirmsDelete = false
    @State private var confirmsRevert = false
    @State private var result: (text: String, symbol: String)?
    private let themed = Themed()

    private var chosen: ReleaseTypes { ReleaseTypes(albums: albums, eps: eps, singles: singles) }

    /// The switches are as the artist's Magpie profile has them already.
    private var unchanged: Bool {
        current?.types.map { $0.albums == albums && $0.eps == eps && $0.singles == singles } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let current {
                    Section {
                        LabeledContent(MonitoringCopy.now) {
                            Label(current.types.map(MonitoringCopy.describe) ?? MonitoringCopy.custom,
                                  systemImage: current.types == nil ? "slider.horizontal.3" : "checkmark.circle")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("monitoring-now")
                    } header: {
                        Text(artistName)
                    }
                    Section {
                        Toggle(MonitoringCopy.albums, isOn: $albums).accessibilityIdentifier("monitoring-albums")
                        Toggle(MonitoringCopy.eps, isOn: $eps).accessibilityIdentifier("monitoring-eps")
                        Toggle(MonitoringCopy.singles, isOn: $singles).accessibilityIdentifier("monitoring-singles")
                    } footer: {
                        Text(chosen.hasKind ? MonitoringCopy.footer : MonitoringCopy.chooseOne)
                    }
                    .disabled(working)
                    if current.canRevert {
                        Section {
                            Button(MonitoringCopy.revert) { confirmsRevert = true }
                                .frame(minHeight: Tokens.minHitSize)
                                .disabled(working)
                                .accessibilityIdentifier("monitoring-revert")
                        } footer: {
                            Text(MonitoringCopy.revertMessage)
                        }
                    }
                } else if let loadError {
                    Section { Label(loadError, systemImage: "exclamationmark.circle") }
                } else {
                    Section { ProgressView() }
                }
                if let result {
                    Section {
                        Label(result.text, systemImage: result.symbol)
                            .foregroundStyle(themed.palette.inkColor)
                            .accessibilityIdentifier("monitoring-result")
                    }
                }
            }
            .navigationTitle(MonitoringCopy.change)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result?.symbol == "checkmark.circle" ? "Done" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? MonitoringCopy.changing : MonitoringCopy.apply) { Task { await change() } }
                        .disabled(working || current == nil || current?.busy == true || !chosen.hasKind || unchanged)
                        .accessibilityIdentifier("monitoring-apply")
                }
            }
            .overlay { if working { ProgressView() } }
            .magpieScreen()
            .task { await load() }
            // D240: Delete them (destructive), Keep them (the preferred, bold answer), Cancel (nothing sent).
            .alert(preview.map { MonitoringCopy.prompt(albums: $0.albumCount, songs: $0.songCount, bytes: $0.bytes) } ?? "",
                   isPresented: $asksDeleteOrKeep, presenting: preview) { p in
                Button(MonitoringCopy.deleteThem, role: .destructive) { confirmsDelete = true }
                    .disabled(p.deletable.isEmpty)
                Button(MonitoringCopy.keepThem) { Task { await apply(p, .keep) } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { preview = nil }
            } message: { p in
                if !p.excludedFileIds.isEmpty { Text(MonitoringCopy.favouritesStay) }
            }
            .alert(preview.map { MonitoringCopy.confirmDelete($0.deletable.count) } ?? "", isPresented: $confirmsDelete,
                   presenting: preview) { p in
                Button(MonitoringCopy.deleteSongs(p.deletable.count), role: .destructive) { Task { await apply(p, .delete) } }
                Button("Cancel", role: .cancel) { preview = nil }
            } message: { _ in
                Text(MonitoringCopy.forGood)
            }
            .alert(MonitoringCopy.revert, isPresented: $confirmsRevert) {
                Button(MonitoringCopy.revertConfirm) { Task { await revert() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(MonitoringCopy.revertMessage)
            }
        }
    }

    private func load() async {
        guard let changer = model.monitoringChanger else { loadError = MonitoringCopy.unavailable; return }
        do {
            let now = try await changer.current(artistId: lidarrId)
            current = now
            if let types = now.types { albums = types.albums; eps = types.eps; singles = types.singles }
            if now.busy { result = (MonitoringCopy.busy, "clock") }
        } catch {
            loadError = MonitoringCopy.message(for: error)
        }
    }

    /// Reads what the choice would do; asks first when songs would be left behind.
    private func change() async {
        guard let changer = model.monitoringChanger, chosen.hasKind else { return }
        working = true
        defer { working = false }
        result = nil
        do {
            var p = try await changer.preview(artistId: lidarrId, types: chosen, keep: MonitoringKeepList())
            if p.changesNothing { result = (MonitoringCopy.nothingToChange, "checkmark.circle"); return }
            if p.asksDeleteOrKeep {
                // What the owner keeps is read only now, when a delete could be offered (when in doubt, keep).
                let keep = try await model.monitoringKeepLists(artist: artistName).all
                p = try await changer.preview(artistId: lidarrId, types: chosen, keep: keep)
                preview = p
                asksDeleteOrKeep = true
                return
            }
            await apply(p, .keep)
        } catch {
            result = (MonitoringCopy.message(for: error), "exclamationmark.circle")
        }
    }

    private func apply(_ p: MonitoringPreview, _ choice: ReduceChoice) async {
        guard let changer = model.monitoringChanger else { return }
        working = true
        defer { working = false; preview = nil }
        do {
            result = MonitoringCopy.outcome(try await changer.apply(p, choice: choice))
            onChanged()
            await load()
        } catch {
            result = (MonitoringCopy.message(for: error), "exclamationmark.circle")
        }
        AccessibilityNotification.Announcement(result?.text ?? "").post()
    }

    private func revert() async {
        guard let changer = model.monitoringChanger else { return }
        working = true
        defer { working = false }
        do {
            result = MonitoringCopy.outcome(try await changer.revert(artistId: lidarrId))
            onChanged()
            await load()
        } catch {
            result = (MonitoringCopy.message(for: error), "exclamationmark.circle")
        }
        AccessibilityNotification.Announcement(result?.text ?? "").post()
    }
}
