import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 22 (owner, 2026-11-06, D171–D174): "when the entire artist is added because you've decided to keep a find,
/// you should be given the option to keep or delete the single. When deleting the single, ensure that the artist isn't
/// deleted." Bring in more offers the choice only for a kept Single with an album or EP coming in; Keep it (the
/// default) sends nothing; Remove it waits until a release this Bring in more brought in holds the song with its file,
/// then deletes exactly the single's files (`ConfinedShape.keptSingleDelete`) and unmonitors it. Never the artist.
@Suite struct KeptSingleTests {
    /// The album's copy of the song, and a B-side on the single, as Lidarr lists them once they're in.
    static let albumCopyPath = "/music/library/Aurora Field/Lowlands (2016) [Album]/01 - Song.flac"
    static let singlePath = "/music/library/Aurora Field/" + FakeLidarr.songFile
    static let albumSong = Song(id: "album-1", title: "Song", artist: "Aurora Field", album: "Lowlands", duration: 200,
                                suffix: "flac")

    /// A kept find whose own release is the single (50); Lidarr's paths follow the move; the single has a B-side (2).
    static func keptSingle(_ h: Harness) async throws -> RequestID {
        let id = try await BringInMoreTests.keptFind(h)
        h.server.with { s in
            for i in s.artists.indices { s.artists[i].recorded = "/music/library/Aurora Field" }
            s.extraFiles.append(.init(id: 2, artistId: 42, albumId: 50,
                                      path: "/music/library/Aurora Field/Lowlands (2016)/02 - B-side.mp3",
                                      trackTitle: "B-side", trackRecording: mbid(150)))
        }
        return id
    }

    /// The album (51) arrives holding the song (file 3), and the library lists both copies.
    static func albumArrives(_ h: Harness, recording: MBID = recSingleAndAlbum, title: String = "Song") {
        h.server.with { s in
            s.extraFiles.append(.init(id: 3, artistId: 42, albumId: 51, path: albumCopyPath,
                                      trackTitle: title, trackRecording: recording))
            for i in s.albums.indices where s.albums[i].id == 51 { s.albums[i].trackFiles = 1 }
        }
        h.library.state.withLock {
            $0.titled = [(KeepTests.mainSong, singlePath), (albumSong, albumCopyPath)]
        }
    }

    static func deletes(_ h: Harness) -> [[Int]] {
        h.server.writeBodies().filter { $0.0 == "DELETE trackfile/bulk" }.map { $0.1["trackFileIds"] as? [Int] ?? [] }
    }

    static func unmonitors(_ h: Harness) -> [[Int]] {
        h.server.writeBodies().filter { $0.0 == "PUT album/monitor" && $0.1["monitored"] as? Bool == false }
            .map { $0.1["albumIds"] as? [Int] ?? [] }
    }

    static func artistDeletes(_ h: Harness) -> Int {
        h.server.writes.filter { $0.httpMethod == "DELETE" && ($0.url?.path.contains("/artist/") ?? false) }.count
    }

    /// One pass after the check interval.
    static func pass(_ h: Harness) async {
        h.clock.advance(RequestRunner.keptSingleCheckInterval + 1)
        await h.runner.tick()
    }

    // MARK: - The offer

