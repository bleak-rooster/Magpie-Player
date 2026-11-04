import Foundation
import MagpieCore
import Testing
@testable import Requests

private let recordingMBID = MBID("0b2c6a1e-0000-4000-8000-000000000003")!
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let linkedId = RequestID()

private func recording(mbid: MBID? = recordingMBID) -> ExternalRecording {
    ExternalRecording(recordingMBID: mbid, title: "Harbour Lights", artist: "The Tides", duration: 201, source: .lidarr)
}

private func add(request: RequestID? = nil, createdAt: Date = now) -> PendingPlaylistAdd {
    PendingPlaylistAdd(playlistId: "pl-1", playlistName: "Road trip", recording: recording(), requestId: request,
                       createdAt: createdAt)
}

private func request(_ state: RequestState, find: Bool = false, songId: String? = "s-1") -> MagpieRequest {
    var r = MagpieRequest(id: linkedId, recording: recording(), tier: .standard, createdAt: now)
    r.state = state
    r.songId = songId
    if find {
        r.plan = Plan(recordingMBID: recordingMBID, releaseGroupMBID: recordingMBID, artistMBID: recordingMBID,
                      lidarrArtistId: nil, mode: .finds)
    }
    return r
}

/// Round 14 A3 (Decision 5, D101): a song saved to a playlist before the library has it waits as a "Coming" row and is
/// added when it lands; "Just this song" (Decision 4) is kept on arrival first.
@Suite struct PendingPlaylistAddStepTests {
    @Test func justThisSongWaitsThenIsKeptThenAdded() {
        let a = add(request: linkedId)
        #expect(PendingPlaylistAdds.step(a, request: request(.downloading(progress: 0.4), find: true), now: now)
                == .waiting(.downloading(progress: 0.4)))
        let ready = request(.ready, find: true)
        #expect(PendingPlaylistAdds.step(a, request: ready, now: now) == .keep(ready.id), "a find: kept on arrival first")
        var moving = ready
        moving.keep = KeepProgress(phase: .moving, startedAt: now, artistId: 1, fromPath: "/finds/a", findsRoot: "/finds",
                                   mainRoot: "/music", findTagId: 1, priorQualityProfileId: nil, commandBaseline: 0)
        #expect(PendingPlaylistAdds.step(a, request: moving, now: now) == .waiting(.ready), "never kept twice")
        var kept = request(.kept, find: true, songId: "s-2")
        kept.relinkPending = true
        #expect(PendingPlaylistAdds.step(a, request: kept, now: now) == .waiting(.kept), "the moved song isn't found yet")
        kept.relinkPending = false
        #expect(PendingPlaylistAdds.step(a, request: kept, now: now) == .add(songId: "s-2"))
    }

    @Test func aSongThatWentStraightIntoTheLibraryIsAddedOnArrival() {
        let a = add(request: linkedId)
        #expect(PendingPlaylistAdds.step(a, request: request(.ready), now: now) == .add(songId: "s-1"))
        #expect(PendingPlaylistAdds.step(a, request: request(.ready, songId: nil), now: now) == .waiting(.ready))
    }

    @Test func aStoppedRequestFails() {
        let a = add(request: linkedId)
        #expect(PendingPlaylistAdds.step(a, request: request(.failed(reason: .noRelease)), now: now) == .failed)
        #expect(PendingPlaylistAdds.step(a, request: request(.cancelled), now: now) == .failed)
        #expect(PendingPlaylistAdds.step(a, request: nil, now: now) == .requestGone,
                "not in the list: never persisted as failed (the list may not be read yet; fix I1)")
        #expect(!PendingAddStep.requestGone.persistsFailure && PendingAddStep.failed.persistsFailure)
        var stuck = request(.ready, find: true)
        stuck.keepNeedsAttention = true
        #expect(PendingPlaylistAdds.step(a, request: stuck, now: now) == .failed)
        var failedKeep = request(.ready, find: true)
        failedKeep.keepFailed = true
        #expect(PendingPlaylistAdds.step(a, request: failedKeep, now: now) == .failed, "Retry keeps it again")
        var collided = request(.ready, find: true)
        collided.collision = true
        #expect(PendingPlaylistAdds.step(a, request: collided, now: now) == .add(songId: "s-1"),
                "it stays in your Finds, and still goes on the playlist")
        var marked = add(request: linkedId)
        marked.failedAt = now
        #expect(PendingPlaylistAdds.step(marked, request: request(.ready), now: now) == .failed)
    }

    @Test func wholeArtistLooksTheLibraryUpUntilItsLimit() {
        #expect(PendingPlaylistAdds.step(add(), request: nil, now: now) == .lookUp)
        let old = add(createdAt: now.addingTimeInterval(-PendingPlaylistAdds.wholeArtistLimit - 1))
        #expect(PendingPlaylistAdds.step(old, request: nil, now: now) == .failed)
    }

    @Test func theLibrarysSongByMBIDElseTitleArtistAndDurationNeverByNameAlone() {
        let byId = Song(id: "a", title: "Other title", artist: "x", album: "", duration: 10, recordingMBID: recordingMBID)
        let text = Song(id: "b", title: "harbour lights", artist: "THE TIDES", album: "", duration: 199)
        let longer = Song(id: "c", title: "Harbour Lights", artist: "The Tides", album: "", duration: 240)
        let noLength = Song(id: "d", title: "Harbour Lights", artist: "The Tides", album: "", duration: 0)
        #expect(PendingPlaylistAdds.librarySong(for: recording(), mbidMatches: [byId], textMatches: [text])?.id == "a")
        #expect(PendingPlaylistAdds.librarySong(for: recording(), mbidMatches: [], textMatches: [longer, text])?.id == "b")
        #expect(PendingPlaylistAdds.librarySong(for: recording(), mbidMatches: [], textMatches: [longer, noLength]) == nil)
        var noDuration = recording(mbid: nil)
        noDuration.duration = nil
        #expect(PendingPlaylistAdds.librarySong(for: noDuration, mbidMatches: [], textMatches: [text]) == nil)
        let wrongId = Song(id: "e", title: "Harbour Lights", artist: "The Tides", album: "", duration: 201,
                           recordingMBID: MBID("0b2c6a1e-0000-4000-8000-0000000000ff")!)
        #expect(PendingPlaylistAdds.librarySong(for: recording(), mbidMatches: [wrongId], textMatches: []) == nil)
    }
}

