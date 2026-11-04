import Foundation
import MagpieCore

// Round 14 A1: Aurral 2.13's Discover answers (docs/research/aurral-discover.md), read leniently like the 2.10 models:
// every field optional, a bad element dropped, lists capped, and only `AurralError.decoding` when the answer isn't the
// expected JSON at all.

private extension Dictionary where Key == String, Value == Any {
    /// An int, or digits as text (Aurral sends some ids either way).
    func intOrDigits(_ key: String) -> Int? {
        if let n = int(key) { return n }
        guard let s = string(key), AurralRoute.isDigits(Substring(s), max: 9) else { return nil }
        return Int(s)
    }
    func image(_ key: String) -> AurralImage? { AurralImage(string(key)) }
    func preview(_ key: String = "preview_url") -> AurralPreview? { string(key).flatMap(AurralPreview.init(path:)) }
    /// A positive duration in milliseconds.
    func millis(_ key: String) -> Int? { int(key).flatMap { $0 > 0 ? $0 : nil } }
}

private func root(_ data: Data) throws -> [String: Any] {
    guard let o = object(data) as? [String: Any] else { throw AurralError.decoding }
    return o
}

// MARK: - Songs (charts, Discover playlists, an artist's top songs)

/// How a chart song moved since yesterday (`movement`: a number, `"new"`, or null before the second day).
public enum AurralChartMovement: Sendable, Hashable {
    case up(Int), down(Int), same, new

    static func decode(_ value: Any?) -> AurralChartMovement? {
        if let s = value as? String { return s == "new" ? .new : nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              abs(n.doubleValue) < 1e6 else { return nil }
        let d = Int(n.doubleValue)
        return d == 0 ? .same : d > 0 ? .up(d) : .down(-d)
    }
}

/// A song Aurral found on Deezer: a chart entry, a Discover playlist's song, or one of an artist's top songs. It has no
/// MusicBrainz ids (`AurralClient.editorialLinks` finds the artist's and album's).
public struct AurralSong: Sendable, Hashable {
    /// Deezer's track id (`key`; a Discover playlist's song takes it from its preview).
    public var key: String?
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    public var deezerAlbumId: String?
    public var durationMs: Int?
    public var artwork: AurralImage?
    public var largeArtwork: AurralImage?
    public var preview: AurralPreview?
    /// The chart position (1 = No. 1).
    public var position: Int?
    public var movement: AurralChartMovement?

    public init(key: String? = nil, trackName: String, artistName: String, albumName: String? = nil,
                deezerAlbumId: String? = nil, durationMs: Int? = nil, artwork: AurralImage? = nil,
                largeArtwork: AurralImage? = nil, preview: AurralPreview? = nil, position: Int? = nil,
                movement: AurralChartMovement? = nil) {
        self.key = key; self.trackName = trackName; self.artistName = artistName; self.albumName = albumName
        self.deezerAlbumId = deezerAlbumId; self.durationMs = durationMs; self.artwork = artwork
        self.largeArtwork = largeArtwork; self.preview = preview; self.position = position; self.movement = movement
    }

    public var duration: TimeInterval? { durationMs.map { TimeInterval($0) / 1000 } }

    /// A chart or Discover playlist song; nil without a title or an artist.
    static func decode(_ s: [String: Any]) -> AurralSong? {
        guard let trackName = s.text("trackName"), let artistName = s.text("artistName") else { return nil }
        let preview = s.preview()
        let albumId = s.idText("deezerAlbumId")
        return AurralSong(key: s.idText("key") ?? preview?.trackId, trackName: trackName, artistName: artistName,
                          albumName: s.text("albumName"),
                          deezerAlbumId: albumId.flatMap { AurralRoute.isDigits(Substring($0), max: 20) ? $0 : nil },
                          durationMs: s.millis("durationMs"), artwork: s.image("artworkUrl"),
                          largeArtwork: s.image("largeArtworkUrl"), preview: preview,
                          position: s.int("position").flatMap { $0 > 0 ? $0 : nil }, movement: AurralChartMovement.decode(s["movement"]))
    }

