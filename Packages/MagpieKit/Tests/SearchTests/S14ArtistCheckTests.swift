import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import Testing
@testable import Search

private let linkedArtist = MBID("0b2c6a1e-0000-4000-8000-0000000000a1")!
private let ownArtist = MBID("0b2c6a1e-0000-4000-8000-0000000000a2")!
private let group = MBID("0b2c6a1e-0000-4000-8000-0000000000a3")!
private let recording = MBID("0b2c6a1e-0000-4000-8000-0000000000a4")!

private let tides = OutsideSong(title: "Harbour Lights", artist: "The Tides", album: "Wide Open", duration: 201,
                                deezerAlbumId: "302127")

private func detail() -> MBReleaseDetail {
    MBReleaseDetail(id: group, title: "Wide Open", date: "2020", status: "Official",
                    tracks: [MBTrack(recording: recording, title: "Harbour Lights", length: 200)])
}

/// S14 M2 (D116): an artist MBID the server's editorial links name is used only when Lidarr's lookup of that MBID names
/// the song's own artist (`SongIdentity.artistKey`); a song's own MBID is used as it is.
@Suite struct S14ArtistCheckTests {
    @Test func linkedArtistIsUsedWhenLidarrNamesTheSongsArtist() async throws {
        let mbid = try await OutsideSongMatch.artist(tides, links: { _, _, _ in (linkedArtist, nil) },
                                                     artistName: { $0 == linkedArtist ? "Tides, The" : nil })
        #expect(mbid == linkedArtist)
    }

    @Test func linkedArtistWithAnotherNameIsUnmatched() async {
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.artist(tides, links: { _, _, _ in (linkedArtist, nil) },
                                              artistName: { _ in "Someone Else Entirely" })
        }
    }

    @Test func linkedArtistLidarrDoesntKnowOrCantSayIsUnmatched() async {
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.artist(tides, links: { _, _, _ in (linkedArtist, nil) }, artistName: { _ in nil })
        }
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.artist(tides, links: { _, _, _ in (linkedArtist, nil) },
                                              artistName: { _ in throw URLError(.timedOut) })
        }
        let blank = OutsideSong(title: "X", artist: "  ", duration: 100)
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.artist(blank, links: { _, _, _ in (linkedArtist, nil) }, artistName: { _ in "  " })
        }
    }

    @Test func theSongsOwnArtistIsNotLookedUp() async throws {
        var known = tides
        known.artistMBID = ownArtist
        let mbid = try await OutsideSongMatch.artist(known, links: { _, _, _ in Issue.record("links"); return (nil, nil) },
                                                     artistName: { _ in Issue.record("lookup"); return nil })
        #expect(mbid == ownArtist)
    }

    /// The recording (Listen to the full song, Just this song) keeps the linked artist only when it checks out;
    /// otherwise none, so the request takes MusicBrainz's own artist for the recording.
    @Test func resolveKeepsTheLinkedArtistOnlyWhenItChecksOut() async throws {
        let ok = try await OutsideSongMatch.resolve(tides, links: { _, _, _ in (linkedArtist, group) },
                                                    release: { _ in detail() }, artistName: { _ in "The Tides" })
        #expect(ok.recordingMBID == recording && ok.artistMBID == linkedArtist)
        let other = try await OutsideSongMatch.resolve(tides, links: { _, _, _ in (linkedArtist, group) },
                                                       release: { _ in detail() }, artistName: { _ in "Impostor" })
        #expect(other.recordingMBID == recording && other.artistMBID == nil)
        let unknown = try await OutsideSongMatch.resolve(tides, links: { _, _, _ in (linkedArtist, group) },
                                                         release: { _ in detail() }, artistName: { _ in throw URLError(.timedOut) })
        #expect(unknown.artistMBID == nil)
    }

    /// Fix: a featured or joined credit matches on the full name or the primary artist, never a part or a substring.
    @Test func thePrimaryArtistOfAFeaturedCreditMatches() async throws {
        func check(_ credit: String, _ lidarr: String) async -> Bool {
            let song = OutsideSong(title: "T", artist: credit, duration: 100)
            return (try? await OutsideSongMatch.artist(song, links: { _, _, _ in (linkedArtist, nil) },
                                                       artistName: { _ in lidarr })) == linkedArtist
        }
        for credit in ["X feat. Y", "X ft. Y", "X Featuring Y", "X with Y", "X x Y", "X & Y", "X, Y", "X FEAT. Y & Z"] {
            #expect(await check(credit, "X"), "\(credit) ↔ X")
            #expect(!(await check(credit, "Y")), "\(credit) ↔ Y")
        }
        #expect(await check("Simon & Garfunkel", "Simon & Garfunkel"), "the full name")
        #expect(await check("X feat. Y", "X feat. Y"))
        #expect(!(await check("Xavier feat. Y", "X")), "never a substring")
        #expect(!(await check("The Xx", "X")))
        #expect(!(await check("X feat. Y", "X feat")))
    }
}
