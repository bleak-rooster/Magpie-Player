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

    /// How far below its one-line ideal width a label may be squeezed (its text scales down a little, never
    /// truncates) before the bar stacks instead.
    public static let fitAllowance: CGFloat = 0.85

    /// Rows of item indices. Phase 2 (owner ruling): every item in one row of equal slots; one to a row when
    /// `stacked`, or when a label wouldn't fit its slot even squeezed by `fitAllowance`.
    public static func rows(idealWidths: [CGFloat], width: CGFloat, stacked: Bool) -> [[Int]] {
        let indices = Array(idealWidths.indices)
        guard !stacked else { return indices.map { [$0] } }
        let slot = slotWidth(width, count: indices.count)
        let fits = idealWidths.allSatisfy { $0 * fitAllowance <= slot + 0.5 }
        return fits ? [indices] : indices.map { [$0] }
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
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1). Y7 audit: so Shuffle
        // doesn't look like Play there, its capsule is an opaque deep shade of the accent with a white label, deep
        // enough that the label clears AA even over its progress.
        if prominence == .secondary, theme.character == .immersive {
            return Colors(label: p.ink, fill: immersiveSecondaryFill(accent: p.accent, label: p.ink), progress: immersiveShade)
        }
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

    /// The done part of an Immersive secondary capsule: it darkens the deep shade further.
    static let immersiveShade = PaletteColor(hex: 0x000000, alpha: 0.25)

    /// Immersive's secondary capsule: the accent darkened until `label` clears AA on it.
    /// Review minor 8: it never quietly keeps a fill that misses. Both the fill and its darker progress part are
    /// checked, and if no shade of the accent clears 4.6:1 it falls back to near-black.
    public static func immersiveSecondaryFill(accent: PaletteColor, label: PaletteColor) -> PaletteColor {
        func clears(_ fill: PaletteColor) -> Bool {
            Contrast.ratio(label, on: fill) >= 4.6 && Contrast.ratio(label, on: immersiveShade.composited(over: fill)) >= 4.6
        }
        var fill = accent
        fill.alpha = 1
        for step in 0...20 {
            let t = 0.45 + Double(step) * 0.025
            fill.red = accent.red * (1 - t); fill.green = accent.green * (1 - t); fill.blue = accent.blue * (1 - t)
            if clears(fill) { return fill }
        }
        // A light label that no shade reaches (or a dark one): near-black, or near-white under a dark label.
        let fallback = PaletteColor(hex: label.relativeLuminance > 0.5 ? 0x121212 : 0xF2F2F2)
        assert(Contrast.ratio(label, on: fallback) >= 4.5, "Immersive secondary misses AA")
        return fallback
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
        HStack(spacing: Tokens.Spacing.iconGap) {
            if busy {
                ProgressView().tint(c.label.color).accessibilityHidden(true)
            } else {
                Image(systemName: symbol).imageScale(.medium).accessibilityHidden(true)
            }
            // Three equal slots (phase 2): a label may shrink a little to share the row, never truncate
            // (`ActionBarArrangement.fitAllowance`); one that can't, stacks the bar.
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(theme.actionFont)
        .padding(.horizontal, Tokens.Spacing.s)
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
        .modifier(BusyValue(busy: busy))   // review minor 5: VoiceOver hears the busy state
    }
}

/// "Working" as the VoiceOver value while busy; nothing otherwise, so a caller's own value (Download's status) stands.
private struct BusyValue: ViewModifier {
    let busy: Bool
    func body(content: Content) -> some View {
        if busy { content.accessibilityValue("Working") } else { content }
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
