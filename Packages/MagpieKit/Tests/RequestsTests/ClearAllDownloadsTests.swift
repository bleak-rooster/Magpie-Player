import Foundation
import os
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 27 R (owner, 2026-11-14): "a switch here also to make it stop and delete all current/pending/stalled downloads
/// by blocklisting them and retriggering the downloads after they have all been removed" (D292), with the owner's Q2
/// answer: another app's downloads are cleared too. Clear all reads the whole queue fresh, takes every download that
/// isn't importing or done (one per download, at most 100), removes each through the restarter's own path (re-checked on
/// a fresh read; a live Magpie request's through its counted removal) and, only once every removal has been tried,
/// sends each removed download's search: the runner's own for a request, `restartSearch` for the albums Lidarr names.
@Suite struct ClearAllDownloadsTests {
    static let deleteQuery = "removeFromClient=true&blocklist=true&skipRedownload=true"

    private func queued(_ id: Int, album: Int? = nil, status: String = "downloading", tracked: String = "downloading",
                        sizeleft: Double = 50, download: String? = nil, client: String = "SABnzbd",
                        messages: [String] = []) -> FakeLidarr.Queued {
        FakeLidarr.Queued(albumId: album ?? (41 + id - 901), size: 100, sizeleft: sizeleft, status: status,
                          tracked: tracked, messages: messages, id: id, artistId: 9, client: client, downloadId: download)
    }

    private func writes(_ h: Harness) -> [String] {
        h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
    }

    private func searches(_ h: Harness) -> [[Int]] {
        h.server.writeBodies().filter { $0.0 == "POST command" && $0.1["name"] as? String == "AlbumSearch" }
            .compactMap { $0.1["albumIds"] as? [Int] }
    }

