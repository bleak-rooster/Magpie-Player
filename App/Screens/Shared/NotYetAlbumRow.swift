import DesignSystem
import SwiftUI

/// An album that's not in the library: record art, title, a detail line, and "Not in your library" in text with a
/// symbol (D3). Information only (Try works on songs). Search and the Artist page.
struct NotYetAlbumRow: View {
    let title: String
    let detail: String
    let label: String
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            RecordArt(side: 48).recordBadge(RowState.notYet.statusSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).lineLimit(2)
                Text(detail).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                StatusLine(.notYet)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(RowState.notYet.voiceOverValue ?? "")
    }
}
