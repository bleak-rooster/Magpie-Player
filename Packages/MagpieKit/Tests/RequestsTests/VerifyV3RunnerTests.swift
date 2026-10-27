import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Verify V3: FLOWS.md §3f ("Try") claims that had no test of their own, driven through the runner against the
/// scripted Lidarr + MusicBrainz (`Harness`). No real server is contacted.
@Suite struct VerifyV3RunnerTests {
    /// §3f Resolve: "A song with no recording MBID fails ("no release")." MusicBrainz is never asked and nothing is
    /// written to Lidarr.
    @Test func songWithoutRecordingMBIDFailsWithNoRelease() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let song = ExternalRecording(recordingMBID: nil, title: "Untagged", artist: "Aurora Field", source: .listenBrainz)
        let id = try await h.runner.tryRecording(song, tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .failed(reason: .noRelease))
        #expect(h.server.mbCalls == 0)
        #expect(h.server.writes.isEmpty)
    }

    /// §3f Resolve: "For a new artist, only Official Album/EP/Single studio releases qualify." A song that is only on
    /// a live album, a bootleg single and a compilation fails without a write; given an official EP and an official
    /// album, the EP is chosen (Single < EP < Album).
    @Test func newArtistOnlyOfficialPlainReleasesQualify() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let none = mbid(103), epAndAlbum = mbid(104)
        let rgEP = mbid(13), rgComp = mbid(14), rgBoot = mbid(15)
        func release(_ n: Int, _ rg: MBID, _ type: String, status: String = "Official",
                     secondary: [String] = []) -> [String: Any] {
            ["id": mbid(600 + n).rawValue, "title": "Release \(n)", "status": status, "date": "2001",
             "release-group": ["id": rg.rawValue, "primary-type": type, "secondary-types": secondary]]
        }
        let credit: [[String: Any]] = [["name": "Aurora Field", "artist": ["id": artistA.rawValue]]]
        for (rec, releases) in [
            (none, [release(1, rgLive, "Album", secondary: ["Live"]), release(2, rgBoot, "Single", status: "Bootleg"),
                    release(3, rgComp, "Album", secondary: ["Compilation"])]),
            (epAndAlbum, [release(4, rgAlbum, "Album"), release(5, rgEP, "EP")]),
        ] {
            let body = try JSONSerialization.data(withJSONObject: ["id": rec.rawValue, "title": "Song",
                                                                   "releases": releases, "artist-credit": credit])
            h.server.transport.stub(pathSuffix: "/ws/2/recording/\(rec.rawValue)", body: body)
        }

        let failed = try await h.runner.tryRecording(h.recording(none, title: "Live Only"), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(failed) == .failed(reason: .noRelease))
        #expect(h.server.writes.isEmpty)

        let picked = try await h.runner.tryRecording(h.recording(epAndAlbum, title: "On The EP"), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(picked)?.plan?.releaseGroupMBID == rgEP)
        let add = try #require(h.server.writeBodies().first { $0.0 == "POST artist" })
        let options = try #require(add.1["addOptions"] as? [String: Any])
        #expect(options["albumsToMonitor"] as? [String] == [rgEP.rawValue])
    }

    /// §3f Resolve, PARTIAL claim "For an artist already in Lidarr, only the release groups Lidarr already lists
    /// qualify": an artist Magpie itself added whose albums Lidarr hasn't listed yet is picked for as a new artist
    /// (the Finds-profile releases), and the request waits for the album without writing.
    @Test func magpieCreatedArtistWithoutAlbumsYetPicksAsForANewArtist() async throws {
        let h = await Harness()
        h.server.with { $0.artists = [.init(id: 42, mbid: artistA, root: "/music/library")] }
        try await h.ledger.record(LedgerEntry(lidarrArtistId: 42, albumId: nil, rgMbid: rgAlbum, createdArtist: true,
                                              wasMonitoredBefore: false, root: "/music/library", mode: .fallback,
                                              send: .applied, requestId: "earlier"))
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        let r = try #require(await h.request(id))
        #expect(r.plan?.releaseGroupMBID == rgSingle, "not limited to the (still empty) list Lidarr has")
        #expect(r.plan?.lidarrArtistId == 42)
        #expect(r.state == .searching && r.albumId == nil)
        #expect(h.server.writes.isEmpty, "waits for Lidarr to list the album; never a second add")
    }

    /// §3f Progress, PARTIAL claim "Ten minutes with nothing grabbed after the search finished means still
    /// looking": the ten minutes count from when the search *started*; the finished search command is only a gate.
    @Test func stillLookingCountsFromTheSearchStart() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.searchCommandId == 78)

        h.server.with { $0.commandStatus = "started" }
        h.clock.advance(9 * 60)
        await h.runner.tick()
        #expect(await h.state(id) == .searching)

        // The search finishes at 9 min; one minute later (10 min after it started) the request already waits.
        h.server.with { $0.commandStatus = "completed" }
        h.clock.advance(61)
        await h.runner.tick()
        guard case .waiting(let reason, _) = await h.state(id) else { Issue.record("expected waiting"); return }
        #expect(reason.kind == .stillLooking)
    }

    /// §3f Ready: "Whenever the index matches the recording, the request becomes Ready" — from any state before
    /// Ready, not only after an import.
    @Test func readyWheneverTheIndexHasItEvenBeforeImport() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .searching)

        h.library.state.withLock { $0.indexed[recAlbumOnly] = "song-7" }
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.state == .ready && r.songId == "song-7")
        #expect(h.ready.withLock { $0 } == [id])
        #expect(h.library.state.withLock { $0.scans } == 0, "no import, so no scan was needed")
    }

    /// §3f Ready: "After an import, the app starts a quick scan ... Scans repeat every 2–10 min." A scan starts on
    /// the import; another only after 2 minutes, and never while Navidrome reports a scan running.
    @Test func rescansEveryTwoMinutesOnlyWhenNoScanRuns() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.clock.advance(5)
        h.server.with { $0.history = [.init(albumId: 31, type: "trackFileImported", date: h.clock.now)] }
        await h.runner.tick()
        #expect(await h.state(id) == .importing)
        #expect(h.library.state.withLock { $0.scans } == 1, "one scan on the import")

        h.clock.advance(60)
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.scans } == 1, "not again within 2 minutes")

        h.library.state.withLock { $0.scanning = true }
        h.clock.advance(61)
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.scans } == 1, "not while a scan runs")

        h.library.state.withLock { $0.scanning = false }
        await h.runner.tick()
        #expect(h.library.state.withLock { $0.scans } == 2)
        #expect(await h.state(id) == .importing)
    }

    /// §3f Limits: "A second Try of the same song returns the existing request" — also once it is Ready (no new
    /// request, no MusicBrainz call, no write).
    @Test func secondTryOfAReadySongReturnsIt() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        h.library.state.withLock { $0.indexed[recAlbumOnly] = "song-7" }
        await h.runner.tick()
        #expect(await h.state(id) == .ready)
        let calls = h.server.transport.requests.count

        #expect(try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard) == id)
        await h.runner.settle()
        #expect(await h.runner.requests.count == 1)
        #expect(h.server.transport.requests.count == calls)
    }

    /// §2 / §3f / §4 say MusicBrainz is asked on Try only. Bring in more's offer asks it too (to tell which album the
    /// song is on for "This album only"): evidence for the FLOWS.md correction.
    @Test func bringInMoreOfferAlsoAsksMusicBrainz() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await BringInMoreTests.keptFind(h)
        let before = h.server.mbCalls
        _ = try await h.runner.bringInOffer(id)
        #expect(h.server.mbCalls == before + 1)
    }
}
