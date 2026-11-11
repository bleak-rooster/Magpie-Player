import Foundation
import MagpieCore

/// Round 26 K1 (owner, 2026-11-10): what an artist's top songs need from the index (D260, D263). The album step links a
/// Lidarr track to its library song by recording id, else by the artist's songs on the same album with the same title and
/// length; the saved list (K2) drops songs the library no longer has. Reads `entries` only: the ladder (`match`,
/// `librarySong`) and the snapshot format are unchanged.
extension MatchIndex {
    /// One of an artist's library songs as the index keeps it: the title and album are `Normalize.name`d (the index
    /// doesn't keep the file's own title), the length is nil when unknown.
    public struct ArtistSong: Sendable, Hashable {
        public var id: String
        public var title: String
        public var album: String
        public var duration: TimeInterval?
        public var recording: MBID?
    }

    /// The library song with this recording MBID, or nil: the first one `avoiding` doesn't name, else the first (as the
    /// ladder's tier 1 takes it). Fix round 1 (M5): the index doesn't keep a song's library, so the caller names the ids
    /// it knows are Discover copies; a Discover copy listed first then never hides the main library's copy.
    public func songId(recording: MBID, avoiding: (String) -> Bool = { _ in false }) -> String? {
        let all = entries.lazy.filter { $0.recording == recording.rawValue }.map(\.id)
        return all.first { !avoiding($0) } ?? all.first
    }

    /// The artist's library songs: those tagged with `mbid`, and untagged ones whose artist has the same normalised name;
    /// never a namesake tagged with another MBID. Without an MBID, by the normalised name alone. An empty name and no
    /// MBID find none.
    public func artistSongs(name: String, mbid: MBID?) -> [ArtistSong] {
        let n = Normalize.name(name)
        guard mbid != nil || !n.isEmpty else { return [] }
        return entries.filter { e in
            if let mbid, e.artistMBID == mbid.rawValue { return true }
            if mbid != nil, e.artistMBID != nil { return false }
            return !n.isEmpty && e.artist == n
        }.map { e in
            ArtistSong(id: e.id, title: e.title, album: e.album, duration: e.duration, recording: e.recording.flatMap(MBID.init))
        }
    }

    /// Whether the library still has a song with this id.
    public func contains(songId: String) -> Bool {
        entries.contains { $0.id == songId }
    }
}
