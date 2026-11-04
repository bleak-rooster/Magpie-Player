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
        self.init(title: title, artist: artist, artwork: artwork, inLibrary: inLibrary, status: status,
                  onPreview: onPreview, menuItems: menu())
    }

    /// The one place the row's fields are set (both public initialisers come here).
    fileprivate init(title: String, artist: String, artwork: Image?, inLibrary: Bool, status: PreviewStatus?,
                     onPreview: @escaping () -> Void, menuItems: MenuItems?) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.inLibrary = inLibrary
        self.status = status; self.onPreview = onPreview; self.menu = menuItems
    }

    public static func accessibilityLabel(title: String, artist: String, inLibrary: Bool) -> String {
        inLibrary ? "\(title), \(artist), in your library" : "\(title), \(artist)"
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        // The round button leads the row; words ("No preview available") go under the song's text, where they have room
        // to wrap (fix I3). At accessibility sizes the art sits above the text.
        let wordsBelow = status?.showsWords == true
        HStack(alignment: ax ? .top : .center, spacing: Tokens.Spacing.m) {
            if let status, !wordsBelow { PreviewButton(status: status, action: onPreview) }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Group {
                    if ax {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.s) { SleeveArt(image: artwork, side: thumb); text }
                    } else {
                        HStack(spacing: Tokens.Spacing.m) { SleeveArt(image: artwork, side: thumb); text }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityLabel(title: title, artist: artist, inLibrary: inLibrary))
                if let status, wordsBelow { PreviewButton(status: status, action: onPreview) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(minHeight: 60)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        let ax = typeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout).lineLimit(ax ? nil : 1)
            HStack(spacing: 6) {
                Text(artist).font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(ax ? nil : 1)
                if inLibrary {
                    Label("In your library", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(themed.palette.accentInkColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension PreviewRow where MenuItems == EmptyView {
    /// A row with no ⋯ menu.
    init(title: String, artist: String, artwork: Image? = nil, inLibrary: Bool = false, status: PreviewStatus?,
         onPreview: @escaping () -> Void) {
        self.init(title: title, artist: artist, artwork: artwork, inLibrary: inLibrary, status: status,
                  onPreview: onPreview, menuItems: nil)
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
