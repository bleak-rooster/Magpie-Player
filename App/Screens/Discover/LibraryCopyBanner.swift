import DesignSystem
import MagpieCore
import SwiftUI

/// Round 12 Y6: on the owner's own playlist (never a Discover one) holding Aurral copies of songs the library has, a
/// line and "Use your library's copy" (one checked send, `AppModel.useLibraryCopies`). Shows nothing otherwise.
struct LibraryCopyBanner: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    let songs: [Song]
    @State private var copies = 0
    @State private var working = false
    @State private var error: String?
    private let themed = Themed()

    var body: some View {
        Group {
            if copies > 0 {
                VStack(spacing: Tokens.Spacing.s) {
                    Text(DiscoverCopy.libraryCopies(copies)).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    // Y7 phase 2: the page's ActionBar style (tinted; busy while it swaps), on the 16 pt margins.
                    ActionBar {
                        ActionButton(working ? "Swapping\u{2026}" : DiscoverCopy.useLibraryCopy, symbol: "arrow.triangle.swap",
                                     busy: working) {
                            Task { await swap() }
                        }
                        .disabled(working)
                        .accessibilityIdentifier("playlist-use-library-copy")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
                            .foregroundStyle(themed.palette.ink2Color)
                            .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                    }
                }
            }
        }
        .task(id: songs.map(\.id)) {
            guard model.aurralSetUp, model.canEdit(playlist) else { copies = 0; return }
            copies = await model.aurralCopiesInOwnPlaylist(playlist, songs: songs).count
        }
    }

    private func swap() async {
        working = true
        defer { working = false }
        do {
            try await model.useLibraryCopies(in: playlist)
            copies = 0
            error = nil
        } catch {
            self.error = DiscoverSwapError.message(for: error)
        }
    }
}
