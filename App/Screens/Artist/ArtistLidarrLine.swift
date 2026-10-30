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
        /// No MusicBrainz id: Magpie can't tell who to add.
        case unknownArtist
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
        case .notInLidarr(let mbid):
            var line = ArtistLidarrPresentation(text: "Not in Lidarr", symbol: "plus.circle")
            if mbid == nil { line.hint = .unknownArtist }
            else if !changesAllowed { line.hint = .turnOnChanges(toAdd: true) }
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
        case .unknownArtist: "Magpie can't tell which artist this is in MusicBrainz, so it can't add them."
        }
    }

    /// The confirmation before the add.
    static func confirmation(_ artist: String) -> String {
        "Adds \(artist) to Lidarr, monitors their albums and starts searching. This may download a lot of music."
    }
}

/// The artist page's Lidarr line: reads the state (never offline), and asks before the add.
@MainActor @Observable final class ArtistLidarrModel {
    private(set) var state: ArtistLidarrState?
    private(set) var justAdded = false
    private(set) var working = false
    private(set) var error: String?
    /// The add waits for "Add to Lidarr and download" in the confirmation.
    var confirmingAdd = false

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
            let fresh = try await model.artistLidarrState(name: name, mbid: mbid)
            state = fresh
            if case .monitored(_, true)? = fresh { justAdded = false }   // Lidarr's own search shows now
        } catch {
            // Lidarr didn't answer: the last state stays (none at first: no line).
        }
    }

    /// The button: only asks. Nothing is written until `confirmAdd`.
    func requestAdd() {
        guard presentation?.action == .add else { return }
        confirmingAdd = true
    }

    func confirmAdd() async {
        confirmingAdd = false
        guard presentation?.action == .add, case .notInLidarr(let mbid?)? = state, !working else { return }
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
                    line.requestAdd()
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
                if hint != .unknownArtist {
                    Button("Open Settings") { showsSettings = true }
                        .font(.footnote)
                        .frame(minHeight: Tokens.minHitSize)
                        .tint(p.accentInkColor)
                        .accessibilityIdentifier("artist-lidarr-settings")
                }
            }
            if let error = line.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(p.ink2Color)
                    .accessibilityIdentifier("artist-lidarr-error")
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Add to Lidarr?", isPresented: $line.confirmingAdd, titleVisibility: .visible) {
            Button("Add to Lidarr and download") { Task { await line.confirmAdd() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ArtistLidarrPresentation.confirmation(line.name))
        }
        .sheet(isPresented: $showsSettings) { SettingsView(opening: [.requests]) }
    }
}
