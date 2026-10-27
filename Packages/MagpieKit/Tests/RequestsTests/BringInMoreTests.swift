import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task 7.1b, D5: after a Keep that moved the find into the library, "Bring in more from <artist>?" offers
/// Albums + EPs (preselected in the app), This album only, Everything, and a separate Follow new releases.
/// Additive only (G6 spirit): monitor + search albums that aren't monitored yet, never unmonitor, never touch the
/// owner's profiles; every write through the gate with the ledger saved first (M6); G7 limits.
@Suite struct BringInMoreTests {
    static let ep = mbid(20), second = mbid(21), bSide = mbid(22), early = mbid(23)

    /// A kept (moved) find, artist 42 in `/music/library`, whose Lidarr catalogue is: the find's single (50,
    /// monitored), "Lowlands" (51, the album the song is on), an EP (52), a newer album (53), a newer single (54),
    /// and an album the owner already monitors (55).
    static func keptFind(_ h: Harness) async throws -> RequestID {
        let id = try await KeepTests.readyFind(h)
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        try #require(try await h.runner.keep(id) == .moved)
        h.server.with { s in
            s.albums = [
                .init(id: 50, artistId: 42, rg: rgSingle, title: "Lowlands (single)", monitored: true, type: "Single",
                      duration: 200_000, releaseDate: "2016-01-01T00:00:00Z"),
                .init(id: 51, artistId: 42, rg: rgAlbum, title: "Lowlands", monitored: false, type: "Album",
                      duration: 2_400_000, releaseDate: "2016-05-01T00:00:00Z"),
                .init(id: 52, artistId: 42, rg: ep, title: "Harbour EP", monitored: false, type: "EP",
                      duration: 1_200_000, releaseDate: "2018-01-01T00:00:00Z"),
                .init(id: 53, artistId: 42, rg: second, title: "Second Light", monitored: false, type: "Album",
                      duration: 3_000_000, releaseDate: "2020-01-01T00:00:00Z"),
                .init(id: 54, artistId: 42, rg: bSide, title: "B-side", monitored: false, type: "Single",
                      duration: 180_000, releaseDate: "2021-01-01T00:00:00Z"),
                .init(id: 55, artistId: 42, rg: early, title: "Early", monitored: true, type: "Album",
                      duration: 1_800_000, releaseDate: "2014-01-01T00:00:00Z"),
            ]
        }
        return id
    }

    static func monitored(_ h: Harness) -> Set<Int> {
        h.server.with { s in Set(s.albums.filter(\.monitored).map(\.id)) }
    }

    @Test func offerAfterAMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let writes = h.server.writes.count

        let offer = try await h.runner.bringInOffer(id)

