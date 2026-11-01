import DesignSystem
import Observation
import SwiftUI

/// While a finger is on the A–Z bar, the letter under it, large in the middle of the screen (round 11 R2); it fades out
/// `hideDelay` after the finger lifts. VoiceOver's adjustable index doesn't show it (its value says the letter).
@MainActor @Observable final class LetterBubbleState {
    /// The letter to show; nil when hidden.
    private(set) var shown: String?
    @ObservationIgnored let hideDelay: Duration
    @ObservationIgnored private var hiding: Task<Void, Never>?

    init(hideDelay: Duration = .milliseconds(400)) { self.hideDelay = hideDelay }

    /// The finger is over `letter`.
    func dragged(to letter: String) {
        hiding?.cancel()
        hiding = nil
        if shown != letter { shown = letter }
    }

    /// The finger lifted: the bubble goes after `hideDelay`, unless another touch comes first.
    func released() {
        hiding?.cancel()
        let delay = hideDelay
        hiding = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.shown = nil
        }
    }
}

/// The bubble: the letter in the display face, the theme's accent, on a material square. Without Reduce Motion it
/// grows in; with it, it only fades.
struct LetterBubble: View {
    let state: LetterBubbleState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.magpieTheme) private var theme
    private let themed = Themed()

    var body: some View {
        ZStack {
            if let letter = state.shown {
                Text(letter)
                    .font(.system(size: 56, weight: .bold, design: theme.usesSerifDisplay ? .serif : .rounded))
                    .foregroundStyle(themed.palette.accentInkColor)
                    .frame(width: 96, height: 96)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("letter-bubble")
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.15) : .snappy(duration: 0.2), value: state.shown)
        .allowsHitTesting(false)
    }
}
