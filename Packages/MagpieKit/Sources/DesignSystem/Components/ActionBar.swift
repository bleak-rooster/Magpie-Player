import SwiftUI

/// Y7 (plan item 10): the one row of page actions (Play, Shuffle, Download) every page uses.
///
/// - Items share one width per row and one height (at least 44 pt), with the same icon and label spacing.
/// - Two to a row; a third (Download) takes the next row at full width, so it never squeezes Play and Shuffle.
/// - A label that wouldn't fit its slot on one line stacks the whole bar rather than truncating; at accessibility
///   sizes it always stacks (D15).
/// - The bar keeps the page's 16 pt side margins itself, so every page lines it up the same way.
public struct ActionBar<Content: View>: View {
    private let content: Content
    private let insetsMargins: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.actionBarProbe) private var probe

    /// `insetsMargins: false` for a bar inside a stack that already keeps the 16 pt margins.
    public init(insetsMargins: Bool = true, @ViewBuilder content: () -> Content) {
        self.insetsMargins = insetsMargins
        self.content = content()
    }

    public var body: some View {
        ActionBarLayout(stacked: typeSize.isAccessibilitySize) {
            Group(subviews: content) { items in
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if let probe {
                        item.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe(index, $0) }
                    } else {
                        item
                    }
                }
            }
        }
        .environment(\.actionFillsHeight, true)
        .padding(.horizontal, insetsMargins ? Tokens.Spacing.margin : 0)
    }
}

extension EnvironmentValues {
    /// Tests: reports each ActionBar item's global frame by its position in the bar.
    @Entry public var actionBarProbe: (@MainActor (Int, CGRect) -> Void)?
    /// Inside a bar, capsules fill the height the bar gives them (one height per bar); alone they keep their own.
    @Entry var actionFillsHeight = false
}

/// Where each item goes; pure, so the rules can be tested without drawing.
public enum ActionBarArrangement {
    /// The gap between items, across and down.
    public static let spacing: CGFloat = Tokens.Spacing.s

    /// Rows of item indices: two to a row, or one to a row when `stacked` or when a label (its one-line ideal
    /// width) wouldn't fit its slot.
    public static func rows(idealWidths: [CGFloat], width: CGFloat, stacked: Bool) -> [[Int]] {
        let indices = Array(idealWidths.indices)
        guard !stacked else { return indices.map { [$0] } }
        let paired = stride(from: 0, to: indices.count, by: 2).map { Array(indices[$0..<min($0 + 2, indices.count)]) }
        let fits = paired.allSatisfy { row in
            let slot = slotWidth(width, count: row.count)
            return row.allSatisfy { idealWidths[$0] <= slot + 0.5 }
        }
        return fits ? paired : indices.map { [$0] }
    }

    /// Each item's frame in a bar `width` wide, every item `height` tall.
    public static func frames(idealWidths: [CGFloat], height: CGFloat, width: CGFloat, stacked: Bool) -> [CGRect] {
        var frames = Array(repeating: CGRect.zero, count: idealWidths.count)
        for (r, row) in rows(idealWidths: idealWidths, width: width, stacked: stacked).enumerated() {
            let slot = slotWidth(width, count: row.count)
            for (c, index) in row.enumerated() {
                frames[index] = CGRect(x: CGFloat(c) * (slot + spacing), y: CGFloat(r) * (height + spacing),
                                       width: slot, height: height)
            }
        }
        return frames
    }

    static func slotWidth(_ width: CGFloat, count: Int) -> CGFloat {
        count <= 1 ? width : (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }
}

struct ActionBarLayout: Layout {
    var stacked: Bool

