import Foundation
import MagpieCore

/// DTO → domain mapping. MBIDs are always built with `MBID(_:)` so one bad ID cannot drop a response.
enum Mapping {
    static let variousArtists = "Various Artists"

    static func mbid(_ s: String?) -> MBID? { s.flatMap { MBID($0) } }

    static func song(_ d: SubsonicSong) -> Song {
        Song(id: d.id, title: d.title ?? "", artist: d.artist ?? "", artistId: d.artistId,
             album: d.album ?? "", albumId: d.albumId, track: d.track, disc: d.discNumber,
             duration: d.duration ?? 0, suffix: d.suffix, bitRate: d.bitRate, coverArtId: d.coverArt,
             recordingMBID: mbid(d.musicBrainzId), isrcs: d.isrc ?? [], libraryId: nil,
             starred: d.starred != nil)
    }

    static func song(_ d: NativeSong) -> Song {
        Song(id: d.id, title: d.title ?? "", artist: d.artist ?? "", artistId: d.artistId,
             album: d.album ?? "", albumId: d.albumId, track: d.trackNumber, disc: d.discNumber,
             duration: d.duration ?? 0, suffix: d.suffix, bitRate: d.bitRate,
             coverArtId: d.hasCoverArt == true ? "mf-\(d.id)" : nil,
             recordingMBID: mbid(d.mbzRecordingID), isrcs: d.tags?.isrc ?? [], libraryId: d.libraryId,
             starred: d.starred ?? false)
    }

    /// Disc, then track; songs without numbers keep server order at the end of their disc.
    static func ordered(_ songs: [Song]) -> [Song] {
        songs.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if (x.disc ?? 1) != (y.disc ?? 1) { return (x.disc ?? 1) < (y.disc ?? 1) }
            if (x.track ?? Int.max) != (y.track ?? Int.max) { return (x.track ?? Int.max) < (y.track ?? Int.max) }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func album(_ d: SubsonicAlbum, withSongs: Bool = false) -> Album {
        let songs = withSongs ? ordered((d.song ?? []).map(song)) : nil
        let artist = d.isCompilation == true ? variousArtists : (d.artist ?? "")
        // Subsonic `musicBrainzId` on an album is the release id, not the release group: leave RG nil.
        return Album(id: d.id, name: d.name ?? "", artist: artist, artistId: d.artistId, year: d.year,
                     songCount: d.songCount ?? songs?.count ?? 0, duration: d.duration ?? 0,
                     coverArtId: d.coverArt, releaseGroupMBID: nil, songs: songs)
    }

    static func artist(_ d: SubsonicArtist) -> Artist {
        Artist(id: d.id, name: d.name ?? "", albumCount: d.albumCount ?? d.album?.count ?? 0,
               coverArtId: d.coverArt, mbid: mbid(d.musicBrainzId))
    }

    static func playlist(_ d: SubsonicPlaylist) -> Playlist {
        Playlist(id: d.id, name: d.name ?? "", songCount: d.songCount ?? d.entry?.count ?? 0,
                 duration: d.duration ?? 0, coverArtId: d.coverArt)
    }

    /// Prefers synced lyrics; line starts arrive in milliseconds.
    static func lyrics(_ list: SubsonicBody.LyricsList?) -> Lyrics? {
        guard let all = list?.structuredLyrics, !all.isEmpty else { return nil }
        let chosen = all.first { $0.synced == true && !($0.line ?? []).isEmpty }
            ?? all.first { !($0.line ?? []).isEmpty }
        guard let chosen else { return nil }
        let synced = chosen.synced == true
        let lines = (chosen.line ?? []).map { l in
            LyricLine(start: synced ? l.start.map { $0 / 1000 } : nil, text: l.value ?? "")
        }
        return Lyrics(synced: synced, lines: lines)
    }
}
