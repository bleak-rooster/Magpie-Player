import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// R17: a Magpie request's Soulseek download that hasn't moved for the stall limit (default 1 minute) is removed from
/// Lidarr's queue (blocklisted, so another source is tried) and searched again, at most 5 times; Search again does
/// the same by hand. The dev stack has no Soulseek, so the fake Lidarr plays one ("Slskd", `SlskdClient`).
@Suite struct StalledSoulseekTests {
    static let deleteQuery = "removeFromClient=true&blocklist=true&skipRedownload=true"

    /// The owner's artist 7, album 31 not monitored: a Try monitors it and searches (Magpie's own, in the ledger).
    private func searching(albumMonitored: Bool = false) async throws -> (Harness, RequestID) {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: albumMonitored)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .searching)
        return (h, id)
    }

    private func soulseek(_ queueId: Int, album: Int = 31, sizeleft: Double = 60, client: String = "Slskd")
        -> FakeLidarr.Queued {
        FakeLidarr.Queued(albumId: album, size: 100, sizeleft: sizeleft, id: queueId, artistId: 7, client: client)
    }

    private func deletes(_ h: Harness) -> [String] {
        h.server.writes.filter { $0.httpMethod == "DELETE" }.map { "\($0.url!.path)?\($0.url!.query ?? "")" }
    }

    // MARK: - Detection

    /// Nothing moved for 60 s: DELETE in the exact shape, then the runner's own AlbumSearch, and the request says
    /// the source stalled. Not a second sooner.
    @Test func stallFiresAtTheThreshold() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901)] }
        await h.runner.tick()
        #expect(await h.state(id) == .downloading(progress: 0.4))
        h.clock.advance(30); await h.runner.tick()
        h.clock.advance(29); await h.runner.tick()
        #expect(deletes(h).isEmpty, "59 s without a change is not a stall")

        h.clock.advance(1); await h.runner.tick()
        let writes = h.server.writeBodies().map(\.0)
        #expect(writes == ["PUT album/monitor", "POST command", "DELETE queue/901", "POST command"])
        #expect(deletes(h) == ["/lidarr/api/v1/queue/901?" + Self.deleteQuery])
        #expect(h.server.writeBodies().last?.1["name"] as? String == "AlbumSearch")
        #expect(h.server.writeBodies().last?.1["albumIds"] as? [Int] == [31])
        let r = try #require(await h.request(id))
        #expect(r.state == .searching)
        #expect(r.stallRetries == 1)
        #expect(r.sourceStalledAt == h.clock.now)
        #expect(r.isSourceStalled)
        #expect(await h.gate.changeLog().contains { $0.method == "DELETE" && $0.path == "/api/v1/queue/901?" + Self.deleteQuery })
        // The download clients are read once per session (cached).
        await h.runner.tick()
        #expect(h.server.with { $0.downloadClientReads } == 1)
    }

    /// R20 (owner's ruling over the appraisal): the clock starts when the item appears in the queue, so a copy queued
    /// remotely that never made progress (`sizeleft == size`) is given up on after the limit too.
    @Test func clockStartsWhenTheItemAppears() async throws {
        let (h, id) = try await searching()
        var queued = soulseek(902, sizeleft: 100)
        queued.status = "queued"
        h.server.with { $0.queue = [queued] }
        await h.runner.tick()
        h.clock.advance(59); await h.runner.tick()
        #expect(deletes(h).isEmpty)
        h.clock.advance(1); await h.runner.tick()
        #expect(deletes(h) == ["/lidarr/api/v1/queue/902?" + Self.deleteQuery])
        #expect(await h.request(id)?.stallRetries == 1)
    }

    /// Progress (sizeleft, or status / trackedDownloadState) restarts the clock.
    @Test func anyChangeRestartsTheClock() async throws {
        let (h, _) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901, sizeleft: 60)] }
        await h.runner.tick()
        h.clock.advance(50); h.server.with { $0.queue = [self.soulseek(901, sizeleft: 55)] }
        await h.runner.tick()
        h.clock.advance(50); h.server.with { $0.queue[0].status = "queued" }
        await h.runner.tick()
        h.clock.advance(59); await h.runner.tick()
        #expect(deletes(h).isEmpty)
        h.clock.advance(1); await h.runner.tick()
        #expect(deletes(h).count == 1)
    }

    /// Fix round 1 I1: a copy that's complete, waiting to import, being imported or blocked from importing is never
    /// "stalled": not after 10 minutes either. Only a copy still coming (downloading, something left) counts.
    @Test(arguments: [("importPending", "completed", 0.0), ("importing", "completed", 0.0),
                      ("importBlocked", "warning", 0.0), ("downloading", "completed", 0.0)])
    func copyPastDownloadingNeverStalls(_ tracked: String, _ status: String, _ sizeleft: Double) async throws {
        let (h, id) = try await searching()
        var copy = soulseek(901, sizeleft: sizeleft)
        copy.tracked = tracked; copy.status = status
        h.server.with { $0.queue = [copy] }
        for _ in 0..<11 { await h.runner.tick(); h.clock.advance(60) }
        #expect(deletes(h).isEmpty)
        #expect(await h.request(id)?.stallRetries == nil)
    }

    /// Fix round 1 I2: a stalled copy that's one download with another album (rows sharing its downloadId) is left
    /// alone: removing it would take that album too.
    @Test func sharedDownloadNeverRemoved() async throws {
        let (h, id) = try await searching()
        var mine = soulseek(901); mine.downloadId = "multi"
        var other = soulseek(902, album: 99); other.downloadId = "multi"
        h.server.with { $0.queue = [mine, other] }
        for _ in 0..<5 { await h.runner.tick(); h.clock.advance(60) }
        #expect(deletes(h).isEmpty)
        #expect(await h.request(id)?.stallRetries == nil)
    }

    /// Re-read fresh right before: a download that moved meanwhile is left alone (and nothing is searched).
    @Test func freshReadMustStillShowTheStall() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901)] }
        await h.runner.tick()
        h.clock.advance(60)
        // Counting from here: the poll's queue read is the 1st; the 2nd is the runner's fresh read before the delete.
        h.server.with { $0.hold = (suffix: "/queue/details", n: 2); $0.holdSeen = 0 }
        let tick = Task { await h.runner.tick() }
        await h.server.latch.waitArrived()
        h.server.with { $0.queue = [self.soulseek(901, sizeleft: 40)] }
        await h.server.latch.release()
        await tick.value
        #expect(deletes(h).isEmpty)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(await h.request(id)?.stallRetries == nil)
    }

    /// The blocklisting delete makes Lidarr record the download as failed: that's the new search's start, not a
    /// failure to wait on.
    @Test func ownDeleteIsNotADownloadFailure() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901)] }
        await h.runner.tick()
        h.clock.advance(60); await h.runner.tick()
        #expect(deletes(h).count == 1)
        h.clock.advance(5)
        h.server.with { s in s.history = [.init(albumId: 31, type: "downloadFailed", date: h.clock.now)] }
        await h.runner.tick()
        #expect(await h.state(id) == .searching)
    }

    /// Only Soulseek downloads: a stalled Usenet one is left to Lidarr.
    @Test func onlySoulseekDownloads() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901, client: "SABnzbd")] }
        for _ in 0..<12 { await h.runner.tick(); h.clock.advance(60) }
        #expect(deletes(h).isEmpty)
        #expect(await h.request(id)?.stallRetries == nil)
    }

    /// Only Magpie's requests: the owner's own stalled Soulseek download of another album is never touched, and
    /// neither is a download of an album the owner had monitored before the Try (the ledger says it's theirs).
    @Test func onlyMagpieRequests() async throws {
        let (h, _) = try await searching()
        h.server.with { $0.queue = [self.soulseek(902, album: 99)] }
        for _ in 0..<5 { await h.runner.tick(); h.clock.advance(60) }
        #expect(deletes(h).isEmpty)

        let (owned, ownedId) = try await searching(albumMonitored: true)
        owned.server.with { $0.queue = [self.soulseek(901)] }
        for _ in 0..<5 { await owned.runner.tick(); owned.clock.advance(60) }
        #expect(deletes(owned).isEmpty)
        #expect(await owned.request(ownedId)?.stallRetries == nil)
        #expect(owned.server.writeBodies().map(\.0) == ["POST command"], "only the Try's own search")
    }

    /// At most 5 automatic stall retries; then it waits as Still looking, and nothing more is removed.
    @Test func fiveRetriesThenStillLooking() async throws {
        let (h, id) = try await searching()
        for n in 0..<6 {
            h.server.with { $0.queue = [self.soulseek(901 + n)] }
            await h.runner.tick()
            h.clock.advance(60)
            await h.runner.tick()
        }
        #expect(h.server.with { $0.removedFromQueue } == [901, 902, 903, 904, 905])
        let r = try #require(await h.request(id))
        #expect(r.stallRetries == RequestRunner.maxStallRetries)
        guard case .waiting(let reason, _) = r.state else { Issue.record("not waiting: \(r.state)"); return }
        #expect(reason.kind == .stillLooking)
        #expect(r.stallsUsedUp)
        #expect(h.server.with { $0.queue.map(\.id) } == [906], "the sixth download stays")
    }

    /// Settings › Requests: "Stalled downloads give up after" 1, 2, 5 or 10 minutes, 1 by default; the runner uses it.
    @Test func stallLimitSetting() async throws {
        #expect(StallLimit.allCases.map(\.seconds) == [60, 120, 300, 600])
        #expect(StallLimit.allCases.map(\.title) == ["1 min", "2 min", "5 min", "10 min"])
        #expect(StallLimit.standard == .oneMinute)
        #expect(StallLimit(seconds: 300) == .fiveMinutes)
        #expect(StallLimit(seconds: 7) == .oneMinute, "anything else reads as the default")

        let (h, _) = try await searching()
        await h.runner.setStallLimit(StallLimit.twoMinutes.seconds)
        h.server.with { $0.queue = [self.soulseek(901)] }
        await h.runner.tick()
        h.clock.advance(60); await h.runner.tick()
        h.clock.advance(59); await h.runner.tick()
        #expect(deletes(h).isEmpty)
        h.clock.advance(1); await h.runner.tick()
        #expect(deletes(h).count == 1)
    }

    // MARK: - Search again

    /// With a download: asks first (nothing sent), then removes it the same way and searches; the stall count starts
    /// over. Rate-limited to once per 30 s.
    @Test func searchAgainWithADownload() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [self.soulseek(901)] }
        await h.runner.tick()

        await #expect(throws: RequestRunner.SearchAgainError.needsConfirmation) {
            try await h.runner.searchAgain(id, removingDownload: false)
        }
        #expect(deletes(h).isEmpty)

        try await h.runner.searchAgain(id, removingDownload: true)
        #expect(deletes(h) == ["/lidarr/api/v1/queue/901?" + Self.deleteQuery])
        #expect(h.server.writeBodies().map(\.0).suffix(2) == ["DELETE queue/901", "POST command"])
        let r = try #require(await h.request(id))
        // Fix round 1 I3: a removal by hand counts toward the same five.
        #expect(r.state == .searching && r.searchAgainAt == h.clock.now && r.stallRetries == 1)

        h.clock.advance(29)
        await #expect(throws: RequestRunner.SearchAgainError.tooSoon) {
            try await h.runner.searchAgain(id, removingDownload: true)
        }
        h.clock.advance(1)
        try await h.runner.searchAgain(id, removingDownload: false)   // nothing queued now: no question
        #expect(h.server.writeBodies().map(\.0).last == "POST command")
        #expect(deletes(h).count == 1)
    }

    /// Fix round 1 I3: five removals over the request's whole life, automatic and by hand together; a tap never
    /// starts the count over. Once used up, Find another copy removes nothing (`removalsUsedUp`), and the count
    /// survives a relaunch.
    @Test func fiveRemovalsInAllEvenByHand() async throws {
        let (h, id) = try await searching()
        for n in 0..<3 {   // three automatic
            h.server.with { $0.queue = [self.soulseek(901 + n)] }
            await h.runner.tick(); h.clock.advance(60); await h.runner.tick()
        }
        for n in 3..<5 {   // two by hand
            h.server.with { $0.queue = [self.soulseek(901 + n)] }
            await h.runner.tick()
            h.clock.advance(31)
            try await h.runner.searchAgain(id, removingDownload: true)
        }
        #expect(h.server.with { $0.removedFromQueue } == [901, 902, 903, 904, 905])
        #expect(await h.request(id)?.stallRetries == 5)
        #expect(await h.request(id)?.removalsUsedUp == true)

        h.server.with { $0.queue = [self.soulseek(906)] }
        await h.runner.tick()
        h.clock.advance(31)
        await #expect(throws: RequestRunner.SearchAgainError.limitReached) {
            try await h.runner.searchAgain(id, removingDownload: true)
        }
        h.clock.advance(60); await h.runner.tick()
        #expect(h.server.with { $0.removedFromQueue }.count == 5, "the sixth copy stays")

        await h.runner.stop()
        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        #expect(await again.request(id)?.stallRetries == 5)
        again.clock.advance(again.clock.now.distance(to: h.clock.now) + 31)
        await #expect(throws: RequestRunner.SearchAgainError.limitReached) {
            try await again.runner.searchAgain(id, removingDownload: true)
        }
    }

    /// Fix round 1 I1: Find another copy never removes a copy past downloading (here waiting to import): no question,
    /// nothing removed.
    @Test func searchAgainLeavesACopyPastDownloading() async throws {
        let (h, id) = try await searching()
        var copy = soulseek(901, sizeleft: 0)
        copy.tracked = "importPending"; copy.status = "completed"
        h.server.with { $0.queue = [copy] }
        await h.runner.tick()
        try await h.runner.searchAgain(id, removingDownload: false)
        #expect(deletes(h).isEmpty)
    }

    /// No download: no question, just the search.
    @Test func searchAgainWithoutADownload() async throws {
        let (h, id) = try await searching()
        try await h.runner.searchAgain(id, removingDownload: false)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "POST command"])
        #expect(await h.request(id)?.canSearchAgain == true)
    }

    /// Not for a request that's home, importing or stopped.
    @Test func searchAgainOnlyWhileLooking() async throws {
        let (h, id) = try await searching()
        h.server.with { s in s.history = [.init(albumId: 31, type: "trackFileImported", date: h.clock.now)] }
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        #expect(await h.request(id)?.canSearchAgain == false)
        await #expect(throws: RequestRunner.SearchAgainError.notNow) {
            try await h.runner.searchAgain(id, removingDownload: true)
        }
        #expect(h.server.writeBodies().count == 2)
    }

    // MARK: - The machine

    @Test func machineSearchAgainAndStalled() {
        let now = Date(timeIntervalSince1970: 1_000)
        for s in [RequestState.searching, .downloading(progress: 0.3),
                  .waiting(reason: WaitReason(.downloadFailed, since: now), retryAt: now)] {
            let (next, effects) = RequestMachine.step(s, .searchAgain, now: now, prior: nil)
            #expect(next == .searching && effects == [.startSearch])
        }
        for s in [RequestState.importing, .ready, .pending, .cancelled] {
            #expect(RequestMachine.step(s, .searchAgain, now: now, prior: nil).0 == s)
        }
        let (stalled, _) = RequestMachine.step(.downloading(progress: 0.3), .stalled, now: now, prior: nil)
        guard case .waiting(let reason, _) = stalled else { Issue.record("not waiting"); return }
        #expect(reason.kind == .stillLooking)
        let waiting = RequestState.waiting(reason: reason, retryAt: now)
        #expect(RequestMachine.step(waiting, .stalled, now: now, prior: reason).0 == waiting)
    }
}
