import Foundation
import Testing
import LidarrKit
import MagpieCore
import MagpieTestSupport
@testable import Requests

/// Task H1: edge cases of Not for me, Keep and Bring in more (M6/M7) the feature suites don't reach: the
/// defence-in-depth checks one at a time, relaunches at each saved step, Lidarr answering garbage, Unicode folder
/// names, and the G7 / 20-release boundaries.
@Suite struct FindsEdgeCaseTests {
    static let findPath = KeepTests.findPath

    static func deletes(_ h: Harness) -> [URLRequest] { h.server.writes.filter { $0.httpMethod == "DELETE" } }

    // MARK: - Not for me: defence in depth (each check alone refuses, nothing written)

    /// A BulkMoveArtist of the artist still running in Lidarr (a Keep from another device, or the owner's own
    /// move): nothing is deleted while files may be on their way somewhere.
    @Test func notForMeRefusesWhileAMoveRuns() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.move = .hangs
            s.commands.append(.init(id: 90, name: "BulkMoveArtist", status: "started", artistIds: [42]))
        }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) { _ = try await h.runner.notForMeCheck(id) }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
        #expect(await h.request(id)?.notForMe == nil)
    }

    /// Lidarr's artist is now another MusicBrainz artist than the one the request added (an id reused after a
    /// delete and re-add): never deleted.
    @Test func notForMeRefusesAnotherArtistUnderTheSameId() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { $0.artists[0].mbid = mbid(999) }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// G3.1: the ledger must hold an entry for the album that says Magpie monitored it. Without one (the request
    /// points at an album the ledger never saw), or when the owner had it monitored before: never deleted.
    @Test func notForMeNeedsTheAlbumsLedgerEntry() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let albumId = try #require(await h.request(id)?.albumId)
        var entry = try #require(try await h.ledger.entry(albumId: albumId))
        entry.wasMonitoredBefore = true
        try await h.ledger.record(entry)
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }

        let h2 = await Harness(setup: Harness.findsSetup)
        let id2 = try await NotForMeTests.readyFind(h2)
        await h2.runner.mutate(id2) { $0.albumId = 51 }   // no ledger entry for album 51
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h2.runner.notForMe(id2, permanentConfirmed: true)
        }
        #expect(Self.deletes(h).isEmpty && Self.deletes(h2).isEmpty)
    }

    /// Another request still bringing the same album in (its files may not all be there yet): not offered and
    /// refused, also across a relaunch.
    @Test func notForMeRefusesWhileTheAlbumIsStillArriving() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let ready = try #require(await h.request(id))
        var arriving = MagpieRequest(recording: h.recording(recAlbumOnly2), tier: .standard, createdAt: h.clock.now)
        arriving.plan = ready.plan
        arriving.lidarrArtistId = 42
        arriving.albumId = ready.albumId
        arriving.state = .downloading(progress: 0.4)
        try await h.store.save(try await h.store.load() + [arriving])
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        _ = await relaunched.runner.load()
        #expect(await relaunched.runner.letGoCandidate(ready) == nil)
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await relaunched.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(Self.deletes(h).isEmpty)
    }

    /// The artist folder changes between two deletes (Lidarr renamed or moved it while the first answer was lost):
    /// the second is never sent; it needs a look.
    @Test func notForMeStopsWhenTheFolderChangesMidway() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.deleteFails503 = 1
            s.hold = ("/trackfile/bulk", 1)
            s.holdMethod = "DELETE"
        }
        let run = Task { try await h.runner.notForMe(id, permanentConfirmed: true) }
        await h.server.latch.waitArrived()
        let moved = Self.findPath + " (2)"
        h.server.with { s in
            s.artists[0].path = moved
            s.artists[0].files = moved
            s.artists[0].recorded = moved
        }
        await h.server.latch.release()
        await #expect(throws: RequestRunner.NotForMeError.needsAttention) { _ = try await run.value }
        #expect(Self.deletes(h).count == 1)
        let r = try #require(await h.request(id))
        #expect(r.notForMeNeedsAttention && r.notForMe == nil && r.state == .ready)
        await h.runner.tick()
        #expect(Self.deletes(h).count == 1, "nothing more after that")
    }

    // MARK: - Not for me: relaunch at each saved step

    /// The app is killed while the unmonitor is in flight. The relaunch reads Lidarr, unmonitors what is still
    /// monitored, removes the empty artist once (files kept), and deletes no file again.
    @Test func relaunchWhileUnmonitoringFinishes() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.hold = ("/album/monitor", 1)
            s.holdMethod = "PUT"
        }
        let run = Task { try await h.runner.notForMe(id, permanentConfirmed: true) }
        await h.server.latch.waitArrived()
        let saved = try #require(await h.request(id)?.notForMe)
        #expect(saved.phase == .unmonitoring && saved.sent)
        await h.runner.stop()

        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        relaunched.clock.advance(120)
        await relaunched.runner.tick()
        let r = try #require(await relaunched.request(id))
        #expect(r.state == .dismissed && r.notForMe == nil && !r.notForMeNeedsAttention)
        await h.server.latch.release()
        _ = try? await run.value
        let paths = NotForMeTests.writePaths(h, after: 0).filter { !$0.hasPrefix("POST") }
        #expect(paths.filter { $0.hasPrefix("DELETE trackfile") } == ["DELETE trackfile/bulk"])
        #expect(paths.filter { $0.hasPrefix("DELETE artist/") } == ["DELETE artist/42?deleteFiles=false&addImportListExclusion=false"])
        #expect(h.server.with { $0.albums.first { $0.id == 50 }?.monitored } == false)
    }

    /// Killed while removing the artist: the relaunch sees the artist gone (404) and is done, without another
    /// write.
    @Test func relaunchAfterTheArtistWentIsDone() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.hold = ("/artist/42", 1)
            s.holdMethod = "DELETE"
        }
        let run = Task { try await h.runner.notForMe(id, permanentConfirmed: true) }
        await h.server.latch.waitArrived()
        #expect(await h.request(id)?.notForMe?.phase == .removingArtist)
        await h.runner.stop()
        await h.server.latch.release()   // it reached Lidarr; the answer never got back to the killed app
        _ = try? await run.value
        let writes = h.server.writes.count

        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        relaunched.clock.advance(120)
        await relaunched.runner.tick()
        let r = try #require(await relaunched.request(id))
        #expect(r.state == .dismissed && r.notForMe == nil && !r.notForMeNeedsAttention)
        #expect(h.server.writes.count == writes, "nothing sent again")
    }

    // MARK: - Sign-out or Lidarr disconnect mid-way (the app stops the runner)

    /// Stopped while the move PUT is in flight: nothing more is sent by that runner, and it says so.
    @Test func stoppedMidKeepSendsNothingMore() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)
        h.server.with { s in
            s.hold = ("/artist/editor", 1)
            s.holdMethod = "PUT"
        }
        let before = h.server.writes.count
        let keep = Task { try await h.runner.keep(id) }
        await h.server.latch.waitArrived()
        await h.runner.stop()
        await h.server.latch.release()   // the PUT reaches Lidarr after the stop
        await #expect(throws: RequestRunner.KeepError.self) { _ = try await keep.value }
        await h.runner.tick()
        #expect(NotForMeTests.writePaths(h, after: before) == ["PUT artist/editor"], "only the one in flight")
        #expect(h.library.state.withLock { $0.rescans.isEmpty })
    }

    /// Stopped while the first delete is in flight: no unmonitor or artist delete follows from that runner.
    @Test func stoppedMidNotForMeSendsNothingMore() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.hold = ("/trackfile/bulk", 1)
            s.holdMethod = "DELETE"
        }
        let before = h.server.writes.count
        let run = Task { try await h.runner.notForMe(id, permanentConfirmed: true) }
        await h.server.latch.waitArrived()
        await h.runner.stop()
        await h.server.latch.release()   // the delete reaches Lidarr after the stop
        await #expect(throws: RequestRunner.NotForMeError.unavailable) { _ = try await run.value }
        await h.runner.tick()
        #expect(NotForMeTests.writePaths(h, after: before) == ["DELETE trackfile/bulk"], "only the one in flight")
    }

    // MARK: - Lidarr answering garbage

    /// A proxy's HTML page (HTTP 200) or a server error for every Lidarr call: Not for me, Keep and Bring in more
    /// say they can't right now and write nothing.
    @Test(arguments: [MockTransport.Response(status: 200, body: Data("<html>Sign in</html>".utf8)),
                      MockTransport.Response(status: 200, body: Data(#"{"unexpected":true}"#.utf8)),
                      MockTransport.Response(status: 500), MockTransport.Response(status: 401)])
    func garbageFromLidarrWritesNothing(answer: MockTransport.Response) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { $0.everyLidarrAnswer = answer }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.NotForMeError.unavailable) { _ = try await h.runner.notForMeCheck(id) }
        await #expect(throws: RequestRunner.NotForMeError.unavailable) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        await #expect(throws: RequestRunner.KeepError.self) { _ = try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.notForMe == nil && r.keep == nil && !r.notForMeNeedsAttention)

        let k = await Harness(setup: Harness.findsSetup)
        let kept = try await BringInMoreTests.keptFind(k)
        k.server.with { $0.everyLidarrAnswer = answer }
        let beforeKept = k.server.writes.count
        await #expect(throws: RequestRunner.BringInError.unavailable) { _ = try await k.runner.bringInOffer(kept) }
        await #expect(throws: RequestRunner.BringInError.unavailable) {
            _ = try await k.runner.bringIn(kept, choice: .albumsAndEPs, follow: true)
        }
        #expect(k.server.writes.count == beforeKept)
    }

    // MARK: - Unicode folder names

    /// CJK, right-to-left and accented artist folders are let go like any other, compared byte for byte.
    @Test(arguments: ["/music/samples/東京事変", "/music/samples/فيروز", "/music/samples/Sigur R\u{F3}s",
                      "/music/samples/" + String(repeating: "Ä", count: 120)])
    func unicodeFolderIsLetGo(path: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with { s in
            s.artists[0].path = path
            s.artists[0].files = path
            s.artists[0].recorded = path
        }
        let before = h.server.writes.count
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .removed)
        #expect(NotForMeTests.writePaths(h, after: before) == [
            "DELETE trackfile/bulk", "PUT album/monitor",
            "DELETE artist/42?deleteFiles=false&addImportListExclusion=false",
        ])
    }

    /// Lidarr records the folder in one Unicode form (NFC) and the disk lists the other (NFD): the files aren't
    /// proven where Lidarr says they are, so nothing is deleted (fails closed).
    @Test func unicodeFormMismatchDeletesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        let nfc = "/music/samples/Sigur R\u{F3}s", nfd = "/music/samples/Sigur Ro\u{301}s"
        h.server.with { s in
            s.artists[0].path = nfc
            s.artists[0].recorded = nfc
            s.artists[0].files = nfd
        }
        await #expect(throws: RequestRunner.NotForMeError.notAFind) {
            _ = try await h.runner.notForMe(id, permanentConfirmed: true)
        }
        #expect(Self.deletes(h).isEmpty)
    }

    // MARK: - Bring in more boundaries

    /// G7 boundary: four requests on their way still allow it; the fifth stops it.
    @Test func fourActiveStillBringIn() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await BringInMoreTests.keptFind(h)
        let active = (0..<(RequestRunner.maxActive - 1)).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .downloading(progress: 0.1)
            return r
        }
        try await h.store.save(try await h.store.load() + active)
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(try await relaunched.runner.bringIn(id, choice: .albumsAndEPs, follow: false).albums == 3)
    }

    /// The 20-release limit at its edge: exactly 20 is all of them (not capped); 21 brings in the newest 20.
    @Test func bringInLimitBoundary() {
        func albums(_ n: Int) -> [LidarrAlbum] {
            (0..<n).map { i in
                LidarrAlbum(id: 100 + i, title: "A\(i)", artistId: 42, foreignAlbumId: mbid(2_000 + i), monitored: false,
                            albumType: "Album", releaseDate: Date(timeIntervalSince1970: Double(i) * 86_400))
            }
        }
        let twenty = RequestRunner.bringInOption(albums(20), choice: .albumsAndEPs, songAlbums: nil, skip: [], limit: 20)
        #expect(twenty?.albumIds.count == 20 && twenty?.available == 20 && twenty?.isCapped == false)
        let more = RequestRunner.bringInOption(albums(21), choice: .albumsAndEPs, songAlbums: nil, skip: [], limit: 20)
        #expect(more?.albumIds.count == 20 && more?.available == 21 && more?.isCapped == true)
        #expect(more?.albumIds.first == 120 && !(more?.albumIds.contains(100) ?? true), "the oldest is left out")
    }

    /// M6: the answer was lost and only some albums turned out monitored: those are claimed and searched (and
    /// marked applied); the rest stay "may have landed", unsearched; following still goes through.
    @Test func partlyAppliedLostAnswer() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await BringInMoreTests.keptFind(h)
        h.server.with { $0.monitorAppliesOnlyThen504 = [53] }
        let before = h.server.writes.count

        let result = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)

        #expect(result == .init(albums: 1, searching: true, following: true))
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command", "PUT artist/editor"])
        #expect(writes[0].1["albumIds"] as? [Int] == [53, 52, 51])
        #expect(writes[1].1["albumIds"] as? [Int] == [53], "only what landed is searched")
        #expect(try await h.ledger.entry(albumId: 53)?.send == .applied)
        #expect(try await h.ledger.entry(albumId: 52)?.send == .unclear)
        #expect(try await h.ledger.entry(albumId: 51)?.send == .unclear)
        #expect(BringInMoreTests.monitored(h) == [50, 53, 55], "nothing unmonitored")
    }
}
