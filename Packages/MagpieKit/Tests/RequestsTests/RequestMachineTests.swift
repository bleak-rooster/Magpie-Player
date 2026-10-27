import Testing
import Foundation
import MagpieCore
import LidarrKit
@testable import Requests

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let mbid = MBID("11111111-1111-1111-1111-111111111111")!
private let plan = Plan(recordingMBID: mbid, releaseGroupMBID: mbid, artistMBID: mbid, lidarrArtistId: 7, mode: .finds)
private let wr = WaitReason(.stillLooking, attempt: 0, since: t0)

private enum S: String, CaseIterable {
    case pending, resolving, adding, searching, downloading, importing, ready, kept, dismissed, cancelled, waiting, failed
    var value: RequestState {
        switch self {
        case .pending: .pending
        case .resolving: .resolving
        case .adding: .adding
        case .searching: .searching
        case .downloading: .downloading(progress: 0.4)
        case .importing: .importing
        case .ready: .ready
        case .kept: .kept
        case .dismissed: .dismissed
        case .cancelled: .cancelled
        case .waiting: .waiting(reason: wr, retryAt: t0)
        case .failed: .failed(reason: .unknown)
        }
    }
}

private enum E: String, CaseIterable {
    case start, resolved, added, searchStarted, queueProgress, imported, visibleInLibrary, noGrabAfter
    case lidarrUnavailable, downloadFailed, cancel, keep, notForMe, retryDue, error
    var value: RequestEvent {
        switch self {
        case .start: .start
        case .resolved: .resolved(plan)
        case .added: .added
        case .searchStarted: .searchStarted
        case .queueProgress: .queueProgress(0.5)
        case .imported: .imported
        case .visibleInLibrary: .visibleInLibrary(songId: "s1")
        case .noGrabAfter: .noGrabAfter(600)
        case .lidarrUnavailable: .lidarrUnavailable
        case .downloadFailed: .downloadFailed
        case .cancel: .cancel
        case .keep: .keep
        case .notForMe: .notForMe
        case .retryDue: .retryDue
        case .error: .error(.addFailed)
        }
    }
}

// Compile-time guards: adding a case to either enum breaks these until S / E are extended.
private func _guardState(_ s: RequestState) -> S {
    switch s {
    case .pending: .pending
    case .resolving: .resolving
    case .adding: .adding
    case .searching: .searching
    case .downloading: .downloading
    case .importing: .importing
    case .ready: .ready
    case .kept: .kept
    case .dismissed: .dismissed
    case .cancelled: .cancelled
    case .waiting: .waiting
    case .failed: .failed
    }
}
private func _guardEvent(_ e: RequestEvent) -> E {
    switch e {
    case .start: .start
    case .resolved: .resolved
    case .added: .added
    case .searchStarted: .searchStarted
    case .queueProgress: .queueProgress
    case .imported: .imported
    case .visibleInLibrary: .visibleInLibrary
    case .noGrabAfter: .noGrabAfter
    case .lidarrUnavailable: .lidarrUnavailable
    case .downloadFailed: .downloadFailed
    case .cancel: .cancel
    case .keep: .keep
    case .notForMe: .notForMe
    case .retryDue: .retryDue
    case .error: .error
    }
}

private struct Key: Hashable { let s: S; let e: E }

private func retry(_ kind: WaitKind, after: TimeInterval) -> (RequestState, [Effect]) {
    let at = t0.addingTimeInterval(after)
    return (.waiting(reason: WaitReason(kind, attempt: 0, since: t0), retryAt: at), [.scheduleRetry(at)])
}

