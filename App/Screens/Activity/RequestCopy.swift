import DesignSystem
import Foundation
import MagpieCore
import Requests

/// What a request's state says to the owner (D7: honest steps, real % only in the app). Pure, so tests can
/// check the wording. Never names a service (design language §5); a `.needsSettings` wait repeats Try's pointer
/// to Settings.
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
    static func group(_ request: MagpieRequest) -> Group? {
        request.isNotListed || request.keepNeedsAttention || request.notForMeNeedsAttention
            ? .attention : group(request.state)
    }

    static let notListed = "Not showing up in your library yet"

    /// D8: what Try is called when it only asks (Patient): the row's button and the sheet's say the same.
    static let askForIt = "Ask for it"

    /// The not-yet row's button: "Ask for it" when Try only asks (Patient), otherwise "Try".
    static func tryTitle(_ availability: TryAvailability) -> String {
        if case .available(let tier) = availability, tier.asksInsteadOfWaiting { return askForIt }
        return "Try"
    }

    /// A request's screen is titled with its song (its artist when the title is blank), not its speed.
    static func detailTitle(_ request: MagpieRequest) -> String {
        let title = request.recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? request.recording.artist : title
    }

    /// Final review I4: what the app knows about why requests can't move, beyond the runner's one
    /// `.serviceUnavailable` (changes switched off, set-up missing, a rejected key, or simply unreachable).
    enum WaitContext: Equatable {
        case unknown
        /// Try isn't available; the message says what to change in Settings (`TryAvailability.message`).
        case needsSettings(String)
        /// The last check of the connection found the key rejected.
        case keyRejected
    }

    /// Waiting with no known cause: unreachable, or the lookup service or the requests file failed. Never "your
    /// server", which reads as the music server (it is playing).
    static let cantBringHome = "Can't bring songs home right now. We'll try again."
    /// H4: the first such wait. It is usually a moment's hiccup (most often the release lookup, which answers "busy"
    /// now and then), and the automatic retry follows within a minute; only a wait that repeats is worth saying more.
    static let stillTrying = "Still looking…"
    static let keyRejected = "The key Magpie uses to bring songs home stopped working. Paste a new one in Settings."

    /// The status line for a request (its state, or the not-listed note).
    static func status(_ request: MagpieRequest, context: WaitContext = .unknown) -> String {
        if request.isNotListed { return notListed }
        if request.isFind, request.state == .ready {
            if request.notForMeNeedsAttention { return notForMeNeedsAttention }
            if request.notForMe != nil { return lettingGo }
            if request.keepNeedsAttention { return keepNeedsAttention }
            return request.keep != nil ? keeping : request.keepFailed ? keepFailed : readyInFinds
        }
        if request.state == .kept { return kept(request) }
        return status(request.state, context: context)
    }

    /// A find lands in Finds, not in the library (Task 6.2a).
    static let readyInFinds = "Ready · in your Finds"
    /// Task 6.2b: a Keep is moving it.
    static let keeping = "Moving it into your library"
    static let keepFailed = "Ready · in your Finds · couldn't keep it yet"
    static let keepNeedsAttention = "Couldn't finish keeping it · needs a look"
    static let keptInFinds = "Kept · in your Finds folder for now"
    /// Task 6.2c: Not for me is deleting it.
    static let lettingGo = "Letting it go"
    static let notForMeNeedsAttention = "Couldn't finish letting it go · needs a look"
    static let keptLosslessSoon = "Kept · lossless soon"
    static let keptLossless = "Kept · lossless"

    /// Kept: "Lossless soon" until the library song is lossless (Keep moved it to the lossless profile).
    static func kept(_ request: MagpieRequest) -> String {
        if request.keptInPlace { return keptInFinds }
        guard request.relinkPending != nil else { return status(.kept) }   // kept before Task 6.2b
        let quality = Quality.from(suffix: request.songSuffix, bitRate: nil)
        return quality == .lossless || quality == .hiRes ? keptLossless : keptLosslessSoon
    }

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

    /// One status line. `context` only speaks for `.serviceUnavailable` waits.
    static func status(_ state: RequestState, context: WaitContext = .unknown) -> String {
        switch state {
        case .pending, .resolving, .adding: "Looking…"   // R20
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
            case .serviceUnavailable:
                switch context {
                case .unknown: reason.attempt == 0 ? stillTrying : cantBringHome
                case .needsSettings(let message): message
                case .keyRejected: keyRejected
                }
            case .downloadFailed: "That copy didn't work. Looking for another."
            }
        case .failed(let reason):
            switch reason {
            case .notFoundYet: "Couldn't find it"
            case .noRelease: "Couldn't find a release with this song"
            case .notInCatalogue: "Not in this artist's catalogue on your server"
            case .addFailed: "Your server said no to this one"
            case .stoppedInLidarr: "Stopped on your server"
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
    static func symbol(_ request: MagpieRequest) -> String {
        request.isNotListed ? "exclamationmark.circle" : symbol(request.state)
    }

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

    /// A not-yet song already asked for shows how it's coming along instead of "Not in your library"
    /// (Search, Made for you).
    static func rowState(for recording: ExternalRecording, in requests: [MagpieRequest]) -> RowState {
        guard let request = requests.last(where: { r in
            group(r) != nil && (r.recording.recordingMBID.map { $0 == recording.recordingMBID } ?? false)
        }) else { return .notYet }
        switch request.state {
        case .downloading(let p) where p > 0: return .onItsWay(progress: p, phrase: percent(p))
        case .waiting, .failed: return .notFound
        case .ready where request.isFind: return .newFind   // final fix 2 B-M5: here, in your Finds
        case .ready, .kept: return .library
        default: return .onItsWay(progress: nil, phrase: "")
        }
    }
}