    static func decodeList(_ items: Any?) -> [AurralSong] {
        (items as? [Any] ?? []).lazy.compactMap { $0 as? [String: Any] }.compactMap(decode).prefix(aurralListCap).map { $0 }
    }

    /// `GET /api/artists/:mbid/preview`: `{tracks: [{id, title, album, artworkUrl, preview_url, duration_ms}]}`, the
    /// artist's top songs that have previews (up to 6). Aurral doesn't repeat the artist: `artistName` is the one asked.
    public static func decodeArtistPreview(_ data: Data, artistName: String) throws -> [AurralSong] {
        try root(data).objects("tracks", cap: 50).compactMap { t in
            guard let id = t.idText("id"), let title = t.text("title") else { return nil }
            return AurralSong(key: id, trackName: title, artistName: artistName, albumName: t.text("album"),
                              durationMs: t.millis("duration_ms"), artwork: t.image("artworkUrl"), preview: t.preview())
        }
    }
}

// MARK: - Recommended (`GET /api/discover`)

/// A recommended artist (Aurral 2.13 `toDiscoveryArtist`). Recommendations are artists only.
public struct AurralRecommendedArtist: Sendable, Hashable {
    public var mbid: MBID?
    public var name: String
    public var image: AurralImage?
    public var tags: [String]
    public var matchedTags: [String]
    public var sourceArtist: String?
    public var sourceArtists: [String]
    /// The seeds that led here (`supportingSeeds[].artistName`): "Because you like X".
    public var supportingSeeds: [String]
    /// 1 = close to home; 2 or more = further out.
    public var discoveryDepth: Int
    public var firstDiscoveredAt: Date?
    public var matchPercent: Int?
    public var popularityLabel: String?
    public var listeners: Int?

    public init(mbid: MBID?, name: String, image: AurralImage? = nil, tags: [String] = [], matchedTags: [String] = [],
                sourceArtist: String? = nil, sourceArtists: [String] = [], supportingSeeds: [String] = [],
                discoveryDepth: Int = 1, firstDiscoveredAt: Date? = nil, matchPercent: Int? = nil,
                popularityLabel: String? = nil, listeners: Int? = nil) {
        self.mbid = mbid; self.name = name; self.image = image; self.tags = tags; self.matchedTags = matchedTags
        self.sourceArtist = sourceArtist; self.sourceArtists = sourceArtists; self.supportingSeeds = supportingSeeds
        self.discoveryDepth = discoveryDepth; self.firstDiscoveredAt = firstDiscoveredAt; self.matchPercent = matchPercent
        self.popularityLabel = popularityLabel; self.listeners = listeners
    }

    /// Aurral's "Further out" (depth 2 or more).
    public var isFurtherOut: Bool { discoveryDepth >= 2 }

    static func decode(_ a: [String: Any]) -> AurralRecommendedArtist? {
        guard let name = a.text("name") else { return nil }
        return AurralRecommendedArtist(
            mbid: a.mbid("id") ?? a.mbid("navigateTo"), name: name, image: a.image("image"), tags: a.strings("tags", cap: 20),
            matchedTags: a.strings("matchedTags", cap: 20), sourceArtist: a.text("sourceArtist"),
            sourceArtists: a.strings("sourceArtists", cap: 20),
            supportingSeeds: a.objects("supportingSeeds", cap: 20).compactMap { $0.text("artistName") },
            discoveryDepth: max(1, min(a.int("discoveryDepth") ?? 1, 99)), firstDiscoveredAt: a.date("firstDiscoveredAt"),
            matchPercent: a.int("matchPercent").map { max(0, min($0, 100)) }, popularityLabel: a.text("popularityLabel"),
            listeners: a.int("listeners").flatMap { $0 >= 0 ? $0 : nil })
    }
}

/// A seed Aurral built the recommendations from (`basedOn[]`).
public struct AurralSeed: Sendable, Hashable {
    public var name: String
    public var source: String?
    public init(name: String, source: String? = nil) { self.name = name; self.source = source }
}

/// `GET /api/discover?limit=&offset=`: the signed-in user's recommended artists.
public struct AurralRecommendations: Sendable, Equatable {
    public var artists: [AurralRecommendedArtist]
    public var globalTop: [AurralRecommendedArtist]
    public var basedOn: [AurralSeed]
    public var topTags: [String]
    public var topGenres: [String]
    public var lastUpdated: Date?
    /// Aurral is still filling in details.
    public var isEnriching: Bool
    public var configured: Bool?

