import SwiftUI

/// Round 14 A2 (D89): what a preview button shows.
public enum PreviewStatus: Sendable, Equatable {
    case ready
    case loading
    /// Playing (or paused), with how much of the 30 seconds has gone, 0...1, and the whole seconds left.
    case playing(progress: Double, secondsLeft: Int)
    /// This song has no preview: the button is disabled and says so.
    case noPreview
    /// The preview couldn't be played right now; tapping tries again.
    case unavailable

    /// The words (design language §5: about music, never a service).
    public var label: String {
        switch self {
        case .ready: "Play preview"
        case .loading: "Loading preview"
        case .playing: "Stop preview"
        case .noPreview: "No preview available"
        case .unavailable: "Preview unavailable right now"
        }
    }

    /// VoiceOver's value: the time left while it plays.
    public var accessibilityValue: String {
        guard case .playing(_, let left) = self else { return "" }
        return left == 1 ? "1 second left" : "\(left) seconds left"
    }

    var symbol: String {
        switch self {
        case .ready: "play.fill"
        case .loading, .playing: "stop.fill"
        case .noPreview: "speaker.slash"
        case .unavailable: "exclamationmark.arrow.circlepath"
        }
    }

    var isEnabled: Bool { self != .noPreview }

    var progress: Double {
        guard case .playing(let p, _) = self, p.isFinite else { return 0 }
        return min(max(p, 0), 1)
    }
}

/// Round 14 A2 (D89): play or stop a song's 30-second preview, with a ring that fills over the 30 seconds. Disabled, and
/// saying "No preview available", for a song without one. At least 44 points to tap; the glyph scales with Dynamic Type.
public struct PreviewButton: View {
    private let status: PreviewStatus
    private let action: () -> Void
    private let themed = ThemedPalette()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    public init(status: PreviewStatus, action: @escaping () -> Void) {
        self.status = status
        self.action = action
    }

    public var body: some View {
        let p = themed.palette
        Button(action: action) {
            ZStack {
                Circle().stroke(p.sepColor, lineWidth: 2.5)
                if case .loading = status {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .trim(from: 0, to: status.progress)
                        .stroke(p.accentInkColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: status.progress)
                    Image(systemName: status.symbol)
                        .font(.system(size: side * 0.38, weight: .semibold))
                        .foregroundStyle(status.isEnabled ? p.inkColor : p.ink2Color)
                }
            }
            .frame(width: side, height: side)
            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!status.isEnabled)
        .accessibilityLabel(status.label)
        .accessibilityValue(status.accessibilityValue)
        .accessibilityAddTraits(status == .ready ? .startsMediaSession : [])
        .accessibilityIdentifier("preview-button")
    }
}

#Preview("PreviewButton") {
    HStack {
        PreviewButton(status: .ready) {}
        PreviewButton(status: .loading) {}
        PreviewButton(status: .playing(progress: 0.4, secondsLeft: 18)) {}
        PreviewButton(status: .noPreview) {}
        PreviewButton(status: .unavailable) {}
    }
    .padding()
}
