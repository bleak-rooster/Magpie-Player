#if os(iOS)
import AVFoundation
import Foundation

/// Round 21 (owner, 2026-11-06): Magpie runs on iOS 26 again (D166). The audio session's interruption events come
/// through iOS 27's pair (`didBecomeInactiveNotification`, then `resumptionRecommendationNotification`) where it
/// exists, and through the classic `interruptionNotification` (began / ended with `.shouldResume`) on iOS 26. Both
/// engines see the same two callbacks either way, so playback behaves alike on both systems.
///
/// Route changes (D168): only `.oldDeviceUnavailable` (headphones unplugged, Bluetooth or the car gone, an AirPlay
/// speaker dropped) pauses; nothing resumes on its own. A new route (Bluetooth connects, AirPlay picked) keeps playing.
public enum AudioSessionEvents {
    /// An interruption as the engines see it.
    public enum Interruption: Equatable, Sendable {
        /// The session went inactive (a call, another app's audio).
        case began
        /// The interruption ended; `shouldResume` is the system's recommendation.
        case ended(shouldResume: Bool)
    }

    /// iOS 26's `interruptionNotification` user info, read as an `Interruption`; nil when it carries no type.
    public static func classicInterruption(_ userInfo: [AnyHashable: Any]?) -> Interruption? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// Whether a route change pauses playback: only when the output in use went away (D168).
    public static func pausesPlayback(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let reason = (userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        return reason == .oldDeviceUnavailable
    }

    /// Observes interruptions on `session` with the API this system has; `began` and `ended` run on the main actor.
    public static func observeInterruptions(_ session: AVAudioSession,
                                     began: @escaping @MainActor () -> Void,
                                     ended: @escaping @MainActor (_ shouldResume: Bool) -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        if #available(iOS 27, *) {
            return [
                center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session,
                                   queue: .main) { _ in
                    MainActor.assumeIsolated { began() }
                },
                center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session,
                                   queue: .main) { note in
                    let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                    let shouldResume = context?.recommendation == .shouldResume
                    MainActor.assumeIsolated { ended(shouldResume) }
                },
            ]
        }
        return [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
                let interruption = classicInterruption(note.userInfo)
                MainActor.assumeIsolated {
                    switch interruption {
                    case .began: began()
                    case .ended(let shouldResume): ended(shouldResume)
                    case nil: break
                    }
                }
            },
        ]
    }
}
#endif
