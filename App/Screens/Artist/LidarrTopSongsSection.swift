import DesignSystem
import MagpieCore
import SwiftUI

/// Round 26 K2 (owner, 2026-11-10; D263, D264): an artist page's Top songs for an artist Lidarr has: up to five songs
/// you already have, each the library row of `TopSongsSection` (plays the shown list from that row; its queue and
/// library menu items). No source note (plan §3 h) and no new copy. A refresh that brings other songs swaps the rows in
/// place with no animation and no announcement; rows are identified by song id, so a focused row that stays keeps its
/// focus.
struct LidarrTopSongsSection: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Top songs").magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Tokens.Spacing.margin)
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                Button { model.play(songs, startAt: index) } label: {
                    Artwork(song.coverArtId, side: 48) { image in
                        PreviewRow(title: song.title, artist: song.artist, artwork: image, inLibrary: true,
                                   status: nil, onPreview: {})
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .contextMenu { SongQueueMenuItems(song: song); SongLibraryMenuItems(song: song) }
                .songSwipeActions(song, in: .stack)   // fix round 1 (design H1): swipes and Play next / Add to queue, as Popular
                .padding(.horizontal, Tokens.Spacing.margin)
                .accessibilityIdentifier("top-song-\(song.id)")
            }
        }
        .transaction { $0.animation = nil }   // D264: a refreshed list swaps in place, no animation
        .accessibilityIdentifier("top-songs")
    }
}