/// Every valid transition. Anything not listed must leave state unchanged with no effects.
private let valid: [Key: (RequestState, [Effect])] = {
    var m: [Key: (RequestState, [Effect])] = [
        Key(s: .pending, e: .start): (.resolving, [.resolveRelease]),
        Key(s: .resolving, e: .resolved): (.adding, [.addOrMonitor(plan)]),
        Key(s: .adding, e: .added): (.searching, [.startSearch]),
        Key(s: .searching, e: .searchStarted): (.searching, [.poll]),
        Key(s: .searching, e: .queueProgress): (.downloading(progress: 0.5), [.poll]),
        Key(s: .downloading, e: .queueProgress): (.downloading(progress: 0.5), [.poll]),
        Key(s: .searching, e: .imported): (.importing, [.scan]),
        Key(s: .downloading, e: .imported): (.importing, [.scan]),
        Key(s: .waiting, e: .imported): (.importing, [.scan]),
        Key(s: .adding, e: .imported): (.importing, [.scan]),
        Key(s: .waiting, e: .queueProgress): (.downloading(progress: 0.5), [.poll]),
        Key(s: .searching, e: .noGrabAfter): retry(.stillLooking, after: 60),
        Key(s: .searching, e: .downloadFailed): retry(.downloadFailed, after: 60),
        Key(s: .downloading, e: .downloadFailed): retry(.downloadFailed, after: 60),
        Key(s: .importing, e: .downloadFailed): retry(.downloadFailed, after: 60),
        Key(s: .ready, e: .keep): (.kept, []),
        Key(s: .ready, e: .notForMe): (.dismissed, [.cleanup]),
        Key(s: .waiting, e: .retryDue): (.resolving, [.resolveRelease]),
    ]
    for s in [S.resolving, .adding, .searching, .downloading, .importing] {
        m[Key(s: s, e: .lidarrUnavailable)] = retry(.serviceUnavailable, after: 60)
        m[Key(s: s, e: .error)] = (.failed(reason: .addFailed), [.cleanup])
    }
    for s in [S.pending, .resolving, .adding, .searching, .downloading, .importing, .waiting] {
        m[Key(s: s, e: .visibleInLibrary)] = (.ready, [.notifyReady])
        m[Key(s: s, e: .cancel)] = (.cancelled, [.cleanup])
    }
    return m
}()

@Suite struct RequestMachineTests {
    @Test func table() {
        var checked = 0
        for s in S.allCases {
            #expect(_guardState(s.value) == s)
            for e in E.allCases {
                #expect(_guardEvent(e.value) == e)
                let got = RequestMachine.step(s.value, e.value, now: t0, prior: nil)
                let want = valid[Key(s: s, e: e)] ?? (s.value, [])
                #expect(got.0 == want.0 && got.1 == want.1, "\(s) x \(e): got \(got), want \(want)")
                checked += 1
            }
        }
        #expect(checked == S.allCases.count * E.allCases.count)
    }

    @Test func terminalStatesIgnoreEverything() {
        for s in [S.kept, .dismissed, .cancelled, .failed] {
            for e in E.allCases {
                let got = RequestMachine.step(s.value, e.value, now: t0, prior: nil)
                #expect(got.0 == s.value && got.1.isEmpty)
            }
        }
    }

