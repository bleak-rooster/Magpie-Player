import SwiftUI

/// Try / Keep / Play capsule. Looks ~30 pt tall; the hit area is at least 44 x 44 (a11y M3).
public struct CapsuleButton: View {
    public enum Style: Sendable { case tint, fill }

    public nonisolated static let minimumHitSize: CGFloat = Tokens.minHitSize

    private let title: String
    private let symbol: String?
    private let style: Style
    private let action: () -> Void
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme

    public init(_ title: String, symbol: String? = nil, style: Style = .tint, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.style = style; self.action = action
    }

    public var body: some View {
        let p = themed.palette
        // Immersive capsules are always solid: a tint over art can drop to 1.9:1 (a11y C1).
        let solid = style == .fill || theme.character == .immersive
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .foregroundStyle(solid ? p.onAccentColor : p.accentInkColor)
            .background(solid ? p.accentColor : p.accentColor.opacity(0.16), in: Capsule())
            .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("CapsuleButton") {
    HStack { CapsuleButton("Try", symbol: "play.fill") {}; CapsuleButton("Keep", style: .fill) {} }.padding()
}
