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
        #expect(preview == .notListed(artistId: 7, single: rgSingle), "the single the switch would list")
    }

    @Test func aNewArtistsSongPreviewsItsSmallestRelease() async throws {
        let h = await Harness(setup: Self.setup)
        h.server.artistIsNew()
        #expect(try await h.runner.targetPreview(h.recording(recSingleAndAlbum)) == .newArtist(title: "Release 2", isAlbum: false))
        #expect(try await h.runner.targetPreview(h.recording(recAlbumOnly)) == .newArtist(title: "Release 4", isAlbum: true))
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
        #expect(writes.map(\.0) == ["DELETE trackfile/bulk", "PUT album/monitor"])
        #expect(Set(writes[0].1["trackFileIds"] as? [Int] ?? []) == [2, 3], "that album's files, all of them")
        #expect(writes[1].1["albumIds"] as? [Int] == [33] && writes[1].1["monitored"] as? Bool == false)
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

    // MARK: - 4. Singles switch, any artist (D146)

    /// An owner-added artist (id 20, metadata profile 5, following "all" new releases) whose listing gains the target
    /// single (rg T, album 2) and two other singles (3, 4) on the refresh. Lidarr marks the new ones monitored (the
    /// worst case); album 1 was there before, with files.
    final class SinglesLidarr: @unchecked Sendable {
        let transport = MockTransport()
        let client: LidarrClient
        let ledger: Ledger
        let gate: LidarrWriteGate
        private let lock = NSLock()
        private var refreshed = false
        var refreshFails = false
        var everyReleaseHasFiles = false
        static let target = MBID("55555555-5555-4555-8555-555555555555")!

        init(changesOn: Bool = true) async {
            client = LidarrClient(base: ArtistLidarrTests.base, apiKey: "devkey", transport: transport)
            ledger = Ledger(fileURL: nil, instance: client.instanceScope)
            let dir = FileManager.default.temporaryDirectory.appending(path: "Singles-\(UUID().uuidString)")
            gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"),
                                   defaultsSuite: "Singles.\(UUID().uuidString)",
                                   confinement: WriteConfinement(ledger: ledger, roots: {
                                       WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: nil, findTagId: nil)
                                   }))
            await gate.setEnabled(changesOn)
            ArtistAddChoicesTests.stubProfiles(transport, existing: [])
            transport.stub(pathSuffix: "/api/v1/artist/20", body: Data(#"""
            {"id":20,"artistName":"Owner","foreignArtistId":"\#(ArtistLidarrTests.ownerMBID.rawValue)","monitored":true,
             "tags":[],"metadataProfileId":5,"monitorNewItems":"all","path":"/music/library/Owner"}
            """#.utf8))
            transport.stub(pathSuffix: "/api/v1/album") { [self] _ in
                let after = lock.withLock { refreshed }
                var rows: [[String: Any]] = [["id": 1, "title": "Album", "artistId": 20, "foreignAlbumId": mbid(901).rawValue,
                                              "monitored": true, "statistics": ["trackFileCount": 10]]]
                if after {
                    rows += [["id": 2, "title": "Target", "artistId": 20, "foreignAlbumId": Self.target.rawValue, "monitored": true],
                             ["id": 3, "title": "Other single", "artistId": 20, "foreignAlbumId": mbid(903).rawValue, "monitored": true],
                             ["id": 4, "title": "Old single", "artistId": 20, "foreignAlbumId": mbid(904).rawValue, "monitored": false]]
                }
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: rows))
            }
            transport.stub(pathSuffix: "/api/v1/trackfile") { [self] _ in
                .init(status: 200, body: Data((everyReleaseHasFiles ? #"[{"id":7,"path":"/x","albumId":1}]"# : "[]").utf8))
            }
            transport.stub(pathSuffix: "/api/v1/command") { _ in .init(status: 200, body: Data(#"[{"id":9,"name":"RefreshArtist","status":"completed"}]"#.utf8)) }
            transport.stub(method: "POST", pathSuffix: "/api/v1/command") { [self] _ in
                if refreshFails { return .init(status: 500) }
                lock.withLock { refreshed = true }
                return .init(status: 201, body: Data(#"{"id":9}"#.utf8))
            }
            transport.stub(method: "PUT", pathSuffix: "/api/v1/artist/editor", body: Data("[]".utf8))
            transport.stub(method: "PUT", pathSuffix: "/api/v1/album/monitor", body: Data("[]".utf8))
        }

        var writes: [(String, [String: Any])] {
            transport.requests.filter { ($0.httpMethod ?? "GET") != "GET" }.map { r in
                ("\(r.httpMethod!) \(r.url!.path.replacingOccurrences(of: "/api/v1/", with: ""))",
                 (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:])
            }
        }
    }

    struct ProfileBody: Encodable, Sendable { var artistIds: [Int]; var metadataProfileId: Int }
    struct UnmonitorBody: Encodable, Sendable { var albumIds: [Int]; var monitored: Bool }

    static var singles: ReleaseTypes {
        var types = ReleaseTypes.standard
        types.kinds = .albumsEPsAndSingles
        return types
    }

    @Test func anOwnersArtistEndsWithOnlyTheTargetNewlyMonitoredAndFollowingRestored() async throws {
        let fake = await SinglesLidarr()
        try await ArtistLidarr.includeSingles(artistId: 20, target: SinglesLidarr.target, types: Self.singles,
                                              lidarr: fake.client, gate: fake.gate, checks: 2, pause: .zero)
        let writes = fake.writes
        #expect(writes.map(\.0) == ["PUT artist/editor", "POST metadataprofile", "PUT artist/editor", "POST command",
                                    "PUT album/monitor", "PUT artist/editor"])
        #expect(writes[0].1["monitorNewItems"] as? String == "none" && writes[0].1.count == 2, "first: nothing new monitored")
        #expect(writes[2].1["metadataProfileId"] as? Int == 20, "Magpie's singles profile")
        #expect(writes[3].1["name"] as? String == "RefreshArtist")
        #expect(writes[4].1["albumIds"] as? [Int] == [3] && writes[4].1["monitored"] as? Bool == false,
                "the new single that isn't the target goes back to unmonitored; the target and the old ones stay")
        #expect(writes[5].1["monitorNewItems"] as? String == "all", "following restored")
        let log = await fake.gate.changeLog()
        #expect(log.first?.method == "NOTE"
                && log.first?.bodySummary == LidarrWriteGate.singlesNote(artistId: 20, metadataProfileId: 5, monitorNewItems: "all"),
                "the undo is saved before the first write")
    }

    @Test func undoRestoresTheSavedProfileAndNothingElse() async throws {
        let fake = await SinglesLidarr()
        try await ArtistLidarr.includeSingles(artistId: 20, target: SinglesLidarr.target, types: Self.singles,
                                              lidarr: fake.client, gate: fake.gate, checks: 2, pause: .zero)
        let before = fake.writes.count
        try await ArtistLidarr.undoSingles(artistId: 20, gate: fake.gate)
        let undo = Array(fake.writes.dropFirst(before))
        #expect(undo.map(\.0) == ["PUT artist/editor"] && undo[0].1["metadataProfileId"] as? Int == 5)
        // Any other profile that isn't Magpie's is refused.
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "artist/editor", body: ProfileBody(artistIds: [20], metadataProfileId: 6),
                                         confinedAs: .singlesSwitch)
        }
        #expect(fake.writes.count == before + 1)
    }

    @Test func aFailureMidwayRestoresFollowingAndSaysSo() async throws {
        let fake = await SinglesLidarr()
        fake.refreshFails = true
        await #expect(throws: ArtistLidarr.SinglesError.failed(followingRestored: true)) {
            try await ArtistLidarr.includeSingles(artistId: 20, target: SinglesLidarr.target, types: Self.singles,
                                                  lidarr: fake.client, gate: fake.gate, checks: 2, pause: .zero)
        }
        let writes = fake.writes
        #expect(writes.last?.0 == "PUT artist/editor" && writes.last?.1["monitorNewItems"] as? String == "all")
        #expect(!writes.contains { $0.0 == "PUT album/monitor" })
    }

    @Test func withChangesOffNothingIsSent() async throws {
        let fake = await SinglesLidarr(changesOn: false)
        await #expect(throws: ArtistLidarrError.changesOff) {
            try await ArtistLidarr.includeSingles(artistId: 20, target: SinglesLidarr.target, types: Self.singles,
                                                  lidarr: fake.client, gate: fake.gate, checks: 1, pause: .zero)
        }
        #expect(fake.writes.isEmpty)
    }

    /// A release with files is never unmonitored by the switch's shape.
    @Test func theSwitchNeverUnmonitorsAReleaseWithFiles() async throws {
        let fake = await SinglesLidarr()
        fake.everyReleaseHasFiles = true
        await #expect(throws: WriteGateError.self) {
            _ = try await fake.gate.send("PUT", "album/monitor", body: UnmonitorBody(albumIds: [1], monitored: false),
                                         confinedAs: .singlesSwitch)
        }
        #expect(fake.writes.isEmpty)
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
