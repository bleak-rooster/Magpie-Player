import Foundation
import LidarrKit
import MagpieCore
import MatchIndex

/// Round 26 K1 (owner, 2026-11-10, item 3): "If there is no immediately equivalent match, then Magpie should try and find
/// the match within the albums and/or EPs (since sometimes it is a single that has not been downloaded independently)."
/// (D260.) The artist is in Lidarr, so Lidarr already holds MusicBrainz's tracklists of their releases, each release's
/// type and which tracks have a file: two reads on the owner's network instead of rate-limited MusicBrainz calls, and the
/// types refuse live, remix and demo releases outright. Then the track is linked to its library song. When in doubt,
/// skip: a wrong song is worse than a missing one (plan §4).
public enum AlbumTrackMatch {
    /// The primary types searched ("albums and/or EPs"); never Single, Broadcast or Other.
    static let primaryTypes: Set<String> = ["album", "ep"]
    /// The secondary types allowed besides none (a studio release); anything else (Live, Remix, DJ-mix, Demo,
    /// Mixtape/Street, Spokenword, Interview, Audiobook, Audio drama…) makes the release ineligible.
    static let allowedSecondaryTypes: Set<String> = ["compilation", "soundtrack"]
    /// The album step's length guard: the track is 0.5×–2× the top song's length when both are known (an edit can be
    /// minutes shorter than the album take; a mis-titled interlude is caught).
    static let lengthRatio: ClosedRange<Double> = 0.5...2

    /// Whether a release can hold the top song's album copy: an Album or EP (case-insensitive) that is studio, a
    /// soundtrack or a compilation. A release with no type is never eligible.
    public static func isEligible(_ album: LidarrAlbum) -> Bool {
        guard let type = album.albumType?.lowercased(), primaryTypes.contains(type) else { return false }
        return album.secondaryTypes.allSatisfy { allowedSecondaryTypes.contains($0.lowercased()) }
    }

    /// The Lidarr track to use for a top song, or nil. Eligible: the track has a file; its release `isEligible`; its
    /// title has the top song's `TopSongIdentity.titleKey` (non-empty); its length within `lengthRatio` of the top song's
    /// when both are known. Of several: the top song's own recording first, then studio Album, studio EP, Soundtrack,
    /// Compilation, then the smallest length difference, then the earliest release date, then the lowest track id.
    public static func find(title: String, duration: TimeInterval?, recording: MBID?, albums: [LidarrAlbum],
                            tracks: [LidarrTrack]) -> LidarrTrack? {
        let key = TopSongIdentity.titleKey(title)
        guard !key.isEmpty else { return nil }
        let wanted = known(duration)
        var byId: [Int: LidarrAlbum] = [:]
        for album in albums where byId[album.id] == nil { byId[album.id] = album }
        let fits: [(track: LidarrTrack, album: LidarrAlbum)] = tracks.compactMap { track in
            guard track.hasFile, let albumId = track.albumId, let album = byId[albumId], isEligible(album),
                  TopSongIdentity.titleKey(track.title ?? "") == key else { return nil }
            if let wanted, let length = known(track.duration),
               !lengthRatio.contains(length / wanted) { return nil }
            return (track, album)
        }
        func sameRecording(_ t: LidarrTrack) -> Bool {
            guard let recording, let id = t.foreignRecordingId else { return false }
            return MBID(id) == recording
        }
        func gap(_ t: LidarrTrack) -> TimeInterval {
            guard let wanted, let length = known(t.duration) else { return .infinity }
            return abs(length - wanted)
        }
        return fits.min { a, b in
            if sameRecording(a.track) != sameRecording(b.track) { return sameRecording(a.track) }
            let (ra, rb) = (rank(a.album), rank(b.album))
            if ra != rb { return ra < rb }
            let (ga, gb) = (gap(a.track), gap(b.track))
            if ga != gb { return ga < gb }
            let (da, db) = (a.album.releaseDate ?? .distantFuture, b.album.releaseDate ?? .distantFuture)
            if da != db { return da < db }
            return a.track.id < b.track.id
        }?.track
    }

    /// The track's release, as `find` uses it.
    public static func album(of track: LidarrTrack, in albums: [LidarrAlbum]) -> LidarrAlbum? {
        guard let albumId = track.albumId else { return nil }
        return albums.first { $0.id == albumId }
    }

    /// Studio Album 0, studio EP 1, Soundtrack 2, Compilation (with or without Soundtrack) 3.
    static func rank(_ album: LidarrAlbum) -> Int {
        let secondary = Set(album.secondaryTypes.map { $0.lowercased() })
        if secondary.contains("compilation") { return 3 }
        if secondary.contains("soundtrack") { return 2 }
        return album.albumType?.lowercased() == "ep" ? 1 : 0
    }

    // MARK: - The library link

    /// The library song for a Lidarr track (D260): the index's song with the track's recording id; else exactly one of the
    /// artist's songs (`MatchIndex.artistSongs`) on the same album (`Normalize.name` of Lidarr's album title), with the
    /// same `TopSongIdentity.titleKey` and a length within 3 s of Lidarr's; else nil (none, or more than one). Never by
    /// name alone: Lidarr's length must be known.
    public static func librarySongId(track: LidarrTrack, album: LidarrAlbum, artistName: String, artistMBID: MBID?,
                                     index: MatchIndex, avoiding: (String) -> Bool = { _ in false }) -> String? {
        if let id = track.foreignRecordingId.flatMap(MBID.init),
           let song = index.songId(recording: id, avoiding: avoiding) { return song }   // fix round 1, M5
        let key = TopSongIdentity.titleKey(track.title ?? "")
        let albumKey = Normalize.name(album.title)
        guard !key.isEmpty, !albumKey.isEmpty, let length = known(track.duration) else { return nil }
        let hits = index.artistSongs(name: artistName, mbid: artistMBID).filter { song in
            // The index keeps `Normalize.name`d titles, so the library side is compared in that form; K2 holds the full
            // song to the strict rule again (`links`) before it shows it.
            song.album == albumKey && TopSongIdentity.titleKey(song.title) == key
                && known(song.duration).map { abs($0 - length) <= MatchIndex.durationTolerance } == true
        }
        return hits.count == 1 ? hits.first?.id : nil
    }

    /// Whether a full library song (from `getSong`, or a search for a track the index couldn't link) is the track's
    /// copy: the same recording id; else the artist's (by MBID, else by name when the song has none), on the same
    /// album, with the same strict title and a length within 3 s of Lidarr's.
    public static func links(_ song: Song, to track: LidarrTrack, album: LidarrAlbum, artistName: String,
                             artistMBID: MBID?) -> Bool {
        if let rec = song.recordingMBID, let id = track.foreignRecordingId.flatMap(MBID.init), rec == id { return true }
        let byArtist: Bool = if let artistMBID, let tagged = song.artistMBID { tagged == artistMBID } else {
            !Normalize.name(artistName).isEmpty && Normalize.name(song.artist) == Normalize.name(artistName)
        }
        let key = TopSongIdentity.titleKey(track.title ?? "")
        guard byArtist, !key.isEmpty, let length = known(track.duration), let mine = known(song.duration) else { return false }
        return Normalize.name(song.album) == Normalize.name(album.title) && !Normalize.name(album.title).isEmpty
            && TopSongIdentity.titleKey(song.title) == key && abs(mine - length) <= MatchIndex.durationTolerance
    }

    /// A length that is one: finite and above zero.
    static func known(_ d: TimeInterval?) -> TimeInterval? {
        guard let d, d.isFinite, d > 0 else { return nil }
        return d
    }
}
