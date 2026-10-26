import Foundation
import MagpieCore

/// Finds the library song an outside recording already is (the match ladder, research §4):
///
/// | tier | rule | confidence |
/// |---|---|---|
/// | 1 | same recording MBID | 1.0 |
/// | 2 | a shared ISRC | 0.95 |
/// | 3 | same artist MBID + normalised title + \|Δd\| ≤ 3 s | 0.9 |
/// | 4 | same normalised artist + title + \|Δd\| ≤ 3 s | 0.8 |
/// | 5 | same normalised artist + title, a duration unknown | 0.6 |
///
/// Merging accepts ≥ `acceptThreshold`. Two known durations more than 3 s apart never match by name.
public struct MatchIndex: Sendable, Codable {
    public static let acceptThreshold = 0.8
    public static let durationTolerance: TimeInterval = 3

    /// What the index keeps per song: only the fields the ladder reads (also the snapshot format).
    struct Entry: Sendable, Codable, Hashable {
        var id: String
        var key: String
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval?
        var recording: String?
        var artistMBID: String?
        var isrcs: [String]?

        enum CodingKeys: String, CodingKey {
            case id = "i", key = "k", title = "t", artist = "a", album = "l", duration = "d"
            case recording = "r", artistMBID = "m", isrcs = "s"
        }
    }

    let entries: [Entry]
    private let byRecording: [String: Int]
    private let byISRC: [String: Int]
    private let byArtistMBIDTitle: [String: [Int]]
    private let byKey: [String: [Int]]
    private let artistNames: Set<String>
    private let artistMBIDs: Set<String>
    private let albums: Set<String>

    public static let empty = MatchIndex(songs: [])

    public init(songs: [Song]) {
        self.init(entries: songs.map { s in
            Entry(id: s.id, key: Normalize.key(artist: s.artist, title: s.title), title: Normalize.name(s.title),
                  artist: Normalize.name(s.artist), album: Normalize.name(s.album),
                  duration: s.duration > 0 ? s.duration : nil, recording: s.recordingMBID?.rawValue,
                  artistMBID: s.artistMBID?.rawValue, isrcs: s.isrcs.isEmpty ? nil : s.isrcs.map { $0.uppercased() })
        })
    }

    init(entries: [Entry]) {
        self.entries = entries
        var byRecording: [String: Int] = [:], byISRC: [String: Int] = [:]
        var byArtistMBIDTitle: [String: [Int]] = [:], byKey: [String: [Int]] = [:]
        var artistNames = Set<String>(), artistMBIDs = Set<String>(), albums = Set<String>()
        for (i, e) in entries.enumerated() {
            if let r = e.recording, byRecording[r] == nil { byRecording[r] = i }
            for isrc in e.isrcs ?? [] where byISRC[isrc] == nil { byISRC[isrc] = i }
            if let m = e.artistMBID {
                byArtistMBIDTitle[m + "\u{1F}" + e.title, default: []].append(i)
                artistMBIDs.insert(m)
            }
            byKey[e.key, default: []].append(i)
            if !e.artist.isEmpty { artistNames.insert(e.artist) }
            if !e.album.isEmpty { albums.insert(e.artist + "\u{1F}" + e.album) }
        }
        self.byRecording = byRecording; self.byISRC = byISRC
        self.byArtistMBIDTitle = byArtistMBIDTitle; self.byKey = byKey
        self.artistNames = artistNames; self.artistMBIDs = artistMBIDs; self.albums = albums
    }

    public init(from decoder: Decoder) throws {
        self.init(entries: try decoder.singleValueContainer().decode([Entry].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(entries)
    }

    public var count: Int { entries.count }

    /// The best library match for `r`, or nil. Callers merge only at ≥ `acceptThreshold`.
    public func match(_ r: ExternalRecording) -> (songId: String, confidence: Double)? {
        if let m = r.recordingMBID, let i = byRecording[m.rawValue] { return (entries[i].id, 1.0) }
        for isrc in r.isrcs {
            if let i = byISRC[isrc.uppercased()] { return (entries[i].id, 0.95) }
        }
        let title = Normalize.name(r.title)
        if let m = r.artistMBID, let hits = byArtistMBIDTitle[m.rawValue + "\u{1F}" + title],
           let i = hits.first(where: { durationsAgree(entries[$0].duration, r.duration) == true }) {
            return (entries[i].id, 0.9)
        }
        guard let hits = byKey[Normalize.key(artist: r.artist, title: r.title)] else { return nil }
        if let i = hits.first(where: { durationsAgree(entries[$0].duration, r.duration) == true }) {
            return (entries[i].id, 0.8)
        }
        if let i = hits.first(where: { durationsAgree(entries[$0].duration, r.duration) == nil }) {
            return (entries[i].id, 0.6)
        }
        return nil
    }

    /// The library song `r` already is, for hiding duplicates in search: a match at ≥ `acceptThreshold`,
    /// or a by-name match (0.6) when exactly one library song has that artist and title (research §4,
    /// step 5: "treat as in-library only if unambiguous"). LB search carries no durations, so without
    /// this every untagged library song would also show up as "Not in your library".
    public func librarySong(for r: ExternalRecording) -> String? {
        guard let m = match(r) else { return nil }
        if m.confidence >= Self.acceptThreshold { return m.songId }
        return byKey[Normalize.key(artist: r.artist, title: r.title)]?.count == 1 ? m.songId : nil
    }

    /// Whether the library has songs by this artist (by MBID, else by normalised name).
    public func hasArtist(name: String, mbid: MBID?) -> Bool {
        if let mbid, artistMBIDs.contains(mbid.rawValue) { return true }
        let n = Normalize.name(name)
        return !n.isEmpty && artistNames.contains(n)
    }

    /// Whether the library has songs from an album with this (normalised) artist and title.
    public func hasAlbum(title: String, artist: String) -> Bool {
        albums.contains(Normalize.name(artist) + "\u{1F}" + Normalize.name(title))
    }

    /// true: both known and within tolerance; false: both known and apart; nil: one is unknown.
    private func durationsAgree(_ a: TimeInterval?, _ b: TimeInterval?) -> Bool? {
        guard let a, let b, b > 0 else { return nil }
        return abs(a - b) <= Self.durationTolerance
    }
}
