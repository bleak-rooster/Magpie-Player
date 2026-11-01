import DesignSystem
import LidarrKit
import MagpieCore
import Requests
import SwiftUI

/// What an artist page's Lidarr line shows (P3, kept visible by R20): the status (text plus symbol, D3), and at most
/// one action or hint. R20: the action is "Add to your library" (not in Lidarr) or "Add more to your library" (an
/// artist Magpie added that isn't monitored), each opening the Add sheet (or one confirmation with Add with my
/// defaults on).
struct ArtistLidarrPresentation: Equatable {
    enum Action: Equatable { case add, addMore }
    enum Hint: Equatable {
        /// "Allow Magpie to change your library" is off: replaces the button, with a link to Settings › New music.
        case turnOnChanges
        /// Magpie's profiles or main root aren't set up yet.
        case setUpFirst
    }

    var text: String
    var symbol: String
    var action: Action?
    var hint: Hint?

    static let offline = ArtistLidarrPresentation(text: AppModel.offlineCopy, symbol: "wifi.slash")

    /// Nil for no line (no Lidarr, or it couldn't be read).
    static func make(_ state: ArtistLidarrState?, offline: Bool, changesAllowed: Bool, canAdd: Bool,
                     justAdded: Bool = false) -> ArtistLidarrPresentation? {
        if offline { return .offline }
        guard let state else { return nil }
        switch state {
        case .monitored(_, let searching):
            let text = searching || justAdded ? "In Lidarr \u{00B7} Monitored \u{00B7} Searching\u{2026}" : "In Lidarr \u{00B7} Monitored"
            return ArtistLidarrPresentation(text: text, symbol: "checkmark.circle")
        case .notMonitored(_, let magpieAdded):
            var line = ArtistLidarrPresentation(text: "In Lidarr \u{00B7} Not monitored", symbol: "pause.circle")
            // Owner-data rule: only an artist Magpie added is offered "Add more to your library".
            if magpieAdded {
                if !changesAllowed { line.hint = .turnOnChanges }
                else if !canAdd { line.hint = .setUpFirst }
                else { line.action = .addMore }
            }
            return line
        case .notInLidarr:
            // Without the library's MBID the add asks Lidarr's search on the tap, and the owner picks the exact
            // artist in the Add sheet ("Which <artist>?", I3).
            var line = ArtistLidarrPresentation(text: "Not in Lidarr", symbol: "plus.circle")
            if !changesAllowed { line.hint = .turnOnChanges }
            else if !canAdd { line.hint = .setUpFirst }
            else { line.action = .add }
            return line
        }
    }

    static func actionTitle(_ action: Action) -> String {
        switch action {
        case .add: NewMusicCopy.addToLibrary
        case .addMore: NewMusicCopy.addMoreToLibrary
        }
    }

    static func hintText(_ hint: Hint) -> String {
        switch hint {
        case .turnOnChanges: "Turn on Allow Magpie to change your library in Settings \u{203A} New music to add more."
        case .setUpFirst: "Set up Magpie in Settings \u{203A} New music to add more."
        }
    }

    /// Lidarr's search has no artist of that exact name: nothing is added.
    static func notFound(_ artist: String) -> String { "Couldn't find \(artist) to add. Try again later." }
}

/// The artist page's Lidarr line: reads the state (never offline), and hands the page an Add (`addFlow`): the Add
/// sheet or one confirmation decides, then the add goes through the gate.
@MainActor @Observable final class ArtistLidarrModel {
    private(set) var state: ArtistLidarrState?
    private(set) var justAdded = false
    private(set) var working = false
    var error: String?
    /// The Add the page presents (`.addFlow`, which clears it as it shows).
    var addFlow: AddFlowRequest?

    /// What the last Add offered: the add uses only one of these (re-review N1).
    private var offered: [MBID] = []
    /// The MBID a successful add used, so later refreshes find the artist by it (only after a success: re-review N2).
    private var resolvedMBID: MBID?

    @ObservationIgnored private let model: AppModel
    let name: String
    let mbid: MBID?

    init(model: AppModel, name: String, mbid: MBID?) {
        self.model = model; self.name = name; self.mbid = mbid
    }

    var presentation: ArtistLidarrPresentation? {
        guard model.lidarr != nil else { return nil }   // without Lidarr nothing is shown
        return ArtistLidarrPresentation.make(state, offline: model.isOffline, changesAllowed: model.changesAllowed,
                                             canAdd: model.canAddArtists, justAdded: justAdded)
    }

    /// Reads Lidarr, unless offline (no request then) or there's no Lidarr. A failed read shows no line.
    func refresh() async {
        guard model.lidarr != nil, !model.isOffline else { return }
        do {
            let fresh = try await model.artistLidarrState(name: name, mbid: mbid ?? resolvedMBID)
            state = fresh
            // Lidarr's own state shows from now on, so "Searching…" never sticks after its search ended.
            if case .monitored? = fresh { justAdded = false }
        } catch {
            // Lidarr didn't answer: the last state stays (none at first: no line).
        }
    }

