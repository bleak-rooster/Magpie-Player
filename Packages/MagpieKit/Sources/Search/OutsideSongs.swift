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

    /// S14 M2 (D116): Lidarr's name for an artist MBID (`artist/lookup?term=lidarr:<mbid>`); nil when it knows none.
    public typealias ArtistName = @Sendable (MBID) async throws -> String?

    /// `artistName` checks the artist the links name (S14 M2): the recording keeps it only when Lidarr's name for it is
    /// the song's artist; otherwise it carries none, and the request takes MusicBrainz's own artist for the recording.
    /// Round 19: the way to a recording that needs no music server: MusicBrainz's recordings of a title by an artist.
    /// (The phone never asks Deezer itself, plan decision 11, so a chart row's ISRC isn't read.)
    public struct Finder: Sendable {
        public var search: @Sendable (_ title: String, _ artist: String) async throws -> [MBRecording]

        public init(search: @escaping @Sendable (_ title: String, _ artist: String) async throws -> [MBRecording]) {
            self.search = search
        }
    }

    /// The song's recording, by the first way that names it (round 19, owner: popular singles weren't found):
    /// 1. its own recording MBID;
    /// 2. the server's editorial links (artist and album) and that album's tracklist, by title and length (D100);
    /// 3. MusicBrainz's recordings of the title by the song's artist: the same title, an artist of the credit, the length
    ///    within `searchLengthSlack` when both are known; one on a plain official release first. This needs no music
    ///    server (Lidarr alone), and catches what the links miss: a single too new for them, a deluxe or compilation
    ///    album, a radio edit, a duet.
    /// Never by name alone without the artist; anything short of that is `unmatched` ("Couldn't match this song").
    public static func resolve(_ song: OutsideSong, links: Links, release: Release,
                               artistName: ArtistName = { _ in nil }, finder: Finder? = nil) async throws -> ExternalRecording {
        if let known = song.recording { return known }
        if let linked = try? await byLinks(song, links: links, release: release, artistName: artistName) { return linked }
        let title = Self.searchTitle(song.title)
        if let finder, !title.isEmpty, let found = try? await finder.search(title, primaryArtist(song.artist)),
           let pick = Self.pick(found, for: song) {
            return Self.recording(pick, song: song)
        }
        throw Failure.unmatched
    }

    /// D100's way: the server's editorial links, then the album's tracklist by title and length.
    static func byLinks(_ song: OutsideSong, links: Links, release: Release, artistName: ArtistName) async throws -> ExternalRecording {
        var artistMBID = song.artistMBID
        var group = song.releaseGroupMBID
        if group == nil || artistMBID == nil {
            guard let found = try? await links(song.artist, song.album, song.deezerAlbumId) else { throw Failure.unmatched }
            if artistMBID == nil, let linked = found.artist, await names(linked, song.artist, artistName) {
                artistMBID = linked
            }
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

    /// How far a search hit's length may be from the song's (a radio edit and the album version differ by more than D100's
    /// 3 s; a different recording of the song by more than this).
    public static let searchLengthSlack: TimeInterval = 8

    /// The recording of `song` among `found`, or nil: the title, an artist of the credit, and the length (when both are
    /// known) must all match. Best first: the title, a plain official single/EP/album holding it, one named after the song, the length closest,
    /// then the most releases (the one people have).
    public static func pick(_ found: [MBRecording], for song: OutsideSong) -> MBRecording? {
        let key = SongIdentity.titleKey(song.title)
        let artists = Set([song.artist, primaryArtist(song.artist)].map(SongIdentity.artistKey)).subtracting([""])
        func titled(_ r: MBRecording) -> Bool { !key.isEmpty && SongIdentity.titleKey(r.title) == key }
        func credited(_ r: MBRecording) -> Bool { r.artistNames.contains { artists.contains(SongIdentity.artistKey($0)) } }
        func gap(_ r: MBRecording) -> TimeInterval? {
            guard let a = r.length, let b = song.duration, a.isFinite, b.isFinite else { return nil }
            return abs(a - b)
        }
        let fits = found.filter { r in titled(r) && credited(r) && gap(r).map { $0 <= searchLengthSlack } != false }
        func plain(_ r: MBRecording) -> Bool {
            r.releases.contains { rel in
                rel.status?.lowercased() == "official" && rel.releaseGroup.secondaryTypes.isEmpty
                    && ["single", "ep", "album"].contains(rel.releaseGroup.primaryType?.lowercased() ?? "")
            }
        }
        func named(_ r: MBRecording) -> Bool { r.releases.contains { !key.isEmpty && SongIdentity.titleKey($0.title) == key } }
        return fits.max { a, b in
            if titled(a) != titled(b) { return !titled(a) }
            if plain(a) != plain(b) { return !plain(a) }
            if named(a) != named(b) { return !named(a) }
            let (ga, gb) = (gap(a) ?? .infinity, gap(b) ?? .infinity)
            if ga != gb { return ga > gb }
            return a.releases.count < b.releases.count
        }
    }

    /// The request's recording: the song's own names and length, MusicBrainz's ids; the artist the credit names as the
    /// song's own (a duet's first-named artist on the server's row), else the credit's first.
    static func recording(_ r: MBRecording, song: OutsideSong) -> ExternalRecording {
        let artists = Set([song.artist, primaryArtist(song.artist)].map(SongIdentity.artistKey)).subtracting([""])
        let index = r.artistNames.firstIndex { artists.contains(SongIdentity.artistKey($0)) }
        let artist = song.artistMBID ?? index.flatMap { r.artistIds.indices.contains($0) ? r.artistIds[$0] : nil }
            ?? r.artistIds.first
        return ExternalRecording(recordingMBID: r.id, artistMBID: artist, title: song.title, artist: song.artist,
                                 releaseTitle: song.album, duration: r.length ?? song.duration,
                                 isrcs: r.isrcs, source: .lidarr)
    }

    /// The title MusicBrainz is searched for: without a featured-artist note ("Song (feat. X)" is "Song" there).
    static func searchTitle(_ title: String) -> String {
        var t = title
        for marker in ["(feat.", "(ft.", "(featuring", "[feat.", "(with ", " feat. ", " ft. "] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The artist's MBID alone (Add artist, Whole artist): the song's own, else the one the links name, but only when
    /// Lidarr's name for that MBID is the song's artist (S14 M2, D116: never an artist the server alone vouches for).
    public static func artist(_ song: OutsideSong, links: Links, artistName: ArtistName) async throws -> MBID {
        if let known = song.artistMBID { return known }
        guard let found = try? await links(song.artist, song.album, song.deezerAlbumId), let mbid = found.artist,
              await names(mbid, song.artist, artistName) else {
            throw Failure.unmatched
        }
        return mbid
    }

    /// Whether Lidarr's name for `mbid` is `artist`, or the primary artist of a featured or joined credit ("X feat. Y",
    /// "X & Y": X), compared whole and folded (case, accents, "Tides, The"); never a part after the first, never a
    /// substring. Any failure is no.
    static func names(_ mbid: MBID, _ artist: String, _ artistName: ArtistName) async -> Bool {
        let keys = Set([artist, primaryArtist(artist)].map(SongIdentity.artistKey)).subtracting([""])
        guard !keys.isEmpty, let named = try? await artistName(mbid) else { return false }
        return keys.contains(SongIdentity.artistKey(named))
    }

    /// Where a credit's featured or joined artists start (case-insensitive).
    static let creditSeparators = [" feat. ", " ft. ", " featuring ", " with ", " x ", " & ", ", "]

    /// The credit up to its first featured or joined part ("X feat. Y & Z" → "X"); the whole credit when it has none.
    static func primaryArtist(_ credit: String) -> String {
        let cut = creditSeparators.compactMap { credit.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        return cut.map { String(credit[..<$0]) } ?? credit
    }
}

/// Owner answer 7 (D103): the preview for a song the server didn't list itself (ListenBrainz's, a tracklist's): the same
/// song among what the server can preview. `artistSongs` were asked for by the artist's MBID (the artist's top songs),
/// so their artist counts as matched; `otherSongs` (loaded charts and Discover playlists) must name the artist.
public enum PreviewMatch {
    public static func find(title: String, artist: String, duration: TimeInterval?, artistSongs: [AurralSong],
                            otherSongs: [AurralSong]) -> AurralSong? {
        let key = SongIdentity.titleKey(title)
        guard !key.isEmpty, duration.map({ $0.isFinite && $0 > 0 }) == true else { return nil }   // the length must be known
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
    public static func load<Row>(_ order: [TopSongsProvider], isolation: isolated (any Actor)? = #isolation,
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
