import Foundation

/// D6: the one landing rule for a find that just became ready. Pure, so the phone and CarPlay ("Try it next")
/// decide the same way.
public enum LandingRule {
    public enum Landing: Sendable, Equatable {
        /// Start it now.
        case play
        /// Put it next in the queue (never cut in) and offer "Play now".
        case queueNextWithBanner

        public var showsBanner: Bool { self == .queueNextWithBanner }
    }

    /// Plays at once only when the owner is still on the find's wait screen and nothing else is playing.
    public static func landing(waitingOnScreen: Bool, playing: Bool) -> Landing {
        waitingOnScreen && !playing ? .play : .queueNextWithBanner
    }
}