        #expect(offer.artistId == 42 && !offer.followsNewReleases)
        let albums = try #require(offer.options[.albumsAndEPs])
        #expect(albums.albumIds == [53, 52, 51], "not monitored yet, newest first")
        #expect(albums.duration == 6_600 && !albums.isCapped)
        let this = try #require(offer.options[.thisAlbum])
        #expect(this.albumIds == [51] && this.title == "Lowlands" && this.duration == 2_400)
        let everything = try #require(offer.options[.everything])
        #expect(everything.albumIds == [54, 53, 52, 51] && everything.duration == 6_780)
        #expect(h.server.writes.count == writes, "an offer only reads")
    }

    /// The exact writes: monitor the albums, search them, and (toggle on) follow new releases. Nothing else, and
    /// nothing is ever unmonitored.
    @Test func bringsInAlbumsAndEPsAndFollows() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let before = h.server.writes.count

        let result = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)

        #expect(result == .init(albums: 3, searching: true, following: true))
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command", "PUT artist/editor"])
        #expect(Set(writes[0].1.keys) == ["albumIds", "monitored"])
        #expect(writes[0].1["albumIds"] as? [Int] == [53, 52, 51] && writes[0].1["monitored"] as? Bool == true)
        #expect(writes[1].1["name"] as? String == "AlbumSearch" && writes[1].1["albumIds"] as? [Int] == [53, 52, 51])
        #expect(Set(writes[2].1.keys) == ["artistIds", "monitorNewItems"])
        #expect(writes[2].1["artistIds"] as? [Int] == [42] && writes[2].1["monitorNewItems"] as? String == "new")
        #expect(Self.monitored(h) == [50, 51, 52, 53, 55])
        #expect(h.server.with { $0.artists.first?.monitorNewItems } == "new")
        #expect(h.server.with { $0.artists.first?.quality } == 9, "the profile Keep set stays")

        // Ledgered as Magpie's, kept (Not for me never touches them, G3.4) and closed (never inherited by a Cancel).
        let entries = try await h.ledger.entries.filter { [51, 52, 53].contains($0.albumId ?? 0) }
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.isApplied && $0.keptAt != nil && $0.closedAt != nil && !$0.wasMonitoredBefore
                                     && $0.createdArtist && $0.lidarrArtistId == 42 })
        #expect(Set(entries.map(\.rgMbid)) == [rgAlbum, Self.ep, Self.second])
    }

    /// M6: the ledger has the albums (as "may have landed") before the monitor write leaves the device.
    @Test func ledgerIsSavedBeforeTheWrite() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.hold = ("/album/monitor", 1); $0.holdMethod = "PUT"; $0.holdSeen = 0 }

        let task = Task { try await h.runner.bringIn(id, choice: .thisAlbum, follow: false) }
        await h.server.latch.waitArrived()
        let entry = try #require(try await h.ledger.entry(albumId: 51))
        #expect(entry.send == .unclear && entry.keptAt != nil)
        await h.server.latch.release()
        #expect(try await task.value == .init(albums: 1, searching: true, following: false))
        #expect(try await h.ledger.entry(albumId: 51)?.send == .applied)
    }

    /// V-fix polish: "kept" must be said of this very artist. The kept entries belong to an earlier artist under the
    /// same reused Lidarr id (another MBID); this artist only has an unkept "created" entry: nothing is brought in.
    @Test func keptByAnEarlierArtistUnderAReusedIdIsNotKept() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let earlier = MBID("11111111-1111-4111-8111-111111111111")!
        for var e in try await h.ledger.entries where e.lidarrArtistId == 42 {
            e.artistMbid = earlier
            try await h.ledger.record(e)
        }
        try await h.ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: 99, rgMbid: Self.second, createdArtist: true,
                                              wasMonitoredBefore: false, root: "/music/library", mode: .fallback,
                                              send: .applied, requestId: "other", artistMbid: artistA))
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.BringInError.notKept) {
            _ = try await h.runner.bringIn(id, choice: .everything, follow: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// Dedupe: albums already monitored, and albums a request still on its way has in the ledger, are left alone.
    @Test func dedupesAgainstMonitoredAndOpenRequests() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        try await h.ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: 52, rgMbid: Self.ep, createdArtist: true,
                                              wasMonitoredBefore: false, root: "/music/library", mode: .fallback,
                                              send: .unclear, requestId: "other"))

        let offer = try await h.runner.bringInOffer(id)
        #expect(offer.options[.albumsAndEPs]?.albumIds == [53, 51])
        _ = try await h.runner.bringIn(id, choice: .everything, follow: false)
        let monitor = try #require(h.server.writeBodies().last { $0.0 == "PUT album/monitor" })
        #expect(monitor.1["albumIds"] as? [Int] == [54, 53, 51])
        #expect(try await h.ledger.entry(albumId: 52)?.requestId == "other", "the request's entry is untouched")
    }

    /// A5: no length for an album Lidarr doesn't know the length of, so no number for that choice.
    @Test func unknownLengthMeansNoSize() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { s in s.albums[2].duration = nil }   // the EP

        let offer = try await h.runner.bringInOffer(id)
        #expect(offer.options[.albumsAndEPs]?.albumIds == [53, 52, 51])
        #expect(offer.options[.albumsAndEPs]?.duration == nil)
        #expect(offer.options[.thisAlbum]?.duration == 2_400)
    }

    /// The song's album is already in: This album only has nothing left to bring in.
    @Test func thisAlbumAlreadyIn() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { s in s.albums[1].monitored = true }

        let offer = try await h.runner.bringInOffer(id)
        let this = try #require(offer.options[.thisAlbum])
        #expect(this.albumIds.isEmpty && this.title == "Lowlands" && this.duration == nil)
        let before = h.server.writes.count
        #expect(try await h.runner.bringIn(id, choice: .thisAlbum, follow: false) == .init(albums: 0, searching: false, following: false))
        #expect(h.server.writes.count == before)
    }

    /// G7: one Bring in more brings in at most as many releases as the limit of 5 has room for (security FL4; and
    /// never more than `bringInLimit`), the newest, and says how many there were.
    @Test func everythingIsCapped() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { s in
            for n in 0..<25 {
                s.albums.append(.init(id: 100 + n, artistId: 42, rg: mbid(1_000 + n), title: "Live \(n)", monitored: false,
                                      type: "Single", duration: 60_000,
                                      releaseDate: String(format: "2022-01-%02dT00:00:00Z", n + 1)))
            }
        }
        let offer = try await h.runner.bringInOffer(id)
        let everything = try #require(offer.options[.everything])
        #expect(everything.albumIds == [124, 123, 122, 121, 120], "newest first, as many as there's room for")
        #expect(everything.available == 29 && everything.isCapped)

        let result = try await h.runner.bringIn(id, choice: .everything, follow: false)
        #expect(result.albums == RequestRunner.maxActive)
        let monitor = try #require(h.server.writeBodies().last { $0.0 == "PUT album/monitor" })
        #expect((monitor.1["albumIds"] as? [Int])?.count == RequestRunner.maxActive)
    }

    /// G7: five requests on their way already: no releases now. Following new releases downloads nothing now, so it
    /// still goes (H2b fix 1), and the releases it couldn't bring in are counted.
    @Test func atMostFiveActive() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let active = (0..<5).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .downloading(progress: 0.1)
            return r
        }
        try await h.store.save(try await h.store.load() + active)
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.BringInError.tooMany) {
            _ = try await relaunched.runner.bringIn(id, choice: .albumsAndEPs, follow: false)
        }
        #expect(h.server.writes.count == before)
        let offer = try await relaunched.runner.bringInOffer(id)
        #expect(offer.options[.albumsAndEPs]?.albumIds == [] && offer.options[.albumsAndEPs]?.available == 3)
        #expect(try await relaunched.runner.bringIn(id, choice: nil, follow: true)
                == .init(albums: 0, searching: false, following: true))
        #expect(h.server.writeBodies().dropFirst(before).map(\.0) == ["PUT artist/editor"], "following only")
        #expect(await relaunched.request(id)?.bringingIn == nil)
    }

    /// H2b fix 1: exactly what the sheet offered comes in. The room grew while the sheet was open (a request came
    /// home): still only the offered releases, not more.
    @Test func roomThatGrewBringsOnlyWhatWasOffered() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let mine = try await h.store.load()
        let active = (0..<3).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .searching
            return r
        }
        try await h.store.save(mine + active)
        let busy = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let offered = try #require(try await busy.runner.bringInOffer(id).options[.everything]).albumIds
        #expect(offered == [54, 53])
        await busy.runner.stop()
        try await h.store.save(mine)   // they came home meanwhile: room for 5 now
        let now = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let result = try await now.runner.bringIn(id, choice: .everything, offered: offered, follow: false)
        #expect(result == .init(albums: 2, searching: true, following: false))
        let monitor = try #require(h.server.writeBodies().last { $0.0 == "PUT album/monitor" })
        #expect(monitor.1["albumIds"] as? [Int] == [54, 53])
    }

    /// H2b fix 1: the room shrank while the sheet was open: the newest that fit come in, and the rest are counted
    /// so the owner hears it.
    @Test func roomThatShrankSaysHowManyWait() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let offered = try #require(try await h.runner.bringInOffer(id).options[.everything]).albumIds
        #expect(offered == [54, 53, 52, 51])
        await h.runner.stop()
        let active = (0..<3).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .searching
            return r
        }
        try await h.store.save(try await h.store.load() + active)
        let now = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let result = try await now.runner.bringIn(id, choice: .everything, offered: offered, follow: false)
        #expect(result == .init(albums: 2, searching: true, following: false, heldBack: 2))
        let monitor = try #require(h.server.writeBodies().last { $0.0 == "PUT album/monitor" })
        #expect(monitor.1["albumIds"] as? [Int] == [54, 53])
    }

    /// Security FL4: what Bring in more brings in counts toward the limit of 5 like requests on their way, until each
    /// release has files in Lidarr, is no longer monitored, or a day has passed (as a request gives up).
    @Test func bringInCountsTowardTheLimitOfFive() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        #expect(try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: false).albums == 3)
        #expect(await h.request(id)?.bringingIn == [53, 52, 51])
        #expect(await h.runner.activeCount == 3)

        // Three releases and two requests on their way: no room for a Try or another Bring in more.
        let active = (0..<2).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .downloading(progress: 0.1)
            return r
        }
        try await h.store.save(try await h.store.load() + active)
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(await relaunched.runner.load())
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.TryError.tooMany) {
            _ = try await relaunched.runner.tryRecording(relaunched.recording(recAlbumOnly), tier: .standard)
        }
        await #expect(throws: RequestRunner.BringInError.tooMany) {
            _ = try await relaunched.runner.bringIn(id, choice: .everything, follow: false)
        }
        #expect(h.server.writes.count == before)

        // One arrives (files), one the owner stops monitoring: room again; the last one gives up after a day.
        h.server.with { s in
            for i in s.albums.indices where s.albums[i].id == 53 { s.albums[i].trackFiles = 12 }
            for i in s.albums.indices where s.albums[i].id == 52 { s.albums[i].monitored = false }
        }
        relaunched.clock.advance(61)
        await relaunched.runner.tick()
        #expect(await relaunched.request(id)?.bringingIn == [51])
        #expect(await relaunched.runner.activeCount == 3)
        relaunched.clock.advance(RequestMachine.giveUpAfter)
        await relaunched.runner.tick()
        #expect(await relaunched.request(id)?.bringingIn == nil)
    }

    /// FL4: two requests on their way leave room for three releases.
    @Test func bringInIsCappedByTheRoomLeft() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let active = (0..<2).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(200 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .searching
            return r
        }
        try await h.store.save(try await h.store.load() + active)
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let everything = try #require(try await relaunched.runner.bringInOffer(id).options[.everything])
        #expect(everything.albumIds == [54, 53, 52] && everything.available == 4 && everything.isCapped)
        #expect(try await relaunched.runner.bringIn(id, choice: .everything, follow: false).albums == 3)
    }

    /// Not after a Keep that stayed in the Finds folder, and not for a find that isn't kept.
    @Test func onlyAfterAMove() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)
        await #expect(throws: RequestRunner.BringInError.notKept) { _ = try await h.runner.bringInOffer(id) }

        h.server.with { $0.folders = [KeepTests.keptPath] }
        #expect(try await h.runner.keep(id) == .keptInPlace)
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.BringInError.notKept) { _ = try await h.runner.bringInOffer(id) }
        await #expect(throws: RequestRunner.BringInError.notKept) {
            _ = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)
        }
        #expect(h.server.writes.count == before)
    }

    /// Following already: the toggle shows it, and nothing is sent for it.
    @Test func alreadyFollowingSendsNothingForIt() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.artists[0].monitorNewItems = "all" }

        #expect(try await h.runner.bringInOffer(id).followsNewReleases)
        let before = h.server.writes.count
        #expect(try await h.runner.bringIn(id, choice: nil, follow: true) == .init(albums: 0, searching: false, following: true))
        #expect(h.server.writes.count == before)
        #expect(h.server.with { $0.artists.first?.monitorNewItems } == "all", "never changed, never turned off")
    }

    /// Follow only: one editor write with exactly the follow fields.
    @Test func followOnly() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        let before = h.server.writes.count

        #expect(try await h.runner.bringIn(id, choice: nil, follow: true) == .init(albums: 0, searching: false, following: true))
        #expect(Array(h.server.writeBodies().dropFirst(before)).map(\.0) == ["PUT artist/editor"])
        #expect(Self.monitored(h) == [50, 55])
    }

    /// G1: changes off: nothing is sent.
    @Test func changesOff() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        await h.gate.setEnabled(false)
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.BringInError.changesOff) {
            _ = try await h.runner.bringIn(id, choice: .everything, follow: true)
        }
        #expect(h.server.writes.count == before)
    }

    // MARK: - Lost answers (fix 1)

    /// The monitor write applied but its answer was lost: a fresh read shows the albums monitored, so they are
    /// applied, searched and reported as coming in.
    @Test func lostAnswerThatApplied() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.monitorAppliedThen504 = 1 }
        let before = h.server.writes.count

        let result = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: false)

        #expect(result == .init(albums: 3, searching: true, following: false))
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(writes[1].1["albumIds"] as? [Int] == [53, 52, 51])
        for album in [51, 52, 53] { #expect(try await h.ledger.entry(albumId: album)?.send == .applied) }
    }

    /// The answer was lost and the albums aren't monitored: nothing is claimed or searched; the entries stay "may
    /// have landed".
    @Test func lostAnswerNotApplied() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.monitorFails503 = 1 }
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.BringInError.failed) {
            _ = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)
        }
        #expect(Array(h.server.writeBodies().dropFirst(before)).map(\.0) == ["PUT album/monitor"])
        #expect(try await h.ledger.entry(albumId: 53)?.send == .unclear)
        #expect(Self.monitored(h) == [50, 55])
    }

    /// The answer was lost and Lidarr can't be read: unconfirmed, nothing more sent.
    @Test func lostAnswerUnconfirmed() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.monitorFails503 = 1; $0.confirmFailsAfterLost = true }
        let before = h.server.writes.count

        await #expect(throws: RequestRunner.BringInError.unconfirmed) {
            _ = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)
        }
        #expect(Array(h.server.writeBodies().dropFirst(before)).map(\.0) == ["PUT album/monitor"])
        #expect(try await h.ledger.entry(albumId: 53)?.send == .unclear)
    }

    // MARK: - Ownership preconditions (fix 2): fresh state decides; refused with nothing written

    static func expectRefused(_ h: Harness, _ runner: RequestRunner, _ id: RequestID) async {
        let before = h.server.writes.count
        await #expect(throws: RequestRunner.BringInError.notKept) { _ = try await runner.bringInOffer(id) }
        await #expect(throws: RequestRunner.BringInError.notKept) {
            _ = try await runner.bringIn(id, choice: .everything, follow: true)
        }
        #expect(h.server.writes.count == before)
    }

    @Test func refusesArtistMagpieDidNotCreate() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        for var e in try await h.ledger.entries where e.lidarrArtistId == 42 {
            e.createdArtist = false
            try await h.ledger.record(e)
        }
        await Self.expectRefused(h, h.runner, id)
    }

    @Test func refusesArtistStillAFind() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.artists[0].tags.append(2) }
        await Self.expectRefused(h, h.runner, id)
    }

    @Test(arguments: ["/music/samples/Aurora Field", "/music/library", "/music/library-old/Aurora Field", "/elsewhere/Aurora Field"])
    func refusesArtistOutsideTheMainRoot(_ path: String) async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.artists[0].path = path }
        await Self.expectRefused(h, h.runner, id)
    }

    @Test func refusesAnotherArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.artists[0].mbid = mbid(999) }
        await Self.expectRefused(h, h.runner, id)
    }

    @Test func refusesArtistGoneFromLidarr() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.artists = [] }
        await Self.expectRefused(h, h.runner, id)
    }

    /// Fix 5: no plan, so the artist can't be told apart from another: refused.
    @Test func refusesRequestWithoutPlan() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        var saved = try await h.store.load()
        for i in saved.indices where saved[i].id == id { saved[i].plan = nil }
        try await h.store.save(saved)
        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await Self.expectRefused(h, relaunched.runner, id)
    }

    /// Lidarr refuses the monitor write: nothing is claimed, the ledger says not sent, no search is started.
    @Test func refusedMonitorWriteClaimsNothing() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.keptFind(h)
        h.server.with { $0.monitorRejects = 1 }
        await #expect(throws: RequestRunner.BringInError.failed) {
            _ = try await h.runner.bringIn(id, choice: .albumsAndEPs, follow: true)
        }
        #expect(!h.server.writeBodies().contains { $0.0 == "POST command" && ($0.1["albumIds"] as? [Int]) == [53, 52, 51] })
        #expect(!h.server.writeBodies().contains { $0.0 == "PUT artist/editor" && $0.1["monitorNewItems"] != nil })
        #expect(try await h.ledger.entry(albumId: 53)?.send == .notSent)
        #expect(Self.monitored(h) == [50, 55])
    }
}

/// D6 proof (fix 8): `onReady` fires only on the transition into ready. A request that is ready already when the
/// requests are loaded again (relaunch, another runner) never fires it, so the app can't land it a second time
/// (`AppModel.landedRequests` is memory only).
@Suite struct ReadyFiresOnceTests {
    @Test func reloadedReadyRequestDoesNotFireAgain() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)
        await h.runner.tick()
        #expect(h.ready.withLock { $0 } == [id], "once, on the transition")

        let relaunched = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(await relaunched.runner.load())
        await relaunched.runner.tick()
        await relaunched.runner.tick()
        #expect(await relaunched.state(id) == .ready)
        #expect(relaunched.ready.withLock { $0 }.isEmpty)
    }
}
