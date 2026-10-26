import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

@Suite struct RequestRunnerTests {
    // MARK: - Brief tests

    /// A7 / G6: the owner's artist is never edited; one album is monitored and searched.
    @Test func existingArtistMonitorsOneAlbumOnly() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .patient)
        await h.runner.settle()

        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(!writes.contains { $0.0.hasPrefix("PUT artist") || $0.0.hasPrefix("POST artist") })
        #expect(writes[0].1["albumIds"] as? [Int] == [31])
        #expect(writes[0].1["monitored"] as? Bool == true)
        #expect(writes[1].1["name"] as? String == "AlbumSearch")
        #expect(writes[1].1["albumIds"] as? [Int] == [31])
        // The single isn't in this artist's catalogue on the server, so the album it does have is used (A7).
        #expect(await h.request(id)?.plan?.releaseGroupMBID == rgAlbum)
        #expect(await h.state(id) == .searching)
        let entry = try #require(try await h.ledger.entry(albumId: 31))
        #expect(entry.createdArtist == false && entry.wasMonitoredBefore == false && entry.mode == .fallback)
        #expect(await h.gate.changeLog().count == 2)
    }

    /// A6: one POST /artist carrying everything, built from the lookup row; no separate monitor or search.
    @Test func newArtistSingleAtomicAdd() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()

        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist"])
        let body = writes[0].1
        #expect(body["foreignArtistId"] as? String == artistA.rawValue)
        #expect(body["artistName"] as? String == "Aurora Field")
        #expect(body["rootFolderPath"] as? String == "/music/library")
        #expect(body["RootFolderPath"] == nil, "a differently-cased copy from the lookup is dropped")
        #expect(body["qualityProfileId"] as? Int == 4)
        #expect(body["metadataProfileId"] as? Int == 3)
        #expect(body["tags"] as? [Int] == [1])
        #expect(body["monitored"] as? Bool == true)
        #expect(body["monitorNewItems"] as? String == "none")
        let options = try #require(body["addOptions"] as? [String: Any])
        #expect(options["monitor"] as? String == "none")
        #expect(options["albumsToMonitor"] as? [String] == [rgSingle.rawValue])
        #expect(options["searchForMissingAlbums"] as? Bool == true)

        let r = try #require(await h.request(id))
        #expect(r.state == .searching && r.albumId == 50 && r.lidarrArtistId == 42 && r.addSent)
        #expect(r.albumTitle == "Release 2")
        let entry = try #require(try await h.ledger.entry(albumId: 50))
        #expect(entry.createdArtist && !entry.wasMonitoredBefore && entry.root == "/music/library" && entry.rgMbid == rgSingle)
    }

    /// G7: the same song returns the same request; another song on the same release follows the first.
    @Test func duplicateJoinsExisting() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let first = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        let again = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        #expect(first == again)
        await h.runner.settle()
        let other = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()

        #expect(h.server.writeBodies().map(\.0) == ["POST artist"])
        let joined = try #require(await h.request(other))
        #expect(joined.joinedTo == first && joined.albumId == 51 && joined.state == .searching)
        #expect(await h.runner.requests.count == 2)
    }

    /// Two different songs on one release asked at once still add the artist once.
    @Test func concurrentTriesOnOneReleaseAddOnce() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()
        await h.runner.tick()
        #expect(h.server.writeBodies().map(\.0) == ["POST artist"])
        #expect(await h.runner.requests.allSatisfy { $0.albumId == 51 && $0.state == .searching })
    }

    /// D7: Lidarr importing is not Ready; Ready is the library listing the song after a scan.
    @Test func readyOnlyAfterNavidromeLists() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()

        h.server.with { $0.queue = [.init(albumId: 31, size: 100, sizeleft: 40)] }
        await h.runner.tick()
        #expect(await h.state(id) == .downloading(progress: 0.6))

        h.clock.advance(5)
        h.server.with { s in
            s.queue = []
            s.history = [.init(albumId: 31, type: "grabbed", date: h.clock.now),
                         .init(albumId: 31, type: "trackFileImported", date: h.clock.now)]
        }
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        #expect(h.library.state.withLock { $0.scans } >= 1)

        // Lidarr has it, the library doesn't list it yet: still not Ready.
        h.clock.advance(31)
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        #expect(h.ready.withLock { $0 }.isEmpty)

        // Listed, but the index only learns it on its next refresh (at most every 30 s).
        h.library.list(recAlbumOnly, as: "song-9")
        h.clock.advance(5)
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        h.clock.advance(30)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.songId == "song-9")
        #expect(h.ready.withLock { $0 } == [id])
        #expect(h.library.state.withLock { $0.refreshes } == 3, "once per 30 s at most")
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// G6: Cancel unmonitors only what Magpie monitored, and never deletes.
    @Test func cancelUnmonitorsOnlyIfMagpieMonitored() async throws {
        // Magpie monitored it: Cancel unmonitors.
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.cancel(id)
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command", "PUT album/monitor"])
        #expect(writes[2].1["monitored"] as? Bool == false && writes[2].1["albumIds"] as? [Int] == [31])
        #expect(await h.state(id) == .cancelled)
        #expect(await h.request(id)?.cleanupPending == false)
        #expect(!h.server.writes.contains { $0.httpMethod == "DELETE" })

        // The owner had it monitored: Cancel leaves it alone.
        let o = await Harness()
        o.server.ownerHasArtist(albumMonitored: true)
        let id2 = try await o.runner.tryRecording(o.recording(recAlbumOnly), tier: .standard)
        await o.runner.settle()
        await o.runner.cancel(id2)
        #expect(o.server.writeBodies().map(\.0) == ["POST command"])
        #expect(try await o.ledger.entry(albumId: 31)?.wasMonitoredBefore == true)
        #expect(await o.state(id2) == .cancelled)
        #expect(o.server.with { $0.albums.first { $0.id == 31 }?.monitored } == true)
    }

    /// Cancelling one of two requests on the same album leaves it monitored for the other.
    @Test func cancelKeepsAlbumAnotherRequestNeeds() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let a = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        let b = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()
        await h.runner.cancel(a)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
        await h.runner.cancel(b)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "PUT album/monitor"])
        await h.runner.forget(a)
        #expect(await h.runner.requests.map(\.id) == [b])
    }

    /// Lidarr applies `albumsToMonitor` when its refresh of a new artist ends, which can be after a quick
    /// Cancel: the clean-up keeps checking for a while and unmonitors it then.
    @Test func cancelRightAfterAddCatchesLateMonitor() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { s in for i in s.albumsOnAdd.indices { s.albumsOnAdd[i].monitored = false } }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.cancel(id)
        #expect(h.server.writeBodies().map(\.0) == ["POST artist"])
        #expect(await h.request(id)?.cleanupPending == true)

        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 51 { s.albums[i].monitored = true } }
        h.clock.advance(30)
        await h.runner.tick()
        #expect(h.server.writeBodies().map(\.0) == ["POST artist", "PUT album/monitor"])
        #expect(h.server.with { $0.albums.first { $0.id == 51 }?.monitored } == false)

        h.clock.advance(RequestRunner.addSettleTime)
        await h.runner.tick()
        #expect(await h.request(id)?.cleanupPending == false)
        #expect(await !h.runner.needsPolling)
        #expect(!h.server.writes.contains { $0.httpMethod == "DELETE" })
    }

    /// G1: with changes off nothing is created and nothing is written.
    @Test func gateOffNoWrites() async throws {
        let h = await Harness(changesOn: false)
        h.server.artistIsNew()
        await #expect(throws: RequestRunner.TryError.changesOff) {
            _ = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        }
        await h.runner.tick()
        #expect(h.server.writes.isEmpty)
        #expect(await h.runner.requests.isEmpty)
        #expect(await h.gate.changeLog().isEmpty)
    }

    // MARK: - More behaviour

    /// Switched off mid-request: the request waits instead of failing, and nothing is sent.
    @Test func changesTurnedOffMidRequestWaits() async throws {
        let h = await Harness(changesOn: false)
        h.server.ownerHasArtist(albumMonitored: false)
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .adding
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 7,
                      mode: .fallback)
        try await h.store.save([r])
        await h.runner.tick()
        #expect(h.server.writes.isEmpty)
        guard case .waiting(let reason, _) = await h.state(r.id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .serviceUnavailable)
    }

    /// G7: at most five on their way at once.
    @Test func atMostFiveActive() async throws {
        let h = await Harness()
        let active = (0..<5).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .downloading(progress: 0.1)
            return r
        }
        var done = MagpieRequest(recording: h.recording(mbid(300)), tier: .standard, createdAt: h.clock.now)
        done.state = .ready
        try await h.store.save(active + [done])
        await #expect(throws: RequestRunner.TryError.tooMany) {
            _ = try await h.runner.tryRecording(h.recording(recAlbumOnly2), tier: .standard)
        }
        // The same song as one already on its way is not a new request.
        #expect(try await h.runner.tryRecording(h.recording(mbid(202)), tier: .standard) == active[2].id)
        #expect(h.server.transport.requests.isEmpty)
    }

    /// A14: search done, nothing queued or grabbed for 10 minutes: "still looking"; the retry searches again
    /// without touching monitoring a second time.
    @Test func nothingFoundWaitsThenSearchesAgain() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .patient)
        await h.runner.settle()

        h.server.with { $0.commandStatus = "started" }
        h.clock.advance(601)
        await h.runner.tick()
        #expect(await h.state(id) == .searching, "the search is still running")

        h.server.with { $0.commandStatus = "completed" }
        await h.runner.tick()
        guard case .waiting(let reason, let retryAt) = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .stillLooking && reason.attempt == 0)
        #expect(await h.request(id)?.priorWait == reason)

        h.clock.advance(retryAt.timeIntervalSince(h.clock.now) + 1)
        await h.runner.tick()
        #expect(await h.state(id) == .searching)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "POST command"])
        #expect(try await h.ledger.entry(albumId: 31)?.wasMonitoredBefore == false, "Magpie's own monitor is remembered")
    }

    /// Lidarr reports a failed download: wait (Lidarr retries), not fail (A14).
    @Test func downloadFailedWaits() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.clock.advance(5)
        h.server.with { s in
            s.history = [.init(albumId: 31, type: "grabbed", date: h.clock.now),
                         .init(albumId: 31, type: "downloadFailed", date: h.clock.now.addingTimeInterval(1))]
        }
        await h.runner.tick()
        guard case .waiting(let reason, _) = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .downloadFailed)
    }

    /// A blip while polling doesn't move the request; five minutes of silence does.
    @Test func lidarrSilenceWaitsOnlyAfterFiveMinutes() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.down = true }
        h.clock.advance(60)
        await h.runner.tick()
        #expect(await h.state(id) == .searching)
        h.clock.advance(300)
        await h.runner.tick()
        guard case .waiting(let reason, _) = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .serviceUnavailable)
    }

    /// The artist isn't new but has no release with the song: fail, never change its profiles (A7).
    @Test func notInArtistsCatalogueFails() async throws {
        let h = await Harness()
        h.server.with { s in
            s.artists = [.init(id: 7, mbid: artistA, root: "/music/library")]
            s.albums = [.init(id: 40, artistId: 7, rg: mbid(99), title: "Other", monitored: false)]
        }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .failed(reason: .notInCatalogue))
        #expect(h.server.writes.isEmpty)
    }

    /// Requests survive a relaunch and pick up where they were.
    @Test func resumesAfterRelaunch() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()

        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        #expect(await again.state(id) == .searching)
        h.server.with { $0.queue = [.init(albumId: 31, size: 10, sizeleft: 5)] }
        await again.runner.tick()
        #expect(await again.state(id) == .downloading(progress: 0.5))
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
    }

    /// A relaunch between the POST and its answer: the artist Lidarr now has is Magpie's, not the owner's.
    @Test func interruptedAddIsStillMagpies() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { $0.albumsAppearOnAdd = true }
        // Simulate: request saved in `adding` with addSent, artist already created in Lidarr.
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .adding
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: nil,
                      mode: .fallback)
        r.addSent = true
        r.root = "/music/library"
        try await h.store.save([r])
        h.server.with { s in
            s.artists = [.init(id: 42, mbid: artistA, root: "/music/library")]
            s.albums = [.init(id: 51, artistId: 42, rg: rgAlbum, title: "Lowlands", monitored: true)]
        }
        await h.runner.tick()
        let entry = try #require(try await h.ledger.entry(albumId: 51))
        #expect(entry.createdArtist && !entry.wasMonitoredBefore)
        #expect(!h.server.writeBodies().contains { $0.0 == "POST artist" })
    }

    /// A retired runner does nothing more, so a successor on the same store never races it.
    @Test func stoppedRunnerDoesNothing() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        await h.runner.stop()
        await #expect(throws: RequestRunner.TryError.unavailable) {
            _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        }
        await h.runner.tick()
        #expect(h.server.transport.requests.isEmpty)
    }

    @Test func refusalsFailAndOutagesWait() {
        #expect(RequestRunner.event(for: WriteGateError.forbidden("x")) == .error(.addFailed))
        #expect(RequestRunner.event(for: WriteGateError.disabled) == .lidarrUnavailable)
        #expect(RequestRunner.event(for: LidarrError.http(status: 400)) == .error(.addFailed))
        #expect(RequestRunner.event(for: LidarrError.http(status: 503)) == .lidarrUnavailable)
        #expect(RequestRunner.event(for: URLError(.timedOut)) == .lidarrUnavailable)
    }
}