    /// "Add to your library": only asks. With the library's MBID the Add names the artist; without, Lidarr's search
    /// is read first (GETs) and the Add names the one exact match, or lists several to pick from; none: nothing can
    /// be added. Nothing is written until the Add is confirmed.
    func requestAdd() async {
        guard presentation?.action == .add, case .notInLidarr? = state, !working else { return }
        error = nil
        let candidates: [ArtistLidarr.Candidate]
        if let mbid {
            candidates = [ArtistLidarr.Candidate(mbid: mbid, name: name)]
        } else {
            working = true
            defer { working = false }
            do {
                candidates = try await model.artistCandidates(name: name)
            } catch {
                self.error = NewMusicCopy.message(for: error)
                return
            }
            guard !candidates.isEmpty else {
                error = ArtistLidarrPresentation.notFound(name)
                return
            }
        }
        offered = candidates.map(\.mbid)
        addFlow = model.addRequest(artist: name, candidates: candidates) { [weak self] mbid, choices in
            guard let self else { throw ArtistLidarrError.failed }
            try await self.add(mbid, choices)
        }
    }

    /// The owner confirmed this artist (one of those the Add offered) with these choices.
    func add(_ mbid: MBID, _ choices: DownloadChoices) async throws {
        guard offered.contains(mbid), presentation?.action == .add, case .notInLidarr? = state, !working else {
            throw ArtistLidarrError.failed
        }
        working = true
        defer { working = false }
        do {
            let id = try await model.addArtist(mbid: mbid, choices: choices)
            offered = []
            resolvedMBID = mbid
            state = .monitored(lidarrId: id, searching: true)
            justAdded = true
        } catch ArtistLidarrError.alreadyInLidarr {
            // Nothing written. With the library's own MBID it's this artist: show it as it is. A picked candidate
            // may be another artist: say so, and the line stays as it was (N2).
            if self.mbid != nil { await refresh() }
            throw ArtistLidarrError.alreadyInLidarr
        }
    }

    /// "Add more to your library", for an unmonitored artist Magpie added (the package proves it again).
    func requestAddMore() {
        guard presentation?.action == .addMore, case .notMonitored(let id, true)? = state, !working else { return }
        error = nil
        addFlow = model.addMoreRequest(artist: name, lidarrId: id) { [weak self] in
            self?.state = .monitored(lidarrId: id, searching: true)
            self?.justAdded = true
        }
    }

    /// How an Add from this line went: a failure shows under the line (a success shows as the new status).
    func finished(_ outcome: AddOutcome) {
        if !outcome.succeeded { error = outcome.message }
    }
}

/// The line under the artist's name.
struct ArtistLidarrLine: View {
    @Bindable var line: ArtistLidarrModel
    let presentation: ArtistLidarrPresentation
    /// False while another capsule takes the one place (Keep <artist> for an artist only in your Finds, R20).
    var showsAction = true
    /// R19: the outside album page names the artist ("Add <artist> to your library").
    var addTitle: String? = nil
    @State private var showsSettings = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        VStack(spacing: Tokens.Spacing.s) {
            Label(presentation.text, systemImage: presentation.symbol)
                .font(.subheadline)
                .foregroundStyle(p.ink2Color)
                .accessibilityIdentifier("artist-lidarr-status")
            if let action = presentation.action, showsAction {
                CapsuleButton(line.working ? "Adding\u{2026}" : action == .add ? addTitle ?? ArtistLidarrPresentation.actionTitle(action)
                              : ArtistLidarrPresentation.actionTitle(action), symbol: "plus") {
                    switch action {
                    case .add: Task { await line.requestAdd() }
                    case .addMore: line.requestAddMore()
                    }
                }
                .disabled(line.working)
                .accessibilityIdentifier(action == .add ? "artist-lidarr-add" : "artist-lidarr-add-more")
            }
            if let hint = presentation.hint, showsAction {
                Text(ArtistLidarrPresentation.hintText(hint))
                    .font(.footnote).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    .accessibilityIdentifier("artist-lidarr-hint")
                Button("Open Settings") { showsSettings = true }
                    .font(.footnote)
                    .frame(minHeight: Tokens.minHitSize)
                    .tint(p.accentInkColor)
                    .accessibilityIdentifier("artist-lidarr-settings")
            }
            if let error = line.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(p.ink2Color)
                    .accessibilityIdentifier("artist-lidarr-error")
            }
        }
        .frame(maxWidth: .infinity)
        .addFlow($line.addFlow) { line.finished($0) }
        .sheet(isPresented: $showsSettings) { SettingsView(opening: [.requests]) }
    }
}
