import DesignSystem
import LidarrKit
import MagpieCore
import Requests
import SwiftUI

/// What an artist page's Lidarr line shows (P3): the status (text plus symbol, D3), and at most one action or hint.
struct ArtistLidarrPresentation: Equatable {
    enum Action: Equatable { case add, monitor }
    enum Hint: Equatable {
        /// "Allow Magpie to change Lidarr" is off: replaces the button (Add, or Monitor), with a link to Settings › Requests.
        case turnOnChanges(toAdd: Bool)
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
            // Owner-data rule: only an artist Magpie added is offered "Monitor".
            if magpieAdded { changesAllowed ? (line.action = .monitor) : (line.hint = .turnOnChanges(toAdd: false)) }
            return line
        case .notInLidarr:
            // Without the library's MBID the add asks Lidarr's search on the tap, and the owner confirms the exact
            // artist (I3).
            var line = ArtistLidarrPresentation(text: "Not in Lidarr", symbol: "plus.circle")
            if !changesAllowed { line.hint = .turnOnChanges(toAdd: true) }
            else if !canAdd { line.hint = .setUpFirst }
            else { line.action = .add }
            return line
        }
    }

    static func hintText(_ hint: Hint) -> String {
        switch hint {
        case .turnOnChanges(let toAdd):
            toAdd ? "Turn on Allow Magpie to change Lidarr in Settings \u{203A} Requests to add artists."
                   : "Turn on Allow Magpie to change Lidarr in Settings \u{203A} Requests to monitor this artist."
        case .setUpFirst: "Set up Magpie in Lidarr in Settings \u{203A} Requests to add artists."
        }
    }

    /// The confirmation before the add.
    static func confirmation(_ artist: String) -> String {
        "Adds \(artist) to Lidarr, monitors their albums and starts searching. This may download a lot of music."
    }

    /// The confirmation when Lidarr's search has several artists of that exact name: the owner picks one.
    static func pickConfirmation(_ artist: String) -> String {
        "Lidarr knows more than one \(artist). Pick the one to add: Magpie adds them to Lidarr, monitors their albums and starts searching. This may download a lot of music."
    }

    /// Lidarr's search has no artist of that exact name: nothing is added.
    static func notFound(_ artist: String) -> String { "Couldn't find \(artist) in Lidarr's search" }
}

/// The artist page's Lidarr line: reads the state (never offline), and asks before the add.
@MainActor @Observable final class ArtistLidarrModel {
    private(set) var state: ArtistLidarrState?
    private(set) var justAdded = false
    private(set) var working = false
    private(set) var error: String?
    /// The add waits for the owner's choice in the confirmation.
    var confirmation: Confirmation?

    enum Confirmation: Equatable {
        /// One artist: the library's own MBID (named as the library names it), or the one exact search candidate
        /// (named with its disambiguation and type).
        case one(label: String, mbid: MBID)
        /// Several artists of that exact name: the owner picks.
        case pick([ArtistLidarr.Candidate])
    }

    /// Bound to the confirmation dialog.
    var confirming: Bool {
        get { confirmation != nil }
        set { if !newValue { confirmation = nil } }
    }
    /// The MBID an add resolved to, so a refresh after "already in Lidarr" finds the artist by it.
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

    /// The button: only asks. With the library's MBID the confirmation names the artist; without, Lidarr's search is
    /// read first (GETs) and the confirmation names the one exact match, or lists several to pick from; none: nothing
    /// can be added. Nothing is written until `confirmAdd`.
    func requestAdd() async {
        guard presentation?.action == .add, case .notInLidarr? = state, !working else { return }
        error = nil
        if let mbid {
            confirmation = .one(label: name, mbid: mbid)
            return
        }
        working = true
        defer { working = false }
        do {
            let found = try await model.artistCandidates(name: name)
            switch found.count {
            case 0: error = ArtistLidarrPresentation.notFound(name)
            case 1: confirmation = .one(label: found[0].label, mbid: found[0].mbid)
            default: confirmation = .pick(found)
            }
        } catch {
            self.error = Self.message(for: error, artist: name)
        }
    }

    /// The owner confirmed this artist (one of the confirmation's).
    func confirmAdd(_ mbid: MBID) async {
        let offered: [MBID] = switch confirmation {
        case .one(_, let m)?: [m]
        case .pick(let list)?: list.map(\.mbid)
        case nil: []
        }
        confirmation = nil
        guard offered.contains(mbid), presentation?.action == .add, case .notInLidarr? = state, !working else { return }
        resolvedMBID = mbid
        working = true
        error = nil
        defer { working = false }
        do {
            let id = try await model.addArtistToLidarr(mbid: mbid)
            state = .monitored(lidarrId: id, searching: true)
            justAdded = true
        } catch ArtistLidarrError.alreadyInLidarr {
            await refresh()   // added meanwhile (by the owner): show it as it is, write nothing
        } catch {
            self.error = Self.message(for: error, artist: name)
        }
    }

    func monitor() async {
        guard presentation?.action == .monitor, case .notMonitored(let id, true)? = state, !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.monitorArtistInLidarr(id: id)
            state = .monitored(lidarrId: id, searching: true)
        } catch {
            self.error = Self.message(for: error, artist: name)
            await refresh()
        }
    }

    static func message(for error: Error, artist: String) -> String {
        switch error {
        case ArtistLidarrError.changesOff, WriteGateError.disabled:
            "Turn on Allow Magpie to change Lidarr in Settings \u{203A} Requests first."
        case ArtistLidarrError.notFound: "Lidarr couldn't find \(artist). Try again later."
        default: "Lidarr didn't take the change. Try again in a moment."
        }
    }
}

/// The line under the artist's name.
struct ArtistLidarrLine: View {
    @Bindable var line: ArtistLidarrModel
    let presentation: ArtistLidarrPresentation
    @State private var showsSettings = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        VStack(spacing: Tokens.Spacing.s) {
            Label(presentation.text, systemImage: presentation.symbol)
                .font(.subheadline)
                .foregroundStyle(p.ink2Color)
                .accessibilityIdentifier("artist-lidarr-status")
            switch presentation.action {
            case .add?:
                CapsuleButton(line.working ? "Adding\u{2026}" : "Add to Lidarr and download", symbol: "plus") {
                    Task { await line.requestAdd() }
                }
                .disabled(line.working)
                .accessibilityIdentifier("artist-lidarr-add")
            case .monitor?:
                CapsuleButton(line.working ? "Monitoring\u{2026}" : "Monitor", symbol: "checkmark") {
                    Task { await line.monitor() }
                }
                .disabled(line.working)
                .accessibilityIdentifier("artist-lidarr-monitor")
            case nil:
                EmptyView()
            }
            if let hint = presentation.hint {
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
        .confirmationDialog("Add to Lidarr?", isPresented: $line.confirming, titleVisibility: .visible,
                            presenting: line.confirmation) { confirmation in
            switch confirmation {
            case .one(_, let mbid):
                Button("Add to Lidarr and download") { Task { await line.confirmAdd(mbid) } }
            case .pick(let candidates):
                ForEach(candidates) { candidate in
                    Button(candidate.label) { Task { await line.confirmAdd(candidate.mbid) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            switch confirmation {
            case .one(let label, _): Text(ArtistLidarrPresentation.confirmation(label))
            case .pick: Text(ArtistLidarrPresentation.pickConfirmation(line.name))
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView(opening: [.requests]) }
    }
}
