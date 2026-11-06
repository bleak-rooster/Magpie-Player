import Testing
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
@testable import Requests

/// Round 17 (owner, 2026-11-05): a release that can't be found gives way to the next one holding the song (single,
/// EP, album, then a release whose tracklist has the song's title); with none left the request fails and says so.
@Suite struct NextReleaseTests {
    /// The owner's artist lists the single (32) and the album (31); the song is on both.
    private func artistWithSingleAndAlbum(_ h: Harness) {
        h.server.ownerHasArtist(albumMonitored: false)
        h.server.with { s in
            s.albums.append(FakeLidarr.Album(id: 32, artistId: 7, rg: rgSingle, title: "Lowlands (single)",
                                             monitored: false, type: "Single"))
        }
    }

    private func monitored(_ h: Harness, _ albumId: Int) -> Bool? {
        h.server.with { s in s.albums.first { $0.id == albumId }?.monitored }
    }

    @Test func orderedPutsTheSingleFirstThenTheAlbum() {
        let release = { (n: Int, rg: MBID, type: String, secondary: [String]) in
            MBRelease(id: mbid(500 + n), title: "R\(n)", date: "2001", status: "Official",
                      releaseGroup: MBReleaseGroup(id: rg, primaryType: type, secondaryTypes: secondary))
        }
        let recording = MBRecording(id: recSingleAndAlbum, title: "Song", releases: [
            release(1, rgAlbum, "Album", []), release(2, rgSingle, "Single", []), release(3, rgLive, "Album", ["Live"]),
            release(4, rgAlbum, "Album", []),
        ])
        #expect(ReleasePicker.ordered(containing: recording, available: nil) == [rgSingle, rgAlbum])
        #expect(ReleasePicker.smallest(containing: recording, available: nil) == rgSingle)
    }

