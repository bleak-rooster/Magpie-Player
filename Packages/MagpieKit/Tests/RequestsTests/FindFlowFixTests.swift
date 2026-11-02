import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Y5 fix round 1 (review I1–I10): crash windows, the file record on multi-entry artists, leases across long steps,
/// the migration, the coalesced scans, and the chaos suite (kill at each step, relaunch, reach the end state).
@Suite struct FindFlowFixTests {
    typealias F = FindFlowTests

    static func mainSongReady(_ h: Harness) {
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
    }

    static func moves(_ h: Harness) -> Int {
        KeepTests.editorWrites(h).filter { $0["rootFolderPath"] as? String == "/music/library" }.count
    }

    /// A ready find of artist 42 with two requests on two albums (two ledger entries), both ready.
    static func twoAlbumFind(_ h: Harness) async throws -> RequestID {
        let first = try await F.readyFind(h)
        let second = try await h.runner.tryRecording(h.recording(recAlbumOnly, title: "Other"), tier: .standard)
        await h.runner.settle()
        h.library.state.withLock { $0.indexed[recAlbumOnly] = "find-2" }
        await h.runner.tick()
        try #require(await h.request(second)?.state == .ready)
        try #require(try await F.entries(h).count >= 2)
        return first
    }

    // MARK: - I1

