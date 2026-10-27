import SwiftUI

/// Home/Search tile: art, title, artist and (for anything not in the library) a mandatory status line.
public struct AlbumTile: View {
    private let title: String
    private let subtitle: String
    private let artwork: Image?
    private let state: RowState
    private let width: CGFloat
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme

    public init(title: String, subtitle: String, artwork: Image? = nil, state: RowState = .library, width: CGFloat = 140) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork; self.state = state; self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Group {
                if state.isRecord {
                    RecordArt(image: artwork, side: width, saturation: state.saturation,
                              arc: state.arcFraction, isSpinning: state.isOnItsWay)
                } else {
                    SleeveArt(image: artwork, side: width)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                StatusLine(state)
            }
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(state.voiceOverValue ?? "")
    }
}

#Preview("AlbumTile") {
    ScrollView(.horizontal) {
        HStack(alignment: .top) {
            AlbumTile(title: "Glasshouse", subtitle: "Corin Hale")
            AlbumTile(title: "Saltwater Hymns", subtitle: "Corin Hale", state: .notYet)
            AlbumTile(title: "Analog Summer", subtitle: "Velvet Static", state: .find(daysLeft: 5))
        }.padding()
    }
}
