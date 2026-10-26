import SwiftUI

/// Square art (the sleeve): music you own. Takes already-loaded art; no networking here.
public struct SleeveArt: View {
    private let image: Image?
    private let placeholder: Color
    private let side: CGFloat?
    private let saturation: Double
    @Environment(\.magpieTheme) private var theme

    public init(image: Image? = nil, placeholder: Color = .gray.opacity(0.35), side: CGFloat? = nil, saturation: Double = 1) {
        self.image = image; self.placeholder = placeholder; self.side = side; self.saturation = saturation
    }

    public var body: some View {
        let radius = side.map(Tokens.Radius.art(forSide:)) ?? Tokens.Radius.art
        ZStack {
            placeholder
            if let image { image.resizable().scaledToFill() }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: side, height: side)
        .saturation(saturation)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.black.opacity(0.06)))
        .accessibilityHidden(true)
    }
}

#Preview("SleeveArt") {
    HStack { SleeveArt(placeholder: .orange, side: 48); SleeveArt(placeholder: .indigo, side: 96) }.padding()
}
