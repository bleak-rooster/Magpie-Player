import DesignSystem
import SwiftUI

/// Round 28 O3 (owner, 2026-11-15; plan §3 j, D341): an album, artist, playlist or flow page whose online read got no
/// answer (no connection, a proxy or portal page) shows what's on the phone with this note, so the owner's music isn't
/// hidden behind an error. Text plus its symbol (D3); it never animates in or out, so rows don't move under a finger.
/// Fix round 1 (design M4): with a 44 pt Try again that reads the page again (pull to refresh does too).
struct PhoneCopyNote: View {
    let retry: () async -> Void
    @State private var trying = false
    private let themed = Themed()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Label(OfflinePageCopy.phoneCopy, systemImage: OfflinePageCopy.phoneCopySymbol)
                .font(.footnote)
                .foregroundStyle(themed.palette.ink2Color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phone-copy-note")
            Button {
                Task {
                    trying = true
                    await retry()
                    trying = false
                }
            } label: {
                Text(OfflinePageCopy.tryAgain)
                    .frame(minHeight: Tokens.minHitSize, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .disabled(trying)
            .accessibilityIdentifier("phone-copy-try-again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.margin)
        .padding(.vertical, Tokens.Spacing.s)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
    }
}
