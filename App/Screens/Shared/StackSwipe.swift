import CoreGraphics
import Observation
import SwiftUI
import UIKit

/// The rules of Magpie's own row swipe (R12, fix round 1 I2), as plain values so they can be tested.
struct StackSwipeRules: Equatable {
    /// The back swipe owns this much of the leading edge.
    static let leadingEdgeInset: CGFloat = 24
    /// A drag must travel this far before it counts as a swipe (more than the scroll view's pan needs)…
    static let minimumDistance: CGFloat = 20
    /// …and be this much more sideways than vertical.
    static let dominance: CGFloat = 1.5
    static let buttonWidth: CGFloat = 76

    var width: CGFloat
    var leadingCount: Int
    var trailingCount: Int
    var leadingFull: Bool
    var trailingFull: Bool

    enum Edge: Equatable { case leading, trailing }
    enum Outcome: Equatable {
        /// A full swipe: the edge's outermost action.
        case fire(Edge)
        /// The row rests at this offset (0: closed).
        case rest(CGFloat)
    }

    /// Whether a pan that has moved `translation` from `startX` (distance from the leading edge) is a row swipe: by
    /// distance, horizontal-dominant, and not from the leading edge (the back swipe's).
    static func shouldBegin(translation: CGSize, startX: CGFloat) -> Bool {
        guard startX >= leadingEdgeInset else { return false }
        let dx = abs(translation.width), dy = abs(translation.height)
        return dx >= minimumDistance && dx > dy * dominance
    }

    /// The offset while dragging: never towards an edge without buttons.
    func clamp(_ x: CGFloat) -> CGFloat {
        var x = x
        if leadingCount == 0 { x = min(x, 0) }
        if trailingCount == 0 { x = max(x, 0) }
        return x
    }

    /// The release at `x`. Only a committed release (the finger lifted, not a cancelled or failed pan) fires.
    func release(x: CGFloat, velocity: CGFloat, committed: Bool) -> Outcome {
        guard committed else { return .rest(0) }
        let x = clamp(x)
        let full = width > 0 && abs(x) > width * 0.5
        if x > 0 {
            if full && leadingFull { return .fire(.leading) }
            return .rest(x > 44 || velocity > 400 ? Self.buttonWidth * CGFloat(leadingCount) : 0)
        }
        if x < 0 {
            if full && trailingFull { return .fire(.trailing) }
            return .rest(x < -44 || velocity < -400 ? -Self.buttonWidth * CGFloat(trailingCount) : 0)
        }
        return .rest(0)
    }
}

/// Only one row rests open at a time (M5): opening one closes the others.
@MainActor @Observable final class OpenSwipeRow {
    static let shared = OpenSwipeRow()
    var id: UUID?
}

/// Magpie's swipe for rows in a scroll view (`swipeActions` works only in a `List`): a horizontal pan slides the row
/// and uncovers its buttons; past half the width a full swipe fires the outermost one (where allowed); otherwise it
/// rests open (tap a button, or the row to close) or springs back.
struct StackSwipe: ViewModifier {
    let leading: [SwipeButtonModel]
    let trailing: [SwipeButtonModel]
    let leadingFull: Bool
    let trailingFull: Bool
    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var id = UUID()
    /// This drag is a row swipe (decided once, on its first change).
    @State private var tracking = false
    @State private var decided = false
    @GestureState private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var rules: StackSwipeRules {
        StackSwipeRules(width: width, leadingCount: leading.count, trailingCount: trailing.count,
                        leadingFull: leadingFull, trailingFull: trailingFull)
    }

    func body(content: Content) -> some View {
        content
            // Before the offset, so the tap-to-close layer moves with the row and leaves the buttons uncovered (C2).
            .overlay {
                if resting != 0 {
                    Color.clear.contentShape(Rectangle()).onTapGesture { settle(0) }   // a tap closes, doesn't play
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 0 { buttons(leading, width: offset, outermostLast: false) }
            }
            .background(alignment: .trailing) {
                if offset < 0 { buttons(trailing, width: -offset, outermostLast: true) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // High priority over the row's own Button, so a swipe never also plays the row. It needs more travel than
            // the scroll view's pan, so a vertical drag is the scroll view's before this one could begin; a drag from
            // the leading edge is ignored (the back swipe's).
            .highPriorityGesture(drag, including: .all)
            .onChange(of: dragging) { _, now in
                // The drag ended without a release (cancelled or failed): close, never fire (I2 a).
                if !now { decided = false }
                if !now, tracking { tracking = false; settle(0) }
            }
            .onChange(of: OpenSwipeRow.shared.id) { _, open in if open != id, resting != 0 { settle(0) } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: StackSwipeRules.minimumDistance, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if !decided {
                    decided = true
                    var startX = value.startLocation.x
                    if layoutDirection == .rightToLeft { startX = screenWidth - startX }
                    tracking = StackSwipeRules.shouldBegin(translation: value.translation, startX: startX)
                }
                guard tracking else { return }
                offset = rules.clamp(resting + value.translation.width)
            }
            .onEnded { value in
                decided = false
                guard tracking else { return }
                tracking = false
                let velocity = value.predictedEndTranslation.width - value.translation.width
                ended(value.translation.width, velocity, true)
            }
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    /// The buttons share the uncovered width; the outermost sits at the row's edge.
    private func buttons(_ models: [SwipeButtonModel], width: CGFloat, outermostLast: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(outermostLast ? models.reversed() : models) { b in
                Button {
                    b.action()
                    settle(0)
                } label: {
                    Label(b.title, systemImage: b.symbol).labelStyle(.iconOnly)
                        .font(.title3).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(b.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)   // VoiceOver uses the row's actions
            }
        }
        .frame(width: width)
        .clipped()
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat, _ committed: Bool) {
        switch rules.release(x: resting + translation, velocity: velocity, committed: committed) {
        case .fire(let edge):
            (edge == .leading ? leading : trailing).first?.action()
            settle(0)
        case .rest(let x):
            settle(x)
        }
    }

    private func settle(_ x: CGFloat) {
        resting = x
        if x != 0 { OpenSwipeRow.shared.id = id }
        if reduceMotion { offset = x } else { withAnimation(.spring(duration: 0.3)) { offset = x } }
    }
}
