import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 14 A3 (owner answer 6, D104): an artist page's Top songs from outside the library (the server's or
/// ListenBrainz's): the library's copy plays in full; any other has its preview (or "No preview available"; no controls
/// without previews) and the outside song's ⋯ menu. A small note says where they came from when it fell back.
struct TopSongsSection: View {
    @Environment(AppModel.self) private var model
    let result: TopSongsResult
    private let themed = Themed()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top songs").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                if result.fellBack {
                    Text(SongActionsCopy.topSongsNote(result.provider)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("top-songs-note")
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            ForEach(result.rows) { row in
                TopSongRowView(row: row, rows: result.rows).accessibilityIdentifier("top-song-\(row.id)")
            }
        }
        .accessibilityIdentifier("top-songs")
    }
}

private struct TopSongRowView: View {
    @Environment(AppModel.self) private var model
    let row: TopSongRow
    let rows: [TopSongRow]

    var body: some View {
        Group {
            if let song = row.library {
                Button {
                    let owned = rows.compactMap(\.library)
                    model.play(owned, startAt: owned.firstIndex(of: song) ?? 0)
                } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        PreviewRow(title: song.title, artist: song.artist, artwork: image, inLibrary: true,
                                   status: nil, onPreview: {})
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .contextMenu { SongQueueMenuItems(song: song); SongLibraryMenuItems(song: song) }
            } else {
                let item = row.preview.map(model.previewItem(for:))
                let status: PreviewStatus? = !model.previewsAvailable ? nil
                    : item.map { PreviewCopy.status(model.previewPlayer.state(for: $0), player: model.previewPlayer) } ?? .noPreview
                if OutsideSongMenu.isAvailable(model) {
                    PreviewRow(title: row.song.title, artist: row.song.artist, status: status,
                               onPreview: { if let item { model.togglePreview(item) } }) { OutsideSongMenu(song: row.song) }
                } else {
                    PreviewRow(title: row.song.title, artist: row.song.artist, status: status,
                               onPreview: { if let item { model.togglePreview(item) } })
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
    }
}
