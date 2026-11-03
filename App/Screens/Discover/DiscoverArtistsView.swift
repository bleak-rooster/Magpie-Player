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
struct DiscoverArtistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let artists: [DiscoverArtist]
    let adder: DiscoverArtistAdder
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            List {
                if model.lidarr == nil {
                    Text("Set up adding music in Settings \u{203A} Lidarr to add these artists.")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                }
                ForEach(artists) { artist in
                    DiscoverArtistRow(artist: artist, line: adder.line(for: artist, model: model)) {
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
        }
    }
}

private struct DiscoverArtistRow: View {
    let artist: DiscoverArtist
    @Bindable var line: ArtistLidarrModel
    let add: () -> Void
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).font(.body)
                if let presentation = line.presentation {
                    Label(presentation.text, systemImage: presentation.symbol)
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                }
            }
            Spacer()
            if line.presentation?.action == .add {
                // Y7 phase 2: the design system's compact capsule in a list row, filled as the row's Add.
                CapsuleButton(NewMusicCopy.addToLibrary, symbol: "plus", style: .fill, action: add)
                    .accessibilityLabel(DiscoverCopy.addArtist(artist.name))
            }
        }
        .accessibilityElement(children: .combine)
        .task { await line.refresh() }
    }
}
