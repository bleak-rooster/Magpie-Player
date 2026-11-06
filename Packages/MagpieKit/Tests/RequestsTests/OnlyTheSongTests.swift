import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 18 (owner, 2026-11-05): a song's Try keeps only that song (Lidarr and Tubifarry download whole releases, so the
/// release's other songs leave the Finds folder once the song is ready), and a downloaded find can always be let go.
@Suite struct OnlyTheSongTests {
    static let findPath = KeepTests.findPath
    static let album = findPath + "/Lowlands (2016)"

    static func other(_ id: Int, _ title: String, path: String? = nil, recording: MBID? = nil) -> FakeLidarr.ExtraFile {
        let p = path ?? album + "/0\(id) - \(title).mp3"
        return FakeLidarr.ExtraFile(id: id, artistId: 42, albumId: 50, path: p, onDisk: p, trackTitle: title,
                                    trackRecording: recording ?? mbid(700 + id))
    }

    /// A ready song Try whose release came with two more songs (track files 2 and 3). The trim is held (a refresh of the
    /// artist still running) until `go(h)`.
    static func readyWithOthers(_ h: Harness) async throws -> RequestID {
        h.server.with { s in s.extraFiles += [other(2, "Other"), other(3, "Third")] }
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.commands.append(FakeLidarr.Command(id: 990, name: "RefreshArtist", status: "started", artistIds: [42])) }
        h.library.state.withLock { $0.indexed[recSingleAndAlbum] = "find-1" }
        await h.runner.tick()
        let r = try #require(await h.request(id))
        try #require(r.state == .ready && r.isFind && r.onlyTheSong == true && r.trimDone == nil, "\(r.state)")
        h.server.with { $0.songImported = true }   // Lidarr's track list shows the song's file
        return id
    }

    /// The refresh holding the trim is done (and nothing is in the queue).
    static func go(_ h: Harness) {
        h.server.with { s in
            for i in s.commands.indices where s.commands[i].id == 990 { s.commands[i].status = "completed" }
            s.queue.removeAll()
        }
    }

    static func deletes(_ h: Harness, after before: Int) -> [[Int]] {
        h.server.writeBodies().dropFirst(before).filter { $0.0 == "DELETE trackfile/bulk" }.map { $0.1["trackFileIds"] as? [Int] ?? [] }
    }

    static func trackFileIds(_ h: Harness) -> Set<Int> {
        h.server.with { s in Set(s.extraFiles.filter(\.recorded).map(\.id) + (s.artists.contains { $0.recorded != nil } ? [s.songFileId] : [])) }
    }

    // MARK: - The trim

    /// The release's other songs go (one bulk delete of exactly those files), the song stays, the album is unmonitored
    /// so nothing brings them back, and the library is scanned.
    @Test func keepsOnlyTheSong() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyWithOthers(h)
        Self.go(h)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.trimDone == true)
        #expect(Self.trackFileIds(h) == [1], "only the song's file is left")
        #expect(h.server.writeBodies().contains { $0.0 == "DELETE trackfile/bulk" && Set($0.1["trackFileIds"] as? [Int] ?? []) == [2, 3] })
        #expect(h.server.with { s in s.albums.first { $0.id == 50 }?.monitored } == false, "unmonitored: not searched again")
        #expect(h.library.state.withLock { $0.scans } > 0)
        #expect(r.state == .ready, "the song is still ready to play")
        let before = h.server.writes.count
        h.clock.advance(600)
        await h.runner.tick()
        #expect(Self.deletes(h, after: before).isEmpty, "nothing more on later passes")
    }

    /// Every avenue's song Try (Trending, Recommended, Search, an artist's top songs, a playlist, an outside album's
    /// track, the car…) is `tryRecording` without an album; the plain, Try and Add to library intents all mark it.
    /// "Try this album" doesn't.
    @Test func everySongTryIsMarkedAndNoAlbumTryIs() async throws {
        for intent in [RequestRunner.Intent.plain, .trial, .library] {
            for picked in [nil, rgAlbum] {
                let h = await Harness(setup: Harness.findsSetup)
                h.server.artistIsNew()
                let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, releaseGroup: picked,
                                                         intent: intent)
                #expect(await h.request(id)?.onlyTheSong == true, "\(intent) \(String(describing: picked))")
            }
        }
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let album = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        #expect(await h.request(album)?.onlyTheSong == nil)
    }

    /// The song matched by recording, else by title (round 17's other release); a track without a file never counts.
    @Test func matchesTheSong() {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: mbid(1), title: "Song", artist: "A",
                                                           source: .lidarr), tier: .standard, createdAt: Date())
        r.plan = Plan(recordingMBID: mbid(1), releaseGroupMBID: rgAlbum, artistMBID: artistA, lidarrArtistId: 42, mode: .finds)
        var tracks = [LidarrTrack(id: 1, albumId: 50, trackFileId: 11, foreignTrackId: nil, foreignRecordingId: mbid(9).rawValue),
                      LidarrTrack(id: 2, albumId: 50, trackFileId: 12, foreignTrackId: nil, foreignRecordingId: mbid(8).rawValue),
                      LidarrTrack(id: 3, albumId: 50, trackFileId: 0, foreignTrackId: nil, foreignRecordingId: mbid(1).rawValue)]
        #expect(RequestRunner.wantedTracks(tracks, for: [r]).isEmpty, "the recording's track has no file; no title match")
        tracks[2].trackFileId = 13
        #expect(RequestRunner.wantedTracks(tracks, for: [r]).map(\.id) == [3], "by recording")
        tracks[2].trackFileId = 0
        tracks[0].title = "Song"
        tracks[1].title = "Something Else"
        #expect(RequestRunner.wantedTracks(tracks, for: [r]).map(\.id) == [1], "by title")
        var second = r
        second.recording.title = "Something Else"
        second.plan?.recordingMBID = mbid(77)
        #expect(Set(RequestRunner.wantedTracks(tracks, for: [r, second]).map(\.id)) == [1, 2], "two songs asked for: both stay")
    }

    /// Another song of the release asked for stays; only the rest goes.
    @Test func keepsWhatAnotherRequestWants() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyWithOthers(h)
        var second = MagpieRequest(recording: ExternalRecording(recordingMBID: mbid(702), title: "Other", artist: "Aurora Field",
                                                                source: .listenBrainz), tier: .standard, createdAt: h.clock.now)
        second.state = .ready
        second.plan = try #require(await h.request(id)?.plan)
        second.plan?.recordingMBID = mbid(702)
        second.lidarrArtistId = 42
        second.albumId = 50
        second.songId = "find-2"
        second.trimDone = true
        #expect(await h.runner.adopt(second))
        Self.go(h)
        await h.runner.tick()
        #expect(Self.trackFileIds(h) == [1, 2], "the song and the other asked-for song stay; the third goes")
        #expect(await h.request(id)?.trimDone == true)
    }

    /// Still downloading or importing (a queue row for the album): nothing yet; once the queue is clear, the trim.
    @Test func waitsForTheQueue() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyWithOthers(h)
        Self.go(h)
        h.server.with { $0.queue.append(FakeLidarr.Queued(albumId: 50, size: 10, sizeleft: 5)) }
        await h.runner.tick()
        #expect(Self.trackFileIds(h) == [1, 2, 3])
        #expect(await h.request(id)?.trimDone == nil)
        h.server.with { $0.queue.removeAll() }
        await h.runner.tick()
        #expect(Self.trackFileIds(h) == [1])
    }

    // MARK: - Never trimmed

    /// Each case: no file is deleted.
    @Test func neverTrims() async throws {
        let cases: [(String, (Harness, RequestID) async throws -> Void)] = [
            ("Try this album", { h, id in await h.runner.mutate(id) { $0.albumTarget = rgSingle } }),
            ("a request from before round 18", { h, id in await h.runner.mutate(id) { $0.onlyTheSong = nil } }),
            ("a library artist (not a find)", { h, id in await h.runner.mutate(id) { $0.plan?.mode = .fallback } }),
            ("the song isn't matched to a track", { h, _ in h.server.with { $0.songImported = false; $0.songTitle = "Elsewhere" } }),
            ("kept", { h, _ in
                for var e in try await h.ledger.entries where e.lidarrArtistId == 42 { e.keptAt = h.clock.now; try await h.ledger.record(e) }
            }),
            ("monitored before Magpie", { h, _ in
                for var e in try await h.ledger.entries where e.albumId == 50 { e.wasMonitoredBefore = true; try await h.ledger.record(e) }
            }),
            ("a file outside the find's folder", { h, _ in
                h.server.with { s in s.extraFiles[0].path = "/music/library/Aurora Field/x.mp3"; s.extraFiles[0].onDisk = s.extraFiles[0].path }
            }),
            ("Not for me needing a look", { h, id in await h.runner.mutate(id) { $0.notForMeNeedsAttention = true } }),
        ]
        for (name, change) in cases {
            let h = await Harness(setup: Harness.findsSetup)
            let id = try await Self.readyWithOthers(h)
            try await change(h, id)
            Self.go(h)
            let before = h.server.writes.count
            await h.runner.tick()
            await h.runner.tick()
            #expect(Self.deletes(h, after: before).isEmpty, "\(name)")
            #expect(Self.trackFileIds(h).isSuperset(of: [1, 3]), "\(name)")
        }
    }

    /// Changes off: nothing is sent, and the trim waits (it goes once changes are on again).
    @Test func changesOffWaits() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyWithOthers(h)
        await h.gate.setEnabled(false)
        Self.go(h)
        await h.runner.tick()
        #expect(Self.trackFileIds(h) == [1, 2, 3])
        #expect(await h.request(id)?.trimDone == nil)
        await h.gate.setEnabled(true)
        await h.runner.tick()
        #expect(Self.trackFileIds(h) == [1])
    }

    /// Lidarr failing the delete: counted, and after `trimTryLimit` tries the release is left as it is.
    @Test func failuresAreBounded() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.readyWithOthers(h)
        Self.go(h)
        h.server.with { $0.deleteFails503 = 100 }
        for _ in 0..<(RequestRunner.trimTryLimit + 2) {
            h.clock.advance(60)
            await h.runner.tick()
        }
        let r = try #require(await h.request(id))
        #expect(r.trimDone == true && r.trimTries == RequestRunner.trimTryLimit)
        #expect(Self.trackFileIds(h) == [1, 2, 3])
    }

    // MARK: - Not for me on any downloaded find

    /// A find whose plan named the artist (a second song of a find artist, or round 17's next release) can be let go.
    @Test func notForMeWhenThePlanNamedTheArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        await h.runner.mutate(id) { $0.plan?.lidarrArtistId = 42 }
        #expect(await h.request(id)?.plan?.artistExistsInLidarr == true)
        _ = try await h.runner.notForMeCheck(id)
        #expect(try await h.runner.notForMe(id, permanentConfirmed: false) == .removed)
        #expect(await h.request(id)?.state == .dismissed)
    }

    /// A ready find can't be removed from Activity (that left its songs with no way to let them go).
    @Test func aReadyFindIsNotForgotten() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        #expect(await h.request(id)?.canBeRemoved == false)
        await h.runner.forget(id)
        #expect(await h.request(id) != nil)
    }

    /// A find no request is on any more (removed from Activity before round 18): its request is put back from the ledger
    /// and Lidarr (nothing written), then Not for me goes through it with every check.
    @Test func recoversAFindWithNoRequest() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let old = try await NotForMeTests.readyFind(h)
        await h.runner.mutate(old) { $0.state = .failed(reason: .unknown) }   // stands in for a forgotten request
        let before = h.server.writes.count

        #expect(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: "Someone Else", album: "Lowlands (single)") == nil)
        #expect(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: "A", album: "Another Album") == nil)
        #expect(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: "A", artistMBID: mbid(999),
                                           album: "Lowlands (single)") == nil, "the song's artist MBID wins over its name")
        let id = try #require(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: " a ",
                                                         album: "Lowlands (single)"))
        #expect(h.server.writes.count == before, "putting the request back writes nothing")
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.isFind && r.albumId == 50 && r.lidarrArtistId == 42 && r.songId == "find-1" && r.trimDone == true)
        #expect(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: "A", album: "Lowlands (single)") == id,
                "asked again: the same request")

        #expect(try await h.runner.notForMe(id, permanentConfirmed: false) == .removed)
        #expect(Self.trackFileIds(h).isEmpty)
    }

    /// Never for an artist Magpie didn't create, or one that's kept.
    @Test func recoversOnlyMagpiesFinds() async throws {
        for kept in [false, true] {
            let h = await Harness(setup: Harness.findsSetup)
            let old = try await NotForMeTests.readyFind(h)
            await h.runner.mutate(old) { $0.state = .failed(reason: .unknown) }
            for var e in try await h.ledger.entries where e.lidarrArtistId == 42 {
                if kept { e.keptAt = h.clock.now } else { e.createdArtist = false }
                try await h.ledger.record(e)
            }
            #expect(await h.runner.recoverFind(songId: "find-1", title: "Song", artist: "A", album: "Lowlands (single)") == nil,
                    "kept: \(kept)")
        }
    }
}

/// Round 19 (FindFlowIT): a release that is just the song is left monitored (nothing else could come back), so a Keep's
/// lossless upgrade still arrives.
@Suite struct OnlyTheSongSingleTests {
    @Test func aReleaseOfJustTheSongStaysMonitored() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.server.with { $0.commands.append(FakeLidarr.Command(id: 990, name: "RefreshArtist", status: "started", artistIds: [42])) }
        h.library.state.withLock { $0.indexed[recSingleAndAlbum] = "find-1" }
        await h.runner.tick()
        h.server.with { s in
            s.songImported = true
            for i in s.commands.indices where s.commands[i].id == 990 { s.commands[i].status = "completed" }
        }
        await h.runner.tick()
        #expect(await h.request(id)?.trimDone == true)
        #expect(!h.server.writeBodies().contains { $0.0 == "PUT album/monitor" && $0.1["monitored"] as? Bool == false })
        #expect(h.server.with { s in s.albums.first { $0.id == 50 }?.monitored } == true)
    }
}
