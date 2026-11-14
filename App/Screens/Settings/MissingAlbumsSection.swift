import DesignSystem
import LidarrKit
import Requests
import SwiftUI

/// Round 27 R (owner, 2026-11-14): the words of Settings › Lidarr › Missing albums and of Clear all (plan §8, final).
/// Settings may name Lidarr; nothing here names where downloads come from.
enum MissingAlbumsCopy {
    static let section = "Missing albums"
    static let searchNow = "Search for missing albums now"
    static let confirmTitle = "Search for every missing album?"
    static let confirmMessage = "Lidarr looks for every album it watches that you don\u{2019}t have yet. "
        + "This can take a while and may bring in a lot of music."
    static let confirmButton = "Search"
    static let every = "Search automatically"
    static let everyFooter = "Magpie asks Lidarr when you open it, once the time has passed."
    /// G1's words, as the other Lidarr rows say them.
    static let changesOff = "Turn on \u{201C}Allow Magpie to change your library\u{201D} first."
    static let unreachable = "Couldn\u{2019}t reach Lidarr. Try again in a moment."
    static let clearAll = "Clear all downloads and search again"
    static let clearConfirmButton = "Clear and search again"

    static func title(_ every: MissingAlbumSchedule.Every) -> String {
        switch every {
        case .off: "Off"
        case .day: "Every day"
        case .week: "Every week"
        }
    }

    static func footer(changesAllowed: Bool) -> String { changesAllowed ? everyFooter : changesOff }

    /// "Last asked: 2 hours ago", or "Not asked yet".
    static func lastAsked(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not asked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last asked: " + formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// The outcome under "Search for missing albums now": text plus a symbol (D3).
    static func answer(_ answer: MissingAlbumSchedule.Answer) -> (text: String, symbol: String) {
        switch answer {
        case .sent: ("Lidarr is looking for your missing albums.", "magnifyingglass")
        case .alreadyRunning: ("Lidarr is already looking for missing albums.", "clock")
        case .refused: ("Couldn\u{2019}t ask Lidarr just now. Nothing was sent.", "exclamationmark.triangle")
        case .lostAnswer: ("Magpie couldn\u{2019}t hear back from Lidarr. It may already be looking.", "exclamationmark.triangle")
        }
    }

    private static func downloads(_ n: Int) -> String { n == 1 ? "1 download" : "\(n) downloads" }

    static func clearTitle(_ count: Int) -> String { "Clear \(downloads(count)) and search again?" }

    /// The confirmation's message; per Q2 a second line names how many another app started, and a third how many are
    /// past the run's 100.
    static func clearMessage(foreign: Int, more: Int) -> String {
        var text = "Each one is stopped, removed and blocked so the same copy isn\u{2019}t picked again. Once they\u{2019}re "
            + "all gone, Magpie asks Lidarr to look for those albums again. Anything importing is left alone."
        if foreign > 0 { text += "\n\n\(foreign) of them " + (foreign == 1 ? "was" : "were") + " started by another app." }
        if more > 0 { text += "\n\n" + stillQueued(more) }
        return text
    }

    static func clearProgress(_ done: Int, of total: Int) -> String { "Clearing downloads: \(done) of \(total)" }

    private static func stillQueued(_ n: Int) -> String {
        n == 1 ? "1 more download is still in the queue." : "\(n) more downloads are still in the queue."
    }

    /// One line after a Clear all.
    static func clearOutcome(_ o: ClearAllOutcome) -> String {
        if o.changesOff, o.cleared == 0 { return changesOff }
        var parts: [String] = []
        if o.cleared > 0 {
            var line = "Cleared \(downloads(o.cleared))."
            if o.searchedAlbums > 0 {
                line += " Looking for " + (o.searchedAlbums == 1 ? "1 album" : "\(o.searchedAlbums) albums") + " again."
            }
            parts.append(line)
        }
        if o.clearedWithoutSearch > 0 {
            parts.append(o.clearedWithoutSearch == 1 ? "1 was cleared without a new search."
                         : "\(o.clearedWithoutSearch) were cleared without a new search.")
        }
        if o.notCleared > 0 {
            parts.append(o.notCleared == 1 ? "Couldn\u{2019}t clear 1 download. It was left as it was."
                         : "Couldn\u{2019}t clear \(o.notCleared) downloads. They were left as they were.")
        }
        if o.left > 0 { parts.append(stillQueued(o.left)) }
        if o.changesOff { parts.append(changesOff) }
        return parts.isEmpty ? LidarrDownloadsCopy.empty : parts.joined(separator: " ")
    }
}

/// Settings › Lidarr › Missing albums (D290–D292): search now (confirmed), search automatically, and Clear all (its last
/// row). Shown only while Lidarr is connected; offline the whole Lidarr page is disabled under "You're offline"; without
/// "Allow Magpie to change your library" the rows are disabled with its footer.
struct MissingAlbumsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsSearch = false
    @State private var clearPlan: ClearAllPlan?

