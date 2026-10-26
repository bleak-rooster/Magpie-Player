import Foundation
import MagpieCore
import LidarrKit

/// What the resolver decided to bring in (produced by the release picker, consumed by Task 5.3's runner).
public struct Plan: Sendable, Equatable, Codable {
    public var recordingMBID: MBID
    public var releaseGroupMBID: MBID
    public var artistMBID: MBID
    /// The artist's id in Lidarr when it already exists there (A7: monitor, do not add); nil when it must be added.
    public var lidarrArtistId: Int?
    public var mode: LedgerMode

    public var artistExistsInLidarr: Bool { lidarrArtistId != nil }

    public init(recordingMBID: MBID, releaseGroupMBID: MBID, artistMBID: MBID,
                lidarrArtistId: Int?, mode: LedgerMode) {
        self.recordingMBID = recordingMBID
        self.releaseGroupMBID = releaseGroupMBID
        self.artistMBID = artistMBID
        self.lidarrArtistId = lidarrArtistId
        self.mode = mode
    }
}

public enum WaitKind: String, Sendable, Codable, CaseIterable {
    /// Search finished and nothing was grabbed yet (A14 "still looking").
    case stillLooking
    /// Lidarr (or metadata) could not be reached.
    case serviceUnavailable
    /// `downloadFailed` / `albumImportIncomplete`: Lidarr retries on its own (A14).
    case downloadFailed
}

/// Why a request is waiting, plus the retry bookkeeping the pure machine needs to survive the
/// waiting -> resolving -> waiting loop. `attempt` is 0 for the first wait; `since` is when the request first waited.
public struct WaitReason: Sendable, Equatable, Codable {
    public var kind: WaitKind
    public var attempt: Int
    public var since: Date

    public init(_ kind: WaitKind, attempt: Int = 0, since: Date) {
        self.kind = kind
        self.attempt = attempt
        self.since = since
    }
}

public enum FailReason: String, Sendable, Codable, CaseIterable {
    /// Gave up after 24 h of waiting.
    case notFoundYet
    /// No usable release was found for the song.
    case noRelease
    /// The artist is in Lidarr but none of its releases there contains the song (A7). Profiles are never
    /// changed to make it fit.
    case notInCatalogue
    /// Lidarr refused the add / monitor.
    case addFailed
    case unknown
}

public enum RequestState: Codable, Equatable, Sendable {
    case pending, resolving, adding, searching
    case downloading(progress: Double)
    case importing, ready, kept, dismissed, cancelled
    case waiting(reason: WaitReason, retryAt: Date)
    case failed(reason: FailReason)

    public var isTerminal: Bool {
        switch self {
        case .kept, .dismissed, .cancelled, .failed: true
        default: false
        }
    }
}

public enum RequestEvent: Sendable, Equatable {
    case start
    case resolved(Plan)
    case added
    case searchStarted
    case queueProgress(Double)
    case imported
    case visibleInLibrary(songId: String)
    case noGrabAfter(TimeInterval)
    case lidarrUnavailable
    case downloadFailed
    case cancel, keep, notForMe, retryDue
    case error(FailReason)
}

public enum Effect: Sendable, Equatable {
    case resolveRelease
    case addOrMonitor(Plan)
    case startSearch
    case poll
    case scan
    case notifyReady
    case scheduleRetry(Date)
    case cleanup
}

/// Pure and deterministic: no I/O, no clock. Invalid events leave the state unchanged with no effects.
public struct RequestMachine {
    /// Waits before retry n (0-based); the last value repeats.
    public static let backoff: [TimeInterval] = [60, 300, 900, 3600]
    public static let giveUpAfter: TimeInterval = 24 * 3600
    public static let noGrabThreshold: TimeInterval = 600

