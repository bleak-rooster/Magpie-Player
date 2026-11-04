import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import Testing
@testable import Search

private let artistMBID = MBID("0b2c6a1e-0000-4000-8000-000000000001")!
private let groupMBID = MBID("0b2c6a1e-0000-4000-8000-000000000002")!
private let recordingMBID = MBID("0b2c6a1e-0000-4000-8000-000000000003")!
private let otherRecording = MBID("0b2c6a1e-0000-4000-8000-000000000004")!
private let releaseMBID = MBID("0b2c6a1e-0000-4000-8000-000000000005")!

private func release(_ tracks: [MBTrack]) -> MBReleaseDetail {
    MBReleaseDetail(id: releaseMBID, title: "Wide Open", date: "2020", status: "Official", tracks: tracks)
}

private actor ResolveCalls {
    var links: [String] = []
    var releases: [MBID] = []
    func link(_ s: String) { links.append(s) }
    func release(_ m: MBID) { releases.append(m) }
}

private func song(_ title: String = "Harbour Lights", duration: TimeInterval? = 201) -> OutsideSong {
    OutsideSong(title: title, artist: "The Tides", album: "Wide Open", duration: duration, deezerAlbumId: "302127",
                previewId: "3135556")
}

/// Round 14 A3 (D100): an outside song (a chart's, a Discover playlist's, an artist's top song) becomes a recording
/// Magpie can ask for: the artist's and album's MBIDs from the server's editorial links, then the recording in that
/// release group by normalised title and duration within 3 s, never by name alone.
@Suite struct OutsideSongResolveTests {
    @Test func matchesTheRecordingInTheReleaseGroup() async throws {
        let calls = ResolveCalls()
        let r = try await OutsideSongMatch.resolve(song(), links: { artist, album, deezerAlbum in
            await calls.link("\(artist)|\(album ?? "")|\(deezerAlbum ?? "")")
            return (artistMBID, groupMBID)
        }, release: { group in
            await calls.release(group)
            return release([MBTrack(recording: otherRecording, title: "Undertow", length: 180),
                            MBTrack(recording: recordingMBID, title: "Harbour Lights (Remastered)", length: 199)])
        })
        #expect(r.recordingMBID == recordingMBID && r.artistMBID == artistMBID && r.releaseMBID == releaseMBID)
        #expect(r.title == "Harbour Lights (Remastered)" && r.artist == "The Tides" && r.releaseTitle == "Wide Open")
        #expect(r.duration == 199 && r.source == .lidarr)
        let links = await calls.links, releases = await calls.releases
        #expect(links == ["The Tides|Wide Open|302127"] && releases == [groupMBID])
    }

    @Test func aSongThatAlreadyHasItsRecordingAsksNothing() async throws {
        var s = song()
        s.recordingMBID = recordingMBID
        s.artistMBID = artistMBID
        let r = try await OutsideSongMatch.resolve(s, links: { _, _, _ in Issue.record("asked"); return (nil, nil) },
                                                   release: { _ in Issue.record("asked"); return nil })
        #expect(r.recordingMBID == recordingMBID && r.artistMBID == artistMBID)
    }

    @Test func neverByNameAlone() async {
        // The same title, but 10 s longer: another recording (a live take, an edit).
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(), links: { _, _, _ in (artistMBID, groupMBID) },
                                               release: { _ in release([MBTrack(recording: recordingMBID, title: "Harbour Lights", length: 211)]) })
        }
        // No length on either side: no match.
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(duration: nil), links: { _, _, _ in (artistMBID, groupMBID) },
                                               release: { _ in release([MBTrack(recording: recordingMBID, title: "Harbour Lights", length: 201)]) })
        }
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(), links: { _, _, _ in (artistMBID, groupMBID) },
                                               release: { _ in release([MBTrack(recording: recordingMBID, title: "Harbour Lights", length: nil)]) })
        }
    }

    @Test func noAlbumOrNoReachableServerIsUnmatched() async {
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(), links: { _, _, _ in (artistMBID, nil) }, release: { _ in nil })
        }
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(), links: { _, _, _ in throw AurralError.notFound }, release: { _ in nil })
        }
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.resolve(song(), links: { _, _, _ in (artistMBID, groupMBID) },
                                               release: { _ in throw URLError(.timedOut) })
        }
    }

    @Test func theArtistAloneForAddArtist() async throws {
        let mbid = try await OutsideSongMatch.artist(song(), links: { _, _, _ in (artistMBID, nil) })
        #expect(mbid == artistMBID)
        var known = song()
        known.artistMBID = artistMBID
        #expect(try await OutsideSongMatch.artist(known, links: { _, _, _ in Issue.record("asked"); return (nil, nil) }) == artistMBID)
        await #expect(throws: OutsideSongMatch.Failure.unmatched) {
            try await OutsideSongMatch.artist(song(), links: { _, _, _ in (nil, groupMBID) })
        }
    }

    @Test func fromAnAurralSong() {
        let a = AurralSong(key: "3135556", trackName: "Harbour Lights", artistName: "The Tides", albumName: "Wide Open",
                           deezerAlbumId: "302127", durationMs: 201_000, artwork: nil,
                           preview: AurralPreview(trackId: "3135556"), position: 1)
        let s = OutsideSong(a)
        #expect(s.title == "Harbour Lights" && s.artist == "The Tides" && s.duration == 201 && s.previewId == "3135556")
        #expect(s.deezerAlbumId == "302127" && s.recordingMBID == nil)
        let e = OutsideSong(ExternalRecording(recordingMBID: recordingMBID, artistMBID: artistMBID, title: "X", artist: "Y",
                                              duration: 100, source: .listenBrainz))
        #expect(e.recordingMBID == recordingMBID && e.previewId == nil)
    }
}

