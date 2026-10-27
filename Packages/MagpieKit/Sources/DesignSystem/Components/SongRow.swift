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
    /// The not-yet button's word: "Try", or what Try does on this server ("Ask for it", D8).
    private let tryTitle: String
    private let onKeep: (() -> Void)?
    private let themed = ThemedPalette()
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 48

    public init(song: Song, state: RowState, artwork: Image? = nil, quality: Quality? = nil,
                tryTitle: String = "Try", onTry: @escaping () -> Void = {}, onKeep: (() -> Void)? = nil) {
        self.song = song; self.state = state; self.artwork = artwork; self.quality = quality
        self.tryTitle = tryTitle; self.onTry = onTry; self.onKeep = onKeep
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
        .modifier(RowActions(state: state, tryTitle: tryTitle, onTry: onTry, onKeep: onKeep))
    }

    @ViewBuilder private var artView: some View {
        if state.isRecord {
            // Classic draws records as squares, so the glyph badge carries the state there (a11y C2).
            RecordArt(image: artwork, side: thumb, saturation: state.saturation,
                      arc: state.arcFraction, isSpinning: state.isOnItsWay)
                .recordBadge(state.statusSymbol)
        } else {
            SleeveArt(image: artwork, side: thumb)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .notYet: CapsuleButton(tryTitle, symbol: "play.fill", action: onTry)
        case .find, .newFind: if let onKeep { CapsuleButton("Keep", style: .fill, action: onKeep) }
        default: EmptyView()
        }
    }
}

private struct RowActions: ViewModifier {
    let state: RowState
    let tryTitle: String
    let onTry: () -> Void
    let onKeep: (() -> Void)?
    func body(content: Content) -> some View {
        switch state {
        case .notYet:
            content.accessibilityAction(.default, onTry).accessibilityAction(named: tryTitle, onTry).accessibilityAddTraits(.isButton)
        case .find, .newFind:
            // Named from `accessibilityActionNames(offersKeep:)`, so the spoken action is what the row offers.
            if let onKeep, let name = state.accessibilityActionNames(offersKeep: true).first {
                content.accessibilityAction(named: name, onKeep)
            } else {
                content
            }
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
