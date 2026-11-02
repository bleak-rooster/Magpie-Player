import SwiftUI

/// Try / Keep / Play capsule. Looks ~30 pt tall; the hit area is at least 44 x 44 (a11y M3).
public struct CapsuleButton: View {
    public enum Style: Sendable { case tint, fill }

    public nonisolated static let minimumHitSize: CGFloat = Tokens.minHitSize

    private let title: String
    private let symbol: String?
    private let style: Style
    private let action: () -> Void
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    public init(_ title: String, symbol: String? = nil, style: Style = .tint, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.style = style; self.action = action
    }

    public var body: some View {
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1). Y7: the same colours as
        // the ActionBar, whose tinted label clears AA for every accent.
        let c = ActionStyle.colors(style == .fill ? .primary : .secondary, theme: theme, scheme: scheme)
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).font(theme.capsuleFont)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .foregroundStyle(c.label.color)
            .background(c.fill.color, in: Capsule())
            .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("CapsuleButton") {
    HStack { CapsuleButton("Try", symbol: "play.fill") {}; CapsuleButton("Keep", style: .fill) {} }.padding()
}
