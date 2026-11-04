import SwiftUI

/// Round 14 A2 (D89): a song from outside the library, with its 30-second preview. Art, title, artist, an "In your
/// library" tick when it matches, the preview button (none when previews can't work: `status` nil), and a trailing ⋯
/// menu whose items the caller supplies (Listen to the full song, Add artist, Save to playlist: A3).
///
/// The row's text is one VoiceOver element; the preview button and the menu are their own. At accessibility sizes the
/// text wraps and the art goes above it.
public struct PreviewRow<MenuItems: View>: View {
    private let title: String
    private let artist: String
    private let artwork: Image?
    private let inLibrary: Bool
    private let status: PreviewStatus?
    private let onPreview: () -> Void
    private let menu: MenuItems?
    private let themed = ThemedPalette()
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 48

    public init(title: String, artist: String, artwork: Image? = nil, inLibrary: Bool = false, status: PreviewStatus?,
                onPreview: @escaping () -> Void, @ViewBuilder menu: () -> MenuItems) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.inLibrary = inLibrary
        self.status = status; self.onPreview = onPreview; self.menu = menu()
    }

    public static func accessibilityLabel(title: String, artist: String, inLibrary: Bool) -> String {
        inLibrary ? "\(title), \(artist), in your library" : "\(title), \(artist)"
    }

    public var body: some View {
        let p = themed.palette
        let ax = typeSize.isAccessibilitySize
        HStack(spacing: Tokens.Spacing.m) {
            if let status { PreviewButton(status: status, action: onPreview) }
            let text = VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(ax ? nil : 1)
                HStack(spacing: 6) {
                    Text(artist).font(.footnote).foregroundStyle(p.ink2Color).lineLimit(ax ? nil : 1)
                    if inLibrary {
                        Label("In your library", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.footnote)
                            .foregroundStyle(p.accentInkColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if ax {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) { SleeveArt(image: artwork, side: thumb); text }
                } else {
                    HStack(spacing: Tokens.Spacing.m) { SleeveArt(image: artwork, side: thumb); text }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(title: title, artist: artist, inLibrary: inLibrary))
            if let menu {
                Menu { menu } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("preview-row-menu")
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .frame(minHeight: 60)
        .foregroundStyle(p.inkColor)
        .accessibilityElement(children: .contain)
    }
}

public extension PreviewRow where MenuItems == EmptyView {
    /// A row with no ⋯ menu.
    init(title: String, artist: String, artwork: Image? = nil, inLibrary: Bool = false, status: PreviewStatus?,
         onPreview: @escaping () -> Void) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.inLibrary = inLibrary
        self.status = status; self.onPreview = onPreview; self.menu = nil
    }
}

#Preview("PreviewRow") {
    VStack(spacing: 0) {
        PreviewRow(title: "Harbour Lights", artist: "Stub Arrows", inLibrary: true, status: .playing(progress: 0.3, secondsLeft: 21),
                   onPreview: {}) {
            Button("Listen to the full song") {}
        }
        PreviewRow(title: "No Preview Song", artist: "Mallee Fowl", status: .noPreview, onPreview: {})
        PreviewRow(title: "Paper Moon", artist: "Stub Arrows", status: nil, onPreview: {})
    }
}
