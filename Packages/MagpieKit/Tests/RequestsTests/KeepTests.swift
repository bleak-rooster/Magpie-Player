import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task 6.2b: Keep moves a find's artist from the Finds root into the main root (G4, A3, A4).
/// Preconditions come from fresh Lidarr state: the artist's path is inside the Finds root (PathGuard from fresh
/// root folders), it carries `magpie-find`, and the ledger says Magpie created it.
@Suite struct KeepTests {
    static let findPath = "/music/samples/Aurora Field"
    static let keptPath = "/music/library/Aurora Field"
    static let mainSong = Song(id: "lib-1", title: "Song", artist: "Aurora Field", album: "Lowlands", duration: 200,
                               suffix: "mp3", recordingMBID: recSingleAndAlbum, libraryId: 1)

    /// A Finds-mode Try that is ready: artist 42 in `/music/samples`, tagged magpie + magpie-find, song "find-1".
    static func readyFind(_ h: Harness) async throws -> RequestID {
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.library.state.withLock { $0.indexed[recSingleAndAlbum] = "find-1" }
        await h.runner.tick()
        let r = try #require(await h.request(id))
        try #require(r.state == .ready && r.isFind && r.lidarrArtistId == 42 && r.songId == "find-1")
        try #require(h.server.with { $0.artists.first?.currentPath } == findPath)
        return id
    }

    static func editorWrites(_ h: Harness) -> [[String: Any]] {
        h.server.writeBodies().filter { $0.0 == "PUT artist/editor" }.map(\.1)
    }

    /// G4 / A4: exactly one artist, the main root, moveFiles, the lossless profile, and magpie-find removed;
    /// nothing else.
    @Test func bodyIsExact() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        let before = h.server.writes.count

        let outcome = try await h.runner.keep(id)

        #expect(outcome == .moved)
        let writes = h.server.writeBodies().dropFirst(before)
        #expect(writes.map(\.0) == ["PUT artist/editor"], "one write, no second move")
        let body = try #require(writes.first?.1)
        #expect(Set(body.keys) == ["artistIds", "rootFolderPath", "moveFiles", "qualityProfileId", "tags", "applyTags"])
        #expect(body["artistIds"] as? [Int] == [42])
        #expect(body["rootFolderPath"] as? String == "/music/library")
        #expect(body["moveFiles"] as? Bool == true)
        #expect(body["qualityProfileId"] as? Int == 9)
        #expect(body["tags"] as? [Int] == [2])
        #expect(body["applyTags"] as? String == "remove")

