import DesignSystem
import SwiftUI

/// An album that's not in the library: record art, title, a detail line, and "Not in your library" in text with a
/// symbol (D3). Information only (Try works on songs). Search and the Artist page.
struct NotYetAlbumRow: View {
    let title: String
    let detail: String
    let label: String
    /// R15: the release group's cover from outside (Search), as the record's label; nil is the bare record.
    var artwork: Image? = nil
    private let themed = Themed()
    /// Round 28 S fix round 1 (review I1, design H2) and fix round 2 (m2): the title and detail lines wrap at
    /// accessibility sizes (here and on the Artist and outside artist pages, which share this row).
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            RecordArt(image: artwork, side: 48).recordBadge(RowState.notYet.statusSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text(detail).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                StatusLine(.notYet)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(RowState.notYet.voiceOverValue ?? "")
    }
}
