import Foundation
import MagpieTestSupport
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 15 C3 (owner item 6, D135, D136, D139): Try (temporary) and Add to library (permanent) through the existing
/// runner and gate, for each kind of artist.
@Suite struct LibraryFindsTests {
    /// Finds set up, and "Magpie Lossless Preferred" (id 12) provisioned.
    static let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: 4, metadataProfileId: 3,
                                           tagIds: [1], finds: .init(rootFolderPath: "/music/samples", tagIds: [1, 2]),
                                           libraryQualityProfileId: 12)

    // MARK: - 1. An artist not in Lidarr

    /// Try works as before: the Finds root, Fast Start (MP3), only this release monitored, search on add.
    @Test func tryOnANewArtistGoesIntoFindsAsBefore() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum,
                                                 intent: .trial)
        await h.runner.settle()
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist", "POST command"])
        #expect(writes[0].1["rootFolderPath"] as? String == "/music/samples")
        #expect(writes[0].1["qualityProfileId"] as? Int == 4, "Fast Start")
        let options = try #require(writes[0].1["addOptions"] as? [String: Any])
        #expect(options["albumsToMonitor"] as? [String] == [rgAlbum.rawValue])
        let r = try #require(await h.request(id))
        #expect(r.askedAsTry && !r.addToLibrary && r.isFind)
    }

    /// Add to library: the main root, monitored, lossless preferred, the whole discography monitored; this release is
    /// searched first, then the rest (ArtistSearch, allowed for an artist Magpie added).
    @Test func addToLibraryOnANewArtistBringsTheDiscographyLosslessPreferredTargetFirst() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum,
                                                 intent: .library,
                                                 libraryAdd: .init(metadataProfileId: 14, follow: true))
        await h.runner.settle()
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist", "POST command", "POST command"])
        #expect(writes[0].1["metadataProfileId"] as? Int == 14, "the owner's Add defaults, never the Finds profile (M2)")
        #expect(writes[0].1["monitorNewItems"] as? String == "all", "their following")
        let add = writes[0].1
        #expect(add["rootFolderPath"] as? String == "/music/library", "the main root, never Finds")
        #expect(add["qualityProfileId"] as? Int == 12, "lossless preferred")
        #expect(add["tags"] as? [Int] == [1], "magpie, never magpie-find")
        #expect(add["monitored"] as? Bool == true)
        let options = try #require(add["addOptions"] as? [String: Any])
        #expect(options["monitor"] as? String == "all", "the whole discography")
        #expect(options["searchForMissingAlbums"] as? Bool == false, "this release is searched first")
        #expect(writes[1].1["name"] as? String == "AlbumSearch" && writes[1].1["albumIds"] as? [Int] == [51])
        #expect(writes[2].1["name"] as? String == "ArtistSearch", "then the rest")
        let r = try #require(await h.request(id))
        #expect(r.addToLibrary && !r.isFind && r.discographySearched == true)
    }

    /// Review M3: only a new artist's add needs the lossless-preferred profile; without it that add is never sent (never
    /// with Fast Start), while Add to library on an artist already in Lidarr goes ahead without it.
    @Test func onlyANewArtistsAddNeedsTheLosslessPreferredProfile() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        _ = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, intent: .library)
        await h.runner.settle()
        #expect(!h.server.writeBodies().contains { $0.0 == "POST artist" })
        let library = await Harness(setup: Harness.findsSetup)
        library.server.ownerHasArtist(albumMonitored: false)
        _ = try await library.runner.tryRecording(library.recording(recSingleAndAlbum), tier: .standard, album: rgLive,
                                                  intent: .library)
        await library.runner.settle()
        #expect(library.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
    }

    // MARK: - 2. A find artist (on trial now)

    /// Add to library on a find: the release joins the find (it is a find), and is kept on arrival by the app (the
    /// existing Keep moves the artist; Bring in more brings the rest, lossless preferred).
    @Test func addToLibraryOnAFindArtistIsAFindKeptOnArrival() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        _ = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, intent: .trial)   // the single
        await h.runner.settle()
        let adds = h.server.writeBodies().filter { $0.0 == "POST artist" }.count
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard, album: rgAlbum,
                                                 intent: .library)
        await h.runner.settle()
        let r = try #require(await h.request(id))
        #expect(r.isFind && r.addToLibrary, "the album joins the trial, to be kept on arrival")
        #expect(h.server.writeBodies().filter { $0.0 == "POST artist" }.count == adds, "never a second artist")
        var ready = r
        ready.state = .ready
        ready.songId = "s1"
        #expect(LibraryAdds.step(ready) == .keep(r.id))
    }

    // MARK: - 3. An artist already in the main library

    /// Add to library: this release monitored and searched; the artist (and its profile) untouched.
    @Test func addToLibraryOnALibraryArtistMonitorsAndSearchesThatReleaseOnly() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgLive,
                                                 intent: .library)
        await h.runner.settle()
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(writes[0].1["albumIds"] as? [Int] == [33])
        #expect(!writes.contains { $0.0.hasPrefix("PUT artist") }, "never the artist's profile")
        let r = try #require(await h.request(id))
        #expect(!r.isLibraryTrial && r.artistExisted == true)
    }

    /// Try on a library artist: no Finds folder for one release (Lidarr keeps one path per artist, D139), so it comes
    /// into the main library marked as a trial; the artist's profile is never changed for it.
    @Test func tryOnALibraryArtistIsATrialInTheMainLibrary() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgLive,
                                                 intent: .trial)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command"])
        let r = try #require(await h.request(id))
        #expect(r.isLibraryTrial && !r.isFind)
        var kept = r
        kept.trialKept = true
        #expect(!kept.isLibraryTrial, "Keep clears the mark")
    }

    /// The smallest release the artist's listing has that holds the song (never one Lidarr doesn't list).
    @Test func aSongComesWithTheSmallestListedRelease() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.ownerHasArtist(albumMonitored: false)   // lists the album and the live album, not the single
        let preview = try await h.runner.targetPreview(h.recording(recSingleAndAlbum))
        #expect(preview == .listed(title: "Lowlands", isAlbum: true))
        #expect(h.server.writes.isEmpty, "reads only")
    }

    @Test func aSongNoListedReleaseHoldsNeedsSingles() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { s in s.albums.removeAll() }   // the artist lists nothing that holds it
        let preview = try await h.runner.targetPreview(h.recording(recSingleAndAlbum))
        #expect(preview == .notListed(artistId: 7, single: rgSingle), "the single the switch would list")
    }

    @Test func aNewArtistsSongPreviewsItsSmallestRelease() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        #expect(try await h.runner.targetPreview(h.recording(recSingleAndAlbum)) == .newArtist(title: "Release 2", isAlbum: false, primaryType: "Single", secondaryTypes: []))
        #expect(try await h.runner.targetPreview(h.recording(recAlbumOnly)) == .newArtist(title: "Release 4", isAlbum: true, primaryType: "Album", secondaryTypes: []))
    }

    // MARK: - 3b. A library trial's Keep and Reject (D147)

    /// The library artist's live album (33) tried: Magpie monitors it, unmonitored with no files just before.
    private func libraryTrial(_ h: Harness, filesBefore: Bool = false) async throws -> RequestID {
        h.server.ownerHasArtist(albumMonitored: false)
        if filesBefore {
            h.server.with { s in
                for i in s.albums.indices where s.albums[i].id == 33 { s.albums[i].trackFiles = 1 }
                s.extraFiles.append(.init(id: 2, artistId: 7, albumId: 33, path: "/music/library/Aurora Field/Live/01.flac"))
            }
        }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgLive,
                                                 intent: .trial)
        await h.runner.settle()
        // The release arrives: two files of the trial album, and one of the artist's other album.
        h.server.with { s in
            if !filesBefore {
                s.extraFiles.append(.init(id: 2, artistId: 7, albumId: 33, path: "/music/library/Aurora Field/Live/01.flac"))
            }
            s.extraFiles.append(.init(id: 3, artistId: 7, albumId: 33, path: "/music/library/Aurora Field/Live/02.flac"))
            s.extraFiles.append(.init(id: 4, artistId: 7, albumId: 31, path: "/music/library/Aurora Field/Lowlands/01.flac"))
        }
        return id
    }

    @Test func theTrialIsRecordedWithItsEndDate() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        let r = try #require(await h.request(id))
        let expected = h.clock.now.addingTimeInterval(14 * 86_400)
        #expect(r.isLibraryTrial && r.trialExpiresAt.map { abs($0.timeIntervalSince(expected)) < 60 } == true)
        let entry = try #require(try await h.ledger.entry(albumId: 33))
        #expect(entry.isOpenTrial && entry.trialHadNoFiles == true && entry.rgMbid == rgLive && !entry.wasMonitoredBefore)
    }

    @Test func rejectDeletesOnlyThatAlbumsFilesThenUnmonitorsIt() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        let before = h.server.writes.count
        #expect(await h.runner.trialRejectable(id))
        try await h.runner.rejectTrial(id)
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "DELETE trackfile/bulk"], "unmonitored first (I6)")
        #expect(Set(writes[1].1["trackFileIds"] as? [Int] ?? []) == [2, 3], "that album's files, all of them")
        #expect(writes[0].1["albumIds"] as? [Int] == [33] && writes[0].1["monitored"] as? Bool == false)
        #expect(h.server.with { $0.extraFiles.map(\.id) } == [4], "the artist's other album untouched")
        #expect(!h.server.writeBodies().contains { $0.0.hasPrefix("DELETE artist") }, "never the artist")
        let r = try #require(await h.request(id))
        #expect(!r.isLibraryTrial && r.trialRejected == true && r.state == .dismissed)
        #expect(try await h.ledger.entry(albumId: 33)?.trialRejectedAt != nil)
    }

    @Test func anAlbumThatHadFilesBeforeIsNeverATrialAndTheGateRefusesIt() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h, filesBefore: true)
        #expect(await h.request(id)?.isLibraryTrial == false, "the owner's files: not a trial")
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.TrialError.notATrial) { try await h.runner.rejectTrial(id) }
        // Straight at the gate: refused, nothing sent.
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: [2, 3]),
                                      confinedAs: .trialDelete)
        }
        #expect(h.server.writes.count == before)
    }

    @Test func aRecheckOnChangedStateRefusesAndSendsNothing() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        // Meanwhile Lidarr lists another release under that album id.
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 33 { s.albums[i].rg = rgSingle } }
        let before = h.server.writes.count
        #expect(await h.runner.trialRejectable(id) == false, "the app's read-only check says no first")
        await #expect(throws: RequestRunner.TrialError.refused) { try await h.runner.rejectTrial(id) }
        #expect(h.server.writes.count == before, "nothing sent")
        // And a delete that isn't exactly the album's files (another album's file slipped in) is refused too.
        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 33 { s.albums[i].rg = rgLive } }
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: [2, 3, 4]),
                                      confinedAs: .trialDelete)
        }
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: [2]),
                                      confinedAs: .trialDelete)
        }
        #expect(h.server.writes.count == before)
    }

    @Test func keepClearsTheMarkAndNoRejectFollows() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        let before = h.server.writes.count
        try await h.runner.keepTrial(id)
        #expect(await h.request(id)?.isLibraryTrial == false && h.server.writes.count == before, "nothing written: it stays monitored")
        #expect(try await h.ledger.entry(albumId: 33)?.isOpenTrial == false)
        await #expect(throws: RequestRunner.TrialError.notATrial) { try await h.runner.rejectTrial(id) }
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: [2, 3]),
                                      confinedAs: .trialDelete)
        }
        #expect(h.server.writes.count == before)
    }

    /// Review I4: a closed ledger entry (the request cancelled, failed or given up) is never an open trial: the gate refuses
    /// its files, whatever the owner did with the album since.
    @Test func aClosedTrialEntryIsRefusedAtTheGate() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        let at = h.clock.now
        try await h.ledger.update(albumId: 33) { $0.closedAt = at }
        #expect(try await h.ledger.entry(albumId: 33)?.isOpenTrial == false)
        let before = h.server.writes.count
        #expect(await h.runner.trialRejectable(id) == false)
        await #expect(throws: WriteGateError.self) {
            _ = try await h.gate.send("DELETE", "trackfile/bulk", body: RequestRunner.TrackFileIdsBody(trackFileIds: [2, 3]),
                                      confinedAs: .trialDelete)
        }
        #expect(h.server.writes.count == before)
    }

    /// Review I6: Reject unmonitors first; when that fails, nothing is deleted (the release can't come back by itself).
    @Test func aRejectWhoseUnmonitorFailsDeletesNothing() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        h.server.with { $0.monitorFails503 = 5 }
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.TrialError.self) { try await h.runner.rejectTrial(id) }
        #expect(!h.server.writeBodies().dropFirst(before).contains { $0.0.hasPrefix("DELETE") }, "nothing deleted")
        #expect(h.server.with { Set($0.extraFiles.map(\.id)) } == [2, 3, 4])
        #expect(await h.request(id)?.isLibraryTrial == true, "still on trial: Reject can be tried again")
    }

    /// Review I5: Navidrome groups another release with the same name into the trial's album; only the trial's own files'
    /// songs leave playlists, by path. A file with no matching song is counted and left alone.
    @Test func aTrialsSongsAreItsFilesNotTheSameNamedAlbum() {
        func song(_ id: String) -> Song { Song(id: id, title: "T\(id)", artist: "A", album: "Lowlands Live", duration: 100) }
        let files = [TrackFile(id: 2, path: "/music/library/Aurora Field/Lowlands Live (2001)/01.flac", albumId: 33, artistId: 7),
                     TrackFile(id: 3, path: "/music/library/Aurora Field/Lowlands Live (2001)/02.flac", albumId: 33, artistId: 7),
                     TrackFile(id: 5, path: "/music/library/Aurora Field/Lowlands Live (2001)/03.flac", albumId: 33, artistId: 7)]
        let candidates: [(song: Song, lidarrPath: String)] = [
            (song("t1"), "/music/library/Aurora Field/Lowlands Live (2001)/01.flac"),
            (song("t2"), "/music/library/Aurora Field/Lowlands Live (2001)/02.flac"),
            // The owner's own release of the same name, merged into one Navidrome album.
            (song("o1"), "/music/library/Aurora Field/Lowlands Live (2019)/01.flac"),
            (song("o2"), "/music/library/Aurora Field/Lowlands Live (2019)/02.flac"),
        ]
        let match = TrialSongs.match(files: files, candidates: candidates)
        #expect(match.ids == ["t1", "t2"], "never the owner's songs")
        #expect(match.unmatched == 1, "03 has no song: left alone, and said")
    }

    /// Re-review m7: Keep after a Reject whose delete failed (the album left unmonitored) monitors it again.
    @Test func keepAfterAFailedDeleteMonitorsTheAlbumAgain() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        h.server.with { $0.bulkDelete = .rejects }
        await #expect(throws: RequestRunner.TrialError.needsAttention) { try await h.runner.rejectTrial(id) }
        #expect(h.server.with { $0.albums.first { $0.id == 33 }?.monitored } == false)
        let before = h.server.writes.count
        try await h.runner.keepTrial(id)
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor"] && writes[0].1["monitored"] as? Bool == true)
        #expect(await h.request(id)?.isLibraryTrial == false)
    }

    /// Re-review R2: a new artist's add always lists the release asked for: the owner's types widened to its kind.
    @Test func theAddsTypesAlwaysListTheTarget() throws {
        let albumsOnly = ReleaseTypes(kinds: .albums)
        let ep = try #require(albumsOnly.widened(toInclude: "EP", secondaryTypes: []))
        #expect(ep.includes(albumType: "EP", secondaryTypes: []) && ep.kinds == .albumsAndEPs)
        let single = try #require(albumsOnly.widened(toInclude: "Single", secondaryTypes: []))
        #expect(single.kinds == .albumsEPsAndSingles)
        var noStudio = ReleaseTypes.standard
        noStudio.studio = false
        noStudio.live = true
        #expect(noStudio.widened(toInclude: "Album", secondaryTypes: [])?.studio == true)
        #expect(albumsOnly.widened(toInclude: "Album", secondaryTypes: ["Live"])?.live == true)
        #expect(albumsOnly.widened(toInclude: "Broadcast", secondaryTypes: []) == nil, "can't be expressed: refused")
        #expect(albumsOnly.widened(toInclude: "Album", secondaryTypes: ["Compilation"]) == nil)
    }

    /// R2: an album-page add previews that release group (its own type), not the first track's smallest release.
    @Test func anAlbumPagePreviewIsThatRelease() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        #expect(try await h.runner.targetPreview(h.recording(recSingleAndAlbum), album: rgAlbum)
                == .newArtist(title: "Release 1", isAlbum: true, primaryType: "Album", secondaryTypes: []))
        #expect(try await h.runner.targetPreview(h.recording(recSingleAndAlbum), album: rgSingle)
                == .newArtist(title: "Release 2", isAlbum: false, primaryType: "Single", secondaryTypes: []))
    }

    /// As Finds (D10): when the date passes, nothing is removed by itself; it still shows, with Keep and Reject.
    @Test func expiryRemovesNothingByItself() async throws {
        let h = await Harness(setup: Self.setup)
        let id = try await libraryTrial(h)
        let before = h.server.writes.count
        h.clock.advance(15 * 86_400)
        await h.runner.tick()
        await h.runner.settle()
        #expect(!h.server.writeBodies().dropFirst(before).contains { $0.0.hasPrefix("DELETE") })
        #expect(await h.request(id)?.isLibraryTrial == true)
    }

    // MARK: - Persistence and the status words (D136)

    @Test func theMarksSurviveARelaunchAndOlderFilesDecode() throws {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: recSingleAndAlbum, title: "S", artist: "A",
                                                           source: .lidarr), tier: .standard, createdAt: Date())
        r.addToLibrary = true
        r.askedAsTry = true
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(MagpieRequest.self, from: data)
        #expect(back.addToLibrary && back.askedAsTry)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "intoLibrary")
        json.removeValue(forKey: "tryOnly")
        let old = try JSONDecoder().decode(MagpieRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.addToLibrary && !old.askedAsTry)
    }

    private func request(_ state: RequestState, find: Bool = true, library: Bool = true, songId: String? = "s1") -> MagpieRequest {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: recSingleAndAlbum, title: "S", artist: "A",
                                                           source: .lidarr), tier: .standard, createdAt: Date())
        r.state = state
        r.songId = songId
        r.addToLibrary = library
        r.plan = Plan(recordingMBID: recSingleAndAlbum, releaseGroupMBID: rgAlbum, artistMBID: recSingleAndAlbum,
                      lidarrArtistId: 7, mode: find ? .finds : .fallback)
        return r
    }

    @Test func anArrivedFindForTheLibraryIsKeptOnceNotOtherwise() {
        let r = request(.ready)
        #expect(LibraryAdds.step(r) == .keep(r.id))
        #expect(LibraryAdds.step(request(.ready, library: false)) == .none)
        #expect(LibraryAdds.step(request(.ready, find: false)) == .none)
        var running = request(.ready)
        running.keep = KeepProgress(phase: .moving, startedAt: Date(), artistId: 7, fromPath: "/f", findsRoot: "/f",
                                    mainRoot: "/m", findTagId: 2, priorQualityProfileId: nil, commandBaseline: 0)
        #expect(LibraryAdds.step(running) == .none)
        var collided = request(.ready)
        collided.collision = true
        #expect(LibraryAdds.step(collided) == .none)
        var lettingGo = request(.ready)
        lettingGo.notForMeNeedsAttention = true
        #expect(LibraryAdds.step(lettingGo) == .none)
    }

    @Test func statusWordsFollowTheRequest() {
        #expect(LibraryAdds.status(request(.pending)) == .coming(nil))
        #expect(LibraryAdds.status(request(.downloading(progress: 0.4))) == .coming(0.4))
        #expect(LibraryAdds.status(request(.importing)) == .coming(nil))
        #expect(LibraryAdds.status(request(.failed(reason: .noRelease))) == .couldntBringIn)
        #expect(LibraryAdds.status(request(.ready, library: false)) == .onTrial)
        #expect(LibraryAdds.status(request(.ready)) == .coming(nil), "a find being kept is still coming")
        #expect(LibraryAdds.status(request(.ready, find: false)) == .inLibrary)
        #expect(LibraryAdds.status(request(.kept)) == .inLibrary)
        var trial = request(.ready, find: false, library: false)
        trial.askedAsTry = true
        trial.trialExpiresAt = Date()
        #expect(LibraryAdds.status(trial) == .onTrial)
        #expect(LibraryAdds.status(request(.cancelled)) == nil, "cancelled: the actions are offered again")
    }
}
