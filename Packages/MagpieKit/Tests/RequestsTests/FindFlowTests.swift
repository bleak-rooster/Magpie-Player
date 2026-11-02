import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Y5 (plan items 8 and 9): Add to your library as intent → PUT → verify → commit, the lossless watch and the MP3
/// rule, the reconciliation pass, leases, Lidarr's clock and the migration. Includes the critic's 16 tests.
@Suite struct FindFlowTests {
    static let day: TimeInterval = 24 * 3600

    /// A ready find (artist 42 in the Finds folder) whose song file Lidarr's track list knows (MP3, track ft-1).
    static func readyFind(_ h: Harness) async throws -> RequestID {
        let id = try await KeepTests.readyFind(h)
        h.server.with { $0.songImported = true }
        return id
    }

    /// The owner taps Add to your library and the move goes through.
    static func keptFind(_ h: Harness) async throws -> RequestID {
        let id = try await readyFind(h)
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        try #require(try await h.runner.keep(id) == .moved)
        return id
    }

    static func deletes(_ h: Harness) -> [String] {
        h.server.writes.filter { $0.httpMethod == "DELETE" }.map { $0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: "") }
    }

    /// As before Y5: the migration hasn't run.
    static func forgetMigration(_ h: Harness) {
        let url = RunnerState.url(forRequests: RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!))
        var state = RunnerState.load(url)
        state.migrated = [:]
        RunnerState.save(state, to: url)
    }

    static func entries(_ h: Harness) async throws -> [LedgerEntry] {
        try await h.ledger.entries.filter { $0.lidarrArtistId == 42 }
    }

    // MARK: - Keep: intent → PUT → verify → commit

    @Test func keepRecordsTheFindFilesWithTheIntentAndCommitsAfterTheMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let e = try await Self.entries(h)
        #expect(!e.isEmpty && e.allSatisfy { $0.isConfirmedKept && $0.keepIntentAt == nil })
        let files = try #require(e.first?.findFiles)
        #expect(files == [FindFile(id: 1, albumId: 50, foreignTrackId: "ft-1", relativePath: FakeLidarr.songFile,
                                   size: 1000, quality: "MP3-320")])
        let r = try #require(await h.request(id))
        #expect(r.state == .kept)
        let w = try #require(r.lossless)
        #expect(w.autoDelete && w.albumIds == [50] && w.deadline == h.clock.now.addingTimeInterval(RequestRunner.mp3Grace))
        #expect(h.server.with { $0.posted }.last == "AlbumSearch", "the lossless search right away")
    }

    /// Critic 13 / I2: a queued Keep sent long after the tap gets its grace from the send, not the tap.
    @Test func aQueuedKeepSentAfterTheGraceIsFollowedFromTheSend() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.commands.append(FakeLidarr.Command(id: 71, name: "RssSync", status: "queued", artistIds: [])) }
        #expect(try await h.runner.keep(id) == .queued)
        h.clock.advance(RequestRunner.keepStartGrace * 3)
        await h.runner.tick()
        #expect(await h.request(id)?.keep?.phase == .queued, "still busy: still queued")
        h.server.with { $0.commands.removeAll { $0.id == 71 } }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.state == .kept && r.keep == nil && !r.keepFailed)
        #expect(KeepTests.editorWrites(h).count == 1)
        #expect(r.lossless?.autoDelete == true)
    }

    @Test func aQueuedKeepIsDroppedAfterADay() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.commands.append(FakeLidarr.Command(id: 71, name: "RssSync", status: "queued", artistIds: [])) }
        #expect(try await h.runner.keep(id) == .queued)
        h.clock.advance(RequestRunner.keepQueueLimit)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.keep == nil && r.keepFailed && r.state == .ready)
        #expect(try await Self.entries(h).allSatisfy { !$0.isKeptOrKeeping && $0.findFiles == nil })
        #expect(KeepTests.editorWrites(h).isEmpty)
    }

    /// Critic 14 / I10: the app dies right after the commit was saved, before the request said kept. The relaunch
    /// verifies again and finishes; one move only.
    @Test func aCrashAfterTheCommitFinishesOnRelaunch() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.move = .hangs }
        #expect(try await h.runner.keep(id) == .stillMoving)
        await h.runner.stop()
        // Lidarr finishes the move; the ledger already says kept (the save before the crash).
        h.server.with { s in
            s.move = .completes
            for i in s.commands.indices where s.commands[i].name == "BulkMoveArtist" { s.commands[i].status = "started" }
        }
        try await h.ledger.update(artistId: 42) { $0.keptAt = h.clock.now; $0.keepIntentAt = nil }
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        again.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        for _ in 0..<3 { again.clock.advance(RequestRunner.keepCheckInterval); await again.runner.tick() }
        let r = try #require(await again.request(id))
        #expect(r.state == .kept && r.keep == nil)
        #expect(try await Self.entries(again).allSatisfy(\.isConfirmedKept))
        #expect(KeepTests.editorWrites(h).count == 1)
    }

    /// Critic 12 / I1: two runners on one store. While the first runner's PUT is still in flight, the second one
    /// (another process) sees the fresh lease and sends nothing.
    @Test func twoRunnersNeverMoveTwice() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.hold = ("/api/v1/artist/editor", 1); $0.holdSeen = 0; $0.holdMethod = "PUT" }
        let first = Task { try? await h.runner.keep(id) }
        await h.server.latch.waitArrived()
        let other = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(await other.runner.load())
        #expect(try await other.runner.keep(id) == .stillMoving)
        await other.runner.tick()
        await h.server.latch.release()
        _ = await first.value
        #expect(KeepTests.editorWrites(h).count == 1)
    }

    /// I1: a lease nobody renews for two minutes is another runner's that is gone: dropped, the work goes on.
    @Test func aStaleLeaseIsDropped() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        let url = RunnerState.url(forRequests: RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!))
        var state = RunnerState()
        state.leases = [.init(key: "artist:42", process: "gone", startedAt: h.clock.now, renewedAt: h.clock.now)]
        RunnerState.save(state, to: url)
        #expect(try await h.runner.keep(id) == .stillMoving, "fresh: someone else is on it")
        h.clock.advance(RunnerState.staleAfter)
        await h.runner.tick()
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        #expect(try await h.runner.keep(id) == .moved)
    }

    // MARK: - The MP3 rule

    @Test func atTheDeadlineTheRecordedMP3IsRemovedThroughTheGate() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.clock.advance(RequestRunner.mp3Grace - 60)
        await h.runner.tick()
        #expect(Self.deletes(h).isEmpty, "not before the deadline")
        h.clock.advance(RequestRunner.losslessCheckInterval)
        await h.runner.tick()
        #expect(Self.deletes(h) == ["trackfile/bulk"])
        #expect(h.server.with { $0.posted }.contains("RefreshArtist"), "re-mapped after a refresh (C3)")
        let r = try #require(await h.request(id))
        #expect(r.lossless?.removedAt != nil && r.songId == nil && !r.mp3NeedsAttention)
        #expect(await h.gate.changeLog().contains { $0.method == "DELETE" })
    }

    /// Critic 3 + 4 + 5: a file at the recorded path that is another track (re-imported), or the same track at
    /// another size (tags rewritten), is never deleted: needs attention, and "removed" is never claimed.
    @Test(arguments: ["reimported", "resized"])
    func aChangedMP3NeedsAttention(_ change: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { s in
            if change == "reimported" { s.songFileId = 2; s.songTrack = "ft-other" } else { s.songSize = 1200 }
        }
        await #expect(throws: RequestRunner.MP3Error.needsAttention) { _ = try await h.runner.removeMP3Now(id) }
        #expect(Self.deletes(h).isEmpty)
        let r = try #require(await h.request(id))
        #expect(r.mp3NeedsAttention && r.lossless?.removedAt == nil)
    }

    /// Critic 3: without the refresh Lidarr's record is still the stale, pre-move one: nothing matches at the new
    /// folder while the track still has its MP3, so nothing is deleted (and "removed" isn't claimed).
    @Test func aStaleRecordIsNeverTakenForGone() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.refreshFollowsFiles = false }
        await #expect(throws: RequestRunner.MP3Error.needsAttention) { _ = try await h.runner.removeMP3Now(id) }
        #expect(Self.deletes(h).isEmpty)
        #expect(await h.request(id)?.lossless?.removedAt == nil)
    }

    /// Critic 11: "Remove the MP3 now" and the deadline at the same moment delete once.
    @Test func aManualRemoveAndTheDeadlineDeleteOnce() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.clock.advance(RequestRunner.mp3Grace)
        async let manual = try? h.runner.removeMP3Now(id)
        async let pass: Void = h.runner.tick()
        _ = await (manual, pass)
        await h.runner.tick()
        #expect(Self.deletes(h).count == 1)
    }

    /// Critic 8 / I6: Lidarr unmonitors the album after the delete (the owner's setting): monitored again.
    @Test func anAutoUnmonitoredAlbumIsMonitoredAgain() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { s in
            s.unmonitorOnDelete = true
            s.albums = [.init(id: 50, artistId: 42, rg: rgSingle, title: "Lowlands (single)", monitored: true)]
        }
        #expect(try await h.runner.removeMP3Now(id) == .removed)
        #expect(h.server.with { $0.albums.first?.monitored } == true)
        #expect(h.server.writeBodies().contains { $0.0 == "PUT album/monitor" && $0.1["monitored"] as? Bool == true })
    }

    /// Critic 9 / I7: with Lidarr's recycle bin unset the removal can't be undone (the page and the confirmation say so).
    @Test func theRemovalIsPermanentWithoutARecycleBin() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        #expect(await h.runner.mp3RemovalIsPermanent() == false)
        h.server.with { $0.recycleBin = "" }
        #expect(await h.runner.mp3RemovalIsPermanent() == true)
    }

    /// Critic 10 / I5: a kept find with a running watch can't be removed from Activity, and sign-out keeps the ledger
    /// that backs it.
    @Test func anActiveWatchIsNeverForgotten() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        #expect(await h.request(id)?.canBeRemoved == false)
        await h.runner.forget(id)
        #expect(await h.request(id) != nil)
        #expect(await h.runner.needsPolling)
        Ledger.forgetFinished(in: h.dir)
        #expect(try await !Self.entries(h).isEmpty, "the kept entries stay (open)")
    }

    /// Lossless lands (Lidarr's upgrade): the watch ends, nothing is deleted, the song is looked up again.
    @Test func whenTheFLACLandsTheWatchEnds() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.songQuality = "FLAC"; $0.songFileId = 3 }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Song(id: "lib-1", title: "Song", artist: "A", album: "L",
                                                                           duration: 200, suffix: "flac", recordingMBID: recSingleAndAlbum) }
        h.clock.advance(RequestRunner.losslessCheckInterval)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.lossless?.losslessAt != nil && r.lossless?.isActive == false)
        #expect(r.songSuffix == "flac")
        h.clock.advance(RequestRunner.mp3Grace)
        await h.runner.tick()
        #expect(Self.deletes(h).isEmpty)
    }

    @Test func theWatchSearchesDailyAndEndsAfterThirtyDays() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.songFileId = 4 }   // nothing to remove (as if gone), keep the watch searching
        for _ in 0..<3 { h.clock.advance(Self.day); await h.runner.tick() }
        #expect(h.server.with { $0.posted }.filter { $0 == "AlbumSearch" }.count >= 3)
        h.clock.advance(RequestRunner.losslessWatchLimit)
        await h.runner.tick()
        #expect(await h.request(id)?.lossless?.isActive == false)
    }

    // MARK: - Never automatic for a Keep the owner didn't tap under Y5 (C2)

    /// Critic 6: a find moved into the library by hand is adopted (verified, then committed) with no auto delete.
    @Test func anAdoptedFindIsNeverAutoDeleted() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { s in
            s.artists[0].path = KeepTests.keptPath; s.artists[0].root = "/music/library"
            s.artists[0].tags = [1]; s.artists[0].files = KeepTests.keptPath; s.artists[0].recorded = KeepTests.keptPath
        }
        h.clock.advance(RequestRunner.adoptedInterval)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.state == .kept && r.lossless?.autoDelete == false && r.lossless?.deadline == nil)
        #expect(try await Self.entries(h).allSatisfy(\.isConfirmedKept))
        h.clock.advance(RequestRunner.mp3Grace + Self.day)
        await h.runner.tick()
        #expect(Self.deletes(h).isEmpty)
        #expect(KeepTests.editorWrites(h).isEmpty, "nothing moved by Magpie")
    }

    /// Critic 7 + 15: a find kept before Y5 gets the watch at the migration (no auto delete); the migration runs once,
    /// and a re-run (a crash before its flag) adds nothing.
    @Test func olderKeptFindsGetAWatchOnceAndNeverAutoDelete() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        // As saved before Y5: no watch, no migration flag.
        let url = RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!)
        var saved = try await h.store.load()
        for i in saved.indices { saved[i].lossless = nil }
        await h.runner.stop()
        try await RequestStore(fileURL: url).save(saved)
        let stateURL = RunnerState.url(forRequests: url)
        try? FileManager.default.removeItem(at: stateURL)
        let searchesBefore = h.server.with { $0.posted }.filter { $0 == "AlbumSearch" }.count

        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        let w = try #require(await again.request(id)?.lossless)
        #expect(!w.autoDelete && w.deadline == nil)
        #expect(RunnerState.load(stateURL).migrated["y5"] != nil)
        // A re-run (flag lost): nothing more.
        var state = RunnerState.load(stateURL); state.migrated = [:]; RunnerState.save(state, to: stateURL)
        await again.runner.stop()
        let third = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await third.runner.tick()
        #expect(h.server.with { $0.posted }.filter { $0 == "AlbumSearch" }.count == searchesBefore + 1)
        third.clock.advance(RequestRunner.mp3Grace + Self.day)
        await third.runner.tick()
        #expect(Self.deletes(h).isEmpty)
    }

    /// I3: a Keep that crashed after saying kept (before Y5), with the artist still a tagged find where it was: the lock
    /// is cleared at the migration, and Add to your library works again.
    @Test func aLegacyLockIsClearedOnlyWhenCertain() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keptAt = h.clock.now }
        await h.runner.stop()
        Self.forgetMigration(h)
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        #expect(try await Self.entries(again).allSatisfy { !$0.isKeptOrKeeping })
        again.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        #expect(try await again.runner.keep(id) == .moved)
    }

    @Test func aLockWithTheArtistMovedStays() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keptAt = h.clock.now }
        h.server.with { $0.artists[0].path = "/music/samples/Elsewhere"; $0.artists[0].tags = [1] }
        await h.runner.stop()
        Self.forgetMigration(h)
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        #expect(try await Self.entries(again).allSatisfy { $0.keptAt != nil }, "untagged: not certain, stays locked")
    }

    // MARK: - Facts (I8, I12)

    /// Critic 16 (partial album): only this recording's track file counts as imported.
    @Test func importedIsFoldedPerRecording() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        await h.runner.tick()
        try #require(await h.state(id) == .searching)
        h.server.with { $0.songImported = true; $0.songTrack = "ft-1" }
        h.clock.advance(RequestRunner.factInterval)
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
    }

    @Test func anotherRecordingsFileDoesNotCount() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.tick()
        let state = await h.state(id)
        h.server.with { $0.songImported = true }   // the track listed is recSingleAndAlbum's, on album 50
        h.clock.advance(RequestRunner.factInterval)
        await h.runner.tick()
        #expect(await h.state(id) == state)
    }

    /// Item 9.8 + I12: Lidarr's refresh of the new artist completed and the album isn't there: no release at once. A
    /// global refresh (no artist ids) never counts.
    @Test(arguments: [true, false])
    func aCompletedRefreshEndsTheWaitForTheAlbum(_ targeted: Bool) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.albumsAppearOnAdd = false }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.server.with { s in
            s.commands.append(FakeLidarr.Command(id: 200, name: "RefreshArtist", status: "completed",
                                                 artistIds: targeted ? [42] : []))
        }
        h.clock.advance(60)
        await h.runner.tick()
        if targeted {
            #expect(await h.state(id) == .failed(reason: .noRelease))
        } else {
            #expect(await h.request(id)?.isActive == true, "a global refresh says nothing about this add")
        }
    }

    // MARK: - Lidarr's clock (item 9.7, M4)

    @Test func historyIsAskedInLidarrsTime() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { $0.serverDate = h.clock.now.addingTimeInterval(600) }   // the phone is 10 min behind
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.tick()
        await h.runner.tick()
        let f = ISO8601DateFormatter()
        let asked = try #require(h.server.historyDates.last.flatMap { f.date(from: $0) })
        #expect(asked > h.clock.now.addingTimeInterval(400), "the cursor is in Lidarr's time: \\(asked)")
    }

    @Test func aCachedOrWildDateIsIgnored() async throws {
        for (offset, cached) in [(600.0, true), (3 * 24 * 3600.0, false)] {
            let h = await Harness()
            h.server.with { $0.serverDate = h.clock.now.addingTimeInterval(offset); $0.serverDateCached = cached }
            await h.runner.tick()
            #expect(await h.runner.serverNow() == h.clock.now)
        }
    }

    // MARK: - Every refusing keptAt reader with only an intent (critic 1, runner side; the gate's are in LidarrKit)

    @Test func everyRunnerReaderRefusesOnAnIntent() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keepIntentAt = h.clock.now }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) { _ = try await h.runner.notForMeCheck(id) }
        await #expect(throws: RequestRunner.KeepError.notAFind) { _ = try await h.runner.keep(id) }
        await #expect(throws: RequestRunner.BringInError.notKept) { _ = try await h.runner.bringInOffer(id) }
        let artists = h.server.with { $0.artists }.map {
            LidarrArtist(id: $0.id, artistName: "A", foreignArtistId: $0.mbid, monitored: false, tags: $0.tags)
        }
        let state = ArtistLidarr.state(name: "A", mbid: artistA, artists: artists, commands: [],
                                       ledger: try await Self.entries(h))
        #expect(state == .notMonitored(lidarrId: 42, magpieAdded: false))
        #expect(h.server.writes.count == before)
    }
}
