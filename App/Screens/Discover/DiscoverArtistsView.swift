import AurralKit
import DesignSystem
import MagpieCore
import SwiftUI

/// "Add <artist> to your library" from a Discover page: each artist's Lidarr status (Lidarr's lookup), and Magpie's own
/// Add (R18's sheet or one confirmation with "Add with my defaults", through the gate), never Aurral's add. One per
/// page, shared by the rows' menus and the artists' list, so the Add shows once.
@MainActor @Observable final class DiscoverArtistAdder {
    /// The Add the page presents.
    var addFlow: AddFlowRequest?
    /// A line to show when an artist can't be added from here (already in, a setting is off).
    var message: String?
    /// Each artist's status line, by `DiscoverArtist.id`.
    private(set) var lines: [String: ArtistLidarrModel] = [:]
    private var adding: ArtistLidarrModel?

    func line(for artist: DiscoverArtist, model: AppModel) -> ArtistLidarrModel {
        if let line = lines[artist.id] { return line }
        let line = ArtistLidarrModel(model: model, name: artist.name, mbid: artist.mbid)
        lines[artist.id] = line
        return line
    }

    /// Reads the artist's status, then opens the Add when they can be added; otherwise says why.
    func add(_ artist: DiscoverArtist, model: AppModel) {
        let line = line(for: artist, model: model)
        Task {
            await line.refresh()
            guard let presentation = line.presentation else { return }
            guard presentation.action == .add else {
                message = presentation.hint.map(ArtistLidarrPresentation.hintText) ?? presentation.text
                return
            }
            await line.requestAdd()
            if let flow = line.addFlow {
                line.addFlow = nil
                adding = line
                addFlow = flow
            } else if let error = line.error {
                message = error
            }
        }
    }

    func finished(_ outcome: AddOutcome) {
        adding?.finished(outcome)
        adding = nil
    }
}

/// "Artists in this playlist": each with its status, and Add for each one not in the library yet.
/// Round 27 D2 (owner items 4 and 5, 2026-11-14): each row opens the artist's page, pushed inside the sheet: their
/// library page when the library has them, else the outside page (`AppModel.discoverArtistRoute`, resolved on the tap).
/// Offline the rows don't open and show no chevron. The row's Add says "Add" on one line (D315).
struct DiscoverArtistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artists: [DiscoverArtist]
    let adder: DiscoverArtistAdder
    @State private var path: [Route] = []
    /// The artist whose page is being looked up (by `DiscoverArtist.id`).
    @State private var opening: String?
    private let themed = Themed()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.lidarr == nil {
                    Text("Set up adding music in Settings \u{203A} Lidarr to add these artists.")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                }
                ForEach(artists) { artist in
                    DiscoverArtistRow(artist: artist, line: adder.line(for: artist, model: model),
                                      opening: opening == artist.id,
                                      open: model.discoverArtistLinksAvailable ? { open(artist) } : nil) {
                        dismiss()
                        adder.add(artist, model: model)
                    }
                }
            }
            .navigationTitle(DiscoverCopy.artistsInPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .magpieRoutes()
        }
    }

    /// Looks the artist up (at most 5 s), then pushes their page; one at a time.
    private func open(_ artist: DiscoverArtist) {
        guard opening == nil else { return }
        opening = artist.id
        Task {
            let route = await model.discoverArtistRoute(artist)
            opening = nil
            if let route { path.append(route) }
        }
    }
}

private struct DiscoverArtistRow: View {
    let artist: DiscoverArtist
    @Bindable var line: ArtistLidarrModel
    let opening: Bool
    let open: (() -> Void)?
    let add: () -> Void

    var body: some View {
        DiscoverArtistRowContent(name: artist.name, status: line.presentation.map { ($0.text, $0.symbol) },
                                 showsAdd: line.presentation?.action == .add, opening: opening, open: open, add: add)
            .task { await line.refresh() }
    }
}

/// Round 27 D2: one artist row, a container of two VoiceOver elements: the link (name and status, "<artist>, <status>",
/// with a chevron; plain text when it can't open) and Add (one line, `fixedSize`; "Add <artist> to your library"),
/// each at least 44 pt (D315).
struct DiscoverArtistRowContent: View {
    @Environment(\.discoverLayoutProbe) private var probe
    let name: String
    let status: (text: String, symbol: String)?
    let showsAdd: Bool
    let opening: Bool
    let open: (() -> Void)?
    let add: () -> Void
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            if let open {
                Button(action: open) { linkLabel(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("discover-artist-link")
                    .discoverProbe(probe, "link:" + DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
            } else {
                linkLabel(chevron: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
            }
            if showsAdd {
                DiscoverAddButton(artistName: name, action: add)
                    .discoverProbe(probe, "add:" + DiscoverArtistLinkCopy.addLabel(name))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func linkLabel(chevron: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                if let status {
                    Label(status.text, systemImage: status.symbol)
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                }
            }
            Spacer(minLength: Tokens.Spacing.s)
            if opening {
                ProgressView().controlSize(.small)
            } else if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(themed.palette.ink2Color)
            }
        }
        .frame(minHeight: Tokens.minHitSize)
        .contentShape(Rectangle())
    }
}

extension EnvironmentValues {
    /// Round 27 D2: tests read where the artists sheet's link and Add, and the flow editor's rows, are laid out, with
    /// their VoiceOver labels (as `actionBarProbe`); nil in the app.
    @Entry var discoverLayoutProbe: (@MainActor (String, CGRect) -> Void)?
}

extension View {
    /// Reports this view's frame (in the window) to the probe under `key`, when there is a probe.
    @ViewBuilder func discoverProbe(_ probe: (@MainActor (String, CGRect) -> Void)?, _ key: String) -> some View {
        if let probe {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe(key, $0) }
        } else {
            self
        }
    }
}

/// Round 27 D2 (owner item 5): the row's Add: the design system's compact capsule, "Add" on one line however narrow
/// the row or large the text; VoiceOver keeps "Add <artist> to your library" (D315).
struct DiscoverAddButton: View {
    let artistName: String
    let action: () -> Void

    var body: some View {
        // Y7 phase 2: the design system's compact capsule in a list row, filled as the row's Add.
        CapsuleButton(DiscoverArtistLinkCopy.add, symbol: "plus", style: .fill, action: action)
            .fixedSize()
            .accessibilityLabel(DiscoverArtistLinkCopy.addLabel(artistName))
            .accessibilityIdentifier("discover-artist-add")
    }
}