private func aurral(_ title: String, _ artist: String = "The Tides", ms: Int? = 201_000, preview: String? = "1") -> AurralSong {
    AurralSong(key: preview, trackName: title, artistName: artist, albumName: nil, deezerAlbumId: nil, durationMs: ms,
               artwork: nil, preview: preview.flatMap(AurralPreview.init(trackId:)), position: nil)
}

/// Round 14 A3 (owner answer 7, D103): a ListenBrainz or tracklist song gets a preview only when the same song is
/// among what the server can preview (the artist's top songs, loaded charts, loaded Discover playlists).
@Suite struct PreviewMatchTests {
    @Test func theArtistsOwnPreviewsMatchByTitleAndDuration() {
        let hit = PreviewMatch.find(title: "harbour lights", artist: "Tides, The", duration: 199,
                                    artistSongs: [aurral("Undertow", preview: "2"), aurral("Harbour Lights", preview: "7")],
                                    otherSongs: [])
        #expect(hit?.preview?.trackId == "7", "the artist's list (asked by MBID) needs no name check")
    }

    @Test func chartsAndPlaylistsNeedTheArtistsName() {
        let other = [aurral("Harbour Lights", "Someone Else", preview: "8"), aurral("Harbour Lights", "THE TIDES", preview: "9")]
        #expect(PreviewMatch.find(title: "Harbour Lights", artist: "The Tides", duration: 200, artistSongs: [],
                                  otherSongs: other)?.preview?.trackId == "9")
    }

    @Test func nothingIsGuessed() {
        #expect(PreviewMatch.find(title: "Harbour Lights", artist: "The Tides", duration: 260,
                                  artistSongs: [aurral("Harbour Lights")], otherSongs: []) == nil, "another length")
        #expect(PreviewMatch.find(title: "Harbour Lights", artist: "The Tides", duration: nil,
                                  artistSongs: [aurral("Harbour Lights")], otherSongs: []) == nil, "no length")
        #expect(PreviewMatch.find(title: "Harbour", artist: "The Tides", duration: 201,
                                  artistSongs: [aurral("Harbour Lights")], otherSongs: []) == nil, "a similar title")
        #expect(PreviewMatch.find(title: "Harbour Lights", artist: "The Tides", duration: 201,
                                  artistSongs: [aurral("Harbour Lights", preview: nil)], otherSongs: []) == nil, "no preview")
    }
}

/// Round 14 A3 (owner answer 6, D104): where an artist's Top songs come from, and the fallback in Automatic's order.
@Suite struct TopSongsPlanTests {
    @Test func orders() {
        let all: Set<TopSongsProvider> = [.aurral, .listenBrainz, .library]
        #expect(TopSongsPlan.order(.automatic, available: all) == [.aurral, .listenBrainz, .library])
        #expect(TopSongsPlan.order(.listenBrainz, available: all) == [.listenBrainz, .aurral, .library])
        #expect(TopSongsPlan.order(.library, available: all) == [.library, .aurral, .listenBrainz])
        #expect(TopSongsPlan.order(.aurral, available: all) == [.aurral, .listenBrainz, .library])
        // The four setups.
        #expect(TopSongsPlan.order(.automatic, available: [.library]) == [.library], "Navidrome only")
        #expect(TopSongsPlan.order(.automatic, available: [.listenBrainz, .library]) == [.listenBrainz, .library], "+Lidarr")
        #expect(TopSongsPlan.order(.aurral, available: [.listenBrainz, .library]) == [.listenBrainz, .library],
                "Aurral chosen but gone: Automatic's order")
    }

    @Test func fallsBackWhenASourceFailsOrHasNothing() async {
        let got = await TopSongsPlan.load([.aurral, .listenBrainz, .library]) { provider -> [String] in
            switch provider {
            case .aurral: throw URLError(.timedOut)
            case .listenBrainz: return []
            case .library: return ["a", "b"]
            }
        }
        #expect(got?.provider == .library && got?.rows == ["a", "b"])
        let first = await TopSongsPlan.load([.listenBrainz, .library]) { $0 == .listenBrainz ? ["x"] : ["y"] }
        #expect(first?.provider == .listenBrainz && first?.rows == ["x"])
        let none = await TopSongsPlan.load([.aurral]) { _ -> [String] in [] }
        #expect(none == nil)
    }

    @Test func theNoteNamesAFallback() {
        #expect(TopSongsPlan.fellBack(chosen: .automatic, used: .aurral, order: [.aurral, .listenBrainz, .library]) == false)
        #expect(TopSongsPlan.fellBack(chosen: .automatic, used: .listenBrainz, order: [.aurral, .listenBrainz, .library]))
        #expect(TopSongsPlan.fellBack(chosen: .automatic, used: .listenBrainz, order: [.listenBrainz, .library]) == false,
                "without Aurral, ListenBrainz is Automatic's first")
        #expect(TopSongsPlan.fellBack(chosen: .library, used: .library, order: [.library, .aurral]) == false)
        #expect(TopSongsPlan.fellBack(chosen: .aurral, used: .library, order: [.aurral, .listenBrainz, .library]))
    }
}
