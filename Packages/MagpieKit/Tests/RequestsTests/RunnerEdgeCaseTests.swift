import Foundation
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

// Task 8.1: Lidarr down, behind a proxy, with a wrong key; relaunches mid-request; a scan that never ends.

private let proxyPage = MockTransport.Response(
    status: 200, body: Data("<!DOCTYPE html><html><body>Sign in to continue</body></html>".utf8),
    headers: ["Content-Type": "text/html"])

@Suite struct RunnerEdgeCaseTests {
    private func waitingKind(_ h: Harness, _ id: RequestID) async -> WaitKind? {
        guard case .waiting(let reason, _) = await h.state(id) else { return nil }
        return reason.kind
    }

    // MARK: Lidarr outage

    /// Lidarr is down when Try is tapped: the request waits (serviceUnavailable), writes nothing, and goes on by
    /// itself once Lidarr is back and the retry is due.
    @Test func outageWhileResolvingWaitsThenRecovers() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.down = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await waitingKind(h, id) == .serviceUnavailable)
        #expect(h.server.writes.isEmpty)

        await h.runner.tick()   // not due yet: nothing happens
        #expect(await waitingKind(h, id) == .serviceUnavailable)

        h.server.with { $0.down = false }
        h.clock.advance(61)
        await h.runner.tick()
        await h.runner.settle()
        #expect(await h.state(id) == .searching)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// A long outage backs off (1, 5, 15, 60 minutes) and gives up after a day, never writing.
    @Test func longOutageBacksOffThenGivesUp() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.down = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        var attempts = 0
        for _ in 0..<(25 * 60) {   // a minute at a time for 25 hours
            h.clock.advance(60)
            await h.runner.tick()
            await h.runner.settle()
            if case .waiting(let reason, _) = await h.state(id) { attempts = max(attempts, reason.attempt) }
            if case .failed = await h.state(id) { break }
        }
        #expect(await h.state(id) == .failed(reason: .notFoundYet))
        #expect(attempts < 40, "backed off: \(attempts) retries in a day")
        #expect(h.server.writes.isEmpty)
    }

    // MARK: Proxy HTML and wrong key

    /// Lidarr behind an auth proxy whose session expired: every answer is a 200 HTML sign-in page. Calm wait,
    /// no crash, and nothing is written.
    @Test func proxyHTMLEverywhereWaitsAndNeverWrites() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.everyLidarrAnswer = proxyPage }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await waitingKind(h, id) == .serviceUnavailable)
        h.clock.advance(61)
        await h.runner.tick()
        await h.runner.settle()
        #expect(await waitingKind(h, id) == .serviceUnavailable)
        #expect(h.server.writes.isEmpty)
        #expect(await h.gate.changeLog().isEmpty)
    }

    /// The API key was regenerated in Lidarr: 401 on everything. The request waits; the gate never writes.
    @Test func wrongKeyWaitsAndNeverWrites() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.everyLidarrAnswer = MockTransport.Response(status: 401, body: Data(#"{"error":"Unauthorized"}"#.utf8)) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await waitingKind(h, id) == .serviceUnavailable)
        #expect(h.server.writes.isEmpty)
        #expect(await h.gate.changeLog().isEmpty)
    }

    /// The proxy page appears mid-download (after Magpie's writes): polling waits instead of flipping states,
    /// and Cancel writes nothing it can't confirm (the album can't be read, so the undo is postponed).
    @Test func proxyPageMidDownloadWaitsAndCancelPostponesUndo() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.queue = [.init(albumId: 31, size: 10, sizeleft: 5)] }
        await h.runner.tick()
        #expect(await h.state(id) == .downloading(progress: 0.5))
        let writesBefore = h.server.writes.count

        h.server.with { $0.everyLidarrAnswer = proxyPage }
        h.clock.advance(Double(RequestRunner.lidarrSilenceLimit) + 1)
        await h.runner.tick()
        #expect(await waitingKind(h, id) == .serviceUnavailable)
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(await h.state(id) == .cancelled)
        #expect(h.server.writes.count == writesBefore, "no undo PUT while Lidarr answers HTML")
        #expect(await h.request(id)?.cleanupPending == true, "the undo is owed, not dropped")

        h.server.with { $0.everyLidarrAnswer = nil }
        h.clock.advance(5)
        await h.runner.tick()
        #expect(h.server.writeBodies().last?.0 == "PUT album/monitor")
        #expect(await h.request(id)?.cleanupPending == false)
    }

    // MARK: Relaunch

    /// Relaunched while a request waits for Lidarr: the wait (and its retry time) comes back from disk and the
    /// new runner carries on when it is due.
    @Test func relaunchWhileWaitingResumes() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.down = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        guard case .waiting(_, let retryAt) = await h.state(id) else { Issue.record("expected waiting"); return }
        await h.runner.stop()

        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        guard case .waiting(_, let restored) = await again.state(id) else { Issue.record("expected waiting"); return }
        #expect(restored == retryAt)
        #expect(await again.runner.needsPolling, "the relaunched app polls again")

        h.server.with { $0.down = false }
        again.clock.advance(again.clock.now.distance(to: retryAt) + 1)
        await again.runner.tick()
        await again.runner.settle()
        #expect(await again.state(id) == .searching)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// Killed while resolving (a Lidarr read in flight): the relaunched runner resumes the request from disk;
    /// the dead runner's step, when its answer finally arrives, does nothing.
    @Test func relaunchWhileResolvingResumesOnce() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/api/v1/artist", 1) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        await h.runner.stop()

        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        #expect(await again.runner.needsPolling)
        await again.runner.tick()
        await again.runner.settle()
        #expect(await again.state(id) == .searching)

        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"], "written once, by the new runner")
    }

    // MARK: Scan never finishing

    /// Navidrome's scan status sticks at "scanning": the song is in the library (Navidrome lists files as the
    /// scan reaches them), so the request still becomes Ready, and no second scan is piled on.
    @Test func stuckScanStillFindsTheSong() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.history = [.init(albumId: 31, type: "trackFileImported", date: h.clock.now)] }
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        let scansAtImport = h.library.state.withLock { $0.scans }
        h.library.state.withLock { $0.scanning = true }
        h.library.list(recAlbumOnly, as: "s1")

        for _ in 0..<(10 * 60 / 5) where await h.state(id) != .ready {
            h.clock.advance(5)
            await h.runner.tick()
        }
        #expect(await h.state(id) == .ready)
        #expect(h.library.state.withLock { $0.scans } == scansAtImport, "never starts a scan while one is running")
    }

    /// The scan never ends and the song never shows: Needs attention after the import limit, then left alone
    /// (no polling, no scans, a bounded number of index refreshes).
    @Test func stuckScanWithoutTheSongNeedsAttention() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.history = [.init(albumId: 31, type: "trackFileImported", date: h.clock.now)] }
        await h.runner.tick()
        let scansAtImport = h.library.state.withLock { $0.scans }
        h.library.state.withLock { $0.scanning = true }
        for _ in 0..<(25 * 60 / 5) {
            h.clock.advance(5)
            await h.runner.tick()
        }
        let r = try #require(await h.request(id))
        #expect(r.isNotListed)
        #expect(await !h.runner.needsPolling)
        #expect(h.library.state.withLock { $0.scans } == scansAtImport)
        #expect(h.library.state.withLock { $0.refreshes } < 20, "backed off")
    }
}
