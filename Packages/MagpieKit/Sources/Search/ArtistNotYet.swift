import Foundation
import LidarrKit
import MagpieCore
import MatchIndex

/// The Artist page's "Not in your library" albums, from the connected Lidarr. Read-only (GETs only).
/// With the artist's MBID, the reliable ID lookup comes first (A10): an artist Lidarr has lists its albums from
/// Lidarr; otherwise Lidarr's text search stands in, keeping only album rows by this artist. Albums the library
/// already has (same release group, else the same normalised title) are left out. A failure or a Lidarr that takes
/// longer than 5 s shows nothing.
public enum ArtistNotYet {
    public static let timeout = MergedSearch.sourceTimeout
    /// Most albums shown.
    public static let limit = 30

    /// - Parameter library: the artist's albums in the library (what the page already shows).
    public static func albums(artist: String, mbid: MBID?, library: [Album], lidarr: LidarrClient,
                              timeout: Duration = ArtistNotYet.timeout,
                              sleep: @escaping MergedSearch.Sleep = { try await Task.sleep(for: $0) }) async -> [NotYetAlbum] {
        let found = try? await MergedSearch.withDeadline(timeout, sleep: sleep) {
            try await candidates(artist: artist, mbid: mbid, lidarr: lidarr)
        }
        return excluding(found ?? [], library: library)
    }

    static func candidates(artist: String, mbid: MBID?, lidarr: LidarrClient) async throws -> [NotYetAlbum] {
        if let mbid, let id = try await lidarr.artistLookup(mbid: mbid)?.id {
            let calendar = Calendar(identifier: .gregorian)
            return try await lidarr.albums(artistId: id).map {
                NotYetAlbum(title: $0.title, artist: artist, mbid: $0.foreignAlbumId, artistMBID: mbid,
                            year: $0.releaseDate.map { calendar.component(.year, from: $0) }, kind: $0.albumType)
            }
        }
        let name = Normalize.name(artist)
        guard !name.isEmpty else { return [] }
        return MergedSearch.Source.hits(from: try await lidarr.search(term: artist)).albums.filter {
            if let mbid { $0.artistMBID == mbid } else { Normalize.name($0.artist) == name }
        }
    }

    /// Words that mark an edition of the same album after a dash ("Glasshouse - Deluxe Edition").
    static let editionWords: Set<String> = [
        "deluxe", "edition", "remaster", "remastered", "expanded", "anniversary", "special", "collectors", "collector",
        "bonus", "reissue", "legacy", "limited", "super",
    ]

    /// An album title for matching: `Normalize.name` (which drops bracketed housekeeping asides), plus a dash suffix
    /// that only names an edition. A suffix with a version word ("- Live", "- Demo Edition") keeps it distinct.
    static func titleKey(_ title: String) -> String {
        for dash in [" - ", " \u{2013} ", " \u{2014} "] {
            guard let r = Normalize.lastRange(of: dash, in: title) else { continue }   // linear (crash hunt 4)
            let words = Normalize.name(String(title[r.upperBound...])).split(separator: " ").map(String.init)
            let head = Normalize.name(String(title[..<r.lowerBound]))
            if !head.isEmpty, words.contains(where: editionWords.contains),
               !words.contains(where: { Normalize.versionWords.contains($0) || $0.hasPrefix("remix") }) {
                return head
            }
            break
        }
        return Normalize.name(title)
    }

    /// Drops untitled albums and the library's own, one row per album, newest first, at most `limit`.
    static func excluding(_ candidates: [NotYetAlbum], library: [Album]) -> [NotYetAlbum] {
        let groups = Set(library.compactMap(\.releaseGroupMBID))
        let titles = Set(library.map { titleKey($0.name) })
        var seen = Set<String>()
        let kept = candidates.filter { a in
            let title = titleKey(a.title)
            guard !title.isEmpty, !(a.mbid.map(groups.contains) ?? false), !titles.contains(title) else { return false }
            return seen.insert(a.mbid?.rawValue ?? title).inserted && seen.insert("t" + title).inserted
        }
        return Array(kept.enumerated().sorted { a, b in
            (a.element.year ?? 0) != (b.element.year ?? 0) ? (a.element.year ?? 0) > (b.element.year ?? 0) : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }
}
