import SwiftUI

/// Mini player. Play/pause and Next are separate accessibility elements; Magic Tap toggles playback.
/// It sits in the tab bar's accessory, a bar of fixed height, so like the tab bar its text stops growing at
/// xxxLarge, one line each, and the Large Content Viewer shows it in full at accessibility sizes (H3 I3).
public struct MiniPlayer: View {
    private let title: String
    private let artist: String
    private let artwork: Image?
    private let isPlaying: Bool
    private let onPlayPause: () -> Void
    private let onNext: () -> Void
    private let onOpen: () -> Void
    /// Round 14 A2 (D86): previews paused this song: the play button says Resume.
    private let offersResume: Bool
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(title: String, artist: String, artwork: Image? = nil, isPlaying: Bool,
                onPlayPause: @escaping () -> Void, onNext: @escaping () -> Void, onOpen: @escaping () -> Void = {},
                offersResume: Bool = false) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.isPlaying = isPlaying
        self.onPlayPause = onPlayPause; self.onNext = onNext; self.onOpen = onOpen
        self.offersResume = offersResume && !isPlaying
    }

    public var body: some View {
        let ax = typeSize.isAccessibilitySize
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    SleeveArt(image: artwork, side: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer { Text("\(title), \(artist)") }
            .accessibilityLabel("Now playing: \(title), \(artist)")
            .accessibilityValue(isPlaying ? "Playing" : "Paused")
            .accessibilityHint("Opens Now Playing")

            Button(action: onPlayPause) {
                if offersResume, !ax {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.horizontal, 12).frame(minHeight: Tokens.minHitSize)
                        .background(Capsule().fill(.thinMaterial))
                        .contentShape(Capsule())
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel(isPlaying ? "Pause" : offersResume ? "Resume" : "Play")
            .accessibilityAddTraits(isPlaying ? [] : .startsMediaSession)

            if !ax {   // at accessibility sizes Next is offered as an action instead
                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.title3).frame(width: Tokens.minHitSize, height: Tokens.minHitSize).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, ax ? 2 : 6)
        .frame(minHeight: ax ? 0 : 52)
        .background { background }
        .accessibilityElement(children: .contain)
        .modifier(MagicTap(action: onPlayPause))
        .accessibilityAction(named: "Next track", onNext)
        .accessibilityAction(named: "Open Now Playing", onOpen)
    }

    // System material with hierarchical text styles; opaque surface under Reduce Transparency (a11y H2).
    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if reduceTransparency {
            shape.fill(themed.palette.surfaceColor).overlay(shape.strokeBorder(themed.palette.sepColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

/// Magic Tap toggles playback (iOS only; the trait does not exist on macOS).
private struct MagicTap: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        #if os(iOS)
        content.accessibilityAction(.magicTap, action)
        #else
        content
        #endif
    }
}

#Preview("MiniPlayer") {
    VStack { MiniPlayer(title: "Last Stop Lullaby", artist: "Ada Okafor", isPlaying: true, onPlayPause: {}, onNext: {})
             MiniPlayer(title: "Last Stop Lullaby", artist: "Ada Okafor", isPlaying: false, onPlayPause: {}, onNext: {}) }
        .padding()
}