    var body: some View {
        if model.showsMissingAlbums {
            let usable = model.missingAlbumsUsable
            let state = model.missingAlbums
            Section {
                Button {
                    confirmsSearch = true
                } label: {
                    HStack {
                        Label(MissingAlbumsCopy.searchNow, systemImage: "magnifyingglass")
                        Spacer()
                        if state.searching { ProgressView() }
                    }
                }
                .disabled(!usable || state.searching)
                .accessibilityIdentifier("missing-albums-search")
                if let answer = state.searchAnswer {
                    let words = MissingAlbumsCopy.answer(answer)
                    Label(words.text, systemImage: words.symbol)
                        .font(.footnote)
                        .accessibilityIdentifier("missing-albums-outcome")
                }
                Picker(MissingAlbumsCopy.every, selection: Binding(
                    get: { model.missingSearchEvery },
                    set: { model.missingSearchEvery = $0 })) {
                    ForEach(MissingAlbumSchedule.Every.allCases) { Text(MissingAlbumsCopy.title($0)).tag($0) }
                }
                .disabled(!usable)
                .accessibilityIdentifier("missing-albums-every")
                Text(MissingAlbumsCopy.lastAsked(model.missingSearchLastAsked, now: Date()))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("missing-albums-last-asked")
                ClearAllButton(identifier: "missing-albums-clear-all", plan: $clearPlan)
            } header: {
                Text(MissingAlbumsCopy.section)
            } footer: {
                Text(MissingAlbumsCopy.footer(changesAllowed: model.changesAllowed))
            }
            .alert(MissingAlbumsCopy.confirmTitle, isPresented: $confirmsSearch) {
                Button(MissingAlbumsCopy.confirmButton) { Task { await model.searchMissingAlbumsNow() } }
                    .accessibilityIdentifier("missing-albums-search-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(MissingAlbumsCopy.confirmMessage)
            }
            .clearAllConfirmation(plan: $clearPlan)
        }
    }
}

/// "Clear all downloads and search again" (destructive style), its progress and outcome: the last row of Missing
/// albums and beside Restart all on Downloads in Lidarr. A tap reads the queue for the confirmation (`plan`).
struct ClearAllButton: View {
    @Environment(AppModel.self) private var model
    let identifier: String
    @Binding var plan: ClearAllPlan?

    var body: some View {
        let state = model.missingAlbums
        Button(role: .destructive) {
            Task { plan = await model.prepareClearAll() }
        } label: {
            HStack {
                Label(MissingAlbumsCopy.clearAll, systemImage: "xmark.circle")
                Spacer()
                if state.preparing { ProgressView() }
            }
        }
        .disabled(!model.missingAlbumsUsable || state.clearing || state.preparing)
        .accessibilityIdentifier(identifier)
        if let progress = state.clearProgress {
            Label(MissingAlbumsCopy.clearProgress(progress.done, of: progress.total), systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .accessibilityIdentifier("clear-all-progress")
        } else if let message = state.clearMessage {
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .accessibilityIdentifier("clear-all-message")
        }
    }
}

extension View {
    /// Clear all's one confirmation (D292), shared by both places so the flag that includes another app's downloads
    /// (per Q2, named in its message) is set on one line only.
    func clearAllConfirmation(plan: Binding<ClearAllPlan?>) -> some View {
        modifier(ClearAllConfirmation(plan: plan))
    }
}

private struct ClearAllConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var plan: ClearAllPlan?

    func body(content: Content) -> some View {
        content.confirmationDialog(MissingAlbumsCopy.clearTitle(plan?.count ?? 0), isPresented: Binding(
            get: { plan != nil }, set: { if !$0 { plan = nil } }), titleVisibility: .visible) {
            if let confirmed = plan {
                Button(MissingAlbumsCopy.clearConfirmButton, role: .destructive) {
                    Task { await model.clearAllDownloads(confirmed, includeForeign: true) }
                    plan = nil
                }
                .accessibilityIdentifier("clear-all-confirm")
            }
            Button("Cancel", role: .cancel) { plan = nil }
        } message: {
            Text(MissingAlbumsCopy.clearMessage(foreign: plan?.foreign ?? 0, more: plan?.more ?? 0))
        }
    }
}
