import SwiftUI

/// A titled horizontal shelf ("Finds", "New finds", ...). The title is a heading for the rotor.
public struct ShelfSection<Content: View>: View {
    private let title: String
    private let onSeeAll: (() -> Void)?
    private let content: Content
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme

    public init(_ title: String, onSeeAll: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.onSeeAll = onSeeAll; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).magpieDisplay(.title2).accessibilityAddTraits(.isHeader)
                Spacer()
                if let onSeeAll {
                    Button("See all", action: onSeeAll)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themed.palette.accentInkColor)
                        .frame(minHeight: Tokens.minHitSize)
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Tokens.Spacing.m) { content }
                    .padding(.horizontal, Tokens.Spacing.margin)
            }
        }
        .foregroundStyle(themed.palette.inkColor)
    }
}

#Preview("ShelfSection") {
    ShelfSection("Finds", onSeeAll: {}) {
        AlbumTile(title: "Analog Summer", subtitle: "Velvet Static", state: .find(daysLeft: 5))
        AlbumTile(title: "Late Tide", subtitle: "Ada Okafor", state: .find(daysLeft: 2))
        AlbumTile(title: "Saltwater Hymns", subtitle: "Corin Hale", state: .newFind)
    }
}