/// D101: the pending adds are kept beside the requests (one file per Lidarr, like `RequestStore`), decode leniently, and
/// go with them on sign-out. Requests saved before round 14 are untouched.
@Suite struct PlaylistAddStoreTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "PlaylistAddStoreTests-\(UUID().uuidString)")

    @Test func savesLoadsAndStartsEmpty() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PlaylistAddStore.defaultURL(in: dir, instance: "abc")
        #expect(url.lastPathComponent == "playlist-adds-abc.json")
        let store = PlaylistAddStore(fileURL: url)
        #expect(try await store.load().isEmpty, "no file: none")
        let a = add(request: linkedId)
        try await store.save([a])
        #expect(try await PlaylistAddStore(fileURL: url).load() == [a])
    }

    @Test func aDamagedFileIsSetAsideAndAJunkEntryDropped() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PlaylistAddStore.defaultURL(in: dir, instance: "abc")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(try await PlaylistAddStore(fileURL: url).load().isEmpty)
        let good = add()
        var rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as! [Any]
        rows.append(["playlistId": 4])
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        #expect(try await PlaylistAddStore(fileURL: url).load() == [good])
    }

    @Test func signOutRemovesThemWithTheRequestsAndOldRequestsStillDecode() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try await PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: dir, instance: "abc")).save([add()])
        let requests = RequestStore(fileURL: RequestStore.defaultURL(in: dir, instance: "abc"))
        try await requests.save([request(.ready)])
        #expect(try await requests.load().count == 1, "the requests file is as it was")
        RequestStore.eraseAll(in: dir)
        #expect(try await PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: dir, instance: "abc")).load().isEmpty)
    }
}
