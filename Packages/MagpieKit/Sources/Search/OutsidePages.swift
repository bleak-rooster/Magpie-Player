import Foundation
import ListenBrainzKit
import MagpieCore

/// R19: an outside artist page's albums, from MusicBrainz release groups (official releases only): Albums, EPs and
/// Singles with the studio releases, and everything with a secondary type (Live, Compilation, Soundtrack…) under
/// More. Newest first in each, undated last.
public struct OutsideArtistSections: Equatable, Sendable {
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: MBID
        public var title: String
        /// "Album", "EP", "Single"; under More, the secondary type ("Live").
        public var kind: String
        public var year: Int?
        fileprivate var date: String?
    }

    public var albums: [Item] = []
    public var eps: [Item] = []
    public var singles: [Item] = []
    public var more: [Item] = []

    public var isEmpty: Bool { albums.isEmpty && eps.isEmpty && singles.isEmpty && more.isEmpty }

    public init() {}

    public static func make(_ groups: [MBReleaseGroupSummary]) -> OutsideArtistSections {
        var s = OutsideArtistSections()
        var seen = Set<MBID>()
        for g in groups where seen.insert(g.id).inserted {
            let primary = g.primaryType?.lowercased()
            guard let primary, ["album", "ep", "single"].contains(primary) else { continue }
            let kind = g.secondaryTypes.first ?? (primary == "ep" ? "EP" : g.primaryType ?? "Album")
            let item = Item(id: g.id, title: g.title, kind: kind,
                            year: g.firstReleaseDate.flatMap { Int($0.prefix(4)) }, date: g.firstReleaseDate)
            if !g.secondaryTypes.isEmpty { s.more.append(item) }
            else if primary == "album" { s.albums.append(item) }
            else if primary == "ep" { s.eps.append(item) }
            else { s.singles.append(item) }
        }
        s.albums = newestFirst(s.albums); s.eps = newestFirst(s.eps)
        s.singles = newestFirst(s.singles); s.more = newestFirst(s.more)
        return s
    }

    private static func newestFirst(_ items: [Item]) -> [Item] {
        items.enumerated().sorted { a, b in
            let (x, y) = (a.element.date ?? "", b.element.date ?? "")
            return x != y ? x > y : a.offset < b.offset   // "" (undated) sorts last
        }.map(\.element)
    }
}

/// R19: which release of a release group the outside album page lists. Official first (any release if none is), then
/// the earliest dated (the original issue rather than a later deluxe one), undated after dated; a release without
/// tracks is never picked.
public enum OutsideReleasePick {
    public static func pick(_ releases: [MBReleaseDetail]) -> MBReleaseDetail? {
        let listed = releases.filter { !$0.tracks.isEmpty }
        let official = listed.filter { $0.status?.lowercased() == "official" }
        let pool = official.isEmpty ? listed : official
        return pool.enumerated().min { a, b in
            let (x, y) = (a.element.date ?? "9999", b.element.date ?? "9999")
            return x != y ? x < y : a.offset < b.offset
        }?.element
    }

    /// The tracks as songs to Try.
    public static func recordings(_ release: MBReleaseDetail, artist: String, artistMBID: MBID?) -> [ExternalRecording] {
        release.tracks.map {
            ExternalRecording(recordingMBID: $0.recording, artistMBID: artistMBID, title: $0.title, artist: artist,
                              releaseTitle: release.title, duration: $0.length, source: .lidarr, releaseMBID: release.id)
        }
    }
}

/// R19: what the outside pages read from MusicBrainz, kept in memory for this session only (never on disk). A failure
/// isn't kept, so the next visit asks again.
public actor OutsideCatalog {
    public typealias ReleaseGroups = @Sendable (MBID) async throws -> [MBReleaseGroupSummary]
    public typealias Releases = @Sendable (MBID) async throws -> [MBReleaseDetail]

    private let fetchGroups: ReleaseGroups
    private let fetchReleases: Releases
    private var groups: [MBID: [MBReleaseGroupSummary]] = [:]
    private var releases: [MBID: MBReleaseDetail?] = [:]

    public init(releaseGroups: @escaping ReleaseGroups, releases: @escaping Releases) {
        fetchGroups = releaseGroups; fetchReleases = releases
    }

    public init(musicBrainz: MusicBrainzClient) {
        self.init(releaseGroups: { try await musicBrainz.officialReleaseGroups(artist: $0) },
                  releases: { try await musicBrainz.officialReleases(releaseGroup: $0) })
    }

    public func releaseGroups(artist: MBID) async throws -> [MBReleaseGroupSummary] {
        if let known = groups[artist] { return known }
        let fresh = try await fetchGroups(artist)
        groups[artist] = fresh
        return fresh
    }

    /// The release the album page lists (nil: none to list).
    public func release(releaseGroup: MBID) async throws -> MBReleaseDetail? {
        if let known = releases[releaseGroup] { return known }
        let picked = OutsideReleasePick.pick(try await fetchReleases(releaseGroup))
        releases[releaseGroup] = .some(picked)
        return picked
    }

    /// Sign-out or another account: nothing read is kept.
    public func reset() {
        groups = [:]
        releases = [:]
    }
}
