import DesignSystem
import MagpieCore
import SwiftUI

/// R18 + R20 on the artist page: "Only in your Finds" (text plus symbol, D3) for an artist whose every album Magpie
/// knows is in the Finds library, and the one capsule **Keep <artist>** (every ready find of theirs, then "Kept. Add
/// more from <artist>?"). A find without a Magpie request to Keep through is informational only (owner-data rule):
/// "Added outside Magpie. Change it where you added it."
struct OnlyInFindsLine: View {
    @Environment(AppModel.self) private var model
    let artist: String
    let albums: [Album]
    /// The `findsKeepFlow` host of this page.
    let host: String
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let songs = model.findSongs(of: albums).map(\.id)
        VStack(spacing: Tokens.Spacing.s) {
            Label(NewMusicCopy.onlyInFinds, systemImage: "record.circle")
                .font(.subheadline)
                .foregroundStyle(p.ink2Color)
                .accessibilityIdentifier("artist-only-in-finds")
            switch model.artistKeepState(songIds: songs) {
            case .keepable:
                CapsuleButton(NewMusicCopy.keepArtist(artist), symbol: "checkmark.seal") {
                    model.newMusic.keeping = KeepFlowRequest(host: host, songIds: songs, artist: artist)
                }
                .accessibilityIdentifier("artist-keep")
            case .keeping:
                CapsuleButton(NewMusicCopy.keeping, symbol: "checkmark.seal") {}
                    .disabled(true)
                    .accessibilityIdentifier("artist-keep")
            case .later:
                EmptyView()   // Magpie's own find, not ready to keep yet: its request says why
            case .outside:
                Text(NewMusicCopy.addedOutside)
                    .font(.footnote).foregroundStyle(p.ink2Color).multilineTextAlignment(.center)
                    .accessibilityIdentifier("artist-added-outside")
            }
        }
        .frame(maxWidth: .infinity)
    }
}
