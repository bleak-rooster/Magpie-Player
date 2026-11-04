import SwiftUI

// Round 14 A6: the Spotify-style Home's shelf styles. Each is one VoiceOver element ("title, subtitle"), grows with
// Dynamic Type (wider at accessibility sizes, D15) and takes its colours from the theme (light and dark alike).

/// A recommended artist: a round picture, the name and a short line under it.
public struct ArtistCircle: View {
    private let title: String
    private let subtitle: String?
    private let artwork: Image?
    private let width: CGFloat
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, subtitle: String? = nil, artwork: Image? = nil, width: CGFloat = 120) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork; self.width = width
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        let side = ax ? max(width, AlbumTile.accessibilityWidth) : width
        VStack(spacing: Tokens.Spacing.s) {
            ZStack {
                Circle().fill(themed.palette.surfaceColor)
                if let artwork {
                    artwork.resizable().scaledToFill()
                } else {
                    Text(Self.initials(title)).font(.title2.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            VStack(spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(ax ? 4 : 2).multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(themed.palette.ink2Color).lineLimit(ax ? 3 : 1)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: side)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    /// Up to two initials, for an artist without a picture.
    nonisolated static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// A quick-access tile: art on the left, the name on the right, on the surface colour. Two to a row.
public struct CompactTile: View {
    private let title: String
    private let subtitle: String?
    private let artwork: Image?
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 52

    public init(title: String, subtitle: String? = nil, artwork: Image? = nil) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(spacing: Tokens.Spacing.s) {
            ZStack {
                themed.palette.sepColor
                if let artwork { artwork.resizable().scaledToFill() }
            }
            .frame(width: min(side, 88), height: min(side, 88))
            .clipped()
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(ax ? 3 : 2)
                if let subtitle, ax || typeSize <= .large {
                    Text(subtitle).font(.caption2).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                }
            }
            .padding(.vertical, Tokens.Spacing.xs)
            Spacer(minLength: Tokens.Spacing.xs)
        }
        .frame(minHeight: Tokens.minHitSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themed.palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.art, style: .continuous))
        .foregroundStyle(themed.palette.inkColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A large card: a big square cover with the title and a line under it (Trending, More playlists for you).
public struct LargeCard: View {
    private let title: String
    private let subtitle: String?
    private let artwork: Image?
    private let width: CGFloat
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, subtitle: String? = nil, artwork: Image? = nil, width: CGFloat = 200) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork; self.width = width
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        let width = ax ? max(width, AlbumTile.accessibilityWidth) : width
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SleeveArt(image: artwork, side: width)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(ax ? 4 : 2)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(themed.palette.ink2Color).lineLimit(ax ? 4 : 2)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// One of Home's filter chips: a capsule, filled when selected (with the selected trait, not colour alone, D3).
public struct FilterChip: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title; self.isSelected = isSelected; self.action = action
    }

    public var body: some View {
        let p = themed.palette
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Tokens.CompactCapsule.horizontalPadding)
                .frame(minHeight: Tokens.CompactCapsule.height)
                .foregroundStyle(isSelected ? p.onAccentColor : p.inkColor)
                .background(isSelected ? p.accentColor : p.surfaceColor, in: Capsule())
                .frame(minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Home shelf styles") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            HStack { FilterChip("All", isSelected: true) {}; FilterChip("Discover", isSelected: false) {} }
            HStack(alignment: .top) { ArtistCircle(title: "Ada Okafor", subtitle: "92% match"); ArtistCircle(title: "Low") }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                CompactTile(title: "Glasshouse", subtitle: "Album")
                CompactTile(title: "Discover Weekly", subtitle: "Flow")
            }
            LargeCard(title: "Top Australia", subtitle: "100 songs")
        }
        .padding()
    }
}
