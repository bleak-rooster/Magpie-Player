import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI
import UIKit

/// Round 14 A3 (owner answer 6, D104): an artist page's Top songs from outside the library (the server's or
/// ListenBrainz's): the library's copy plays in full; any other has its preview (or "No preview available"; no controls
/// without previews) and the outside song's ⋯ menu. A small note says where they came from when it fell back.
struct TopSongsSection: View {
    @Environment(AppModel.self) private var model
    let result: TopSongsResult
    /// Round 25 I (D248): the page's Lidarr line's state (nil: not known yet, or no line). An artist Lidarr monitors
    /// shows only the library's songs while "In your library only, for artists in Lidarr" is on.
    var lidarr: ArtistLidarrState? = nil
    private let themed = Themed()

    var body: some View {
        let shown = model.shownTopSongs(result, lidarr: lidarr)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top songs").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                if result.fellBack {
                    Text(SongActionsCopy.topSongsNote(result.provider)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                        .accessibilityIdentifier("top-songs-note")
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            if shown.rows.isEmpty {   // D250: every top song was outside the library
                Label(TopSongsInLibraryCopy.noneInLibrary, systemImage: TopSongsInLibraryCopy.noneSymbol)
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .frame(minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.margin)
                    .accessibilityIdentifier("top-songs-none-in-library")
            }
            ForEach(shown.rows) { row in
                TopSongRowView(row: row, rows: shown.rows).accessibilityIdentifier("top-song-\(row.id)")
            }
        }
        .accessibilityIdentifier("top-songs")
    }
}

private struct TopSongRowView: View {
    @Environment(AppModel.self) private var model
    let row: TopSongRow
    let rows: [TopSongRow]
    /// Round 15 C1 (owner item 3, D128): an outside song's cover, and for which row (never another row's).
    @State private var picture: (row: TopSongRow, image: UIImage)?

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
                let shown = picture?.row == row ? picture?.image : nil
                let art = shown.map { Image(uiImage: $0) }
                Group {
                    if OutsideSongMenu.isAvailable(model) {
                        PreviewRow(title: row.song.title, artist: row.song.artist, artwork: art, status: status,
                                   onPreview: { if let item { model.togglePreview(item) } }) { OutsideSongMenu(song: row.song) }
                    } else {
                        PreviewRow(title: row.song.title, artist: row.song.artist, artwork: art, status: status,
                                   onPreview: { if let item { model.togglePreview(item) } })
                    }
                }
                .artworkTestMarker("top-song-art-\(row.id)", loaded: shown != nil)
                .task(id: row) {
                    guard picture?.row != row, let found = await model.topSongArtwork(row, side: 48) else { return }
                    guard !Task.isCancelled else { return }   // C1 review minor 1: a cancelled load never lands
                    picture = (row, found)
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
    }
}