    private func restarter(_ h: Harness, now: (@Sendable () -> Date)? = nil) -> LidarrDownloadRestarter {
        if let now { return LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner, now: now) }
        return LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
    }

    /// Every download Lidarr started that isn't importing or done: downloading, waiting, paused, held back, the client
    /// unreachable, stalled, failed, couldn't import.
    @Test func clearAll_removesEveryLidarrStartedRow() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [
                queued(901),
                queued(902, status: "queued"),
                queued(903, status: "paused"),
                queued(904, status: "delay"),
                queued(905, status: "downloadClientUnavailable"),
                queued(906, status: "warning", client: "Slskd"),
                queued(907, status: "failed", tracked: "downloadFailed"),
            ]
        }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        #expect(plan.targets.map(\.queueId) == Array(901...907))
        #expect(plan.foreign == 0 && plan.more == 0)
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.cleared == 7)
        #expect(outcome.searchedAlbums == 7)
        #expect(outcome.notCleared == 0 && outcome.left == 0 && outcome.clearedWithoutSearch == 0)
        #expect(h.server.with { $0.removedFromQueue } == Array(901...907))
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.allSatisfy { $0.url?.query == Self.deleteQuery })
    }

    @Test func clearAll_skipsImportingAndDone() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [
                queued(901),
                queued(902, status: "completed", tracked: "importing", sizeleft: 0),
                queued(903, status: "completed", tracked: "imported", sizeleft: 0),
                queued(904, status: "completed", tracked: "importPending", sizeleft: 0),
                queued(905, download: "shared"),
                queued(906, status: "completed", tracked: "importing", sizeleft: 0, download: "shared"),
            ]
        }
        let plan = try await restarter(h).clearAllPlan()
        #expect(plan.targets.map(\.queueId) == [901], "nothing importing or done, nor anything sharing its download")
        _ = await restarter(h).clearAll(plan, includeForeign: true)
        #expect(h.server.with { $0.removedFromQueue } == [901])
    }

    /// Per Q2 another app's downloads are cleared too, counted in the confirmation, and only with the confirmation's
    /// flag; one Lidarr names no album for is removed without a new search, and the outcome says so.
    @Test func clearAll_skipsAnotherAppsUnlessOwnerSaidSo() async throws {
        let h = await Harness()
        h.server.with { s in
            var noAlbum = queued(903, status: "failed", client: "Slskd")
            noAlbum.noAlbum = true
            s.queue = [queued(901), queued(902, status: "failed", client: "Slskd",
                                            messages: ["Download wasn't grabbed by Lidarr, skipping"]), noAlbum]
            s.ungrabbed = ["dl-902", "dl-903"]
        }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        #expect(plan.targets.map(\.queueId) == [901, 902, 903])
        #expect(plan.foreign == 2)
        let without = await r.clearAll(plan, includeForeign: false)
        #expect(without.cleared == 1 && without.notCleared == 2)
        #expect(h.server.with { $0.removedFromQueue } == [901])
        let again = try await r.clearAllPlan()
        let with = await r.clearAll(again, includeForeign: true)
        #expect(with.cleared == 2)
        #expect(with.searchedAlbums == 1, "the one Lidarr ties to an album")
        #expect(with.clearedWithoutSearch == 1, "another app's with no album: cleared without a new search")
        #expect(h.server.with { $0.removedFromQueue } == [901, 902, 903])
        #expect(searches(h).last == [42])
    }

    @Test func clearAll_noSearchUntilAllTried() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...903).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let r = restarter(h)
        _ = await r.clearAll(try await r.clearAllPlan(), includeForeign: true)
        #expect(writes(h) == ["DELETE queue/901", "DELETE queue/902", "DELETE queue/903",
                              "POST command", "POST command", "POST command"])
        #expect(searches(h) == [[41], [42], [43]], "in removal order")
    }

    /// One download carrying two albums: one removal, one search for both.
    @Test func clearAll_searchesEachRemovedDownloadsAlbums() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [queued(901, album: 41, download: "multi"), queued(902, album: 42, download: "multi"), queued(903, album: 43)]
        }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        #expect(plan.targets.map(\.queueId) == [901, 903], "one per download")
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.cleared == 2 && outcome.searchedAlbums == 3)
        #expect(writes(h).filter { $0.hasPrefix("DELETE") } == ["DELETE queue/901", "DELETE queue/903"])
        #expect(searches(h) == [[41, 42], [43]])
    }

    /// Every search lands inside the gate's ten minutes after its removal: removals stop once five minutes have gone
    /// since the first (fix round 1 M1), and the rest wait for the next tap.
    @Test func clearAll_searchesInsideTenMinutes() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...910).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let gate = LidarrWriteGate(client: h.lidarrClient, logURL: h.dir.appending(path: "clock-log.json"),
                                   defaultsSuite: h.suite, now: { clock.withLock { $0 } },
                                   confinement: WriteConfinement(ledger: h.ledger, roots: {
                                       WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
                                   }))
        await gate.setEnabled(true)
        // The run reads the clock once a download; each takes 100 s.
        let r = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: gate, runner: nil, now: {
            clock.withLock { $0 = $0.addingTimeInterval(100); return $0 }
        })
        let outcome = await r.clearAll(try await r.clearAllPlan(), includeForeign: true)
        #expect(outcome.cleared == 3, "the fourth would start five minutes after the first")
        #expect(outcome.left == 7)
        #expect(outcome.searchedAlbums == 3 && outcome.clearedWithoutSearch == 0, "every search inside the gate's window")
        #expect(outcome.searchesTurnedDown == 0)
        #expect(searches(h) == [[41], [42], [43]])
    }

    @Test func clearAll_atMostHundred() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...1005).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        #expect(plan.targets.count == LidarrDownloadRestarter.maxClear)
        #expect(LidarrDownloadRestarter.maxClear == 100)
        #expect(plan.count == 100 && plan.more == 5)
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.cleared == 100 && outcome.left == 5)
        #expect(h.server.with { $0.removedFromQueue } == Array(901...1000))
        #expect(LidarrDownloadRestarter.maxPerTap == 25, "Restart all keeps its 25 (D49)")
    }

    @Test func clearAll_stopsAfterTwoUnreachable() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...905).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        h.server.with { $0.down = true }
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.stoppedUnreachable)
        #expect(outcome.notCleared == 2 && outcome.left == 3 && outcome.cleared == 0)
        #expect(h.server.writes.isEmpty)
    }

    /// A live Magpie request's download goes through its counted removal (one of its five), and its own search follows
    /// only after every removal; the owner's download gets the restart's search.
    @Test func clearAll_liveRequestGoesThroughRemoveCounting() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .searching)
        let before = h.server.writes.count
        h.server.with { $0.queue = [
            FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed", id: 901,
                              artistId: 7, client: "SABnzbd"),
            FakeLidarr.Queued(albumId: 35, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed", id: 902,
                              artistId: 9, client: "SABnzbd"),
        ] }
        let r = restarter(h)
        let outcome = await r.clearAll(try await r.clearAllPlan(), includeForeign: true)
        await h.runner.settle()
        #expect(outcome.cleared == 2 && outcome.searchedAlbums == 2)
        #expect(Array(writes(h).dropFirst(before)) == ["DELETE queue/901", "DELETE queue/902", "POST command", "POST command"])
        #expect(searches(h).suffix(2) == [[35], [31]], "the windowed restart search first, the request's own last (M1)")
        let r1 = try #require(await h.request(id))
        #expect(r1.stallRetries == 1, "counted toward the request's five")
        #expect(r1.state == .searching)
    }

    /// Re-checked on a fresh read: one that started importing is left as it was; one already gone isn't counted.
    @Test func clearAll_rowThatMovedIsSkipped() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...903).map { queued($0) } }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        h.server.with { s in
            s.queue.removeAll { $0.id == 901 }
            if let i = s.queue.firstIndex(where: { $0.id == 902 }) {
                s.queue[i].status = "completed"; s.queue[i].tracked = "importing"; s.queue[i].sizeleft = 0
            }
        }
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.cleared == 1 && outcome.notCleared == 1)
        #expect(h.server.with { $0.removedFromQueue } == [903])
        #expect(searches(h) == [[43]])
    }

    /// Changes switched off: nothing is sent, and the outcome says so.
    @Test func clearAll_changesOffSendsNothing() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = [queued(901)] }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        await h.gate.setEnabled(false)
        let outcome = await r.clearAll(plan, includeForeign: true)
        #expect(outcome.changesOff && outcome.cleared == 0)
        #expect(h.server.writes.isEmpty)
    }

    // MARK: - Fix round 1

    /// M1: slow removals (every Lidarr request takes 30 s, a removal about two and a half minutes) and a live request: removals stop five minutes after the
    /// first; the windowed restart searches go first and none is ever started once its removal is 570 s old, so the gate
    /// never turns one down; the request's own search goes last; only searches actually sent are counted (task M2).
    @Test func clearAll_slowRemovalsAndRunnerSearchesStayInsideWindow() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 2_000_000))
        let h = await Harness(gateNow: { clock.withLock { $0 } })
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .searching)
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed",
                                         id: 901, artistId: 7, client: "SABnzbd")]
                + (902...909).map { queued($0, status: "failed", tracked: "downloadFailed") }
        }
        let r = restarter(h, now: { clock.withLock { $0 } })
        let plan = try await r.clearAllPlan()
        let before = h.server.writes.count
        h.server.with { $0.onEveryLidarrRequest = { _ in clock.withLock { $0 = $0.addingTimeInterval(30) } } }
        let outcome = await r.clearAll(plan, includeForeign: true)
        h.server.with { $0.onEveryLidarrRequest = nil }
        await h.runner.settle()
        #expect(outcome.searchesTurnedDown == 0, "the gate never refused a search")
        #expect(outcome.cleared >= 2 && outcome.left > 0, "removals stopped inside five minutes")
        let sent = Array(h.server.writeBodies().dropFirst(before)).filter { $0.0 == "POST command" }.compactMap { $0.1["albumIds"] as? [Int] }
        #expect(outcome.searchedAlbums == sent.reduce(0) { $0 + $1.count }, "only searches actually sent are counted")
        #expect(outcome.searchedAlbums + outcome.clearedWithoutSearch >= outcome.cleared)
        #expect(sent.count >= 2 && sent.last == [31], "a restart search first, the request's own last")
        #expect(await h.request(id)?.stallRetries == 1)
    }

    /// Security M2: a finished copy that couldn't be added is the owner's to check: never in Clear all, and the
    /// confirmation says how many were left.
    @Test func clearAll_couldntImportIsLeftAlone() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [queued(901),
                       queued(902, status: "completed", tracked: "importBlocked", sizeleft: 0, messages: ["Artist name mismatch"]),
                       queued(903, status: "completed", tracked: "importFailed", sizeleft: 0, messages: ["Has missing tracks"])]
        }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        #expect(plan.targets.map(\.queueId) == [901])
        #expect(plan.couldntImport == 2)
        _ = await r.clearAll(plan, includeForeign: true)
        #expect(h.server.with { $0.removedFromQueue } == [901])
    }

    /// L3: never more than 100, whatever plan it is handed.
    @Test func clearAll_neverMoreThanHundredEvenIfPlanSays() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...1005).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let targets = (901...1005).map { ClearAllPlan.Target(queueId: $0, downloadId: "dl-\($0)", foreign: false) }
        let outcome = await restarter(h).clearAll(ClearAllPlan(targets: targets, more: 0), includeForeign: true)
        #expect(outcome.cleared == 100 && outcome.left == 5)
        #expect(h.server.with { $0.removedFromQueue }.count == 100)
    }

    /// L5: Lidarr took a removal but didn't answer: said apart ("may have been cleared"), not as left alone.
    @Test func clearAll_lostAnswerIsSaidApart() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = (901...903).map { queued($0, status: "failed", tracked: "downloadFailed") }
            s.queueDeleteAnswersLost = 1
        }
        let r = restarter(h)
        let outcome = await r.clearAll(try await r.clearAllPlan(), includeForeign: true)
        #expect(outcome.maybeCleared == 1)
        #expect(outcome.cleared == 2 && outcome.notCleared == 0)
        #expect(h.server.with { $0.removedFromQueue } == [901, 902, 903])
    }

    /// L9: another app's download of an album a live request is waiting on: the request is held while it goes (never
    /// counted toward its five, as D63), and its own search follows the removals.
    @Test func clearAll_foreignDownloadOfALiveRequestHoldsIt() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed",
                                         id: 901, artistId: 7, client: "Slskd")]
            s.ungrabbed = ["dl-901"]
        }
        let before = h.server.writes.count
        let r = restarter(h)
        let outcome = await r.clearAll(try await r.clearAllPlan(), includeForeign: true)
        await h.runner.settle()
        #expect(outcome.cleared == 1)
        #expect(Array(writes(h).dropFirst(before)) == ["DELETE queue/901", "POST command"])
        #expect(searches(h).last == [31])
        #expect((await h.request(id)?.stallRetries ?? 0) == 0, "another app's copy is never counted")
        #expect(await h.request(id)?.state == .searching)
    }

    /// L4: Restart all and Clear all on the one restarter run one after the other, never interleaved.
    @Test func restartAllAndClearAllTakeTurns() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...904).map { queued($0, status: "failed", tracked: "downloadFailed") } }
        let r = restarter(h)
        let plan = try await r.clearAllPlan()
        let items = try await h.lidarrClient.queueDetails(albumIds: [])
        var cache = GrabCache()
        while await cache.lookUp(items, soulseekClients: [], lidarr: h.lidarrClient, now: Date()) > 0 {}
        let board = LidarrDownloads(items, soulseekClients: [], watch: QueueStallWatch(), grabs: cache, stallLimit: 60, now: Date())
        async let restarted = r.restartAll(Array(board.restartable.prefix(2)))
        async let cleared = r.clearAll(plan, includeForeign: true)
        _ = await (restarted, cleared)
        // Restart all writes DELETE, POST pairs; Clear all writes all its DELETEs, then its POSTs. Either may go first,
        // but one's writes never fall between the other's.
        let p = "POST command"
        let restartFirst = ["DELETE queue/901", p, "DELETE queue/902", p, "DELETE queue/903", "DELETE queue/904", p, p]
        let clearFirst = ["DELETE queue/901", "DELETE queue/902", "DELETE queue/903", "DELETE queue/904", p, p, p, p]
        #expect(writes(h) == restartFirst || writes(h) == clearFirst, "\(writes(h))")
    }

    /// Progress is reported as "i of n" before each download.
    @Test func clearAll_reportsProgress() async throws {
        let h = await Harness()
        h.server.with { s in s.queue = (901...903).map { queued($0) } }
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let r = restarter(h)
        _ = await r.clearAll(try await r.clearAllPlan(), includeForeign: true) { done, total in
            seen.withLock { $0.append("\(done)/\(total)") }
        }
        #expect(seen.withLock { $0 } == ["1/3", "2/3", "3/3"])
    }
}