    public static func decode(_ data: Data) throws -> AurralRecommendations {
        let o = try root(data)
        func artists(_ key: String) -> [AurralRecommendedArtist] {
            o.objects(key, cap: 500).compactMap(AurralRecommendedArtist.decode)
        }
        return AurralRecommendations(
            artists: artists("recommendations"), globalTop: artists("globalTop"),
            basedOn: o.objects("basedOn", cap: 100).compactMap { s in s.text("name").map { AurralSeed(name: $0, source: s.text("source")) } },
            topTags: o.strings("topTags"), topGenres: o.strings("topGenres"), lastUpdated: o.date("lastUpdated"),
            isEnriching: o.bool("isEnriching") ?? false, configured: o.bool("configured"))
    }
}

// MARK: - Trending (`GET /api/discover/trending`)

/// The No. 1 song's last 14 days (`spotlight.ranks`, nil where it wasn't in the chart) and its days at the top.
public struct AurralSpotlight: Sendable, Hashable {
    public var ranks: [Int?]
    public var daysAtTop: Int
    public init(ranks: [Int?], daysAtTop: Int) { self.ranks = ranks; self.daysAtTop = daysAtTop }
}

/// The top songs chart: Deezer's "Top <Country>" playlist.
public struct AurralSongsChart: Sendable, Hashable {
    /// The Deezer playlist (Add flow follows it: `AurralClient.addEditorialPlaylist`).
    public var playlistId: String
    public var playlistName: String
    /// The user's flow for it, once added.
    public var libraryPlaylistId: String?
    public var items: [AurralSong]
    public var spotlight: AurralSpotlight?
}

/// A top album (Apple Music's chart; no MBIDs and no previews).
public struct AurralChartAlbum: Sendable, Hashable {
    public var key: String
    public var name: String
    public var artistName: String
    public var artwork: AurralImage?
    public var releaseDate: String?
    public var genre: String?
    public var position: Int?
}

/// A top artist (Deezer's chart; the MBID is Aurral's guess and may be missing).
public struct AurralChartArtist: Sendable, Hashable {
    public var key: String
    public var name: String
    public var image: AurralImage?
    public var fans: Int?
    public var mbid: MBID?
    public var position: Int?
}

/// A genre chart's tile (`genres[]`): `AurralClient.trendingGenre(id)` has its 50 songs.
public struct AurralGenreTile: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var covers: [AurralImage]
    public var artists: [String]
}

/// `GET /api/discover/trending`. Each section is on its own: nil (or no genres) when it has never loaded.
public struct AurralTrending: Sendable, Equatable {
    /// The chart country (ISO 3166 alpha-2, Aurral's server location), e.g. "AU".
    public var region: String?
    public var updatedAt: Date?
    public var songs: AurralSongsChart?
    public var albums: [AurralChartAlbum]?
    public var artists: [AurralChartArtist]?
    public var genres: [AurralGenreTile]

    /// Nothing has loaded yet (Aurral is still fetching the charts).
    public var isEmpty: Bool { songs == nil && albums == nil && artists == nil && genres.isEmpty }

