import DesignSystem
import Foundation
import Requests

/// What a request's state says to the owner (D7: honest steps, real % only in the app). Pure, so tests can
/// check the wording. Never names a service (design language §5): "your server".
enum RequestCopy {
    enum Group: Int, CaseIterable {
        case inProgress, ready, attention

        var title: String {
            switch self {
            case .inProgress: "In progress"
            case .ready: "Ready"
            case .attention: "Needs attention"
            }
        }
    }

    /// Where Activity lists the request; nil for stopped or removed ones.
    static func group(_ state: RequestState) -> Group? {
        switch state {
        case .pending, .resolving, .adding, .searching, .downloading, .importing: .inProgress
        case .ready, .kept: .ready
        case .waiting, .failed: .attention
        case .cancelled, .dismissed: nil
        }
    }

    /// The four voiced steps: Looking → Spotted it → Bringing it home → Ready.
    static func stage(_ state: RequestState) -> WaitStage {
        switch state {
        case .downloading(let p): p > 0 ? .bringingItHome : .spotted
        case .importing: .bringingItHome
        case .ready, .kept: .ready
        default: .looking
        }
    }

    /// One status line.
    static func status(_ state: RequestState) -> String {
        switch state {
        case .pending, .resolving, .adding: "Looking"
        case .searching: "Looking for the best copy"
        case .downloading(let p): p > 0 ? "Bringing it home · \(percent(p))" : "Spotted it"
        case .importing: "Bringing it home · almost there"
        case .ready: "Ready · in your library"
        case .kept: "Kept"
        case .cancelled: "Stopped"
        case .dismissed: "Removed"
        case .waiting(let reason, _):
            switch reason.kind {
            case .stillLooking: "Couldn't spot it yet. We'll keep looking."
            case .serviceUnavailable: "Your server isn't answering. We'll try again."
            case .downloadFailed: "That copy didn't work. Looking for another."
            }
        case .failed(let reason):
            switch reason {
            case .notFoundYet: "Couldn't find it"
            case .noRelease: "Couldn't find a release with this song"
            case .notInCatalogue: "Not in this artist's catalogue on your server"
            case .addFailed: "Your server said no to this one"
            case .unknown: "Something went wrong"
            }
        }
    }

    /// The wait screen's estimate line (D7: real % in the foreground, otherwise the tier phrase).
    static func phrase(_ state: RequestState, tier: Tier) -> String {
        switch state {
        case .downloading(let p) where p > 0: percent(p)
        case .importing: "almost there"
        case .ready: ""
        default: tier.estimate
        }
    }

    /// "Patient · can take a few hours".
    static func tierLine(_ tier: Tier) -> String { "\(tier.title) · \(tier.estimate)" }

    static func percent(_ p: Double) -> String { "\(Int((min(1, max(0, p)) * 100).rounded()))%" }

    /// SF Symbol paired with the status text (D3: state is never shape or colour alone).
    static func symbol(_ state: RequestState) -> String {
        switch group(state) {
        case .inProgress: "arrow.down.circle"
        case .ready: "checkmark.circle"
        case .attention: if case .failed = state { "exclamationmark.circle" } else { "magnifyingglass" }
        case nil: "stop.circle"
        }
    }

    /// Whether Stop looking (Cancel, G6) is offered.
    static func canCancel(_ state: RequestState) -> Bool { !state.isTerminal && state != .ready }
}
