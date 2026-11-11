import Foundation
import LidarrKit
import MagpieCore
import MatchIndex
import Testing
@testable import Search

private let artistMBID = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!
private let singleRec = MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad")!
private let albumRec = MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!

private func album(_ id: Int, _ type: String?, _ secondary: [String] = [], title: String = "First Light",
                   released: TimeInterval? = nil) -> LidarrAlbum {
    LidarrAlbum(id: id, title: title, artistId: 9, albumType: type,
                releaseDate: released.map { Date(timeIntervalSince1970: $0) }, secondaryTypes: secondary)
}

private func track(_ id: Int, album: Int, _ title: String = "Song", _ seconds: TimeInterval? = 245, file: Bool = true,
                   rec: MBID? = nil) -> LidarrTrack {
    var t = LidarrTrack(id: id, albumId: album, trackFileId: file ? id + 1000 : nil, foreignTrackId: nil,
                        foreignRecordingId: rec?.rawValue, duration: seconds)
    t.title = title
    return t
}

private func track(_ id: Int, album: Int, _ seconds: TimeInterval?, file: Bool = true, rec: MBID? = nil) -> LidarrTrack {
    track(id, album: album, "Song", seconds, file: file, rec: rec)
}

/// Round 26 K1 (owner, 2026-11-10): "try and find the match within the albums and/or EPs" (D260). Lidarr's own
/// tracklist of the artist, its release types, which tracks have a file, the strict title rule (D261) and a length guard;
/// then the library song for that track by recording id, else by album, title and length, exactly one.
@Suite struct AlbumTrackMatchTests {
    private func find(_ title: String, _ seconds: TimeInterval?, rec: MBID? = nil,
                      _ albums: [LidarrAlbum], _ tracks: [LidarrTrack]) -> Int? {
        AlbumTrackMatch.find(title: title, duration: seconds, recording: rec, albums: albums, tracks: tracks)?.id
    }

    /// The single's radio edit, 3:31.
    private func find(rec: MBID? = nil, _ albums: [LidarrAlbum], _ tracks: [LidarrTrack]) -> Int? {
        find("Song (Radio Edit)", 211, rec: rec, albums, tracks)
    }

    @Test func album_singleMatchesAlbumTrackWithAFile() {
        let albums = [album(1, "Album"), album(2, "Single", title: "Song")]
        let tracks = [track(10, album: 2, "Song (Radio Edit)", 211, file: false), track(11, album: 1, "Song", 245),
                      track(12, album: 1, "Other Song", 200)]
        #expect(find(albums, tracks) == 11, "the single wasn't downloaded; the album's copy was")
        #expect(find("Song", 245, albums, tracks) == 11)
        #expect(find("Another", 200, albums, tracks) == nil)
        #expect(find("", 200, albums, [track(13, album: 1, "", 200)]) == nil, "an empty title never matches")
    }

    @Test func album_epCounts() {
        #expect(find([album(1, "EP")], [track(11, album: 1)]) == 11)
        #expect(find([album(1, "ep")], [track(11, album: 1)]) == 11, "case-insensitive")
        #expect(find([album(1, "ALBUM")], [track(11, album: 1)]) == 11)
    }

    @Test func album_singleReleaseTypeNotUsed() {
        for type in ["Single", "Broadcast", "Other"] {
            #expect(find([album(1, type)], [track(11, album: 1)]) == nil, "\(type)")
        }
    }

    @Test func album_liveRemixDemoNeverMatch() {
        for secondary in [["Live"], ["Remix"], ["Demo"], ["DJ-mix"], ["Mixtape/Street"], ["Spokenword"], ["Interview"],
                          ["Audiobook"], ["Audio drama"], ["Compilation", "Live"], ["Soundtrack", "Remix"]] {
            #expect(find([album(1, "Album", secondary)], [track(11, album: 1)]) == nil, "\(secondary)")
        }
        #expect(find([album(1, "Album", ["compilation"])], [track(11, album: 1)]) == 11, "case-insensitive")
        #expect(find([album(1, "Album", ["Soundtrack"])], [track(11, album: 1)]) == 11)
        #expect(find("Song (Live)", 245, [album(1, "Album")], [track(11, album: 1)]) == nil, "a live top song isn't the studio take")
        #expect(find([album(1, "Album")], [track(11, album: 1, "Song (Live)")]) == nil)
    }

