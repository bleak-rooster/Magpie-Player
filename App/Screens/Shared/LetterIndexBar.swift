import DesignSystem
import Search
import SwiftUI

/// The right-edge A–Z + "#" index (P2) for lists the system index can't serve: scroll views, the album grid and the
/// server-paged lists (the system's `listSectionIndexVisibility` only indexes the sections a `List` holds).
///
/// Touch or drag picks the letter under the finger, with a selection tick on each change, and shows it large in the
/// middle of the screen until shortly after the finger lifts (round 11 R2, `LetterBubble`). VoiceOver reads it as one
/// adjustable "Letter index" (swipe up or down moves through the letters that have items). It steps aside at
/// accessibility text sizes, and when the screen is too short for 27 letters (D15); the list stays usable.
struct LetterIndexBar: View {
    /// Letters with items: shown in full ink, the rest dimmed (they still go to the nearest letter).
    let available: Set<String>
    let onSelect: (String) -> Void
    /// The bubble the drag drives (R2); VoiceOver's adjusting doesn't show it.
    var bubble: LetterBubbleState?
    @State private var current: String?
    @State private var height: CGFloat = 0
    private let themed = Themed()

    /// Below this a letter's slot is too small to read or hit.
    static let minSlot: CGFloat = 13
    static let letters = LetterIndex.letters

    /// The height 27 letters need, with the bar's padding.
    static let neededHeight = minSlot * CGFloat(letters.count) + 16

    var body: some View {
        bar.frame(width: 24).frame(maxHeight: .infinity, alignment: .center)
    }

    private var bar: some View {
        let p = themed.palette
        return VStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(available.contains(letter) ? p.accentInkColor : p.ink2Color.opacity(0.5))
                    .frame(width: 24, height: Self.minSlot)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let letter = Self.letter(atY: drag.location.y - 8, height: height - 16)
                pick(letter)
                bubble?.dragged(to: letter)
            }
            .onEnded { _ in
                current = nil
                bubble?.released()
            })
        // A tick per letter, not when the finger lifts (`current` back to nil).
        .sensoryFeedback(.selection, trigger: current) { _, new in new != nil }
        .accessibilityElement()
        .accessibilityLabel("Letter index")
        .accessibilityValue(current ?? "")
        .accessibilityAdjustableAction { direction in
            let letters = Self.letters.filter(available.contains)
            guard !letters.isEmpty else { return }
            let i = current.flatMap(letters.firstIndex(of:))
            switch direction {
            case .increment: pick(letters[i.map { min($0 + 1, letters.count - 1) } ?? 0])
            case .decrement: pick(letters[i.map { max($0 - 1, 0) } ?? 0])
            @unknown default: break
            }
        }
        .accessibilityIdentifier("letter-index")
    }

    private func pick(_ letter: String) {
        guard letter != current else { return }
        current = letter
        onSelect(letter)
    }

    /// The letter under `y` (0 at the top letter) in a column `height` tall, clamped to the ends.
    nonisolated static func letter(atY y: CGFloat, height: CGFloat) -> String {
        guard height > 0, y.isFinite else { return letters[0] }
        let i = Int((y / height * CGFloat(letters.count)).rounded(.down))
        return letters[min(max(i, 0), letters.count - 1)]
    }
}

extension EnvironmentValues {
    /// Round 24 (owner, 2026-11-08): the A–Z bar is on screen over this list (set by `.letterIndex`), so a list of more
    /// than 25 items shows letter headers (`LetterSectionHeader`, D225).
    @Entry var letterIndexShown = false
}

extension View {
    /// The letter index along the right edge, over this scroll view, which keeps its rows clear of it.
    func letterIndex(available: Set<String>, hidden: Bool = false,
                     onSelect: @escaping (String) -> Void) -> some View {
        modifier(LetterIndexOverlay(available: available, hidden: hidden, onSelect: onSelect))
    }
}

private struct LetterIndexOverlay: ViewModifier {
    let available: Set<String>
    let hidden: Bool
    let onSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var height: CGFloat = .infinity
    @State private var bubble = LetterBubbleState()

    func body(content: Content) -> some View {
        // Hidden at accessibility sizes and when 27 letters don't fit (D15); then rows keep their full width too.
        let shown = !hidden && !typeSize.isAccessibilitySize && height >= LetterIndexBar.neededHeight
        content
            .environment(\.letterIndexShown, shown)   // D225: the rows' letter headers follow the bar
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .contentMargins(.trailing, shown ? 14 : 0, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if shown { LetterIndexBar(available: available, onSelect: onSelect, bubble: bubble).padding(.trailing, 2) }
            }
            .overlay { LetterBubble(state: bubble) }
    }
}
