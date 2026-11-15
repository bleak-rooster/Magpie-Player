import DesignSystem
import SwiftUI

/// Round 28 O3 (owner, 2026-11-15; plan §3 j, D341): an album, artist, playlist or flow page whose online read failed
/// (no answer, a proxy page, a 5xx, while Magpie is still only checking) shows what's on the phone with this note, so the
/// owner's music isn't hidden behind an error; pull to refresh reads again. Text plus its symbol (D3); it never
/// animates in or out, so rows don't move under a finger.
struct PhoneCopyNote: View {
    private let themed = Themed()

    var body: some View {
        Label(OfflinePageCopy.phoneCopy, systemImage: OfflinePageCopy.phoneCopySymbol)
            .font(.footnote)
            .foregroundStyle(themed.palette.ink2Color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Spacing.margin)
            .padding(.vertical, Tokens.Spacing.s)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phone-copy-note")
    }
}
