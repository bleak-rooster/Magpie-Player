import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// R19: "Try this album" is the existing Try with the album's release group as the target.
@Suite struct TryAlbumTests {
    /// A new artist: the one add monitors the album, not the smallest release holding the song (the single).
    @Test func tryThisAlbumTargetsTheReleaseGroup() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        await h.runner.settle()

        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["POST artist", "POST command"])
        let options = try #require(writes[0].1["addOptions"] as? [String: Any])
        #expect(options["albumsToMonitor"] as? [String] == [rgAlbum.rawValue])
        #expect(writes[0].1["rootFolderPath"] as? String == "/music/samples", "into Finds when set up")
        let r = try #require(await h.request(id))
        #expect(r.plan?.releaseGroupMBID == rgAlbum && r.albumTarget == rgAlbum)
        #expect(r.albumId == 51)
    }

    /// The owner's artist: only the album is monitored; the artist is never changed (A7).
    @Test func tryThisAlbumOnTheOwnersArtistMonitorsThatAlbumOnly() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgLive)
        await h.runner.settle()
        let writes = h.server.writeBodies()
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(writes[0].1["albumIds"] as? [Int] == [33])
        #expect(await h.request(id)?.plan?.releaseGroupMBID == rgLive)
    }

    /// A new artist's add can only monitor what the Finds metadata profile lists: a live album can't be tried.
    @Test func tryThisAlbumOutsideTheFindsProfileWritesNothing() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgLive)
        await h.runner.settle()
        #expect(h.server.writes.isEmpty)
        #expect(await h.state(id) == .failed(reason: .noRelease))
    }

    /// One request per album: a second Try this album (from another track) joins the live one.
    @Test func tryThisAlbumTwiceIsOneRequest() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let first = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        let second = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard, album: rgAlbum)
        await h.runner.settle()
        #expect(first == second)
        #expect(await h.runner.requests.count == 1)
    }

    /// A per-track Try for a song on an album already on its way opens that request (R20: deduped by release group).
    @Test func perTrackTryJoinsTheLiveAlbumRequest() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let album = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        let track = try await h.runner.tryRecording(h.recording(recAlbumOnly2), tier: .standard, releaseGroup: rgAlbum)
        await h.runner.settle()
        #expect(track == album)
        #expect(await h.runner.requests.count == 1)
        #expect(h.server.writeBodies().map(\.0) == ["POST artist", "POST command"])
    }

    /// Review I1: a single-song request for the album's first track never stands for the album: Try this album then
    /// makes its own request, aimed at the album.
    @Test func anEarlierSongTryOfTrackOneIsNotTheAlbum() async throws {
        let h = await Harness()
        h.server.artistIsNew()
        let song = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(song)?.plan?.releaseGroupMBID == rgSingle)
        let album = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        #expect(album != song)
        #expect(await h.runner.requests.count == 2)
        #expect(await h.request(album)?.albumTarget == rgAlbum)
        // A song request that resolved to the album itself does count.
        let again = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard, album: rgAlbum)
        #expect(again == album)
    }
}
