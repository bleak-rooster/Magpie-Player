import SwiftUI

/// Fetch stages, voiced: Looking, Spotted it, Bringing it home, Ready.
public enum WaitStage: Int, CaseIterable, Sendable {
    case looking, spotted, bringingItHome, ready

    public var title: String {
        switch self {
        case .looking: return "Looking"
        case .spotted: return "Spotted it"
        case .bringingItHome: return "Bringing it home"
        case .ready: return "Ready"
        }
    }
}

/// The Try wait screen: spinning record, grooves rippling outward, an honest estimate, and the four steps.
public struct WaitView: View {
    private let title: String
    private let artist: String
    private let artwork: Image?
    private let stage: WaitStage
    private let phrase: String
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor

    public init(title: String, artist: String, artwork: Image? = nil, stage: WaitStage, phrase: String) {
        self.title = title; self.artist = artist; self.artwork = artwork; self.stage = stage; self.phrase = phrase
    }

    public var body: some View {
        let p = themed.palette
        let ax = typeSize.isAccessibilitySize
        ScrollView {
            VStack(spacing: Tokens.Spacing.xl) {
                ZStack {
                    if !reduceMotion { Ripples(color: p.accentInkColor).frame(width: ax ? 160 : 220, height: ax ? 160 : 220) }
                    RecordArt(image: artwork, side: ax ? 160 : 150, isSpinning: stage != .ready)
                }
                .frame(height: ax ? 180 : 240)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(spokenStatus)
                .accessibilityAddTraits(.updatesFrequently)

                VStack(spacing: Tokens.Spacing.xs) {
                    Text(title).magpieDisplay(.title2).multilineTextAlignment(.center)
                    Text(artist).font(.subheadline).foregroundStyle(p.ink2Color)
                    Text(phrase).font(theme.numberFont(.footnote)).foregroundStyle(p.accentInkColor)
                }
                steps
            }
            .padding(Tokens.Spacing.largeTitleMargin)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(p.inkColor)
        .background(p.bgColor)
        .onChange(of: stage) { _, new in
            var line = AttributedString(announcement(for: new))
            line.accessibilitySpeechAnnouncementPriority = new == .ready ? .high : .low
            AccessibilityNotification.Announcement(line).post()
        }
    }

    private var spokenStatus: String {
        stage == .ready ? "Ready" : (phrase.isEmpty ? stage.title : "\(stage.title), \(phrase)")
    }

    private func announcement(for stage: WaitStage) -> String {
        switch stage {
        case .looking: return "Looking."
        case .spotted: return "Spotted it."
        case .bringingItHome: return "Bringing it home."
        case .ready: return "\(title) is ready."
        }
    }

    // Vertical list at accessibility sizes; current step gets a filled glyph, not just colour (a11y M2).
    private var steps: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.s))
            : AnyLayout(HStackLayout(spacing: Tokens.Spacing.m))
        return layout {
            ForEach(WaitStage.allCases, id: \.self) { s in
                let done = s.rawValue < stage.rawValue
                let current = s == stage
                Label {
                    Text((current && noColor ? "Now: " : "") + s.title)
                        .font(.caption.weight(current ? .semibold : .regular))
                } icon: {
                    Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.inset.filled" : "circle"))
                }
                .foregroundStyle(current ? themed.palette.accentInkColor : (done ? themed.palette.inkColor : themed.palette.ink2Color))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)   // the record element already speaks the current stage
    }
}

/// Grooves rippling outward from the record.
private struct Ripples: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate / 2.4
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(color.opacity(0.4 * (1 - phase)), lineWidth: 1)
                        .scaleEffect(0.68 + 0.32 * phase)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("WaitView") {
    WaitView(title: "Harbour Lights", artist: "Corin Hale", stage: .bringingItHome, phrase: "about 30 seconds")
}