    @Test func nothingFoundForTheSingleTriesTheAlbum() async throws {
        let h = await Harness()
        artistWithSingleAndAlbum(h)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.plan?.releaseGroupMBID == rgSingle)
        #expect(await h.request(id)?.releaseAlternates == [rgAlbum])
        #expect(monitored(h, 32) == true)

        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        let r = await h.request(id)
        #expect(r?.plan?.releaseGroupMBID == rgAlbum)
        #expect(r?.albumId == 31)
        #expect(r?.releasesTried == [rgSingle])
        #expect(r?.state == .searching)
        #expect(monitored(h, 32) == false)   // Magpie's monitor of the single came off
        #expect(monitored(h, 31) == true)
        #expect(h.server.writeBodies().map(\.0)
                == ["PUT album/monitor", "POST command", "PUT album/monitor", "PUT album/monitor", "POST command"])
        #expect(h.failed.withLock { $0 }.isEmpty)
    }

    @Test func nothingLeftFailsAndSaysSo() async throws {
        let h = await Harness()
        artistWithSingleAndAlbum(h)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        #expect(await h.state(id) == .failed(reason: .notFoundYet))
        #expect(h.failed.withLock { $0 } == [id])
        #expect(monitored(h, 31) == false)   // the clean-up took the album off
    }

    /// Owner: no Patient exception; every speed fails once nothing is left.
    @Test func patientFailsTooOnceNothingIsLeft() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .patient)
        await h.runner.settle()
        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        #expect(await h.state(id) == .failed(reason: .notFoundYet))
        #expect(h.failed.withLock { $0 } == [id])
    }

    /// A find whose release has no MP3: its artist moves to "Magpie Finds Any Format" (made once, MP3s still first)
    /// and the same release is searched again; nothing then: the next release, in any format.
    @Test func aFindWithNoMP3IsSearchedAgainInOtherFormats() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.artistIsNew()
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.isFind == true)
        #expect(await h.request(id)?.albumId == 50)

        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        var r = await h.request(id)
        #expect(r?.anyFormat == true)
        #expect(r?.plan?.releaseGroupMBID == rgSingle, "the same release, other formats")
        #expect(r?.state == .searching)
        #expect(h.server.with { s in s.artists.first { $0.id == 42 }?.quality } == 20)
        let made = h.server.with { s in s.qualityProfiles.first { $0["id"]?.intValue == 20 } }
        #expect(made?["name"]?.stringValue == "Magpie Finds Any Format")
        let items = made?["items"]?.arrayValue ?? []
        let names = items.map { $0["quality"]?["name"]?.stringValue ?? "" }
        let allowed = Set(items.filter { $0["allowed"]?.boolValue == true }.compactMap { $0["quality"]?["name"]?.stringValue })
        #expect(allowed == ["MP3-VBR-V0", "MP3-320", "AAC-320", "FLAC"])
        #expect(names.suffix(2) == ["MP3-VBR-V0", "MP3-320"], "MP3 stays the first choice")
        #expect(made?["upgradeAllowed"]?.boolValue == false)
        #expect(h.server.writeBodies().map(\.0).suffix(3) == ["POST qualityprofile", "PUT artist/editor", "POST command"])

        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        r = await h.request(id)
        #expect(r?.plan?.releaseGroupMBID == rgAlbum)
        #expect(r?.albumId == 51)
        #expect(r?.state == .searching)
        #expect(h.server.with { s in s.qualityProfiles.count } == 2, "made once")
    }

    @Test func aReleaseWithTheSongsTitleIsTriedLast() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let rgEP = mbid(13), recEP = mbid(103)
        h.server.with { s in
            s.albums.append(FakeLidarr.Album(id: 34, artistId: 7, rg: rgEP, title: "Other EP", monitored: false, type: "EP"))
            s.albumTracks[34] = [(title: "Intro", recording: mbid(104)), (title: "Song (Explicit)", recording: recEP)]
        }
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.releaseAlternates == [])
        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        let r = await h.request(id)
        #expect(r?.plan?.releaseGroupMBID == rgEP)
        #expect(r?.plan?.recordingMBID == recEP)
        #expect(r?.albumId == 34)
        #expect(r?.albumTitle == "Other EP")
        #expect(monitored(h, 34) == true)
        #expect(monitored(h, 31) == false)
    }

    /// A new artist (a find) whose single Lidarr never lists: once its refresh is done, the album holding the song.
    @Test func aSingleLidarrNeverListsGivesWayToTheAlbum() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        h.server.with { s in
            s.albumsOnAdd = [FakeLidarr.Album(id: 51, artistId: 0, rg: rgAlbum, title: "Lowlands", monitored: false)]
        }
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard)
        await h.runner.settle()
        #expect(await h.request(id)?.plan?.releaseGroupMBID == rgSingle)
        h.server.with { s in
            s.commands.append(FakeLidarr.Command(id: 200, name: "RefreshArtist", status: "completed", artistIds: [42]))
        }
        h.clock.advance(60)
        await h.runner.tick()
        await h.runner.settle()
        let r = await h.request(id)
        #expect(r?.plan?.releaseGroupMBID == rgAlbum)
        #expect(r?.albumId == 51)
        #expect(r?.isFind == true)
        #expect(r?.state == .searching)
        #expect(monitored(h, 51) == true)
        #expect(h.server.writeBodies().map(\.0).suffix(2) == ["PUT album/monitor", "POST command"])
    }

    @Test func tryThisAlbumNeverSwapsTheAlbum() async throws {
        let h = await Harness()
        artistWithSingleAndAlbum(h)
        let id = try await h.runner.tryRecording(h.recording(recSingleAndAlbum), tier: .standard, album: rgAlbum)
        await h.runner.settle()
        #expect(await h.request(id)?.releaseAlternates == [])
        h.clock.advance(601)
        await h.runner.tick()
        await h.runner.settle()
        #expect(await h.state(id) == .failed(reason: .notFoundYet))
        #expect(monitored(h, 32) == false)
    }
}
