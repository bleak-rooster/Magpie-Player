import Foundation
import Testing
import LidarrKit
import ListenBrainzKit
import MagpieCore
@testable import Requests

/// Task 5.3 fix round 1.
@Suite struct RunnerFixRoundTests {
    /// CRITICAL 1: requests and ledger entries of one Lidarr are invisible to another, and switching never
    /// writes for the first server's ids.
    @Test func requestsAndLedgerAreScopedToOneLidarr() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-scope-\(UUID().uuidString)")
        let a = await Harness(directory: dir, base: URL(string: "http://127.0.0.1:8686")!)
        a.server.ownerHasArtist(albumMonitored: false)
        let id = try await a.runner.tryRecording(a.recording(recAlbumOnly), tier: .standard)
        await a.runner.settle()
        #expect(try await a.ledger.entry(albumId: 31) != nil)

        // Same files on disk, another server whose album 31 is the owner's own, monitored.
        let otherServer = FakeLidarr()
        otherServer.ownerHasArtist(albumMonitored: true)
        let b = await Harness(directory: dir, lidarr: otherServer, base: URL(string: "http://music.home:8686")!)
        #expect(await b.runner.load())
        #expect(await b.runner.requests.isEmpty)
        #expect(try await b.ledger.entry(albumId: 31) == nil)
        #expect(try await b.ledger.entries.isEmpty)
        await b.runner.cancel(id)   // A's request id means nothing here
        await b.runner.tick()
        #expect(otherServer.writes.isEmpty)
        #expect(a.ledger.instance != b.ledger.instance)
    }

    @Test func runnerRefusesALedgerForAnotherLidarr() async throws {
        let h = await Harness()
        let client = LidarrClient(base: URL(string: "http://other:8686")!, apiKey: "x", transport: h.server.clientTransport)
        let runner = RequestRunner(lidarr: client, gate: h.gate, ledger: h.ledger, mb: MusicBrainzClient(transport: h.server.transport),
                                   library: h.library.access, store: h.store, setup: { Harness.setup })
        await #expect(throws: RequestRunner.TryError.unavailable) {
            _ = try await runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        }
    }

    /// IMPORTANT 1: Cancel while the add is waiting on Lidarr: no write after it, and the clean-up runs after
    /// the step.
    @Test func cancelDuringInFlightStepSendsNothingAfter() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        // GET /album #1 is the resolve, #2 is the monitor step: hold that one.
        h.server.with { $0.hold = ("/api/v1/album", 2) }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        await h.runner.cancel(id)
        #expect(await h.state(id) == .cancelled)
        await h.server.latch.release()
        await h.runner.settle()
        #expect(h.server.writes.isEmpty)
        #expect(await h.request(id)?.cleanupPending == false, "clean-up ran after the step")
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == false)
    }

    /// IMPORTANT 2: the POST reached Lidarr but the answer was lost. The retry adopts the artist (no second
    /// POST), ledgers it at artist level at once, then the album when it appears.
    @Test func unclearAddAdoptsTheArtist() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { $0.addAnswers504 = true; $0.albumsAppearOnAdd = false }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        guard case .waiting = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(await h.request(id)?.addSent == true)

        h.clock.advance(61)
        await h.runner.tick()
        #expect(h.server.writeBodies().map(\.0) == ["POST artist"], "no second add")
        #expect(h.server.mbCalls == 1, "the retry doesn't ask MusicBrainz again")
        let r = try #require(await h.request(id))
        #expect(r.state == .searching && r.lidarrArtistId == 42 && r.albumId == nil)
        #expect(try await h.ledger.createdArtist(42))

        h.server.with { s in s.albums = s.albumsOnAdd.map { var a = $0; a.artistId = 42; return a } }
        await h.runner.tick()
        #expect(await h.request(id)?.albumId == 51)
        let entry = try #require(try await h.ledger.entry(albumId: 51))
        #expect(entry.createdArtist && !entry.wasMonitoredBefore)
        #expect(try await h.ledger.entries.count == 1, "the artist-level entry was replaced by the album's")
    }

    /// IMPORTANT 2: the album never appears: the created artist is in the ledger anyway, and the request ends.
    @Test func albumNeverAppearsStillLedgersTheArtist() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { $0.albumsAppearOnAdd = false }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.createdArtist(42))
        #expect(await h.state(id) == .searching)
        h.clock.advance(RequestRunner.albumAppearLimit + 1)
        await h.runner.tick()
        #expect(await h.state(id) == .failed(reason: .noRelease))
        #expect(try await h.ledger.createdArtist(42))
    }

    /// IMPORTANT 3 ruling: a retry with the album known goes straight to AlbumSearch: no MusicBrainz, no PUT.
    @Test func retryGoesStraightToSearch() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.clock.advance(601)
        await h.runner.tick()
        guard case .waiting(_, let retryAt) = await h.state(id) else { Issue.record("expected waiting"); return }
        h.clock.advance(retryAt.timeIntervalSince(h.clock.now) + 1)
        await h.runner.tick()
        #expect(await h.state(id) == .searching)
        #expect(h.server.mbCalls == 1)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "POST command"])
    }

    /// IMPORTANT 3 ruling: the owner unmonitored the album in Lidarr meanwhile: stop, write nothing.
    @Test func ownerUnmonitoredStopsTheRequest() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.clock.advance(601)
        await h.runner.tick()
        guard case .waiting(_, let retryAt) = await h.state(id) else { Issue.record("expected waiting"); return }
        h.server.with { s in for i in s.albums.indices { s.albums[i].monitored = false } }
        let before = h.server.writes.count
        h.clock.advance(retryAt.timeIntervalSince(h.clock.now) + 1)
        await h.runner.tick()
        #expect(await h.state(id) == .failed(reason: .stoppedInLidarr))
        #expect(h.server.writes.count == before, "no PUT, no search")
        #expect(await h.request(id)?.cleanupPending == false)
    }

    /// IMPORTANT 4: importing but never listed: back off, then Needs attention after 20 min and leave the
    /// library alone; Check again resumes.
    @Test func importingGivesUpAfterTwentyMinutes() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.history = [.init(albumId: 31, type: "trackFileImported", date: h.clock.now)] }
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        for _ in 0..<(20 * 60 / 5) {
            h.clock.advance(5)
            await h.runner.tick()
        }
        let refreshes = h.library.state.withLock { $0.refreshes }
        let scans = h.library.state.withLock { $0.scans }
        #expect(refreshes < 20, "backed off: \(refreshes) index refreshes in 20 min")
        #expect(scans < 12, "backed off: \(scans) scans in 20 min")
        let r = try #require(await h.request(id))
        #expect(r.isNotListed)
        #expect(await !h.runner.needsPolling)

        for _ in 0..<20 {
            h.clock.advance(60)
            await h.runner.tick()
        }
        #expect(h.library.state.withLock { $0.refreshes } == refreshes, "left alone")
        #expect(h.library.state.withLock { $0.scans } == scans)

        await h.runner.checkAgain(id)
        #expect(await h.runner.needsPolling)
        h.library.list(recAlbumOnly, as: "s1")
        await h.runner.tick()
        #expect(await h.state(id) == .ready)
    }

    /// IMPORTANT 5: an import blocked in Lidarr's queue at 100% waits with Lidarr's short note.
    @Test func blockedImportWaits() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.queue = [.init(albumId: 31, size: 100, sizeleft: 0, status: "completed", tracked: "importBlocked",
                                          messages: ["Has unmatched\ntracks\u{7}  " + String(repeating: "x", count: 200)])] }
        await h.runner.tick()
        guard case .waiting(let reason, _) = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .downloadFailed)
        let note = try #require(await h.request(id)?.note)
        #expect(note.hasPrefix("Has unmatched tracks x") && note.count == 120 && !note.contains("\n"))
        await h.runner.tick()
        guard case .waiting = await h.state(id) else { Issue.record("must not flip back to downloading"); return }
    }

    /// IMPORTANT 6: the followed request got an artist but no album, then stopped: the follower gives up in
    /// time instead of searching forever.
    @Test func joinedRequestGivesUpWhenItsLeaderStops() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        h.server.with { $0.albumsAppearOnAdd = false }
        let leader = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        let follower = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()
        let f = await h.request(follower)
        #expect(f?.joinedTo == leader, "\(String(describing: f))")
        await h.runner.cancel(leader)
        await h.runner.tick()
        #expect(await h.request(follower)?.joinedTo == nil)
        h.clock.advance(RequestRunner.albumAppearLimit + 1)
        await h.runner.tick()
        #expect(await h.state(follower) == .failed(reason: .noRelease))
        #expect(h.server.writeBodies().map(\.0) == ["POST artist"])
    }

    /// PROMOTED A: switched off before the POST left: `addSent` is cleared, so a later owner-added artist is
    /// never taken for Magpie's.
    @Test func addSentClearedWhenNothingWasSent() async throws {
        let h = await Harness(changesOn: false)
        h.server.artistIsNew()
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .adding
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: nil,
                      mode: .fallback)
        try await h.store.save([r])
        await h.runner.tick()
        let after = try #require(await h.request(r.id))
        #expect(after.addSent == false && after.addedAt == nil)
        #expect(h.server.writes.isEmpty)
        guard case .waiting = after.state else { Issue.record("expected waiting"); return }
    }

    /// PROMOTED B: history is read from the last poll on, not from the oldest request every time.
    @Test func historyIsReadFromACursor() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        let started = h.clock.now
        h.clock.advance(300)
        await h.runner.tick()
        h.clock.advance(5)
        await h.runner.tick()
        let f = ISO8601DateFormatter()
        let dates = h.server.historyDates.compactMap { f.date(from: $0) }
        #expect(dates.count == 2)
        #expect(dates[0] == started.addingTimeInterval(-60))
        #expect(dates[1] == started.addingTimeInterval(300 - 60), "second poll starts at the first poll, minus a minute")
    }

    // MARK: - Fix round 2

    /// 1: the monitor PUT landed but its answer was lost (504): the request still knows the album, the
    /// follow-up GET marks the entry applied, and Cancel unmonitors it.
    @Test func lostMonitorAnswerStillUndoneOnCancel() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.monitorAppliedThen504 = 1 }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        let r = try #require(await h.request(id))
        guard case .waiting = r.state else { Issue.record("expected waiting, got \(r.state)"); return }
        #expect(r.lidarrArtistId == 7 && r.albumId == 31)
        #expect(try await h.ledger.entry(albumId: 31)?.isApplied == true)
        await h.runner.cancel(id)
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["PUT album/monitor", "PUT album/monitor"])
        #expect(writes.last?.1["monitored"] as? Bool == false)
        #expect(try await h.ledger.entry(albumId: 31)?.isOpen == false, "closed once cleaned up")
    }

    /// 2: an intent (decided, never applied) is never undone, even if the album is monitored by then.
    @Test func intentEntryIsNeverUndone() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: true)   // the owner monitored it meanwhile
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .cancelled
        r.cleanupPending = true
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 7,
                      mode: .fallback)
        r.lidarrArtistId = 7
        r.albumId = 31
        try await h.store.save([r])
        try await h.ledger.record(LedgerEntry(lidarrArtistId: 7, albumId: 31, rgMbid: rgAlbum, createdArtist: false,
                                              wasMonitoredBefore: false, root: "/music/library", mode: .fallback,
                                              send: .unclear, requestId: r.id.description))
        await h.runner.tick()
        #expect(h.server.writes.isEmpty)
        #expect(await h.request(r.id)?.cleanupPending == false)
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == true)
    }

    /// Round 4: a 503 whose confirming GET shows the album still unmonitored is verifiably not sent: the
    /// retry sends the PUT again (and it is Magpie's to undo).
    @Test func failedPutConfirmedUnmonitoredIsSentAgain() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.monitorFails503 = 1 }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .notSent)
        h.clock.advance(61)
        await h.runner.tick()
        #expect(await h.state(id) == .searching)
        #expect(try await h.ledger.entry(albumId: 31)?.send == .applied)
        await h.runner.cancel(id)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "PUT album/monitor", "POST command",
                                                    "PUT album/monitor"])
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == false)
    }

    /// Round 4: a 503 whose confirming GET fails too stays unclear: the retry writes nothing and stops.
    @Test func failedPutUnconfirmedStopsOnRetry() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.monitorFails503 = 1; $0.confirmFailsAfterLost = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .unclear)
        h.clock.advance(61)
        await h.runner.tick()
        #expect(await h.state(id) == .failed(reason: .stoppedInLidarr))
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor"])
    }

    /// Round 4: the app dies while the PUT is in flight (Lidarr may apply it). The entry on disk already says
    /// unclear; after the relaunch the owner has unmonitored the album, so the retry writes nothing and stops.
    @Test func crashWhileMonitorInFlightNeverOverridesTheOwner() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.hold = ("/api/v1/album/monitor", 1); $0.holdMethod = "PUT" }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.server.latch.waitArrived()
        // On disk, read by a fresh ledger: the send is already unclear while the PUT is in flight.
        let onDisk = Ledger(fileURL: h.dir.appending(path: "ledger.json"), instance: h.ledger.instance)
        #expect(try await onDisk.entry(albumId: 31)?.send == .unclear)

        await h.runner.stop()   // the app dies; Lidarr applied the PUT, then the owner unmonitored it
        let again = await Harness(directory: h.dir, lidarr: h.server)
        #expect(await again.runner.load())
        await again.runner.tick()
        h.clock.advance(61); again.clock.advance(61)
        await again.runner.tick()
        #expect(await again.state(id) == .failed(reason: .stoppedInLidarr))
        #expect(h.server.writes.isEmpty, "no PUT from the relaunched runner, no search")
        await again.runner.cancel(id)
        #expect(h.server.writes.isEmpty, "an unclear entry is never undone")
        await h.server.latch.release()
    }

    /// Round 4: entries saved without a known send state never read as applied (fail safe).
    @Test func legacyEntriesDecodeAsUnclear() throws {
        func decode(_ extra: String) throws -> LedgerEntry {
            let json = #"{"lidarrArtistId":7,"albumId":31,"rgMbid":"\#(rgAlbum.rawValue)","createdArtist":false,"#
                + #""wasMonitoredBefore":false,"root":"/music/library","mode":"fallback"\#(extra)}"#
            return try JSONDecoder().decode(LedgerEntry.self, from: Data(json.utf8))
        }
        #expect(try decode("").send == .unclear, "no send (round 3: nil meant applied)")
        #expect(try decode(#","applied":false"#).send == .unclear, "round 2 intent")
        #expect(try decode(#","applied":true"#).send == .unclear, "round 2 applied: not trusted")
        #expect(try decode(#","send":"sentMaybe""#).send == .unclear, "unknown value")
        #expect(try decode(#","send":null"#).send == .unclear)
        #expect(try decode(#","send":"notSent""#).send == .notSent)
        #expect(try decode(#","send":"applied""#).isApplied)
        #expect(try !decode("").isApplied)
        let e = try decode(#","send":"applied","requestId":"r1""#)
        #expect(try JSONDecoder().decode(LedgerEntry.self, from: JSONEncoder().encode(e)) == e)
    }

    /// Round 4: clean-up never undoes a legacy entry (decoded as unclear), even when the album is monitored.
    @Test func cleanupNeverUndoesALegacyEntry() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: true)
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .cancelled
        r.cleanupPending = true
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 7,
                      mode: .fallback)
        r.lidarrArtistId = 7
        r.albumId = 31
        try await h.store.save([r])
        let json = #"{"lidarrArtistId":7,"albumId":31,"rgMbid":"\#(rgAlbum.rawValue)","createdArtist":false,"#
            + #""wasMonitoredBefore":false,"root":"/music/library","mode":"fallback","applied":true,"#
            + #""requestId":"\#(r.id.description)"}"#
        try await h.ledger.record(JSONDecoder().decode(LedgerEntry.self, from: Data(json.utf8)))
        await h.runner.tick()
        #expect(h.server.writes.isEmpty)
        #expect(await h.request(r.id)?.cleanupPending == false)
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == true)
    }

    /// Round 3 (a): the PUT landed, its answer was lost and the confirming GET failed; then the owner
    /// unmonitored the album. The retry must not monitor it again.
    @Test func lostAnswerThenOwnerUnmonitorsIsRespected() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.monitorAppliedThen504 = 1; $0.confirmFailsAfterLost = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .unclear)
        h.server.with { s in for i in s.albums.indices { s.albums[i].monitored = false } }   // the owner
        h.clock.advance(61)
        await h.runner.tick()
        #expect(await h.state(id) == .failed(reason: .stoppedInLidarr))
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor"], "no second monitor, no search")
    }

    /// Round 3: an unclear entry is never undone, even though Magpie's write did land.
    @Test func cancelNeverUndoesAnUnclearEntry() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.monitorAppliedThen504 = 1; $0.confirmFailsAfterLost = true }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .unclear)
        await h.runner.cancel(id)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor"])
        #expect(await h.request(id)?.cleanupPending == false)
    }

    /// Round 3 (b): the first PUT was never sent (changes off); the owner then monitored the album. The
    /// retry takes it as the owner's (wasMonitoredBefore) and Cancel leaves it monitored.
    @Test func notSentThenOwnerMonitorsIsTheOwners() async throws {
        let h = await Harness(changesOn: false)
        h.server.ownerHasArtist(albumMonitored: false)
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .adding
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 7,
                      mode: .fallback)
        try await h.store.save([r])
        await h.runner.tick()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .notSent)
        #expect(h.server.writes.isEmpty)

        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 31 { s.albums[i].monitored = true } }
        await h.gate.setEnabled(true)
        h.clock.advance(61)
        await h.runner.tick()
        #expect(await h.state(r.id) == .searching)
        let entry = try #require(try await h.ledger.entry(albumId: 31))
        #expect(entry.wasMonitoredBefore && entry.isApplied)
        await h.runner.cancel(r.id)
        #expect(h.server.writeBodies().map(\.0) == ["POST command"], "search only; the owner's monitor stays")
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == true)
    }

    /// Round 3: not sent and still unmonitored: the retry sends it (and it is Magpie's to undo).
    @Test func notSentAndUnmonitoredIsSentOnRetry() async throws {
        let h = await Harness(changesOn: false)
        h.server.ownerHasArtist(albumMonitored: false)
        var r = MagpieRequest(recording: h.recording(recAlbumOnly), tier: .standard, createdAt: h.clock.now)
        r.state = .adding
        r.plan = Plan(recordingMBID: recAlbumOnly, releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 7,
                      mode: .fallback)
        try await h.store.save([r])
        await h.runner.tick()
        #expect(try await h.ledger.entry(albumId: 31)?.send == .notSent, "the gate refused it: nothing left")
        #expect(h.server.writes.isEmpty)
        await h.gate.setEnabled(true)
        h.clock.advance(61)
        await h.runner.tick()
        #expect(await h.state(r.id) == .searching)
        #expect(try await h.ledger.entry(albumId: 31)?.send == .applied)
        await h.runner.cancel(r.id)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "PUT album/monitor"])
    }

    /// 3: a finished request's entry is closed; if the owner then monitors the album, a new request treats it
    /// as the owner's and its Cancel leaves it monitored.
    @Test func closedEntryIsNotInherited() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let a = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.cancel(a)
        #expect(try await h.ledger.entry(albumId: 31)?.isOpen == false)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 31 { s.albums[i].monitored = true } }

        let b = try await h.runner.tryRecording(h.recording(recAlbumOnly2, title: "Other"), tier: .standard)
        await h.runner.settle()
        #expect(try await h.ledger.entry(albumId: 31)?.wasMonitoredBefore == true)
        await h.runner.cancel(b)
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "PUT album/monitor", "POST command"])
        #expect(h.server.with { $0.albums.first { $0.id == 31 }?.monitored } == true)
    }

    /// 4: an unscoped ledger is refused.
    @Test func runnerRefusesAnUnscopedLedger() async throws {
        let h = await Harness()
        let client = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: h.server.clientTransport)
        let runner = RequestRunner(lidarr: client, gate: h.gate, ledger: Ledger(fileURL: nil),
                                   mb: MusicBrainzClient(transport: h.server.transport),
                                   library: h.library.access, store: h.store, setup: { Harness.setup })
        await #expect(throws: RequestRunner.TryError.unavailable) {
            _ = try await runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        }
        #expect(h.server.transport.requests.isEmpty)
    }
}
