import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task 6.2c: Not for me deletes a find's album from the Finds folder (G3, A16). Every precondition is proven on
/// fresh Lidarr state right before each write; track file paths are only trusted when Lidarr's filesystem shows
/// the file there; the artist goes only when nothing is left of it on disk and Magpie created it.
@Suite struct NotForMeTests {
    static let findPath = KeepTests.findPath
    static let songPath = findPath + "/" + FakeLidarr.songFile

    /// A ready find (artist 42 in `/music/samples`, album 50, track file 1), with Lidarr monitoring only album 50
    /// (as `albumsToMonitor` leaves it).
    static func readyFind(_ h: Harness) async throws -> RequestID {
        let id = try await KeepTests.readyFind(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false } }
        return id
    }

    static func writes(_ h: Harness, after before: Int) -> [(String, [String: Any])] {
        Array(h.server.writeBodies().dropFirst(before))
    }

    static func writePaths(_ h: Harness, after before: Int) -> [String] {
        h.server.writes.dropFirst(before).map { req in
            var path = req.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: "")
            if let query = req.url!.query { path += "?" + query }
            return "\(req.httpMethod!) \(path)"
        }
    }

    // MARK: - The whole thing

    /// A16: the album's files (bulk), then the album unmonitored, then the artist (files kept, no exclusion).
    @Test func deletesUnmonitorsThenRemovesTheArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        let before = h.server.writes.count
        let scans = h.library.state.withLock { $0.scans }

        let check = try await h.runner.notForMeCheck(id)
        #expect(check.permanent == false)
        #expect(h.server.writes.count == before, "the confirm check writes nothing")

        let outcome = try await h.runner.notForMe(id, permanentConfirmed: false)

        #expect(outcome == .removed)
        #expect(Self.writePaths(h, after: before) == [
            "DELETE trackfile/bulk", "PUT album/monitor",
            "DELETE artist/42?deleteFiles=false&addImportListExclusion=false",
        ])
        let writes = Self.writes(h, after: before)
        #expect(writes[0].1["trackFileIds"] as? [Int] == [1] && writes[0].1.count == 1)
        #expect(writes[1].1["albumIds"] as? [Int] == [50] && writes[1].1["monitored"] as? Bool == false)
        let r = try #require(await h.request(id))
        #expect(r.state == .dismissed && r.notForMe == nil && !r.notForMeNeedsAttention)
        #expect(h.library.state.withLock { $0.scans } > scans, "the library is scanned so the songs leave it")
        #expect(h.server.with { $0.deletedArtists } == [42])
    }

    // MARK: - G3 refusals (nothing written)

    /// G3.4: never on a kept album: not after Keep, and not when the ledger says kept for any album of the artist.
    @Test func refusesKeptAlbum() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        for var entry in try await h.ledger.entries where entry.lidarrArtistId == 42 {
            entry.keptAt = h.clock.now
            try await h.ledger.record(entry)
        }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) { _ = try await h.runner.notForMeCheck(id) }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)

        // Kept for real (the main root has a folder already: kept in place, still in the Finds folder).
        let h2 = await Harness(setup: Harness.findsSetup)
        let kept = try await Self.readyFind(h2)
        h2.server.with { $0.folders = [KeepTests.keptPath] }
        #expect(try await h2.runner.keep(kept) == .keptInPlace)
        let before2 = h2.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h2.runner.notForMe(kept, permanentConfirmed: true)
        }
        #expect(h2.server.writes.count == before2)
    }

    /// G3.3: the artist folder must be strictly inside the Finds root, compared case-sensitively and by whole
    /// components (`/music/samples-old` is not inside `/music/samples`).
    @Test(arguments: ["/music/samples-old/Aurora Field", "/music/Samples/Aurora Field", "/music/library/Aurora Field",
                      "/music/samples", "/music/samples/../library/Aurora Field"])
    func refusesSiblingPath(path: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { s in
            s.artists[0].path = path
            s.artists[0].files = path
            s.artists[0].recorded = path
        }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// G3.3: every track file of the artist must be inside its own Finds folder: one recorded in a sibling
    /// folder, another artist's folder or the main root stops everything.
    @Test(arguments: ["/music/samples-old/Aurora Field/x.mp3", "/music/samples/Other Artist/x.mp3",
                      "/music/library/Aurora Field/x.mp3", "/music/samples/Aurora Field-2/x.mp3"])
    func refusesTrackFileOutsideTheArtistFolder(file: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.extraFiles = [.init(id: 2, artistId: 42, albumId: 51, path: file, onDisk: file)] }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// Ruling 1: Lidarr's track file records can be stale (3.2 leaves them after a move). A file that isn't on
    /// disk where Lidarr records it is never deleted by id.
    @Test func refusesStaleTrackFilePaths() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.artists[0].files = Self.findPath + " (moved)" }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// G3.2 and G2: no `magpie-find`, or a Finds root that no longer checks out against fresh root folders.
    @Test func refusesWithoutFindTagOrValidFindsRoot() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.artists[0].tags = [1] }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        h.server.with {
            $0.artists[0].tags = [1, 2]
            $0.roots = ["/music/library", "/music/samples", "/music/samples/inner"]
        }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.isEmpty)
    }

    /// G3.1: the ledger must say Magpie created the artist (here the requests survived, the ledger didn't say so).
    @Test func refusesWhenTheLedgerDoesNotSayCreated() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        for var entry in try await h.ledger.entries where entry.lidarrArtistId == 42 {
            entry.createdArtist = false
            try await h.ledger.record(entry)
        }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// G6: hidden (and refused) for fallback-mode requests and existing-artist rows.
    @Test func refusesFallbackAndExistingArtist() async throws {
        let fallback = await Harness()
        fallback.server.artistIsNew()
        let a = try await fallback.runner.tryRecording(fallback.recording(recSingleAndAlbum), tier: .standard)
        await fallback.runner.settle()
        fallback.library.state.withLock { $0.indexed[recSingleAndAlbum] = "lib-1" }
        await fallback.runner.tick()
        try #require(await fallback.state(a) == .ready)
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await fallback.runner.notForMe(a, permanentConfirmed: true)
        }

        let existing = await Harness(setup: Harness.findsSetup)
        existing.server.ownerHasArtist(albumMonitored: false)
        let b = try await existing.runner.tryRecording(existing.recording(recAlbumOnly), tier: .standard)
        await existing.runner.settle()
        existing.library.state.withLock { $0.indexed[recAlbumOnly] = "lib-2" }
        await existing.runner.tick()
        try #require(await existing.state(b) == .ready)
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await existing.runner.notForMe(b, permanentConfirmed: true)
        }
        #expect(fallback.server.writes.allSatisfy { $0.httpMethod != "DELETE" })
        #expect(existing.server.writes.allSatisfy { $0.httpMethod != "DELETE" })
    }

    /// Ruling 3: never while a Keep of the artist is under way or needs attention, and never in the middle of one
    /// (Keep and Not for me share the per-artist guard).
    @Test func refusesWhileAKeepIsInFlight() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        await h.runner.mutate(id) {
            $0.keep = KeepProgress(phase: .moving, startedAt: h.clock.now, artistId: 42, fromPath: Self.findPath,
                                   findsRoot: "/music/samples", mainRoot: "/music/library", findTagId: 2,
                                   priorQualityProfileId: 4, commandBaseline: 70)
        }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        await h.runner.mutate(id) {
            $0.keep = nil
            $0.keepNeedsAttention = true
        }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.allSatisfy { $0.httpMethod != "DELETE" })

        // A Keep holding the artist (its move PUT not answered yet): Not for me can't start.
        let h2 = await Harness(setup: Harness.findsSetup)
        let kept = try await Self.readyFind(h2)
        h2.server.with { s in
            s.hold = ("/artist/editor", 1)
            s.holdMethod = "PUT"
        }
        let keep = Task { try await h2.runner.keep(kept) }
        await h2.server.latch.waitArrived()
        await #expect(throws: RequestRunner.NotForMeError.self) {
            _ = try await h2.runner.notForMe(kept, permanentConfirmed: true)
        }
        await h2.server.latch.release()
        _ = try? await keep.value
        #expect(h2.server.writes.allSatisfy { $0.httpMethod != "DELETE" })
    }

    /// While Not for me holds the artist, or after it needs attention, Keep refuses.
    @Test func keepRefusesDuringNotForMe() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        await h.runner.mutate(id) { $0.notForMeNeedsAttention = true }
        await #expect(throws: RequestRunner.KeepError.notAFind) { _ = try await h.runner.keep(id) }
        #expect(KeepTests.editorWrites(h).isEmpty)
    }

    // MARK: - G9: recycle bin off

    /// G3 / G9: with Lidarr's recycle bin unset the check says so (the sheet says "This deletes the files
    /// permanently."), and nothing is deleted unless the owner confirmed exactly that.
    @Test func recycleBinOff() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.recycleBin = "" }
        #expect(try await h.runner.notForMeCheck(id).permanent)
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.confirmAgain) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: false)
        }
        #expect(h.server.writes.count == before)
        #expect(await h.request(id)?.notForMe == nil)

        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .removed)
        #expect(Self.writePaths(h, after: before).first == "DELETE trackfile/bulk")
    }

    // MARK: - The artist (ruling 6)

    /// A16: `DELETE /artist` always carries deleteFiles=false&addImportListExclusion=false; files only ever go
    /// through the track file routes, by the ids proven on disk.
    @Test func neverDeletesFilesViaArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        let before = h.server.writes.count
        _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        let deletes = Self.writePaths(h, after: before).filter { $0.hasPrefix("DELETE ") }
        #expect(deletes.filter { $0.hasPrefix("DELETE artist/") }
            == ["DELETE artist/42?deleteFiles=false&addImportListExclusion=false"])
        #expect(deletes.allSatisfy { $0.hasPrefix("DELETE trackfile/") || $0.hasPrefix("DELETE artist/42?") })
        #expect(h.server.writes.allSatisfy { req in
            let q = (req.url?.query ?? "").lowercased()
            return !q.contains("deletefiles=true") && !q.contains("addimportlistexclusion=true")
        })
    }

    /// Ruling 6: the artist goes only when Magpie created it and no file of it is left on disk (Lidarr's
    /// filesystem, not its track file records), and no other request needs it.
    @Test func artistDeletedOnlyWhenEmptyAndCreated() async throws {
        // Another album's file is still recorded and on disk: the artist stays.
        let h1 = await Harness(setup: Harness.findsSetup)
        let a = try await Self.readyFind(h1)
        let other = Self.findPath + "/Other (2019)/01 - B.mp3"
        h1.server.with { $0.extraFiles = [.init(id: 2, artistId: 42, albumId: 51, path: other, onDisk: other)] }
        let before1 = h1.server.writes.count
        #expect(try await h1.runner.notForMe(a, permanentConfirmed: true) == .removed)
        #expect(Self.writePaths(h1, after: before1) == ["DELETE trackfile/bulk", "PUT album/monitor"])
        #expect(Self.writes(h1, after: before1)[0].1["trackFileIds"] as? [Int] == [1], "only the album's files")
        #expect(h1.server.with { $0.extraFiles.count } == 1)

        // Lidarr records no file, but one is on disk in the artist folder (untracked): the artist stays.
        let h2 = await Harness(setup: Harness.findsSetup)
        let b = try await Self.readyFind(h2)
        let untracked = Self.findPath + "/cover.jpg"
        h2.server.with { $0.extraFiles = [.init(id: 3, artistId: 42, albumId: 51, path: untracked, recorded: false,
                                                 onDisk: untracked)] }
        let before2 = h2.server.writes.count
        #expect(try await h2.runner.notForMe(b, permanentConfirmed: true) == .removed)
        #expect(!Self.writePaths(h2, after: before2).contains { $0.hasPrefix("DELETE artist/") })

        // Another request of the artist is still on its way: the artist stays.
        let h3 = await Harness(setup: Harness.findsSetup)
        let c = try await Self.readyFind(h3)
        let pending = try await h3.runner.tryRecording(h3.recording(recAlbumOnly2), tier: .patient)
        await h3.runner.settle()
        try #require(await h3.request(pending)?.isActive == true)
        // Even with Lidarr showing nothing else monitored: the request alone keeps the artist.
        h3.server.with { s in for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false } }
        let before3 = h3.server.writes.count
        _ = try await h3.runner.notForMe(c, permanentConfirmed: true)
        #expect(!Self.writePaths(h3, after: before3).contains { $0.hasPrefix("DELETE artist/") })
        #expect(Self.writePaths(h3, after: before3).first == "DELETE trackfile/bulk")
    }

    // MARK: - Lost answers, fallbacks and limits

    /// Ruling 5: a delete whose answer was lost is never sent again until a fresh proof says what is still there.
    @Test func lostAnswerIsProvenAgainBeforeAnyResend() async throws {
        // Applied, answer lost: the fresh GET shows the file gone, so no second delete.
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.deleteAppliedThen504 = 1 }
        let before = h.server.writes.count
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .removed)
        #expect(Self.writePaths(h, after: before).filter { $0.hasPrefix("DELETE trackfile") } == ["DELETE trackfile/bulk"])

        // Not applied (503): proven again (track files and disk read after the failed write), then sent again.
        let h2 = await Harness(setup: Harness.findsSetup)
        let b = try await Self.readyFind(h2)
        h2.server.with { $0.deleteFails503 = 1 }
        #expect(try await h2.runner.notForMe(b, permanentConfirmed: true) == .removed)
        let calls = h2.server.transport.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }
        let deletes = calls.indices.filter { calls[$0].hasSuffix("/trackfile/bulk") }
        try #require(deletes.count == 2)
        let between = calls[(deletes[0] + 1)..<deletes[1]]
        #expect(between.contains { $0.hasPrefix("GET") && $0.hasSuffix("/trackfile") })
        #expect(between.contains { $0.hasPrefix("GET") && $0.hasSuffix("/filesystem") })
        #expect(between.contains { $0.hasPrefix("GET") && $0.hasSuffix("/artist/42") })
    }

    /// A16: without a bulk route, one track file at a time, each proven again first.
    @Test func bulkRouteMissingDeletesOneByOne() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        let second = Self.findPath + "/Lowlands (2016)/02 - Two.mp3"
        h.server.with {
            $0.bulkDelete = .noRoute
            $0.extraFiles = [.init(id: 2, artistId: 42, albumId: 50, path: second, onDisk: second)]
        }
        let before = h.server.writes.count
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .removed)
        #expect(Self.writePaths(h, after: before) == [
            "DELETE trackfile/bulk", "DELETE trackfile/1", "DELETE trackfile/2", "PUT album/monitor",
            "DELETE artist/42?deleteFiles=false&addImportListExclusion=false",
        ])
    }

    /// Lidarr refused the first delete: nothing was removed; the find is as it was and can be let go again.
    @Test func rejectedDeleteRemovesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.bulkDelete = .rejects }
        await #expect(throws: RequestRunner.NotForMeError.failed) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.notForMe == nil && !r.notForMeNeedsAttention)
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    /// Bounded: Lidarr says yes but the files never go. It ends in needs attention, with no more writes.
    @Test func filesThatNeverGoNeedAttention() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.bulkDelete = .ignores }
        await #expect(throws: RequestRunner.NotForMeError.needsAttention) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        let deletes = h.server.writes.filter { $0.httpMethod == "DELETE" }.count
        #expect(deletes > 1 && deletes <= 1 + RequestRunner.notForMeUnansweredLimit + 3)
        let r = try #require(await h.request(id))
        #expect(r.notForMeNeedsAttention && r.notForMe == nil && r.state == .ready)
        await h.runner.tick()
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == deletes, "nothing more after that")
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
    }

    /// M6: Lidarr goes away after the first (unanswered) delete. A relaunch picks the Not for me up, proves it
    /// again and finishes; the delete is sent again only because the fresh proof shows the file still there.
    @Test func relaunchMidNotForMeFinishesItSafely() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with {
            $0.deleteFails503 = 1
            $0.rootsDownAfterDelete = true
        }
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .stillGoing)
        let saved = try #require(await h.request(id)?.notForMe)
        #expect(saved.sent && saved.phase == .deleting)
        await h.runner.stop()

        h.server.with {
            $0.rootsDown = false
            $0.rootsDownAfterDelete = false
        }
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        relaunched.clock.advance(120)
        await relaunched.runner.tick()
        let r = try #require(await relaunched.request(id))
        #expect(r.state == .dismissed && r.notForMe == nil)
        #expect(h.server.writes.filter { $0.url!.path.hasSuffix("/trackfile/bulk") }.count == 2)
    }

    /// Bounded in time: Lidarr unreadable for good after a write ends in needs attention, nothing more sent.
    @Test func lidarrGoneForGoodNeedsAttention() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with {
            $0.deleteFails503 = 1
            $0.rootsDownAfterDelete = true
        }
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .stillGoing)
        h.clock.advance(RequestRunner.notForMeLimit)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.notForMeNeedsAttention && r.notForMe == nil)
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    /// Changes switched off: nothing written, and it says so.
    @Test func changesOffWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        await h.gate.setEnabled(false)
        let before = h.server.transport.requests.count
        await #expect(throws: RequestRunner.NotForMeError.changesOff) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.transport.requests.count == before)
    }
}