    private func measure(_ subviews: Subviews, width: CGFloat) -> (ideal: [CGFloat], height: CGFloat) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = ActionBarArrangement.rows(idealWidths: ideal, width: width, stacked: stacked)
        var height = Tokens.minHitSize
        for row in rows {
            let slot = ActionBarArrangement.slotWidth(width, count: row.count)
            for index in row {
                height = max(height, subviews[index].sizeThatFits(ProposedViewSize(width: slot, height: nil)).height)
            }
        }
        return (ideal, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        let (ideal, height) = measure(subviews, width: width)
        let rows = ActionBarArrangement.rows(idealWidths: ideal, width: width, stacked: stacked).count
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(max(rows - 1, 0)) * ActionBarArrangement.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let (ideal, height) = measure(subviews, width: bounds.width)
        let frames = ActionBarArrangement.frames(idealWidths: ideal, height: height, width: bounds.width, stacked: stacked)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Play is the page's one filled action; everything else in the bar is tinted.
public enum ActionProminence: Sendable, Hashable { case primary, secondary }

/// The bar's colours, as plain numbers so contrast can be tested.
public enum ActionStyle {
    public struct Colors: Sendable, Hashable {
        /// The label (text and symbol).
        public var label: PaletteColor
        /// The capsule.
        public var fill: PaletteColor
        /// The done part of a Download capsule's progress, drawn over `fill`.
        public var progress: PaletteColor
    }

    public static func colors(_ prominence: ActionProminence, theme: Theme, scheme: ColorScheme) -> Colors {
        let p = theme.colors(for: scheme)
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1).
        let solid = prominence == .primary || theme.character == .immersive
        if solid {
            // The done part lightens the fill under its dark label, or darkens it under a light one.
            let lightLabel = p.onAccent.relativeLuminance > p.accent.relativeLuminance
            return Colors(label: p.onAccent, fill: p.accent,
                          progress: PaletteColor(hex: lightLabel ? 0x000000 : 0xFFFFFF, alpha: 0.22))
        }
        var tint = p.accent
        tint.alpha = 0.16
        var done = p.accent
        done.alpha = 0.14
        // Y7 audit: accent-ink on the tint misses AA for Tangerine and Ultramarine in light mode (3.9–4.3:1), so the
        // label deepens toward ink until it clears 4.5:1 on the darkest part of the capsule.
        let darkest = done.composited(over: tint.composited(over: p.bg))
        return Colors(label: p.accentInk.deepened(toward: p.ink, untilContrast: 4.6, on: darkest), fill: tint, progress: done)
    }
}

extension PaletteColor {
    /// This colour mixed toward `target` in 5 % steps until it reaches `ratio` on `background` (itself if it does).
    func deepened(toward target: PaletteColor, untilContrast ratio: Double, on background: PaletteColor) -> PaletteColor {
        var out = self
        for step in 0...20 {
            let t = Double(step) / 20
            out.red = red + (target.red - red) * t
            out.green = green + (target.green - green) * t
            out.blue = blue + (target.blue - blue) * t
            if Contrast.ratio(out, on: background) >= ratio { return out }
        }
        return out
    }
}

extension Theme {
    /// Action bar labels: SF Pro subheadline semibold; Immersive's are SF Pro Compressed, bolder, one step up.
    public var actionFont: Font {
        character == .immersive ? .system(.callout, weight: .bold).width(.compressed) : .subheadline.weight(.semibold)
    }
}

/// The capsule itself: a symbol and a one-line label, centred, as wide as it's allowed (in a bar, its slot; alone,
/// the row). A Download capsule passes `progress` (0...1) and shows the done part as a fill from the leading edge;
/// `busy` swaps the symbol for a spinner.
public struct ActionCapsule: View {
    private let title: String
    private let symbol: String
    private let prominence: ActionProminence
    private let progress: Double?
    private let busy: Bool
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.actionFillsHeight) private var fillsHeight

    public init(_ title: String, symbol: String, prominence: ActionProminence = .secondary, progress: Double? = nil,
                busy: Bool = false) {
        self.title = title; self.symbol = symbol; self.prominence = prominence; self.progress = progress
        self.busy = busy
    }

    public var body: some View {
        let c = ActionStyle.colors(prominence, theme: theme, scheme: scheme)
        HStack(spacing: Tokens.Spacing.s - 2) {
            if busy {
                ProgressView().tint(c.label.color).accessibilityHidden(true)
            } else {
                Image(systemName: symbol).imageScale(.medium).accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
        }
        .font(theme.actionFont)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.s)
        .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, maxHeight: fillsHeight ? .infinity : nil)
        .foregroundStyle(c.label.color)
        .background {
            ZStack(alignment: .leading) {
                Capsule().fill(c.fill.color)
                if let progress {
                    GeometryReader { geo in
                        Rectangle().fill(c.progress.color)
                            .frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                    .clipShape(Capsule())
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
    }
}

/// A Play, Shuffle or other page action: an `ActionCapsule` that presses down slightly (just dims under Reduce
/// Motion). Alone (outside an `ActionBar`) it spans the row, like the request page's and Try sheet's actions.
public struct ActionButton: View {
    private let title: String
    private let symbol: String
    private let prominence: ActionProminence
    private let busy: Bool
    private let action: () -> Void

    public init(_ title: String, symbol: String, prominence: ActionProminence = .secondary, busy: Bool = false,
                action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.prominence = prominence; self.busy = busy; self.action = action
    }

    public var body: some View {
        Button(action: action) { ActionCapsule(title, symbol: symbol, prominence: prominence, busy: busy) }
            .buttonStyle(ActionPressStyle())
    }
}

/// The bar's press feedback, also for a Download capsule's menu.
public struct ActionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("ActionBar") {
    VStack(spacing: 24) {
        ActionBar {
            ActionButton("Play", symbol: "play.fill", prominence: .primary) {}
            ActionButton("Shuffle", symbol: "shuffle") {}
            ActionCapsule("Downloading 4 of 10", symbol: "arrow.down.circle.dotted", progress: 0.4)
        }
        ActionBar { ActionButton("Shuffle", symbol: "shuffle") {} }
    }
}
