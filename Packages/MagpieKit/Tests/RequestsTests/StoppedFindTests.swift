import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 16 (owner, 2026-11-05): a Try of a new artist is searched by Magpie itself once Lidarr lists the release
/// monitored (Lidarr's post-add search never reached the owner's downloader), and Stop looking for the last find of an
/// artist Magpie added into the Finds folder removes that artist from Lidarr when nothing of it is left. An artist of
/// the main library, the owner's own, or one with files stays.
@Suite struct StoppedFindTests {
    static func searches(_ h: Harness) -> [[Int]] {
        h.server.writeBodies().filter { $0.0 == "POST command" && $0.1["name"] as? String == "AlbumSearch" }
            .map { $0.1["albumIds"] as? [Int] ?? [] }
    }

    /// The release isn't listed yet when the add answers (Lidarr's refresh is asynchronous): nothing is counted as
    /// searched; once Lidarr lists it monitored, Magpie's own AlbumSearch goes, once.
    @Test func newArtistIsSearchedOnceItsReleaseIsListed() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        h.server.with { $0.albumsAppearOnAdd = false }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()

        let options = try #require(h.server.writeBodies().first?.1["addOptions"] as? [String: Any])
        #expect(options["searchForMissingAlbums"] as? Bool == false, "Magpie searches the release itself")
        #expect(Self.searches(h).isEmpty)
        #expect(await h.request(id)?.searchStartedAt == nil, "no search counted before one is sent")

        // Listed but not monitored yet (the refresh hasn't applied albumsToMonitor): still waiting.
        h.server.with { s in s.albums += s.albumsOnAdd.map { var a = $0; a.artistId = 42; a.monitored = false; return a } }
        h.clock.advance(5)
        await h.runner.tick()
        #expect(Self.searches(h).isEmpty)

        h.server.with { s in for i in s.albums.indices where s.albums[i].id == 50 { s.albums[i].monitored = true } }
        h.clock.advance(5)
        await h.runner.tick()
        #expect(Self.searches(h) == [[50]])
        let r = try #require(await h.request(id))
        #expect(r.state == .searching && r.searchStartedAt != nil && r.searchCommandId != nil)

        h.clock.advance(5)
        await h.runner.tick()
        #expect(Self.searches(h) == [[50]], "searched once")
    }

    /// Listed straight away (a quick refresh): the search follows the add in the same step.
    @Test func newArtistListedAtOnceIsSearchedAtOnce() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        _ = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["POST artist", "POST command"])
        #expect(Self.searches(h) == [[50]])
    }

    /// A searching find of an artist Magpie added, with nothing downloaded.
    static func searchingFind(_ h: Harness) async throws -> RequestID {
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.server.with { s in
            for i in s.artists.indices { s.artists[i].files = nil; s.artists[i].recorded = nil }
            // Lidarr's refresh of the new artist finished (it applied albumsToMonitor).
            s.commands.append(FakeLidarr.Command(id: 79, name: "RefreshArtist", status: "completed", artistIds: [42]))
        }
        try #require(await h.state(id) == .searching)
        try #require(await h.request(id)?.isFind == true)
        return id
    }

    /// Stop looking: the release is unmonitored and, nothing of the artist being left, the artist goes (files kept,
    /// no exclusion).
    @Test func stopLookingRemovesTheFindsArtist() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.searchingFind(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false } }
        await h.runner.cancel(id)
        await h.runner.tick()

        let paths = h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
        #expect(paths.suffix(2) == ["PUT album/monitor", "DELETE artist/42"])
        #expect(h.server.writes.last?.url?.query == "deleteFiles=false&addImportListExclusion=false")
        #expect(h.server.with { $0.deletedArtists } == [42])
        let r = try #require(await h.request(id))
        #expect(r.state == .cancelled && !r.cleanupPending)
    }

    /// A refresh of the artist still running: it waits (Lidarr would re-create it), then goes.
    @Test func stopLookingWaitsForARefresh() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.searchingFind(h)
        h.server.with { s in
            for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false }
            s.commands.append(FakeLidarr.Command(id: 81, name: "RefreshArtist", status: "started", artistIds: [42]))
        }
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(h.server.with { $0.deletedArtists }.isEmpty)
        #expect(await h.request(id)?.cleanupPending == true)

        h.server.with { s in for i in s.commands.indices where s.commands[i].id == 81 { s.commands[i].status = "completed" } }
        h.clock.advance(30)
        await h.runner.tick()
        #expect(h.server.with { $0.deletedArtists } == [42])
        #expect(await h.request(id)?.cleanupPending == false)
    }

    /// The artist stays when something of it is left or it isn't the find's to remove.
    @Test func stopLookingKeepsAnArtistWithSomethingLeft() async throws {
        // Round 20 (D161): the stopped find's own album arrived anyway (imported after the stop): its files go as Not for
        // me would let them go, then, nothing being left, the artist.
        do {
            let h = await Harness(setup: Harness.findsSetup)
            let id = try await Self.searchingFind(h)
            h.server.with { s in
                for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false }
                for i in s.artists.indices { s.artists[i].files = KeepTests.findPath; s.artists[i].recorded = KeepTests.findPath }
            }
            await h.runner.cancel(id)
            await h.runner.tick()
            #expect(h.server.writeBodies().contains { $0.0 == "DELETE trackfile/bulk" && $0.1["trackFileIds"] as? [Int] == [1] })
            h.clock.advance(5)
            await h.runner.tick()
            #expect(h.server.with { $0.deletedArtists } == [42])
            #expect(await h.request(id)?.cleanupPending == false)
        }
        // Another find of the artist still on its way.
        do {
            let h = await Harness(setup: Harness.findsSetup)
            let id = try await Self.searchingFind(h)
            let other = try await h.runner.tryRecording(h.recording(recAlbumOnly, title: "Other"), tier: .standard)
            await h.runner.settle()
            try #require(await h.request(other)?.isActive == true)
            await h.runner.cancel(id)
            await h.runner.tick()
            #expect(h.server.with { $0.deletedArtists }.isEmpty)
        }
        // Moved into the main library (Keep): no longer a find there.
        do {
            let h = await Harness(setup: Harness.findsSetup)
            let id = try await Self.searchingFind(h)
            h.server.with { s in
                for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false }
                for i in s.artists.indices { s.artists[i].root = "/music/library"; s.artists[i].tags = [1] }
            }
            await h.runner.cancel(id)
            await h.runner.tick()
            #expect(h.server.with { $0.deletedArtists }.isEmpty)
        }
        // The owner's own artist (a library Try): never.
        do {
            let h = await Harness(setup: Harness.findsSetup)
            h.server.ownerHasArtist(albumMonitored: false)
            let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
            await h.runner.settle()
            await h.runner.cancel(id)
            await h.runner.tick()
            #expect(h.server.with { $0.deletedArtists }.isEmpty)
            #expect(!h.server.writes.contains { $0.httpMethod == "DELETE" })
        }
    }

    /// Changes switched off: nothing is sent; the clean-up waits and finishes once they're back on.
    @Test func stopLookingWithChangesOffWaits() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await Self.searchingFind(h)
        h.server.with { s in for i in s.albums.indices where s.albums[i].id != 50 { s.albums[i].monitored = false } }
        await h.gate.setEnabled(false)
        await h.runner.cancel(id)
        await h.runner.tick()
        #expect(h.server.with { $0.deletedArtists }.isEmpty)
        #expect(await h.request(id)?.cleanupPending == true)
        await h.gate.setEnabled(true)
        h.clock.advance(30)
        await h.runner.tick()
        #expect(h.server.with { $0.deletedArtists } == [42])
    }
}
