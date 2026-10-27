import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task 8.2 security fixes H1 and M6 (docs/reviews/security-v1.md).
@Suite struct RunnerSecurityTests {
    /// Makes the requests file unwritable (saves fail) while keeping the ledger and the change log writable.
    private func requestSaves(in h: Harness, fail: Bool) throws {
        let dir = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: fail ? 0o555 : 0o755], ofItemAtPath: dir.path)
    }

    private func isWaiting(_ state: RequestState?) -> Bool {
        if case .waiting(let reason, _)? = state { return reason.kind == .serviceUnavailable }
        return false
    }

    /// H1 (audit E6): the monitor PUT is in flight when the app dies, and the request's ids never reached disk
    /// (a failed save). Lidarr shows the album unmonitored after the relaunch (the owner undid it). The
    /// relaunched runner takes the `monitorExisting` path, finds its own unclear entry and writes nothing.
    @Test func ownUnclearEntryIsNeverOverwrittenAfterAFailedSave() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/api/v1/album/monitor", 1); $0.holdMethod = "PUT" }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        await h.runner.stop()   // the app dies with the PUT in flight

        // As if saving the ids had failed: the requests file has neither album nor artist id.
        let url = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!)
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        saved[0]["albumId"] = nil
        saved[0]["lidarrArtistId"] = nil
        try JSONSerialization.data(withJSONObject: saved).write(to: url)

        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        await again.runner.tick()
        h.clock.advance(61); again.clock.advance(61)
        await again.runner.tick()
        #expect(h.server.writes.isEmpty, "no PUT over the owner's unmonitor, no search")
        #expect(await again.state(id) == .failed(reason: .stoppedInLidarr))
        #expect(try await again.ledger.entry(albumId: 31)?.send == .unclear, "never replaced by notSent")
        await h.server.latch.release()
    }

    /// H1: this request's own `notSent` entry (nothing left the device) with the ids lost: still sent once.
    @Test func ownNotSentEntryIsSentWhenTheAlbumIsUnmonitored() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/ws/2/recording/\(recAlbumOnly.rawValue)", 1) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        await h.gate.setEnabled(false)   // the gate refuses before anything leaves the device: notSent
        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writes.isEmpty)
        #expect(try await h.ledger.entry(albumId: 31)?.send == .notSent)
        await h.runner.stop()

        let url = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!)
        var saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        saved[0]["albumId"] = nil
        saved[0]["lidarrArtistId"] = nil
        saved[0]["state"] = ["adding": [String: Any]()]
        try JSONSerialization.data(withJSONObject: saved).write(to: url)

        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        guard await again.state(id) == .adding else {
            Issue.record("fixture state did not decode as adding: \(String(describing: await again.state(id)))")
            return
        }
        await again.runner.tick()
        #expect(h.server.writeBodies().map(\.0).first == "PUT album/monitor")
        #expect(try await again.ledger.entry(albumId: 31)?.send == .applied)
        #expect(try await again.ledger.entry(albumId: 31)?.wasMonitoredBefore == false)
    }

    /// M6: the ids can't be saved before the monitor PUT: nothing is sent and the request waits. Once saves
    /// work again, the retry sends it.
    @Test func monitorWaitsWhenTheRequestCannotBeSaved() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/ws/2/recording/\(recAlbumOnly.rawValue)", 1) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        try requestSaves(in: h, fail: true)
        defer { try? requestSaves(in: h, fail: false) }
        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writes.isEmpty, "no write without the request saved first")
        #expect(isWaiting(await h.state(id)))

        try requestSaves(in: h, fail: false)
        h.clock.advance(3600)
        await h.runner.tick()
        #expect(h.server.writeBodies().map(\.0).first == "PUT album/monitor")
    }

    /// M6: `addSent` can't be saved before `POST /artist`: nothing is sent and the request waits.
    @Test func addWaitsWhenTheRequestCannotBeSaved() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { $0.hold = ("/ws/2/recording/\(recAlbumOnly.rawValue)", 1) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        try requestSaves(in: h, fail: true)
        defer { try? requestSaves(in: h, fail: false) }
        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writes.isEmpty)
        #expect(isWaiting(await h.state(id)))
        #expect(await h.request(id)?.addSent == false)
    }

    /// M6: the search command waits for a save too.
    @Test func searchWaitsWhenTheRequestCannotBeSaved() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/api/v1/album/monitor", 1); $0.holdMethod = "PUT" }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        try requestSaves(in: h, fail: true)
        defer { try? requestSaves(in: h, fail: false) }
        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor"], "no AlbumSearch")
        #expect(isWaiting(await h.state(id)))
    }
}