        let r = try #require(await h.request(id))
        #expect(r.state == .kept && r.keep == nil && !r.keptInPlace)
        let entries = try await h.ledger.entries.filter { $0.lidarrArtistId == 42 }
        #expect(!entries.isEmpty && entries.allSatisfy { $0.keptAt != nil })
        #expect(h.server.with { $0.artists.first?.currentPath } == Self.keptPath)
    }

    /// A3: the move is asynchronous. Scans wait for BulkMoveArtist to complete, then cover both folders; the
    /// song is re-resolved by MBID afterwards.
    @Test func waitsForBulkMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }

        _ = try await h.runner.keep(id)

        let events = h.server.events.withLock { $0 }
        let rescan = try #require(events.firstIndex(of: "rescan"))
        let completed = try #require(events.firstIndex { $0.hasPrefix("command:") && $0.hasSuffix("completed") })
        #expect(completed < rescan, "no scan before the move completed: \(events)")
        #expect(events.filter { $0 == "rescan" }.count == 1)
        let rescans = h.library.state.withLock { $0.rescans }
        #expect(rescans.map(\.from) == [Self.findPath] && rescans.map(\.to) == [Self.keptPath])
        // The artist path was confirmed under the main root after completion (A3).
        let reads = h.server.transport.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }
        #expect(reads.lastIndex { $0.hasSuffix("/api/v1/artist/42") }! > reads.firstIndex { $0.hasSuffix("/artist/editor") }!)

        let r = try #require(await h.request(id))
        #expect(r.songId == "lib-1" && r.relinkPending == false)
        let relinked = h.relinked.withLock { $0 }
        #expect(relinked.count == 1 && relinked.first?.1 == "find-1" && relinked.first?.2.id == "lib-1")
    }

    /// The new library song isn't listed yet right after the scan: later ticks look again (no second move).
    @Test func relinksOnALaterTick() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        _ = try await h.runner.keep(id)
        #expect(await h.request(id)?.relinkPending == true)
        #expect(await h.runner.needsPolling)

        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        h.clock.advance(60)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.songId == "lib-1" && r.relinkPending == false && r.songSuffix == "mp3")
        #expect(Self.editorWrites(h).count == 1)
    }

    /// G4: the owner already has a folder for this artist in the main root. No move: only magpie-find comes
    /// off, and the find stays where it is.
    @Test func destinationExistsUntagsOnly() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.folders = [Self.keptPath] }
        let before = h.server.writes.count

        let outcome = try await h.runner.keep(id)

        #expect(outcome == .keptInPlace)
        let writes = h.server.writeBodies().dropFirst(before)
        #expect(writes.map(\.0) == ["PUT artist/editor"])
        let body = try #require(writes.first?.1)
        #expect(Set(body.keys) == ["artistIds", "tags", "applyTags"])
        #expect(body["artistIds"] as? [Int] == [42] && body["tags"] as? [Int] == [2])
        #expect(body["applyTags"] as? String == "remove")
        #expect(h.server.with { $0.artists.first?.currentPath } == Self.findPath, "not moved")
        #expect(h.library.state.withLock { $0.rescans.isEmpty })
        let r = try #require(await h.request(id))
        #expect(r.state == .kept && r.keptInPlace && r.songId == "find-1")
        #expect(try await h.ledger.entries.filter { $0.lidarrArtistId == 42 }.allSatisfy { $0.keptAt != nil })
    }

    /// G4: an artist the ledger doesn't say Magpie created is never moved (here: the requests survived, the
    /// ledger didn't).
    @Test func refusesNonLedgerArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        let other = FileManager.default.temporaryDirectory.appending(path: "magpie-keep-\(UUID().uuidString)")
        let instance = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k",
                                    transport: h.server.clientTransport).instanceScope
        let file = RequestStore.defaultURL(in: other, instance: instance)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RequestStore.defaultURL(in: h.dir, instance: instance), to: file)
        let relaunched = await Harness(directory: other, lidarr: h.server, setup: Harness.findsSetup)
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.KeepError.notAFind) { try await relaunched.runner.keep(id) }
        #expect(h.server.writes.count == before)
        #expect(await relaunched.request(id)?.state == .ready)
    }

    /// G4 / G3.3: the artist path must be strictly inside the confirmed Finds root, compared case-sensitively
    /// and component by component; anything else is refused with nothing written.
    @Test(arguments: ["/music/samples-old/Aurora Field", "/music/Samples/Aurora Field", "/music/library/Aurora Field",
                      "/music/samples/../library/Aurora Field", "/music/samples", "/elsewhere/Aurora Field"])
    func refusesPathOutsideFinds(path: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.artists[0].path = path }
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.KeepError.notAFind) { try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.keep == nil)
        #expect(try await h.ledger.entries.allSatisfy { $0.keptAt == nil })
    }

    /// G4: no magpie-find tag on the artist (fresh GET): not a find Magpie may move.
    @Test func refusesWithoutFindTag() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.artists[0].tags = [1] }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.KeepError.notAFind) { try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
    }

    /// The stored Finds root is checked again against fresh root folders; if it no longer checks out, nothing moves.
    @Test(arguments: [["/music/library"], ["/music/library", "/music/samples", "/music/samples/inner"],
                      ["/music/samples"]])
    func refusesWhenFindsRootNoLongerChecksOut(roots: [String]) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.roots = roots }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.KeepError.notAFind) { try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
    }

    /// Lidarr unreachable for the fresh reads: nothing written, nothing claimed.
    @Test func lidarrDownWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.rootsDown = true }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.KeepError.unavailable) { try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
    }

    @Test func changesOffWritesNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        await h.gate.setEnabled(false)
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.KeepError.changesOff) { try await h.runner.keep(id) }
        #expect(h.server.writes.count == before)
    }

    /// Only a ready request can be kept.
    @Test func refusesWhatIsNotReady() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        await #expect(throws: RequestRunner.KeepError.notAFind) { try await h.runner.keep(id) }
        #expect(h.server.writeBodies().allSatisfy { $0.0 != "PUT artist/editor" })
    }

    /// G9 "BulkMoveArtist failure": no scan, not kept, the request stays a find that can be kept again, and
    /// magpie-find plus the earlier quality profile are put back (the PUT had already applied them).
    @Test(arguments: [FakeLidarr.Move.fails, .revertsSilently])
    func bulkMoveFailure(move: FakeLidarr.Move) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.move = move }

        await #expect(throws: RequestRunner.KeepError.moveFailed) { try await h.runner.keep(id) }

        #expect(h.library.state.withLock { $0.rescans.isEmpty && $0.mainSongReads == 0 }, "no scan, no re-resolve")
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.keep == nil && r.keepFailed && r.songId == "find-1")
        #expect(try await h.ledger.entries.allSatisfy { $0.keptAt == nil })
        let editor = Self.editorWrites(h)
        #expect(editor.count == 2)
        let restore = try #require(editor.last)
        #expect(Set(restore.keys) == ["artistIds", "qualityProfileId", "tags", "applyTags"])
        #expect(restore["artistIds"] as? [Int] == [42] && restore["tags"] as? [Int] == [2])
        #expect(restore["applyTags"] as? String == "add" && restore["qualityProfileId"] as? Int == 4)
        let artist = try #require(h.server.with { $0.artists.first })
        #expect(artist.currentPath == Self.findPath && artist.tags.contains(2) && artist.quality == 4)

        // Recoverable: Keep again once Lidarr can move it.
        h.server.with { $0.move = .completes }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        #expect(try await h.runner.keep(id) == .moved)
        #expect(await h.request(id)?.state == .kept)
    }

    /// A 4xx from Lidarr: nothing applied, nothing to put back, nothing kept.
    @Test func rejectedPutClaimsNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.editorRejects = 1 }
        await #expect(throws: RequestRunner.KeepError.moveFailed) { try await h.runner.keep(id) }
        #expect(Self.editorWrites(h).count == 1)
        #expect(h.server.with { $0.commandReads.count } == 1, "only the read before the PUT: no waiting on a refused move")
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.keep == nil)
        #expect(try await h.ledger.entries.allSatisfy { $0.keptAt == nil })
    }

    /// Lidarr is slow: Keep says it is still moving and returns; later ticks finish it. Keep tapped again
    /// meanwhile never sends a second move.
    @Test func slowMoveFinishesLaterWithoutASecondMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.move = .hangs }

        #expect(try await h.runner.keep(id) == .stillMoving)
        #expect(h.library.state.withLock { $0.rescans.isEmpty })
        var r = try #require(await h.request(id))
        #expect(r.state == .ready && r.keep != nil)
        #expect(await h.runner.needsPolling)
        #expect(try await h.runner.keep(id) == .stillMoving)

        h.server.with { s in
            s.move = .completes
            for i in s.commands.indices where s.commands[i].name == "BulkMoveArtist" { s.commands[i].status = "completed" }
        }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        h.clock.advance(60)
        await h.runner.tick()
        r = try #require(await h.request(id))
        #expect(r.state == .kept && r.keep == nil && r.songId == "lib-1")
        #expect(Self.editorWrites(h).count == 1, "one move only")
        #expect(h.library.state.withLock { $0.rescans.count } == 1)
    }

    /// M6: the Keep is on disk before the PUT. After a relaunch mid-move the new runner only checks how the
    /// move went; it never sends it again.
    @Test func relaunchMidKeepNeverMovesTwice() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.hold = ("/artist/editor", 1); $0.holdMethod = "PUT" }
        let keep = Task { try? await h.runner.keep(id) }
        await h.server.latch.waitArrived()

        // What a relaunch would load right now.
        let saved = try await RequestStore(fileURL: RequestStore.defaultURL(
            in: h.dir, instance: LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k",
                                              transport: h.server.clientTransport).instanceScope)).load()
        #expect(saved.first { $0.id == id }?.keep != nil)
        #expect(try await h.ledger.entries.filter { $0.lidarrArtistId == 42 }.allSatisfy { $0.keptAt != nil })

        await h.runner.stop()
        await h.server.latch.release()
        _ = await keep.value
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        relaunched.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        for _ in 0..<4 {
            relaunched.clock.advance(60)
            await relaunched.runner.tick()
        }
        #expect(Self.editorWrites(h).count == 1)
        let r = try #require(await relaunched.request(id))
        #expect(r.state == .kept && r.songId == "lib-1")
    }

    /// The PUT's answer was lost but Lidarr applied it: the move is followed through, not repeated.
    @Test func lostAnswerStillFollowsTheMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.editorAppliedThen504 = 1 }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        #expect(try await h.runner.keep(id) == .moved)
        #expect(Self.editorWrites(h).count == 1)
    }

    /// The PUT timed out before reaching Lidarr: no move shows up and the artist stays in Finds. After a
    /// grace period that is a failure: nothing kept, nothing to put back (the tag never came off).
    @Test func moveThatNeverStartedIsNotKept() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.editorTimesOut = 1 }
        await #expect(throws: RequestRunner.KeepError.moveFailed) { try await h.runner.keep(id) }
        #expect(Self.editorWrites(h).isEmpty, "the PUT never arrived and nothing was put back")
        #expect(h.library.state.withLock { $0.rescans.isEmpty })
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.keep == nil && r.keepFailed)
    }

    /// Lidarr no longer lists the finished command (it prunes old ones), but the artist is in the main root and
    /// nothing is moving: kept.
    @Test func prunedCommandWithArtistMovedIsKept() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyFind(h)
        h.server.with { $0.move = .neverListed }
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = Self.mainSong }
        #expect(try await h.runner.keep(id) == .moved)
        #expect(await h.request(id)?.state == .kept)
    }
}
