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
/// Fix round 1 (design L2, M6): the artist's page keeps Done; an artist looked up once opens at once the next time
/// (this sheet only); VoiceOver hears "Opening <artist>" while it's looked up.
struct DiscoverArtistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artists: [DiscoverArtist]
    let adder: DiscoverArtistAdder
    /// Fix round 2 (R1): a `NavigationPath`, so the artist page's own links (albums, `Route`s) push too.
    @State private var path: NavigationPath
    /// The artist whose page is being looked up (by `DiscoverArtist.id`).
    @State private var opening: String?
    /// Where each artist opened, this sheet only (by `DiscoverArtist.id`).
    @State private var opened: [String: Route] = [:]

    /// `path`: pages already open (tests start on one).
    init(artists: [DiscoverArtist], adder: DiscoverArtistAdder, path: NavigationPath = NavigationPath()) {
        self.artists = artists
        self.adder = adder
        _path = State(initialValue: path)
    }
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
            .navigationDestination(for: ArtistPage.self) { page in
                ArtistPageDestination(route: page.route)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
            .magpieRoutes()
        }
    }

    /// Looks the artist up (at most 5 s; once per sheet), then pushes their page; one at a time.
    private func open(_ artist: DiscoverArtist) {
        guard opening == nil else { return }
        if let known = opened[artist.id] {
            path.append(ArtistPage(route: known))
            return
        }
        opening = artist.id
        AccessibilityNotification.Announcement(DiscoverArtistLinkCopy.openingAnnouncement(artist.name)).post()
        Task {
            let route = await model.discoverArtistRoute(artist)
            opening = nil
            guard let route else { return }
            opened[artist.id] = route
            path.append(ArtistPage(route: route))
        }
    }
}

/// Round 27 D2 fix round 1 (L2): an artist's page pushed from the sheet (so it can carry the sheet's Done).
struct ArtistPage: Hashable { var route: Route }

/// The library or outside artist page for a sheet row's route.
private struct ArtistPageDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .artist(let id): ArtistView(artistId: id)
        case .outsideArtist(let artist): OutsideArtistView(artist: artist)
        default: EmptyView()   // the sheet's rows open only these two
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let status: (text: String, symbol: String)?
    let showsAdd: Bool
    let opening: Bool
    let open: (() -> Void)?
    let add: () -> Void
    private let themed = Themed()

    var body: some View {
        // Fix round 1 (design M7): at accessibility sizes Add goes under the name and status.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) { link; addButton }
            } else {
                HStack(spacing: Tokens.Spacing.m) { link; addButton }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var link: some View {
        if let open {
            Button(action: open) { linkLabel(chevron: true) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
                .accessibilityValue(opening ? DiscoverArtistLinkCopy.opening : "")   // design M6
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("discover-artist-link")
                .discoverProbe(probe, "link:" + DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
        } else {
            linkLabel(chevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DiscoverArtistLinkCopy.linkLabel(name: name, status: status?.text))
        }
    }

    @ViewBuilder private var addButton: some View {
        if showsAdd {
            DiscoverAddButton(artistName: name, action: add)
                .discoverProbe(probe, "add:" + DiscoverArtistLinkCopy.addLabel(name))
        }
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