    /// The kept release is a Single: the offer names it, and says which choices bring in an album or EP.
    @Test func offerNamesTheKeptSingle() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)

        let offer = try await h.runner.bringInOffer(id)

        #expect(offer.keptSingle == .init(albumId: 50, title: "Lowlands (single)"))
        #expect(offer.options[.albumsAndEPs]?.albumsOrEPs == 3)
        #expect(offer.options[.thisAlbum]?.albumsOrEPs == 1)
        #expect(offer.options[.everything]?.albumsOrEPs == 3, "the newer single (54) isn't an album or EP")
    }

    /// The kept release is an album: no single to keep or remove.
    @Test func noChoiceForAKeptAlbum() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 50 { s.albums[i].type = "Album" } }

        let offer = try await h.runner.bringInOffer(id)
        #expect(offer.keptSingle == nil)
    }

    /// Only singles come in (Everything with singles only left): nothing holds the song as an album would, so no choice
    /// is recorded even when Remove was asked for.
    @Test func noChoiceWhenOnlySinglesComeIn() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        h.server.with { s in for i in s.albums.indices where [51, 52, 53].contains(s.albums[i].id) { s.albums[i].monitored = true } }

        let offer = try await h.runner.bringInOffer(id)
        #expect(offer.options[.everything]?.albumIds == [54])
        #expect(offer.options[.everything]?.albumsOrEPs == 0)
        _ = try await h.runner.bringIn(id, choice: .everything, follow: false, removeSingle: true)
        #expect(await h.request(id)?.keptSingle == nil)
    }

    // MARK: - Keep it (the default)

    /// Keep it sends nothing: the album arrives with the song and the single stays, untouched.
    @Test func keepItSendsNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false)
        let ks = try #require(await h.request(id)?.keptSingle)
        #expect(ks.choice == .keep && ks.albumId == 50 && ks.bringIn == [51] && ks.outcome == nil)
        let before = h.server.writes.count

        Self.albumArrives(h)
        await Self.pass(h)
        await Self.pass(h)

        #expect(h.server.writes.count == before, "nothing is sent for a single that stays")
        #expect(await h.request(id)?.songId == "lib-1")
        // The window ends: the choice closes quietly.
        h.clock.advance(RequestRunner.keptSingleWindow)
        await Self.pass(h)
        #expect(await h.request(id)?.keptSingle?.outcome == .kept)
        // (A day on, the Keep's lossless watch searches again: its own write. Nothing removes or unmonitors anything.)
        #expect(Self.deletes(h).isEmpty && Self.unmonitors(h).isEmpty && Self.artistDeletes(h) == 0)
    }

    // MARK: - Remove it once the album is here

    /// Remove waits until the album holding the song has its file, then unmonitors the single and deletes exactly all
    /// of its files; never the artist, never another album. The kept song now plays the album's copy.
    @Test func removeWaitsForTheAlbumThenDeletesExactlyTheSingle() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: false, removeSingle: true)
        let ks = try #require(await h.request(id)?.keptSingle)
        #expect(ks.choice == .remove && ks.bringIn == [53, 52, 51])
        let before = h.server.writes.count

        await Self.pass(h)
        #expect(h.server.writes.count == before, "the album isn't here yet: nothing is sent")
        #expect(await h.request(id)?.keptSingle?.outcome == nil)

        Self.albumArrives(h)
        await Self.pass(h)

        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "DELETE trackfile/bulk"])
        #expect(Self.unmonitors(h) == [[50]])
        #expect(Self.deletes(h).map { Set($0) } == [[1, 2]], "exactly all of the single's files")
        #expect(Self.artistDeletes(h) == 0)
        #expect(h.server.with { $0.artists.map(\.id) } == [42], "the artist stays")
        #expect(h.server.with { $0.extraFiles.map(\.id) } == [3], "the album's copy stays")
        let r = try #require(await h.request(id))
        #expect(r.keptSingle?.outcome == .removed && r.keptSingle?.replacedBy == 51)
        #expect(r.songId == "album-1" && r.state == .kept, "the kept song is the album's copy now")
        #expect(h.relinked.withLock { $0.last.map { ($0.1, $0.2.id) } } ?? (nil, "") == ("lib-1", "album-1"))
        let entry = try #require(try await h.ledger.entry(albumId: 50))
        #expect(entry.keptSingleRemovalAt != nil && entry.keptSingleReplacedBy == 51)
        #expect(h.library.state.withLock { $0.repointed.map { "\($0.0)>\($0.1)" } } == ["lib-1>album-1"])

        // Done: later passes send nothing more.
        let after = h.server.writes.count
        await Self.pass(h)
        #expect(h.server.writes.count == after)
    }

    /// The choice can be changed on the request's page while the bring-in is under way.
    @Test func removeChosenLaterOnTheRequestPage() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false)
        #expect(await h.runner.setKeptSingle(id, remove: true))
        #expect(await h.request(id)?.keptSingle?.choice == .remove)

        Self.albumArrives(h)
        await Self.pass(h)
        #expect(Self.deletes(h).map { Set($0) } == [[1, 2]])
        #expect(Self.artistDeletes(h) == 0)
        #expect(await h.runner.setKeptSingle(id, remove: false) == false, "settled: no change any more")
    }

    /// The album never arrives within the bring-in window: the single stays, and why is recorded.
    @Test func nothingDeletedWhenTheAlbumNeverArrives() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, removeSingle: true)
        let before = h.server.writes.count

        await Self.pass(h)
        #expect(h.server.writes.count == before)
        h.clock.advance(RequestRunner.keptSingleWindow)
        await Self.pass(h)

        // (A day on, the Keep's lossless watch searches again: its own write. Nothing removes or unmonitors anything.)
        #expect(Self.deletes(h).isEmpty && Self.unmonitors(h).isEmpty && Self.artistDeletes(h) == 0)
        #expect(await h.request(id)?.keptSingle?.outcome == .albumDidNotArrive)
        Self.albumArrives(h)
        await Self.pass(h)
        #expect(Self.deletes(h).isEmpty && Self.unmonitors(h).isEmpty, "too late: the single stays")
    }

    /// The bring-in is called off (its albums unmonitored): the single stays.
    @Test func nothingDeletedWhenTheBringInIsCancelled() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, removeSingle: true)
        let before = h.server.writes.count
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 51 { s.albums[i].monitored = false } }

        await Self.pass(h)

        #expect(h.server.writes.count == before)
        #expect(await h.request(id)?.keptSingle?.outcome == .albumDidNotArrive)
    }

    /// The album arrived but holds no copy of the song (neither the recording nor the title): the single stays.
    @Test func nothingDeletedWhenTheAlbumHoldsNoCopy() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, removeSingle: true)
        let before = h.server.writes.count

        Self.albumArrives(h, recording: recAlbumOnly, title: "Something Else")
        await Self.pass(h)

        #expect(h.server.writes.count == before)
        #expect(await h.request(id)?.keptSingle?.outcome == .noCopy)
    }

    /// The album's copy isn't listed by the library yet: wait (nothing deleted until it can play in the single's place).
    @Test func waitsUntilTheLibraryListsTheAlbumsCopy() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, removeSingle: true)
        let before = h.server.writes.count
        Self.albumArrives(h)
        h.library.state.withLock { $0.titled = [(KeepTests.mainSong, Self.singlePath)] }

        await Self.pass(h)
        #expect(h.server.writes.count == before)
        #expect(h.library.state.withLock { $0.folderScans } == ["/music/library/Aurora Field"])
        #expect(await h.request(id)?.keptSingle?.outcome == nil)

        h.library.state.withLock { $0.titled = [(KeepTests.mainSong, Self.singlePath), (Self.albumSong, Self.albumCopyPath)] }
        await Self.pass(h)
        #expect(Self.deletes(h).map { Set($0) } == [[1, 2]])
    }

    /// The owner's playlists couldn't be pointed at the album's copy: nothing is deleted yet.
    @Test func waitsWhenPlaylistsCantBeRepointed() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false, removeSingle: true)
        let before = h.server.writes.count
        Self.albumArrives(h)
        h.library.state.withLock { $0.repointFails = true }

        await Self.pass(h)
        #expect(h.server.writes.count == before)
        #expect(await h.request(id)?.keptSingle?.outcome == nil)
    }

    // MARK: - The gate (ConfinedShape.keptSingleDelete)

    /// A ready removal: the album has arrived and the ledger holds the intent; returns the request.
    static func intentRecorded(_ h: Harness) async throws -> RequestID {
        let id = try await Self.keptSingle(h)
        _ = try await h.runner.bringIn(id, choice: .thisAlbum, follow: false)
        Self.albumArrives(h)
        let at = h.clock.now
        try await h.ledger.update(albumId: 50) {
            $0.keptSingleRemovalAt = at
            $0.keptSingleReplacedBy = 51
        }
        return id
    }

    static func send(_ h: Harness, _ ids: [Int]) async throws {
        _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: ids),
                                  confinedAs: .keptSingleDelete)
    }

    static func refused(_ h: Harness, _ ids: [Int] = [1, 2]) async -> Bool {
        do {
            try await send(h, ids)
            return false
        } catch WriteGateError.forbidden {
            return true
        } catch {
            return false
        }
    }

    @Test func gateAllowsExactlyTheSinglesFiles() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        try await Self.send(h, [1, 2])
        #expect(Self.deletes(h).map { Set($0) } == [[1, 2]])
    }

    @Test func gateRefusesAPartialFileSet() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        #expect(await Self.refused(h, [1]))
        #expect(await Self.refused(h, [1, 2, 3]), "never another album's file")
        #expect(Self.deletes(h).isEmpty)
    }

    @Test func gateRefusesAnAlbumNotMagpies() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        try await h.ledger.update(albumId: 50) { $0.createdArtist = false }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesAnAlbumNotKept() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        try await h.ledger.update(artistId: 42) { $0.keptAt = nil }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesWhileAKeepIsUnderWay() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        let at = h.clock.now
        try await h.ledger.update(albumId: 50) { $0.keepIntentAt = at }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesAnAlbumMonitoredBeforeMagpie() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        try await h.ledger.update(albumId: 50) { $0.wasMonitoredBefore = true }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesWithoutTheRecordedIntent() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        try await h.ledger.update(albumId: 50) { $0.keptSingleRemovalAt = nil }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesWhenTheAlbumHasNoFiles() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        h.server.with { $0.extraFiles.removeAll { $0.id == 3 } }
        #expect(await Self.refused(h))
    }

    @Test func gateRefusesARelease() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.intentRecorded(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 50 { s.albums[i].type = "Album" } }
        #expect(await Self.refused(h), "only a Single")
    }

    /// The unmonitor goes through the album monitor confinement: a kept album only with the removal recorded.
    @Test func unmonitorOfAKeptAlbumNeedsTheIntent() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await Self.keptSingle(h)
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("PUT", "album/monitor", body: RequestRunner.AlbumMonitorBody(albumIds: [50], monitored: false))
        }
        let at = h.clock.now
        try await h.ledger.update(albumId: 50) { $0.keptSingleRemovalAt = at; $0.keptSingleReplacedBy = 51 }
        _ = try await h.gate.send("PUT", "album/monitor", body: RequestRunner.AlbumMonitorBody(albumIds: [50], monitored: false))
        #expect(Self.unmonitors(h) == [[50]])
    }
}
