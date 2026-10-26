import SwiftUI

/// What a song/album is, in Magpie's terms. Drives art shape, the status line and VoiceOver.
public enum RowState: Sendable, Hashable {
    case library
    case downloaded
    case notYet
    case onItsWay(progress: Double?, phrase: String)
    case newFind
    case find(daysLeft: Int)
    case keptLosslessSoon
    case lossless
    case notFound

    /// Fade to keep: colour drains over the sample window. Never below 5%.
    public static func findSaturation(daysLeft: Int) -> Double { min(1, max(0.05, Double(daysLeft) / 7)) }

    /// Colour saturation of the art for this state.
    public var saturation: Double {
        if case .find(let d) = self { return Self.findSaturation(daysLeft: d) }
        return 1
    }

    /// Records (no sleeve yet) vs sleeves (owned).
    public var isRecord: Bool {
        switch self {
        case .notYet, .onItsWay, .newFind, .find, .notFound: return true
        case .library, .downloaded, .keptLosslessSoon, .lossless: return false
        }
    }

    public var isOnItsWay: Bool { if case .onItsWay = self { return true } else { return false } }

    /// Fraction of the 7-day sample window left, for the arc around a find.
    public var arcFraction: Double? {
        if case .find(let d) = self { return min(1, max(0, Double(d) / 7)) }
        return nil
    }

    /// Spoken state. `nil` for the silent default (in library).
    public var voiceOverValue: String? {
        switch self {
        case .library: return nil
        case .downloaded: return "Downloaded"
        case .notYet: return "Not in your library"
        case .onItsWay(let progress, let phrase):
            if let progress { return "Bringing it home, \(Int((min(1, max(0, progress)) * 100).rounded())) percent" }
            return phrase.isEmpty ? "Bringing it home" : "Bringing it home, \(phrase)"
        case .newFind: return "New find"
        case .find(let d):
            if d <= 0 { return "Find, leaves today" }
            return "Find, \(d) \(d == 1 ? "day" : "days") left to keep"
        case .keptLosslessSoon: return "In your library, lossless on the way"
        case .lossless: return "In your library, lossless"
        case .notFound: return "Still looking, we'll tell you when it's here"
        }
    }

    /// Visible status text (12 pt line). Empty for plain library items.
    public var statusText: String {
        switch self {
        case .library: return ""
        case .downloaded: return "Downloaded"
        case .notYet: return "Not in your library"
        case .onItsWay(_, let phrase): return phrase.isEmpty ? "Bringing it home" : "Bringing it home · \(phrase)"
        case .newFind: return "New find"
        case .find(let d):
            if d <= 0 { return "Find · leaves today" }
            return "Find · \(d) \(d == 1 ? "day" : "days") left"
        case .keptLosslessSoon: return "Kept · lossless soon"
        case .lossless: return "Lossless"
        case .notFound: return "Still looking"
        }
    }

    /// SF Symbol paired with the text so state is never carried by shape or colour alone.
    public var statusSymbol: String? {
        switch self {
        case .library: return nil
        case .downloaded: return "arrow.down.circle.fill"
        case .notYet: return "record.circle"
        case .onItsWay: return "arrow.down.circle"
        case .newFind: return "sparkles"
        case .find: return "hourglass"
        case .keptLosslessSoon: return "checkmark.circle"
        case .lossless: return "checkmark.seal"
        case .notFound: return "magnifyingglass"
        }
    }

    /// Names of the custom accessibility actions the row offers beyond its default.
    public var accessibilityActionNames: [String] {
        switch self {
        case .notYet: return ["Try"]
        case .find, .newFind: return ["Keep"]
        default: return []
        }
    }
}

/// 12 pt status line: SF Symbol + text. Always shown for non-library states (D3), in every Character.
public struct StatusLine: View {
    private let state: RowState
    private let themed = ThemedPalette()
    @Environment(\.magpieTheme) private var theme

    public init(_ state: RowState) { self.state = state }

    public var body: some View {
        if let symbol = state.statusSymbol, !state.statusText.isEmpty {
            Label {
                Text(state.statusText).font(theme.numberFont(.caption)).lineLimit(2)
            } icon: {
                Image(systemName: symbol).imageScale(.small)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.voiceOverValue ?? state.statusText)
        }
    }

    // Accent-ink (never raw Sheen) on light so text keeps 4.5:1 (D15).
    private var tint: Color {
        switch state {
        case .notYet, .find, .newFind, .onItsWay: return themed.palette.accentInkColor
        default: return themed.palette.ink2Color
        }
    }
}

#Preview("StatusLine") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach([RowState.notYet, .onItsWay(progress: nil, phrase: "about 30 seconds"), .newFind,
                 .find(daysLeft: 5), .keptLosslessSoon, .lossless, .notFound, .downloaded], id: \.self) {
            StatusLine($0)
        }
    }.padding()
}
