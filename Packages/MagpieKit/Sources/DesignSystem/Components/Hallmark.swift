import SwiftUI
import MagpieCore

/// Quality stamp: "Sample", "Lossless soon", "Lossless", "Hi-Res". Shimmers once when a genuine lossless file arrives.
public struct Hallmark: View {
    private let quality: Quality
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer: CGFloat = -1

    public init(_ quality: Quality) { self.quality = quality }

    public nonisolated static func text(for quality: Quality) -> String? {
        switch quality {
        case .sample: return "Sample"
        case .losslessSoon: return "Lossless soon"
        case .lossless: return "Lossless"
        case .hiRes: return "Hi-Res"
        case .standard: return nil
        }
    }

    public nonisolated static func accessibilityText(for quality: Quality) -> String? {
        switch quality {
        case .sample: return "Sample quality"
        case .losslessSoon: return "Lossless on the way"
        case .lossless: return "Lossless"
        case .hiRes: return "High-resolution lossless"
        case .standard: return nil
        }
    }

    private var isGenuineLossless: Bool { quality == .lossless || quality == .hiRes }

    public var body: some View {
        if let text = Self.text(for: quality) {
            let p = themed.palette
            let tint = isGenuineLossless ? p.accentInkColor : p.ink2Color
            Group {
                if typeSize.isAccessibilitySize {
                    Text(text).font(.footnote.weight(.semibold)).foregroundStyle(tint)   // plain text at AX sizes
                } else {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))      // upright SF at <= 12 pt (a11y L3)
                        .textCase(.uppercase).tracking(0.3)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isGenuineLossless ? tint : p.sepColor, lineWidth: 1))
                        .overlay(shimmerOverlay)
                }
            }
            .onChange(of: quality) { old, new in
                guard (new == .lossless || new == .hiRes), old != new, !reduceMotion else { return }
                shimmer = -1
                withAnimation(.easeInOut(duration: 0.9)) { shimmer = 2 }   // once, under 1 s
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(for: quality) ?? text)
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            Tokens.sheenGradient
                .opacity(0.55)
                .frame(width: geo.size.width * 0.5)
                .offset(x: geo.size.width * shimmer)
                .blendMode(.plusLighter)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .allowsHitTesting(false)
        .opacity(shimmer > -1 && shimmer < 2 ? 1 : 0)
    }
}

#Preview("Hallmark") {
    HStack { Hallmark(.sample); Hallmark(.losslessSoon); Hallmark(.lossless); Hallmark(.hiRes) }.padding()
}
