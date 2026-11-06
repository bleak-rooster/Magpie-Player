import Foundation
import Testing
import LidarrKit
import ListenBrainzKit
import MagpieCore
@testable import Requests

/// Round 20 (owner: stopped a find, the artist was deleted, then the album was grabbed anyway): a search Lidarr is still
/// running for the album can grab after the stop (a search Magpie started ignores "monitored"). The clean-up waits for
/// it, cancels the copy it grabbed (from the client too), and only then closes the entry and lets the artist go.
@Suite struct StopDuringSearchTests {
    static func paths(_ h: Harness) -> [String] {
        h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
    }

    static func setSearch(_ h: Harness, _ status: String) {
        h.server.with { s in
            s.commands.removeAll { $0.id == 150 }
            s.commands.append(FakeLidarr.Command(id: 150, name: "AlbumSearch", status: status, artistIds: []))
        }
    }

    @Test func aStopWaitsForTheSearchThenCancelsItsGrabBeforeTheArtistGoes() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await StoppedFindTests.searchingFind(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false } }
        Self.setSearch(h, "started")   // a slow Soulseek search still running
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(Self.paths(h).last == "PUT album/monitor", "the undo goes at once")
        #expect(h.server.with { $0.deletedArtists }.isEmpty, "never while the search runs")
        #expect(await h.request(id)?.cleanupPending == true)
        #expect(try await h.ledger.entry(albumId: 50)?.isOpen == true, "the entry stays open: the copy may still need removing")

        // The search finishes and had grabbed the album after the stop.
        Self.setSearch(h, "completed")
        h.server.with { $0.queue = [FakeLidarr.Queued(albumId: 50, size: 100, sizeleft: 90, id: 902, artistId: 42, client: "Slskd")] }
        h.clock.advance(5)
        await h.runner.tick()
        #expect(Self.paths(h).contains("DELETE queue/902"), "the late copy is cancelled, from the client too")
        #expect(h.server.with { $0.deletedArtists }.isEmpty)

        h.clock.advance(5)
        await h.runner.tick()
        #expect(h.server.with { $0.deletedArtists } == [42], "nothing left of it: now the artist goes")
        let r = try #require(await h.request(id))
        #expect(r.state == .cancelled && !r.cleanupPending)
        #expect(try await h.ledger.entry(albumId: 50)?.isOpen == false)
    }

    /// A search that never finishes (or a copy that can't be removed) holds the clean-up at most an hour.
    @Test func theWaitIsBounded() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        Self.setSearch(h, "started")
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(await h.request(id)?.cleanupPending == true)
        h.clock.advance(RequestRunner.stoppedFindArtistLimit + 1)
        await h.runner.tick()
        #expect(await h.request(id)?.cleanupPending == false)
        #expect(try await h.ledger.entry(albumId: 31)?.isOpen == false)
    }

    /// A stop with no search running and nothing queued finishes in one pass, as before.
    @Test func aQuietStopFinishesAtOnce() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(await h.request(id)?.cleanupPending == false)
        #expect(!Self.paths(h).contains { $0.hasPrefix("DELETE queue") })
    }

    /// Lidarr's command body names the albums an AlbumSearch works on.
    @Test func commandsCarryTheirAlbums() throws {
        let json = #"{"id":7,"name":"AlbumSearch","status":"started","body":{"albumIds":[50,51],"name":"AlbumSearch"}}"#
        let c = try JSONDecoder().decode(CommandStatus.self, from: Data(json.utf8))
        #expect(c.albumIds == [50, 51] && c.artistIds.isEmpty)
    }
}

/// Round 20: a title track, on its own single and on a studio album of the same name, asks for the album first; any other
/// song keeps its own single first.
@Suite struct TitleTrackTests {
    func rel(_ n: Int, _ title: String, _ type: String, _ date: String, secondary: [String] = []) -> MBRelease {
        MBRelease(id: mbid(800 + n), title: title, date: date, status: "Official",
                  releaseGroup: MBReleaseGroup(id: mbid(900 + n), primaryType: type, secondaryTypes: secondary))
    }

    @Test func aTitleTrackAsksForItsAlbumFirst() {
        let r = MBRecording(id: mbid(1), title: "Harbour Lights", releases: [rel(1, "Harbour Lights", "Single", "2020"),
                                                                             rel(2, "Harbour Lights", "Album", "2021"),
                                                                             rel(3, "Best Of", "Album", "2023", secondary: ["Compilation"])])
        #expect(ReleasePicker.ordered(containing: r, available: nil) == [mbid(902), mbid(901)])
    }

    @Test func anotherSongKeepsItsSingleFirst() {
        let r = MBRecording(id: mbid(1), title: "Compass Rose", releases: [rel(1, "Compass Rose", "Single", "2020"),
                                                                           rel(2, "Harbour Lights", "Album", "2021")])
        #expect(ReleasePicker.ordered(containing: r, available: nil) == [mbid(901), mbid(902)])
    }
}
