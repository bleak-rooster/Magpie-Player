import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 23 R23F (owner, 2026-11-07): "an option to let me re-search Aurral playlist/flow songs that haven't
/// downloaded or are stalled … per playlist/flow" (D199, D200). The pure rules: which songs are asked for again, how
/// many per tap, and what the jobs say once they have been.

private func job(_ id: String, _ status: String?, upgrade: String? = nil) -> AurralJob {
    var j = AurralJob(id: id, flowId: "flow-1", artistName: "Low", trackName: "Song \(id)", status: status)
    j.upgradeForJobId = upgrade
    return j
}

@Suite struct SearchAgainRulesTests {
    /// D199: "missing" is what Aurral 2.13 itself offers to search for again (`getTrackSearchAction`: failed, and
    /// saved, a song never downloaded) and its research route accepts. A song pending or downloading is never asked
    /// for (Aurral answers 409 "already being processed"); done, blocked (held for review), cancelled and a quality
    /// upgrade's job aren't either. Each job once, in Aurral's order.
    @Test func missingIsFailedOrNeverDownloaded() {
        let jobs = [job("1", "done"), job("2", "failed"), job("3", "saved"), job("4", "pending"), job("5", "downloading"),
                    job("6", "blocked"), job("7", "cancelled"), job("8", "failed", upgrade: "1"), job("9", nil),
                    job("2", "failed"), job("10", "FAILED"), job("11", "cancel_requested")]
        #expect(SearchAgain.missing(jobs).map(\.id) == ["2", "3", "10"])
    }

    /// D200: at most `perTap` (25) songs are sent per tap, the first ones in Aurral's order; the rest wait for the next.
    @Test func capPerTap() {
        let jobs = (0..<60).map { job("j\($0)", "failed") }
        #expect(SearchAgain.perTap == 25)
        #expect(SearchAgain.batch(jobs).map(\.id) == (0..<25).map { "j\($0)" })
        #expect(SearchAgain.batch(Array(jobs.prefix(3))).count == 3)
        #expect(SearchAgain.batch([job("a", "done"), job("b", "pending")]).isEmpty)
    }

    /// D200: while any song sent is pending or downloading Aurral is still looking (no outcome yet); then found is
    /// each one done, still missing every other (failed again, gone from the list, blocked, cancelled).
    @Test func outcomeOnceTheJobsSettle() {
        let sent = ["1", "2", "3", "4"]
        #expect(SearchAgain.outcome(sent: sent, jobs: [job("1", "done"), job("2", "pending"), job("3", "failed"),
                                                       job("4", "done")]) == nil)
        #expect(SearchAgain.outcome(sent: sent, jobs: [job("1", "done"), job("2", "downloading")]) == nil)
        let settled = SearchAgain.outcome(sent: sent, jobs: [job("1", "done"), job("2", "done"), job("3", "failed"),
                                                             job("4", "done")])
        #expect(settled == SearchAgain.Outcome(found: 3, stillMissing: 1))
        #expect(SearchAgain.outcome(sent: sent, jobs: [job("1", "done")]) == SearchAgain.Outcome(found: 1, stillMissing: 3),
                "a song gone from the list is still missing")
        #expect(SearchAgain.outcome(sent: [], jobs: []) == SearchAgain.Outcome(found: 0, stillMissing: 0))
    }
}
