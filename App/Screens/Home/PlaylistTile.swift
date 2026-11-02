import DesignSystem
import MagpieCore
import SwiftUI

/// Round 12 Y3 (plan item 5): a Home tile that reads as a playlist, not as another album. Navidrome makes a playlist's
/// cover from its albums (a 2×2 grid), so on its own it looks like a random album; the tile adds a stacked frame (two
/// sleeves peeking out above it) and says "Playlist · N songs".
struct PlaylistTile: View {
    let playlist: Playlist
    let artwork: Image?
    var width: CGFloat = 140
    var mark: DownloadMark = .none
    @Environment(\.dynamicTypeSize) private var typeSize
    private let themed = Themed()

    /// "Playlist · 12 songs"; "Playlist · 1 song".
    nonisolated static func subtitle(songCount: Int) -> String {
        "Playlist \u{00B7} " + (songCount == 1 ? "1 song" : "\(songCount) songs")
    }

    /// How far each sleeve behind peeks out above the cover.
    static let stackStep: CGFloat = 4

    var body: some View {
        let p = themed.palette
        let side = typeSize.isAccessibilitySize ? max(width, AlbumTile.accessibilityWidth) : width
        let subtitle = Self.subtitle(songCount: playlist.songCount)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            ZStack(alignment: .bottom) {
                // Two sleeves behind, narrower and higher each time: the stacked frame.
                ForEach([2, 1], id: \.self) { level in
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(p.surfaceColor)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                            .strokeBorder(p.ink2Color.opacity(0.25), lineWidth: 0.5))
                        .frame(width: side - CGFloat(level) * 2 * Self.stackStep * 2, height: side)
                        .offset(y: -CGFloat(level) * Self.stackStep)
                }
                SleeveArt(image: artwork, side: side)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "music.note.list")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(p.inkColor)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
                    }
            }
            .padding(.top, 2 * Self.stackStep)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                HStack(spacing: 4) {
                    Text(subtitle).font(.caption).foregroundStyle(p.ink2Color)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    DownloadMarkView(mark)
                }
            }
        }
        .frame(width: side, alignment: .leading)
        .foregroundStyle(p.inkColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(playlist.name), \(subtitle)")
        .accessibilityValue(mark.joined(to: nil))
    }
}