    @Test func album_unknownTypeNeverMatches() {
        #expect(find([album(1, nil)], [track(11, album: 1)]) == nil)
        #expect(find([album(1, "")], [track(11, album: 1)]) == nil)
        #expect(find([album(1, "Album")], [track(11, album: 2)]) == nil, "a track whose album Lidarr didn't list")
        var orphan = track(11, album: 1)
        orphan.albumId = nil
        #expect(find([album(1, "Album")], [orphan]) == nil)
    }

    @Test func album_compilationRanksLast() {
        var albums = [album(4, "Album", ["Compilation"]), album(3, "Album", ["Soundtrack"]), album(2, "EP"), album(1, "Album")]
        let tracks = [track(40, album: 4), track(30, album: 3), track(20, album: 2), track(10, album: 1)]
        #expect(find(albums, tracks) == 10, "studio album")
        albums.removeLast()
        #expect(find(albums, tracks) == 20, "studio EP")
        albums.removeLast()
        #expect(find(albums, tracks) == 30, "soundtrack")
        albums.removeLast()
        #expect(find(albums, tracks) == 40, "compilation, last")
        #expect(find([album(5, "Album", ["Soundtrack", "Compilation"]), album(3, "Album", ["Soundtrack"])],
                     [track(50, album: 5), track(30, album: 3)]) == 30, "a soundtrack compilation ranks as a compilation")
    }

    @Test func album_trackWithoutFileNeverMatches() {
        #expect(find([album(1, "Album")], [track(11, album: 1, file: false)]) == nil)
        var zero = track(11, album: 1)
        zero.trackFileId = 0
        #expect(find([album(1, "Album")], [zero]) == nil)
    }

    @Test func album_outsideHalfToDoubleNeverMatches() {
        let albums = [album(1, "Album")]
        #expect(find("Song", 200, albums, [track(11, album: 1, 99.9)]) == nil)
        #expect(find("Song", 200, albums, [track(11, album: 1, 400.1)]) == nil)
        #expect(find("Song", 200, albums, [track(11, album: 1, 100)]) == 11)
        #expect(find("Song", 200, albums, [track(11, album: 1, 400)]) == 11)
        #expect(find("Song", nil, albums, [track(11, album: 1, 900)]) == 11, "the top song's length unknown")
        #expect(find("Song", 200, albums, [track(11, album: 1, nil)]) == 11, "the track's length unknown")
        #expect(find("Song", .nan, albums, [track(11, album: 1, 900)]) == 11, "a length that isn't one is unknown")
    }

    @Test func album_prefersSameRecording() {
        let albums = [album(1, "Album"), album(2, "Album", ["Compilation"])]
        let tracks = [track(10, album: 1, rec: albumRec), track(20, album: 2, rec: singleRec)]
        #expect(find(rec: singleRec, albums, tracks) == 20, "the same recording beats a better release type")
        #expect(find(rec: albumRec, albums, tracks) == 10)
        #expect(find(albums, tracks) == 10)
    }

    @Test func album_tieBreaksAreStable() {
        let albums = [album(1, "Album", released: 2_000), album(2, "Album", released: 1_000), album(3, "Album"),
                      album(4, "Album", released: 1_000)]
        let closer = [track(10, album: 1, 215), track(20, album: 2, 245)]
        #expect(find(albums, closer) == 10, "the smallest length difference first")
        let sameLength = [track(10, album: 1, 245), track(20, album: 2, 245), track(30, album: 3, 245)]
        #expect(find(albums, sameLength) == 20, "then the earliest release date; an unknown date last")
        let sameDate = [track(41, album: 4, 245), track(21, album: 2, 245)]
        #expect(find(albums, sameDate) == 21, "then the lowest track id")
        for order in [sameLength, sameLength.reversed(), [sameLength[1], sameLength[2], sameLength[0]]] {
            #expect(find(albums.reversed(), order) == 20, "input order never changes the answer")
        }
        #expect(find(albums, [track(10, album: 1, nil), track(20, album: 2, 300)]) == 20,
                "a known length difference ranks before an unknown one")
    }

    // MARK: - The library link

    private func librarySong(_ id: String, _ title: String = "Song", album: String = "First Light", _ d: TimeInterval = 246,
                             rec: MBID? = nil, artist: String = "Aurora Field", artistMBID: MBID? = artistMBID) -> Song {
        Song(id: id, title: title, artist: artist, album: album, duration: d, recordingMBID: rec, artistMBID: artistMBID)
    }

    private func librarySong(_ id: String, _ d: TimeInterval) -> Song { librarySong(id, "Song", d) }

    private func link(_ track: LidarrTrack, _ album: LidarrAlbum, _ songs: [Song], mbid: MBID? = artistMBID) -> String? {
        AlbumTrackMatch.librarySongId(track: track, album: album, artistName: "Aurora Field", artistMBID: mbid,
                                      index: MatchIndex(songs: songs))
    }

    @Test func link_byRecordingFirst() {
        let songs = [librarySong("byName"), librarySong("byRec", "Something Else", album: "Elsewhere", 100, rec: albumRec)]
        #expect(link(track(11, album: 1, rec: albumRec), album(1, "Album"), songs) == "byRec")
        #expect(link(track(11, album: 1, rec: singleRec), album(1, "Album"), songs) == "byName",
                "a recording the library hasn't got falls to the album, title and length")
    }

    @Test func link_byAlbumTitleTitleAndThreeSeconds() {
        let first = album(1, "Album")
        #expect(link(track(11, album: 1, 245), first, [librarySong("s", album: "First Light (Deluxe Edition)", 248)]) == "s")
        #expect(link(track(11, album: 1, 245), first, [librarySong("s", 248.5)]) == nil, "more than 3 s apart")
        #expect(link(track(11, album: 1, nil), first, [librarySong("s")]) == nil, "Lidarr's length unknown: never by name alone")
        #expect(link(track(11, album: 1, 245), first, [librarySong("s", album: "Second Light")]) == nil, "another album")
        #expect(link(track(11, album: 1, "Song (Reprise)", 245), first, [librarySong("s")]) == nil, "another title")
        #expect(link(track(11, album: 1, 245), first, [librarySong("s", artist: "Someone Else", artistMBID: nil)]) == nil,
                "another artist's song")
        #expect(link(track(11, album: 1, 245), first, [librarySong("s", artistMBID: nil)], mbid: nil) == "s",
                "untagged library and no MBID: by the artist's name")
    }

    @Test func link_ambiguousSkips() {
        let songs = [librarySong("a", 245), librarySong("b", 247)]
        #expect(link(track(11, album: 1, 245), album(1, "Album"), songs) == nil, "two copies within 3 s: when in doubt, skip")
        #expect(link(track(11, album: 1, 245), album(1, "Album"), [librarySong("a", 245), librarySong("b", 260)]) == "a")
    }

    @Test func link_aFullSongPassesTheSameRule() {
        let first = album(1, "Album")
        func links(_ song: Song, _ track: LidarrTrack, mbid: MBID? = artistMBID) -> Bool {
            AlbumTrackMatch.links(song, to: track, album: first, artistName: "Aurora Field", artistMBID: mbid)
        }
        #expect(links(librarySong("s", album: "First Light (Deluxe Edition)", 248), track(11, album: 1, 245)))
        #expect(!links(librarySong("s", "Song (Reprise)", 245), track(11, album: 1, 245)),
                "the full title is held to the strict rule")
        #expect(!links(librarySong("s", 249), track(11, album: 1, 245)))
        #expect(!links(librarySong("s"), track(11, album: 1, nil)), "never by name alone")
        #expect(links(librarySong("s", "Other", album: "Elsewhere", 100, rec: albumRec), track(11, album: 1, 245, rec: albumRec)),
                "the same recording")
        #expect(!links(librarySong("s", artist: "Someone Else", artistMBID: singleRec), track(11, album: 1, 245)),
                "a search hit by another artist")
        #expect(links(librarySong("s", artistMBID: nil), track(11, album: 1, 245)), "an untagged song by the artist's name")
        #expect(!links(librarySong("s", artist: "Someone Else", artistMBID: nil), track(11, album: 1, 245)))
    }
}
