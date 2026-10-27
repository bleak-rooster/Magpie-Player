import SwiftUI

/// Round art with grooves and a spindle hole (the bare record): music you don't have yet.
/// In Classic the record renders as a full-opacity square with no grooves; callers show the status badge.
public struct RecordArt: View {
    private let image: Image?
    private let placeholder: Color
    private let side: CGFloat?
    private let saturation: Double
    private let arc: Double?
    private let isSpinning: Bool
    @Environment(\.magpieTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - arc: fraction (0...1) of the sample window left; draws the "fade to keep" ring.
    ///   - isSpinning: spin at 33 1/3 rpm (1.8 s/turn). Ignored under Reduce Motion.
    public init(image: Image? = nil, placeholder: Color = .gray.opacity(0.45), side: CGFloat? = nil,
                saturation: Double = 1, arc: Double? = nil, isSpinning: Bool = false) {
        self.image = image; self.placeholder = placeholder; self.side = side
        self.saturation = saturation; self.arc = arc; self.isSpinning = isSpinning
    }

    /// Spin only while fetching and only when Reduce Motion is off.
    nonisolated static func shouldSpin(isSpinning: Bool, reduceMotion: Bool) -> Bool { isSpinning && !reduceMotion }

    public var body: some View {
        let spin = Self.shouldSpin(isSpinning: isSpinning, reduceMotion: reduceMotion)
        let p = theme.colors(for: scheme)
        Group {
            if theme.character == .classic {
                SleeveArt(image: image, placeholder: placeholder, side: side, saturation: saturation)
            } else {
                ZStack {
                    TimelineView(.animation(paused: !spin)) { ctx in
                        disc(p).rotationEffect(.degrees(spin ? angle(at: ctx.date) : 0))
                    }
                    if let arc { ArcRing(fraction: arc, fill: p.accentInkColor, track: p.sepColor) }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(width: side, height: side)
            }
        }
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Tokens.Motion.recordTurn)
        return t / Tokens.Motion.recordTurn * 360
    }

    private func disc(_ p: Palette) -> some View {
        ZStack {
            placeholder
            if let image { image.resizable().scaledToFill() }
            Canvas { gc, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                var r = maxR * 0.2 + 2
                while r < maxR - 1 {                        // fine groove lines, 2.6 pt pitch
                    gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                              with: .color(.black.opacity(0.16)), lineWidth: 0.6)
                    r += 2.6
                }
                let hole = maxR * 0.2                         // spindle hole: 20% of the diameter
                let rect = CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)
                gc.fill(Path(ellipseIn: rect), with: .color(theme.character == .immersive ? Color(.sRGB, red: 0.082, green: 0.075, blue: 0.102) : p.bgColor))
                gc.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.25)), lineWidth: 1.5)
            }
        }
        .saturation(saturation)
        .clipShape(Circle())
        .padding(arc == nil ? 0 : 2.5)
    }
}

/// Thin arc around a record showing days left. Light schemes use accent-ink on the track (a11y H3).
struct ArcRing: View {
    let fraction: Double
    let fill: Color
    let track: Color
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: fraction).stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview("RecordArt") {
    HStack(spacing: 16) {
        RecordArt(placeholder: .orange, side: 96)
        RecordArt(placeholder: .indigo, side: 96, saturation: 0.4, arc: 3.0 / 7)
        RecordArt(placeholder: .teal, side: 96, isSpinning: true)
        RecordArt(placeholder: .teal, side: 96).magpieTheme(Theme(character: .classic))
    }.padding()
}