    @Test func aTwoEntryArtistsMP3IsRemoved() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.twoAlbumFind(h)
        Self.mainSongReady(h)
        #expect(try await h.runner.keep(id) == .moved)
        let records = try await F.entries(h).flatMap { $0.findFiles ?? [] }
        #expect(records.count == 1, "the file record is stored once (on its album's entry): \(records)")
        #expect(try await h.runner.removeMP3Now(id) == .removed)
        #expect(F.deletes(h) == ["trackfile/bulk"])
    }

    // MARK: - I2: an orphan intent

    /// The app died after the ledger said "keeping" and before the request saved its Keep: no PUT can have been sent.
    /// The next pass clears it (with a change-log note), and Add to your library works again.
    @Test func anOrphanIntentIsClearedOnTheNextPass() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keepIntentAt = h.clock.now; $0.findFiles = [] }
        await h.runner.stop()
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        #expect(try await F.entries(again).allSatisfy { !$0.isKeptOrKeeping && $0.findFiles == nil })
        #expect(await again.gate.changeLog().contains { $0.method == "NOTE" })
        Self.mainSongReady(again)
        #expect(try await again.runner.keep(id) == .moved)
    }

    /// An orphan intent whose artist isn't a tagged find where it was any more: not cleared, needs a look.
    @Test func anOrphanIntentOnAMovedArtistNeedsAttention() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keepIntentAt = h.clock.now }
        h.server.with { $0.artists[0].tags = [1]; $0.artists[0].path = KeepTests.keptPath; $0.artists[0].root = "/music/library" }
        h.clock.advance(RequestRunner.orphanInterval)
        await h.runner.tick()
        #expect(try await F.entries(h).allSatisfy(\.isKeptOrKeeping), "never cleared when unsure")
        #expect(await h.request(id)?.keepNeedsAttention == true)
    }

    // MARK: - I3, I10 chaos: kill at each step

    /// Critic chaos suite (design §10), Keep side: the app is killed at each step; a relaunch (and, where nothing was
    /// sent, the owner's tap again) reaches the same end: kept, moved once, with the watch and the MP3 rule.
    @Test(arguments: [RequestRunner.FaultPoint.intentSaved, .beforePut, .afterPut, .ledgerCommitted, .requestCommitted])
    func killedDuringAddEndsKeptWithAWatch(_ point: RequestRunner.FaultPoint) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.readyFind(h)
        Self.mainSongReady(h)
        let fired = FaultLatch()
        await h.runner.setFaultHook { p in p == point && fired.fire() }
        _ = try? await h.runner.keep(id)
        #expect(fired.didFire, "the fault point was reached")
        await h.runner.stop()

        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        Self.mainSongReady(again)
        for _ in 0..<6 { again.clock.advance(RequestRunner.keepCheckInterval * 3); await again.runner.tick() }
        if await again.request(id)?.state == .ready {
            // Nothing reached Lidarr: the find is as it was, and the owner taps again.
            #expect(Self.moves(h) == 0)
            #expect(try await again.runner.keep(id) == .moved)
        }
        let r = try #require(await again.request(id))
        #expect(r.state == .kept && r.keep == nil, "\(point): \(r.state)")
        #expect(r.lossless?.autoDelete == true && r.lossless?.deadline != nil, "\(point): watch \(String(describing: r.lossless))")
        #expect(Self.moves(h) == 1, "\(point): one move")
        #expect(try await F.entries(again).allSatisfy(\.isConfirmedKept))
        #expect(h.server.with { $0.posted }.contains("AlbumSearch"), "\(point): the lossless search")
    }

    /// Chaos suite, MP3 side: killed around the removal; the relaunch removes it exactly once.
    @Test(arguments: [RequestRunner.FaultPoint.refreshSent, .beforeDelete, .afterDelete])
    func killedDuringRemovalRemovesOnce(_ point: RequestRunner.FaultPoint) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        let fired = FaultLatch()
        await h.runner.setFaultHook { p in p == point && fired.fire() }
        h.clock.advance(RequestRunner.mp3Grace)
        for _ in 0..<3 { h.clock.advance(RequestRunner.losslessCheckInterval); await h.runner.tick() }
        #expect(fired.didFire)
        await h.runner.stop()
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        for _ in 0..<4 { again.clock.advance(RequestRunner.mp3Grace + RequestRunner.losslessCheckInterval); await again.runner.tick() }
        let r = try #require(await again.request(id))
        #expect(r.lossless?.removedAt != nil && !r.mp3NeedsAttention, "\(point): \(String(describing: r.lossless))")
        #expect(F.deletes(h).count == 1, "\(point): one delete")
    }

    // MARK: - I5 leases and long steps

    /// The tick never waits for Lidarr's refresh: the removal sends it and checks it on a later pass.
    @Test func theDeadlineRemovalDoesNotBlockThePass() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        h.server.with { $0.refreshStaysStarted = true }
        h.clock.advance(RequestRunner.mp3Grace)
        let before = h.clock.now
        await h.runner.tick()
        #expect(h.clock.now == before, "no inline waiting (the harness clock moves on sleeps)")
        #expect(F.deletes(h).isEmpty)
        h.server.with { s in
            s.refreshStaysStarted = false
            for i in s.commands.indices where s.commands[i].name == "RefreshArtist" { s.commands[i].status = "completed" }
        }
        h.clock.advance(RequestRunner.losslessCheckInterval)
        await h.runner.tick()
        #expect(F.deletes(h) == ["trackfile/bulk"])
        #expect(await h.request(id)?.lossless?.removedAt != nil)
    }

    /// Critic 12 / I1: a lease is renewed inside a long step (3 minutes waiting for Lidarr's refresh on a manual
    /// removal), so it is fresh on disk at every moment of it.
    @Test func aLeaseStaysFreshAcrossALongStep() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        let stateURL = RunnerState.url(forRequests: RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!))
        let log = FreshLog()
        let clock = h.clock
        h.server.with { s in
            s.refreshStaysStarted = true
            s.onCommandRead = {
                let lease = RunnerState.load(stateURL).leases.first { $0.key == "artist:42" }
                log.record(lease.map { clock.now.timeIntervalSince($0.renewedAt) < RunnerState.staleAfter } ?? false)
            }
        }
        let start = h.clock.now
        _ = try? await h.runner.removeMP3Now(id)
        #expect(h.clock.now.timeIntervalSince(start) >= 170, "a 3-minute step")
        #expect(log.reads > 10 && log.stale == 0, "fresh at every poll: \(log.reads) reads, \(log.stale) stale")
    }

    /// Critic 12 / I1: the holder dies mid-step (its PUT in flight, no renewal): the lease goes stale, another runner
    /// takes over and only follows the saved Keep; the move is sent once.
    @Test func aLeaseThatGoesStaleMidStepIsTakenOverSafely() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.readyFind(h)
        Self.mainSongReady(h)
        h.server.with { $0.hold = ("/api/v1/artist/editor", 1); $0.holdSeen = 0; $0.holdMethod = "PUT" }
        let first = Task { try? await h.runner.keep(id) }
        await h.server.latch.waitArrived()
        let other = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(await other.runner.load())
        #expect(try await other.runner.keep(id) == .stillMoving, "fresh: busy")
        other.clock.advance(RunnerState.staleAfter + 1)
        _ = try? await other.runner.keep(id)   // stale now: follows the saved Keep, never sends it again
        await h.server.latch.release()
        _ = await first.value
        for _ in 0..<4 { other.clock.advance(RequestRunner.keepCheckInterval); await other.runner.tick() }
        #expect(Self.moves(h) == 1)
        #expect(F.deletes(h).isEmpty)
    }

    // MARK: - I6 migration

    @Test func theMigrationFlagWaitsForEveryStep() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        var saved = try await h.store.load()
        for i in saved.indices { saved[i].lossless = nil }
        await h.runner.stop()
        let url = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!)
        try await RequestStore(fileURL: url).save(saved)
        F.forgetMigration(h)
        h.server.with { $0.albumGetFailures = 0; $0.down = true }   // Lidarr unreadable during the first pass
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        let stateURL = RunnerState.url(forRequests: url)
        #expect(RunnerState.load(stateURL).migrated["y5"] == nil, "not marked while a step couldn't finish")
        h.server.with { $0.down = false }
        await again.runner.tick()
        #expect(await again.request(id)?.lossless != nil)
        #expect(RunnerState.load(stateURL).migrated["y5"] != nil)
    }

    // MARK: - I7 one coalesced, targeted scan

    @Test func lossLessRelinkScansAreCoalescedAndTargeted() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.twoAlbumFind(h)
        Self.mainSongReady(h)
        #expect(try await h.runner.keep(id) == .moved)
        h.server.with { $0.songQuality = "FLAC"; $0.songFileId = 3 }
        h.library.state.withLock { $0.mainSongs = [:]; $0.folderScans = [] }   // Navidrome hasn't listed the FLAC yet
        for _ in 0..<10 { h.clock.advance(30); await h.runner.tick() }   // 5 minutes
        let scans = h.library.state.withLock { $0.folderScans }
        #expect(!scans.isEmpty && scans.count <= 5, "at most one a minute for the artist, coalesced: \(scans.count)")
        #expect(Set(scans) == [KeepTests.keptPath], "the artist folder only")
        h.library.state.withLock { $0.scanning = true; $0.folderScans = [] }
        for _ in 0..<6 { h.clock.advance(120); await h.runner.tick() }
        #expect(h.library.state.withLock { $0.folderScans }.isEmpty, "never while a scan runs")
        h.library.state.withLock { $0.scanning = false }
        h.clock.advance(RequestRunner.relinkLimit)
        for _ in 0..<3 { h.clock.advance(120); await h.runner.tick() }
        let late = h.library.state.withLock { $0.folderScans }
        #expect(late.isEmpty, "bounded: none after 30 minutes")
    }

    @Test func anUnplaceableFolderIsNeverAWholeLibraryScan() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await F.keptFind(h)
        h.server.with { $0.songQuality = "FLAC"; $0.songFileId = 3 }
        h.library.state.withLock { $0.mainSongs = [:]; $0.foldersPlaceable = false; $0.scans = 0; $0.rescans = [] }
        for _ in 0..<6 { h.clock.advance(RequestRunner.losslessCheckInterval); await h.runner.tick() }
        #expect(h.library.state.withLock { $0.scans } == 0, "no plain (full) scan")
        #expect(h.library.state.withLock { $0.rescans.isEmpty }, "no whole-library fallback")
    }

    // MARK: - I8

    @Test func onlyRecordedMP3sAreRemovable() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        #expect(await h.request(id)?.lossless?.hasRecord == true)
        #expect(await h.runner.mp3Removable(id))
        // An adopted find: watch, no record, nothing offered.
        let h2 = await Harness(setup: Harness.findsSetup)
        let adopted = try await F.readyFind(h2)
        h2.server.with { s in
            s.artists[0].path = KeepTests.keptPath; s.artists[0].root = "/music/library"
            s.artists[0].tags = [1]; s.artists[0].files = KeepTests.keptPath; s.artists[0].recorded = KeepTests.keptPath
        }
        h2.clock.advance(RequestRunner.adoptedInterval)
        await h2.runner.tick()
        #expect(await h2.request(adopted)?.lossless?.hasRecord == false)
        #expect(await !h2.runner.mp3Removable(adopted))
    }

    // MARK: - Follow-ups (re-review prep)

    /// Follow-up 1: an album the owner unmonitored before Magpie's delete is never monitored again.
    @Test func anAlbumTheOwnerUnmonitoredStaysUnmonitored() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        h.server.with { s in
            s.unmonitorOnDelete = true
            s.albums = [.init(id: 50, artistId: 42, rg: rgSingle, title: "Lowlands (single)", monitored: false)]
        }
        #expect(try await h.runner.removeMP3Now(id) == .removed)
        #expect(h.server.with { $0.albums.first?.monitored } == false)
        #expect(!h.server.writeBodies().contains { $0.0 == "PUT album/monitor" && $0.1["monitored"] as? Bool == true })
    }

    /// Follow-up 3: the FLAC landed for the track but the recorded MP3 is still there (Lidarr's upgrade didn't remove it:
    /// a second file for one track). The watch removes the recorded MP3 through the gate, then says lossless.
    @Test func aLeftoverRecordedMP3BesideTheFLACIsRemoved() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        h.server.with { s in
            s.refreshFollowsFiles = true
            s.artists[0].recorded = KeepTests.keptPath
            s.songQuality = "FLAC"; s.songFileId = 3; s.songFileName = "Lowlands (2016)/01 - Song.flac"; s.songSize = 5000
            s.extraFiles = [.init(id: 2, artistId: 42, albumId: 50, path: KeepTests.keptPath + "/" + FakeLidarr.songFile,
                                  onDisk: KeepTests.keptPath + "/" + FakeLidarr.songFile, quality: "MP3-320", size: 1000)]
        }
        for _ in 0..<3 { h.clock.advance(RequestRunner.losslessCheckInterval); await h.runner.tick() }
        #expect(F.deletes(h) == ["trackfile/bulk"], "the recorded MP3 only")
        #expect(h.server.with { $0.extraFiles }.isEmpty)
        let r = try #require(await h.request(id))
        #expect(r.lossless?.losslessAt != nil && !r.mp3NeedsAttention)
    }

    /// Re-review N1 (C2): a recorded leftover MP3 of a watch without the automatic delete is never removed automatically.
    @Test func aLeftoverIsNotAutoDeletedWithoutAutoDelete() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        await h.runner.stop()
        var saved = try await h.store.load()
        for i in saved.indices where saved[i].id == id { saved[i].lossless?.autoDelete = false; saved[i].lossless?.deadline = nil }
        try await h.store.save(saved)
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        h.server.with { s in
            s.artists[0].recorded = KeepTests.keptPath
            s.songQuality = "FLAC"; s.songFileId = 3; s.songFileName = "Lowlands (2016)/01 - Song.flac"; s.songSize = 5000
            s.extraFiles = [.init(id: 2, artistId: 42, albumId: 50, path: KeepTests.keptPath + "/" + FakeLidarr.songFile,
                                  onDisk: KeepTests.keptPath + "/" + FakeLidarr.songFile, quality: "MP3-320", size: 1000)]
        }
        for _ in 0..<3 { again.clock.advance(RequestRunner.losslessCheckInterval); await again.runner.tick() }
        #expect(F.deletes(h).isEmpty)
        #expect(h.server.with { $0.extraFiles }.count == 1)
    }

    /// Re-review N2: a Keep that needs a look keeps its intent (the lock): the stuck-intent clean-up leaves it alone.
    @Test func theOrphanCleanupSkipsAKeepThatNeedsAttention() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keepIntentAt = h.clock.now }
        await h.runner.stop()
        var saved = try await h.store.load()
        for i in saved.indices where saved[i].id == id { saved[i].keepNeedsAttention = true }
        try await h.store.save(saved)
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        for _ in 0..<2 { again.clock.advance(RequestRunner.orphanInterval); await again.runner.tick() }
        #expect(try await F.entries(again).allSatisfy(\.isKeptOrKeeping))
        #expect(await !again.gate.changeLog().contains { $0.method == "NOTE" })
    }

    /// Follow-up 3: a leftover lossy file Magpie never recorded: nothing is deleted; it needs a look.
    @Test func anUnrecordedLeftoverNeedsAttention() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await F.keptFind(h)
        h.server.with { s in
            s.artists[0].recorded = KeepTests.keptPath
            s.songQuality = "FLAC"; s.songFileId = 3; s.songFileName = "Lowlands (2016)/01 - Song.flac"
            s.extraFiles = [.init(id: 2, artistId: 42, albumId: 50, path: KeepTests.keptPath + "/Lowlands (2016)/01 - Other.mp3",
                                  onDisk: nil, quality: "MP3-320", size: 1000)]
        }
        for _ in 0..<3 { h.clock.advance(RequestRunner.losslessCheckInterval); await h.runner.tick() }
        #expect(F.deletes(h).isEmpty)
        #expect(await h.request(id)?.mp3NeedsAttention == true)
    }

    /// Follow-up 4: a download watched for "warning" is forgotten once it leaves the queue.
    @Test func theWarningWatchIsPruned() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        var q = FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, id: 907, artistId: 7, client: "SABnzbd")
        q.status = "warning"
        h.server.with { $0.queue = [q] }
        await h.runner.tick()
        #expect(await h.runner.warningWatch.count == 1)
        h.server.with { $0.queue = [] }
        h.clock.advance(5)
        await h.runner.tick()
        #expect(await h.runner.warningWatch.isEmpty)
    }

    // MARK: - I10: the rest

    /// Critic 10: sign-out with an active watch. The requests (and the runner state) go, so the watch ends and nothing
    /// is ever removed automatically for that account; the ledger keeps the kept entries and their record.
    @Test func signOutEndsTheWatchAndNothingIsRemoved() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await F.keptFind(h)
        await h.runner.stop()
        RequestStore.eraseAll(in: h.dir)
        Ledger.forgetFinished(in: h.dir)
        let url = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!)
        #expect(!FileManager.default.fileExists(atPath: RunnerState.url(forRequests: url).path), "the runner state goes too")
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        again.clock.advance(RequestRunner.mp3Grace + 86_400)
        await again.runner.tick()
        #expect(await again.runner.requests.isEmpty)
        #expect(F.deletes(h).isEmpty)
        #expect(try await F.entries(again).contains { !($0.findFiles ?? []).isEmpty && $0.isConfirmedKept })
    }

    /// Critic 1 (the runner's readers): Stall's queue removal, Not for me's artist removal and the cleanup's unmonitor
    /// all refuse while only an intent says "keeping".
    @Test func theRunnersOtherReadersRefuseOnAnIntent() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        try await h.ledger.update(artistId: 7) { $0.keepIntentAt = h.clock.now }
        let r = try #require(await h.request(id))
        #expect(try await h.runner.mayRemoveDownloads(r) == false)
        let p = NotForMeProgress(phase: .removingArtist, startedAt: h.clock.now, artistId: 7, albumId: 31,
                                 artistPath: "/music/samples/x", findsRoot: "/music/samples", mainRoot: "/music/library",
                                 findTagId: 2, permanentConfirmed: true, writeBudget: 5)
        #expect(await h.runner.mayRemoveArtistAllowed(r, p) == false)
        await h.runner.cancel(id)
        for _ in 0..<2 { h.clock.advance(RequestRunner.addSettleTime); await h.runner.tick() }
        #expect(!h.server.writeBodies().contains { $0.0 == "PUT album/monitor" && $0.1["monitored"] as? Bool == false })
    }

    /// Design §3: two passes over an unchanged server send nothing on the second.
    @Test func aSecondPassOverAnUnchangedServerWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await F.keptFind(h)
        h.clock.advance(RequestRunner.losslessCheckInterval)
        await h.runner.tick()
        let writes = h.server.writes.count
        await h.runner.tick()
        #expect(h.server.writes.count == writes)
    }
}

/// Fires once.
final class FaultLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}

final class FreshLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    private(set) var stale = 0
    func record(_ fresh: Bool) { lock.lock(); reads += 1; if !fresh { stale += 1 }; lock.unlock() }
}