    @Test func noGrabBelowThresholdIsIgnored() {
        let got = RequestMachine.step(.searching, .noGrabAfter(599), now: t0, prior: nil)
        #expect(got.0 == .searching && got.1.isEmpty)
        let late = RequestMachine.step(.searching, .noGrabAfter(900), now: t0, prior: nil)
        if case .waiting(let r, _) = late.0 { #expect(r.kind == .stillLooking) } else { Issue.record("expected waiting") }
    }

    @Test func lidarrSelfRetryWhileWaiting() {
        let w = S.waiting.value
        #expect(RequestMachine.step(w, .imported, now: t0, prior: wr).0 == .importing)
        #expect(RequestMachine.step(w, .visibleInLibrary(songId: "s"), now: t0, prior: wr) == (.ready, [.notifyReady]))
        #expect(RequestMachine.step(.searching, .visibleInLibrary(songId: "s"), now: t0, prior: nil) == (.ready, [.notifyReady]))
    }

    @Test func importCompletingDuringServiceWait() {
        let (w, _) = RequestMachine.step(.downloading(progress: 0.3), .lidarrUnavailable, now: t0, prior: nil)
        #expect(RequestMachine.step(w, .imported, now: t0, prior: nil).0 == .importing)
        #expect(RequestMachine.step(w, .visibleInLibrary(songId: "s"), now: t0, prior: nil).0 == .ready)
    }

    @Test func staleRetryDueIsIgnored() {
        let w = RequestState.waiting(reason: wr, retryAt: t0.addingTimeInterval(60))
        let early = RequestMachine.step(w, .retryDue, now: t0.addingTimeInterval(59), prior: nil)
        #expect(early.0 == w && early.1.isEmpty)
        #expect(RequestMachine.step(w, .retryDue, now: t0.addingTimeInterval(60), prior: nil).0 == .resolving)
    }

    @Test func laterUnrelatedWaitAfterResetGetsNormalBackoff() {
        let much = t0.addingTimeInterval(3 * 86_400)
        let (s, _) = RequestMachine.step(.searching, .lidarrUnavailable, now: much, prior: nil)
        guard case .waiting(let r, let at) = s else { Issue.record("expected waiting"); return }
        #expect(r.attempt == 0 && r.since == much && at == much.addingTimeInterval(60))
    }

    @Test func kindChangeRestartsAttempt() {
        let prior = WaitReason(.stillLooking, attempt: 3, since: t0)
        let (s, _) = RequestMachine.step(.searching, .lidarrUnavailable, now: t0.addingTimeInterval(100), prior: prior)
        guard case .waiting(let r, let at) = s else { Issue.record("expected waiting"); return }
        #expect(r.kind == .serviceUnavailable && r.attempt == 0 && r.since == t0)
        #expect(at == t0.addingTimeInterval(160))
    }

    @Test func progressIsClamped() {
        #expect(RequestMachine.step(.searching, .queueProgress(1.7), now: t0, prior: nil).0 == .downloading(progress: 1))
        #expect(RequestMachine.step(.searching, .queueProgress(-1), now: t0, prior: nil).0 == .downloading(progress: 0))
        #expect(RequestMachine.step(.searching, .queueProgress(.nan), now: t0, prior: nil).0 == .downloading(progress: 0))
    }

    @Test func backoffSchedule() {
        var prior: WaitReason?
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            let (state, effects) = RequestMachine.step(.searching, .lidarrUnavailable, now: now, prior: prior)
            guard case .waiting(let reason, let retryAt) = state else { Issue.record("expected waiting"); return }
            #expect(effects == [.scheduleRetry(retryAt)])
            delays.append(retryAt.timeIntervalSince(now))
            prior = reason
            now = retryAt
        }
        #expect(delays == [60, 300, 900, 3600, 3600, 3600])
        #expect(prior?.since == t0)
    }

    @Test func failsAfter24h() {
        let waiting = RequestState.waiting(reason: WaitReason(.stillLooking, attempt: 5, since: t0),
                                           retryAt: t0.addingTimeInterval(60))
        let early = RequestMachine.step(waiting, .retryDue, now: t0.addingTimeInterval(86_399), prior: nil)
        #expect(early.0 == .resolving)
        let late = RequestMachine.step(waiting, .retryDue, now: t0.addingTimeInterval(86_400), prior: nil)
        #expect(late.0 == .failed(reason: .notFoundYet) && late.1 == [.cleanup])
        // Re-entering waiting after the limit fails straight away.
        let prior = WaitReason(.stillLooking, attempt: 6, since: t0)
        let again = RequestMachine.step(.searching, .downloadFailed, now: t0.addingTimeInterval(90_000), prior: prior)
        #expect(again.0 == .failed(reason: .notFoundYet))
    }

    @Test func stateRoundTripsThroughCodable() throws {
        let s = RequestState.waiting(reason: wr, retryAt: t0)
        let back = try JSONDecoder().decode(RequestState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let p = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan))
        #expect(p == plan)
    }
}
