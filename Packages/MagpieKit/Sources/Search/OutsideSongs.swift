import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore

/// Round 14 A3 (D100): a song from outside the library that the app may show with a preview and a ⋯ menu: a chart's, a
/// Discover playlist's, an artist's top song, or a search hit. It may not know its MusicBrainz ids yet.
public struct OutsideSong: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds.
    public var duration: TimeInterval?
    public var deezerAlbumId: String?
    public var artistMBID: MBID?
    public var releaseGroupMBID: MBID?
    public var recordingMBID: MBID?
    /// The server's preview id (a Deezer track id), when it has one.
    public var previewId: String?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil,
                deezerAlbumId: String? = nil, artistMBID: MBID? = nil, releaseGroupMBID: MBID? = nil,
                recordingMBID: MBID? = nil, previewId: String? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.deezerAlbumId = deezerAlbumId; self.artistMBID = artistMBID; self.releaseGroupMBID = releaseGroupMBID
        self.recordingMBID = recordingMBID; self.previewId = previewId
    }

    public init(_ song: AurralSong) {
        self.init(title: song.trackName, artist: song.artistName, album: song.albumName,
                  duration: song.durationMs.map { TimeInterval($0) / 1000 }, deezerAlbumId: song.deezerAlbumId,
                  previewId: song.preview?.trackId)
    }

    public init(_ recording: ExternalRecording, previewId: String? = nil) {
        self.init(title: recording.title, artist: recording.artist, album: recording.releaseTitle,
                  duration: recording.duration, artistMBID: recording.artistMBID, recordingMBID: recording.recordingMBID,
                  previewId: previewId)
    }

    /// The song as the request machinery knows a song (only once it has its recording MBID: `OutsideSongMatch`).
    public var recording: ExternalRecording? {
        guard let recordingMBID else { return nil }
        return ExternalRecording(recordingMBID: recordingMBID, artistMBID: artistMBID, title: title, artist: artist,
                                 releaseTitle: album, duration: duration, source: .lidarr)
    }
}

/// D100: an outside song's MusicBrainz ids. The server's editorial links give the artist and the album (release group);
/// then the recording is the track of that release group's chosen release with the same normalised title and a length
/// within 3 s (`SongIdentity`). Never by name alone; anything short of that is `unmatched` ("Couldn't match this song").
public enum OutsideSongMatch {
    public enum Failure: Error, Equatable { case unmatched }

    /// `(artist name, album title, Deezer album id) → (artist MBID, release group MBID)`; the app passes the server's
    /// `editorialLinks`.
    public typealias Links = @Sendable (String, String?, String?) async throws -> (artist: MBID?, album: MBID?)
    /// A release group's chosen release with its tracklist (`OutsideCatalog.release(releaseGroup:)`).
    public typealias Release = @Sendable (MBID) async throws -> MBReleaseDetail?

    public static func resolve(_ song: OutsideSong, links: Links, release: Release) async throws -> ExternalRecording {
        if let known = song.recording { return known }
        var artistMBID = song.artistMBID
        var group = song.releaseGroupMBID
        if group == nil || artistMBID == nil {
            guard let found = try? await links(song.artist, song.album, song.deezerAlbumId) else { throw Failure.unmatched }
            artistMBID = artistMBID ?? found.artist
            group = group ?? found.album
        }
        guard let group, let detail = try? await release(group),
              let track = detail.tracks.first(where: {
                  SongIdentity.sameDuration($0.length, song.duration)
                      && SongIdentity.titleKey($0.title) == SongIdentity.titleKey(song.title)
                      && !SongIdentity.titleKey(song.title).isEmpty
              }) else { throw Failure.unmatched }
        return ExternalRecording(recordingMBID: track.recording, artistMBID: artistMBID, title: track.title,
                                 artist: song.artist, releaseTitle: detail.title, duration: track.length, source: .lidarr,
                                 releaseMBID: detail.id)
    }

    /// The artist's MBID alone (Add artist).
    public static func artist(_ song: OutsideSong, links: Links) async throws -> MBID {
        if let known = song.artistMBID { return known }
        guard let found = try? await links(song.artist, song.album, song.deezerAlbumId), let mbid = found.artist else {
            throw Failure.unmatched
        }
        return mbid
    }
}

/// Owner answer 7 (D103): the preview for a song the server didn't list itself (ListenBrainz's, a tracklist's): the same
/// song among what the server can preview. `artistSongs` were asked for by the artist's MBID (the artist's top songs),
/// so their artist counts as matched; `otherSongs` (loaded charts and Discover playlists) must name the artist.
public enum PreviewMatch {
    public static func find(title: String, artist: String, duration: TimeInterval?, artistSongs: [AurralSong],
                            otherSongs: [AurralSong]) -> AurralSong? {
        let key = SongIdentity.titleKey(title)
        guard !key.isEmpty, SongIdentity.sameDuration(duration, duration) else { return nil }
        func fits(_ s: AurralSong) -> Bool {
            s.preview != nil && SongIdentity.titleKey(s.trackName) == key
                && SongIdentity.sameDuration(s.durationMs.map { TimeInterval($0) / 1000 }, duration)
        }
        if let hit = artistSongs.first(where: fits) { return hit }
        let artistKey = SongIdentity.artistKey(artist)
        return otherSongs.first { fits($0) && SongIdentity.artistKey($0.artistName) == artistKey }
    }
}

/// D104: the sources an artist's Top songs can come from.
public enum TopSongsProvider: String, Sendable, Hashable, CaseIterable {
    case aurral, listenBrainz, library
}

/// D104: the order to ask the sources in (the chosen one, then Automatic's: the server, ListenBrainz, the library), and
/// the first that answers with songs.
public enum TopSongsPlan {
    public static let automatic: [TopSongsProvider] = [.aurral, .listenBrainz, .library]

    public static func order(_ chosen: ArtistTopSongsSource, available: Set<TopSongsProvider>) -> [TopSongsProvider] {
        let first: TopSongsProvider? = switch chosen {
        case .automatic: nil
        case .aurral: .aurral
        case .listenBrainz: .listenBrainz
        case .library: .library
        }
        var order: [TopSongsProvider] = []
        for p in [first].compactMap({ $0 }) + automatic where available.contains(p) && !order.contains(p) { order.append(p) }
        return order
    }

    /// The first source in `order` that reads with songs; a failing or empty one passes to the next. Nil: none had any.
    public static func load<Row: Sendable>(_ order: [TopSongsProvider],
                                           read: (TopSongsProvider) async throws -> [Row]) async -> (provider: TopSongsProvider, rows: [Row])? {
        for provider in order {
            guard !Task.isCancelled else { return nil }
            if let rows = try? await read(provider), !rows.isEmpty { return (provider, rows) }
        }
        return nil
    }

    /// Whether the row says where its songs came from: the chosen source (Automatic: the first available) had none.
    public static func fellBack(chosen: ArtistTopSongsSource, used: TopSongsProvider, order: [TopSongsProvider]) -> Bool {
        used != order.first
    }
}
