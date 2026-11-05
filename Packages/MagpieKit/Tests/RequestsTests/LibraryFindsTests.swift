import Foundation
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
        #expect(writes.map(\.0) == ["POST artist"])
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
                                                 intent: .library)
        await h.runner.settle()
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist", "POST command", "POST command"])
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

    @Test func addToLibraryNeedsTheLosslessPreferredProfile() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        await #expect(throws: RequestRunner.TryError.notSetUp) {
            _ = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, intent: .library)
        }
        #expect(h.server.writes.isEmpty)
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
        #expect(preview == .notListed(artistId: 7))
    }

    @Test func aNewArtistsSongPreviewsItsSmallestRelease() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        #expect(try await h.runner.targetPreview(h.recording(recSingleAndAlbum)) == .newArtist(title: "Release 2", isAlbum: false))
        #expect(try await h.runner.targetPreview(h.recording(recAlbumOnly)) == .newArtist(title: "Release 4", isAlbum: true))
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
        trial.artistExisted = true
        #expect(LibraryAdds.status(trial) == .onTrial)
        #expect(LibraryAdds.status(request(.cancelled)) == nil, "cancelled: the actions are offered again")
    }
}