    public static func decode(_ data: Data) throws -> AurralTrending {
        let o = try root(data)
        let region = o.text("region").flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0.uppercased() : nil }
        var songs: AurralSongsChart?
        if let s = o.dict("songs"), let id = s.idText("playlistId"), let name = s.text("playlistName") {
            let spotlight = s.dict("spotlight").map { sp in
                AurralSpotlight(ranks: (sp["ranks"] as? [Any] ?? []).prefix(31).map { value -> Int? in
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                          n.doubleValue >= 1, n.doubleValue < 1e6 else { return nil }
                    return Int(n.doubleValue)
                }, daysAtTop: max(0, sp.int("daysAtTop") ?? 0))
            }
            songs = AurralSongsChart(playlistId: id, playlistName: name, libraryPlaylistId: s.idText("libraryPlaylistId"),
                                     items: AurralSong.decodeList(s["items"]), spotlight: spotlight)
        }
        let albums = (o["albums"] as? [Any]).map { list in
            list.prefix(aurralListCap).compactMap { $0 as? [String: Any] }.compactMap { a -> AurralChartAlbum? in
                guard let key = a.idText("key"), let name = a.text("name"), let artist = a.text("artistName") else { return nil }
                return AurralChartAlbum(key: key, name: name, artistName: artist, artwork: a.image("artworkUrl"),
                                        releaseDate: a.text("releaseDate"), genre: a.text("genre"), position: a.int("position"))
            }
        }
        let artists = (o["artists"] as? [Any]).map { list in
            list.prefix(aurralListCap).compactMap { $0 as? [String: Any] }.compactMap { a -> AurralChartArtist? in
                guard let key = a.idText("key"), let name = a.text("name") else { return nil }
                return AurralChartArtist(key: key, name: name, image: a.image("imageUrl"),
                                         fans: a.int("fans").flatMap { $0 >= 0 ? $0 : nil }, mbid: a.mbid("mbid"),
                                         position: a.int("position"))
            }
        }
        let genres = o.objects("genres", cap: 100).compactMap { g -> AurralGenreTile? in
            guard let id = g.intOrDigits("id"), id >= 0, let name = g.text("name") else { return nil }
            return AurralGenreTile(id: id, name: name, covers: g.strings("covers", cap: 8).compactMap(AurralImage.init),
                                   artists: g.strings("artists", cap: 8))
        }
        return AurralTrending(region: region, updatedAt: o.date("updatedAt"), songs: songs, albums: albums, artists: artists,
                              genres: genres)
    }
}

/// `GET /api/discover/trending/genres/:id`: one genre's 50 songs (worldwide: Deezer has no country version).
public struct AurralGenreChart: Sendable, Equatable {
    public var id: Int
    public var name: String
    public var region: String?
    public var updatedAt: Date?
    public var items: [AurralSong]

    public static func decode(_ data: Data) throws -> AurralGenreChart {
        let o = try root(data)
        guard let id = o.intOrDigits("id"), let name = o.text("name") else { throw AurralError.decoding }
        return AurralGenreChart(id: id, name: name, region: o.text("region"), updatedAt: o.date("updatedAt"),
                                items: AurralSong.decodeList(o["items"]))
    }
}

// MARK: - Discover playlists (Deezer editorial)

/// A Discover playlist on a shelf (`{id, name, description, trackCount, artworkUrl, curator}`).
public struct AurralEditorialSummary: Sendable, Hashable {
    /// Deezer's playlist id (digits).
    public var id: String
    public var name: String
    public var description: String?
    public var trackCount: Int
    public var artwork: AurralImage?
    public var curator: String?

    static func decode(_ p: [String: Any]) -> AurralEditorialSummary? {
        guard let id = p.idText("id"), AurralRoute.isDigits(Substring(id), max: 20), let name = p.text("name") else { return nil }
        return AurralEditorialSummary(id: id, name: name, description: p.text("description"),
                                      trackCount: max(0, p.int("trackCount") ?? 0), artwork: p.image("artworkUrl"),
                                      curator: p.text("curator"))
    }
}

/// A genre shelf of Discover playlists (Popular is id 0).
public struct AurralEditorialGenre: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var playlists: [AurralEditorialSummary]
}

/// `GET /api/discover/editorial`: "For you", then one shelf per genre.
public struct AurralEditorialShelf: Sendable, Equatable {
    public var forYou: [AurralEditorialSummary]
    public var genres: [AurralEditorialGenre]

