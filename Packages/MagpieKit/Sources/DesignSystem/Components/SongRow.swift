import SwiftUI
import MagpieCore

/// One song. State drives art shape (sleeve vs record), the status line, and VoiceOver.
/// The row is a single accessibility element; Try/Keep are custom actions, not extra swipe stops.
/// Keep shows only when `onKeep` is given.
public struct SongRow: View {
    private let song: Song
    private let state: RowState
    private let artwork: Image?
    private let quality: Quality?
    private let onTry: () -> Void
    private let onKeep: (() -> Void)?
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 48

    public init(song: Song, state: RowState, artwork: Image? = nil, quality: Quality? = nil,
                onTry: @escaping () -> Void = {}, onKeep: (() -> Void)? = nil) {
        self.song = song; self.state = state; self.artwork = artwork; self.quality = quality
        self.onTry = onTry; self.onKeep = onKeep
    }

    public nonisolated static func accessibilityLabel(for song: Song) -> String { "\(song.title), \(song.artist)" }

    public var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.m))
            : AnyLayout(HStackLayout(spacing: Tokens.Spacing.m))
        layout {
            artView
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.callout).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                HStack(spacing: 6) {
                    Text(song.artist).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    if let quality { Hallmark(quality) }
                }
                StatusLine(state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .frame(minHeight: 60)
        .foregroundStyle(themed.palette.inkColor)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: song))
        .accessibilityValue(state.voiceOverValue ?? "")
        .accessibilityHint(state.accessibilityHint ?? "")
        .modifier(RowActions(state: state, onTry: onTry, onKeep: onKeep))
    }

    private var artView: some View {
        ZStack(alignment: .bottomTrailing) {
            if state.isRecord {
                RecordArt(image: artwork, side: thumb, saturation: state.saturation,
                          arc: state.arcFraction, isSpinning: state.isOnItsWay)
            } else {
                SleeveArt(image: artwork, side: thumb)
            }
            // Classic draws records as squares, so the glyph badge carries the state there (a11y C2).
            if theme.character == .classic, let symbol = state.statusSymbol, state.isRecord {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(themed.palette.onAccentColor)
                    .padding(3).background(themed.palette.accentColor, in: Circle())
                    .offset(x: 4, y: 4)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .notYet: CapsuleButton("Try", symbol: "play.fill", action: onTry)
        case .find, .newFind: if let onKeep { CapsuleButton("Keep", style: .fill, action: onKeep) }
        default: EmptyView()
        }
    }
}

private struct RowActions: ViewModifier {
    let state: RowState
    let onTry: () -> Void
    let onKeep: (() -> Void)?
    func body(content: Content) -> some View {
        switch state {
        case .notYet:
            content.accessibilityAction(.default, onTry).accessibilityAction(named: "Try", onTry).accessibilityAddTraits(.isButton)
        case .find, .newFind:
            if let onKeep { content.accessibilityAction(named: "Keep", onKeep) } else { content }
        default:
            content
        }
    }
}

#Preview("SongRow states") {
    let song = Song(id: "1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 215)
    let states: [RowState] = [.library, .downloaded, .notYet, .onItsWay(progress: 0.4, phrase: "about 30 seconds"),
                              .newFind, .find(daysLeft: 5), .find(daysLeft: 1), .keptLosslessSoon, .lossless, .notFound]
    return List(states.indices, id: \.self) { SongRow(song: song, state: states[$0], quality: $0 == 8 ? .lossless : nil) }
        .listStyle(.plain)
}