    /// - Parameter prior: the request's most recent `WaitReason` within the current waiting episode, or nil.
    ///   Runner contract: persist the `WaitReason` of every `waiting` state and pass it back here; reset it to nil
    ///   on forward progress (entering `downloading`, `importing` or `ready`). Backoff attempts count per
    ///   `WaitKind` (a kind change restarts at 0); `since` (the 24 h limit) carries over within an episode.
    ///   Forgetting to pass it retries every 60 s forever; never resetting it fails a later unrelated wait early.
    public static func step(_ s: RequestState, _ e: RequestEvent, now: Date,
                            prior: WaitReason?) -> (RequestState, [Effect]) {
        let unchanged = (s, [Effect]())
        if s.isTerminal { return unchanged }

        switch (s, e) {
        case (.pending, .start):
            return (.resolving, [.resolveRelease])

        case let (.resolving, .resolved(plan)):
            return (.adding, [.addOrMonitor(plan)])
        case (.adding, .added):
            return (.searching, [.startSearch])
        case (.searching, .searchStarted):
            return (.searching, [.poll])

        case let (.searching, .queueProgress(p)), let (.downloading, .queueProgress(p)),
             let (.waiting, .queueProgress(p)):
            return (.downloading(progress: clamp(p)), [.poll])
        case (.adding, .imported), (.searching, .imported), (.downloading, .imported), (.waiting, .imported):
            return (.importing, [.scan])
        case let (.searching, .noGrabAfter(t)):
            guard t >= noGrabThreshold else { return unchanged }
            return wait(.stillLooking, now: now, prior: prior)
        // Library visibility is ground truth: it completes the request from any pre-ready state.
        case (.pending, .visibleInLibrary), (.resolving, .visibleInLibrary), (.adding, .visibleInLibrary),
             (.searching, .visibleInLibrary), (.downloading, .visibleInLibrary), (.importing, .visibleInLibrary),
             (.waiting, .visibleInLibrary):
            return (.ready, [.notifyReady])

        case (.resolving, .lidarrUnavailable), (.adding, .lidarrUnavailable), (.searching, .lidarrUnavailable),
             (.downloading, .lidarrUnavailable), (.importing, .lidarrUnavailable):
            return wait(.serviceUnavailable, now: now, prior: prior)
        case (.searching, .downloadFailed), (.downloading, .downloadFailed), (.importing, .downloadFailed):
            return wait(.downloadFailed, now: now, prior: prior)

        case let (.resolving, .error(r)), let (.adding, .error(r)), let (.searching, .error(r)),
             let (.downloading, .error(r)), let (.importing, .error(r)):
            return (.failed(reason: r), [.cleanup])

        case let (.waiting(reason, retryAt), .retryDue):
            guard now >= retryAt else { return unchanged }  // stale or duplicate timer
            if now.timeIntervalSince(reason.since) >= giveUpAfter {
                return (.failed(reason: .notFoundYet), [.cleanup])
            }
            return (.resolving, [.resolveRelease])

        case (.ready, .keep):
            return (.kept, [])
        case (.ready, .notForMe):
            return (.dismissed, [.cleanup])

        case (.pending, .cancel), (.resolving, .cancel), (.adding, .cancel), (.searching, .cancel),
             (.downloading, .cancel), (.importing, .cancel), (.waiting, .cancel):
            return (.cancelled, [.cleanup])

        default:
            return unchanged
        }
    }

    private static func wait(_ kind: WaitKind, now: Date, prior: WaitReason?) -> (RequestState, [Effect]) {
        let since = prior?.since ?? now
        if now.timeIntervalSince(since) >= giveUpAfter {
            return (.failed(reason: .notFoundYet), [.cleanup])
        }
        let attempt = (prior.flatMap { $0.kind == kind ? $0.attempt + 1 : nil }) ?? 0
        let retryAt = now.addingTimeInterval(backoff[min(attempt, backoff.count - 1)])
        return (.waiting(reason: WaitReason(kind, attempt: attempt, since: since), retryAt: retryAt),
                [.scheduleRetry(retryAt)])
    }

    private static func clamp(_ p: Double) -> Double {
        p.isNaN ? 0 : min(max(p, 0), 1)
    }
}