    public static func decode(_ data: Data) throws -> AurralEditorialShelf {
        let o = try root(data)
        return AurralEditorialShelf(
            forYou: o.objects("forYou", cap: 100).compactMap(AurralEditorialSummary.decode),
            genres: o.objects("genres", cap: 100).compactMap { g in
                guard let id = g.intOrDigits("id"), id >= 0, let name = g.text("name") else { return nil }
                return AurralEditorialGenre(id: id, name: name,
                                            playlists: g.objects("playlists", cap: 100).compactMap(AurralEditorialSummary.decode))
            })
    }
}

/// `GET /api/discover/editorial/:id`: a Discover playlist's songs.
public struct AurralEditorialPlaylist: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var curator: String?
    public var artwork: AurralImage?
    public var tracks: [AurralSong]
    /// The user's flow for it, once added.
    public var libraryPlaylistId: String?

    public static func decode(_ data: Data) throws -> AurralEditorialPlaylist {
        let o = try root(data)
        guard let id = o.idText("id"), let name = o.text("name") else { throw AurralError.decoding }
        return AurralEditorialPlaylist(id: id, name: name, description: o.text("description"), curator: o.text("curator"),
                                       artwork: o.image("artworkUrl"), tracks: AurralSong.decodeList(o["tracks"]),
                                       libraryPlaylistId: o.idText("libraryPlaylistId"))
    }
}

/// `GET /api/discover/editorial/links`: the artist's and the album's MBIDs for a Deezer song (either may be missing).
public struct AurralEditorialLinks: Sendable, Equatable {
    public var artistMBID: MBID?
    public var albumMBID: MBID?

    public static func decode(_ data: Data) throws -> AurralEditorialLinks {
        let o = try root(data)
        return AurralEditorialLinks(artistMBID: o.mbid("artistMbid"), albumMBID: o.mbid("albumMbid"))
    }
}

/// `POST /api/discover/editorial/:id/library` (Add flow): the synced playlist Aurral made (or already had).
public struct AurralEditorialAddResult: Sendable, Equatable {
    public var playlistId: String
    public var name: String?
    public var alreadyAdded: Bool
    /// How many songs Aurral queued for download (absent when it was already added).
    public var tracksQueued: Int?

    public init(playlistId: String, name: String?, alreadyAdded: Bool, tracksQueued: Int?) {
        self.playlistId = playlistId; self.name = name; self.alreadyAdded = alreadyAdded; self.tracksQueued = tracksQueued
    }

    public static func decode(_ data: Data) throws -> AurralEditorialAddResult {
        let o = try root(data)
        guard let id = o.idText("playlistId") else { throw AurralError.decoding }
        return AurralEditorialAddResult(playlistId: id, name: o.text("name"), alreadyAdded: o.bool("alreadyAdded") ?? false,
                                        tracksQueued: o.int("tracksQueued").flatMap { $0 >= 0 ? $0 : nil })
    }
}

/// A queued job's answer (Download songs, Retry a song): `{success, queued, operationId}`.
public struct AurralQueued: Sendable, Equatable {
    public var queued: Bool
    public var operationId: String?

    public init(queued: Bool, operationId: String? = nil) { self.queued = queued; self.operationId = operationId }

    public static func decode(_ data: Data) throws -> AurralQueued {
        let o = try root(data)
        return AurralQueued(queued: o.bool("queued") ?? false, operationId: o.idText("operationId"))
    }
}

// MARK: - Search

/// What a search page's items decode from.
public protocol AurralSearchItem: Sendable, Equatable {
    static func decodeItem(_ item: [String: Any]) -> Self?
}

/// An artist from Aurral's catalog search (BrainzMash, a MusicBrainz mirror).
public struct AurralSearchArtist: AurralSearchItem, Hashable {
    /// Nil for a library-only result without an MBID.
    public var mbid: MBID?
    public var name: String
    public var sortName: String?
    public var image: AurralImage?
    /// Aurral says the artist is in its library.
    public var inLibrary: Bool

    public static func decodeItem(_ a: [String: Any]) -> AurralSearchArtist? {
        guard let name = a.text("name") else { return nil }
        let mbid = a.bool("hasMbid") == false ? nil : a.mbid("id")
        return AurralSearchArtist(mbid: mbid, name: name, sortName: a.text("sortName"),
                                  image: a.image("imageUrl") ?? a.image("image"), inLibrary: a.bool("inLibrary") ?? false)
    }
}

/// An album (release group) from Aurral's catalog search.
public struct AurralSearchAlbum: AurralSearchItem, Hashable {
    /// The release group's MBID.
    public var mbid: MBID?
    public var title: String
    public var artistName: String
    public var artistMBID: MBID?
    public var primaryType: String?
    public var secondaryTypes: [String]
    public var releaseDate: String?
    public var cover: AurralImage?
    public var inLibrary: Bool

    public static func decodeItem(_ a: [String: Any]) -> AurralSearchAlbum? {
        guard let title = a.text("title"), let artist = a.text("artistName") else { return nil }
        return AurralSearchAlbum(mbid: a.mbid("albumMbid") ?? a.mbid("id"), title: title, artistName: artist,
                                 artistMBID: a.mbid("artistMbid"), primaryType: a.text("primaryType"),
                                 secondaryTypes: a.strings("secondaryTypes", cap: 10), releaseDate: a.text("releaseDate"),
                                 cover: a.image("coverUrl"), inLibrary: a.bool("inLibrary") ?? false)
    }
}

/// `GET /api/search/unified?mode=full`: catalog artists and albums (Aurral has no song search).
public struct AurralUnifiedSearch: Sendable, Equatable {
    public var artists: [AurralSearchArtist]
    public var albums: [AurralSearchAlbum]

    public static func decode(_ data: Data) throws -> AurralUnifiedSearch {
        let catalog = try root(data).dict("catalog") ?? [:]
        return AurralUnifiedSearch(artists: catalog.objects("artists", cap: 100).compactMap(AurralSearchArtist.decodeItem),
                                   albums: catalog.objects("albums", cap: 100).compactMap(AurralSearchAlbum.decodeItem))
    }
}

/// `GET /api/search?scope=artist|album&limit&offset`: one page, for Load more.
public struct AurralSearchPage<Item: AurralSearchItem>: Sendable, Equatable {
    public var items: [Item]
    /// All the results there are.
    public var count: Int
    public var offset: Int
    public var hasMore: Bool

    public static func decode(_ data: Data) throws -> AurralSearchPage<Item> {
        let o = try root(data)
        let raw = o.objects("items", cap: 200)
        let count = max(0, o.int("count") ?? raw.count)
        let offset = max(0, o.int("offset") ?? 0)
        return AurralSearchPage(items: raw.compactMap(Item.decodeItem), count: count, offset: offset,
                                hasMore: o.bool("hasMore") ?? (offset + raw.count < count && !raw.isEmpty))
    }
}

// MARK: - An album's songs

/// `GET /api/artists/release-group/:mbid/tracks`: an album's songs, with previews Aurral matched on Deezer.
public struct AurralReleaseGroupTrack: Sendable, Hashable {
    /// The recording's MBID.
    public var mbid: MBID?
    public var title: String
    public var trackNumber: Int
    public var discNumber: Int
    public var releaseMBID: MBID?
    public var durationMs: Int?
    public var preview: AurralPreview?

    public var duration: TimeInterval? { durationMs.map { TimeInterval($0) / 1000 } }

    public static func decodeList(_ data: Data) throws -> [AurralReleaseGroupTrack] {
        guard let list = object(data) as? [Any] else { throw AurralError.decoding }
        return list.prefix(aurralListCap).compactMap { $0 as? [String: Any] }.compactMap { t in
            guard let title = t.text("title") ?? t.text("trackName") else { return nil }
            return AurralReleaseGroupTrack(mbid: t.mbid("mbid") ?? t.mbid("id"), title: title,
                                           trackNumber: max(0, min(t.int("trackNumber") ?? 0, 9_999)),
                                           discNumber: max(1, min(t.int("discNumber") ?? 1, 999)),
                                           releaseMBID: t.mbid("releaseMbid"), durationMs: t.millis("length"),
                                           preview: t.preview())
        }
    }
}
