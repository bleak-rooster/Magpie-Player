import AurralKit
import Foundation
import MagpieCore

// Round 14 A4 (D90): what Trending, Recommended and the Discover playlists last showed, as plain values the disk copy
// can hold. Pictures are kept as Aurral named them (`AurralImage`: Deezer's or Apple's https picture, or an Aurral
// path); never a login, a session, or a signed preview link (a preview is only its Deezer id).

/// A chart or Discover playlist song.
struct ChartSong: Codable, Hashable, Sendable {
    enum Movement: Codable, Hashable, Sendable { case up(Int), down(Int), same, new }

    var key: String?
    var title: String
    var artist: String
    var album: String?
    var deezerAlbumId: String?
    var durationMs: Int?
    var artwork: AurralImage?
    var previewId: String?
    var position: Int?
    var movement: Movement?

    init(_ s: AurralSong) {
        key = s.key; title = s.trackName; artist = s.artistName; album = s.albumName; deezerAlbumId = s.deezerAlbumId
        durationMs = s.durationMs; artwork = s.artwork; previewId = s.preview?.trackId; position = s.position
        movement = s.movement.map {
            switch $0 {
            case .up(let n): .up(n)
            case .down(let n): .down(n)
            case .same: .same
            case .new: .new
            }
        }
    }

    var song: AurralSong {
        AurralSong(key: key, trackName: title, artistName: artist, albumName: album, deezerAlbumId: deezerAlbumId,
                   durationMs: durationMs, artwork: artwork, preview: previewId.flatMap(AurralPreview.init(trackId:)),
                   position: position)
    }

    var duration: TimeInterval { TimeInterval(durationMs ?? 0) / 1000 }
}

struct ChartAlbum: Codable, Hashable, Sendable {
    var key: String
    var name: String
    var artist: String
    var artwork: AurralImage?
    var genre: String?
    var position: Int?

    init(_ a: AurralChartAlbum) {
        key = a.key; name = a.name; artist = a.artistName; artwork = a.artwork; genre = a.genre; position = a.position
    }
}

struct ChartArtist: Codable, Hashable, Sendable {
    var key: String
    var name: String
    var image: AurralImage?
    var mbid: String?
    var position: Int?

    init(_ a: AurralChartArtist) { key = a.key; name = a.name; image = a.image; mbid = a.mbid?.rawValue; position = a.position }
}

struct GenreTile: Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var cover: AurralImage?
    var artists: [String]

    init(_ g: AurralGenreTile) { id = g.id; name = g.name; cover = g.covers.first; artists = Array(g.artists.prefix(3)) }
}

/// Trending as last read. Each section on its own: nil when it has never loaded (Aurral's chart task hasn't run), and a
/// section missing from a later read keeps its last copy.
struct TrendingSnapshot: Codable, Equatable, Sendable {
    /// Aurral's chart country (its server's own location).
    var region: String?
    /// The top songs chart: its name ("Top Australia"), the Deezer playlist Add flow follows, and the user's synced
    /// playlist for it (once added, as Aurral said).
    var chartName: String?
    var chartPlaylistId: String?
    var libraryPlaylistId: String?
    var songs: [ChartSong]?
    var daysAtTop: Int?
    var albums: [ChartAlbum]?
    var artists: [ChartArtist]?
    var genres: [GenreTile] = []
    /// Fix round 1 (owner, D91): the country the top songs are for (the server's, or the owner's chart country read
    /// through the server); the albums' region when it differs from it (they exist only for the server's); the server's
    /// region when the chosen country's chart couldn't be read ("Showing <region> charts"); the setting this was read for.
    var songsRegion: String?
    var albumsRegion: String?
    var showingServerInstead: String?
    var forSetting: String?
    /// Round 15 C2 (D132): which chart the top songs are (the server's region, or the default chart); nil when the
    /// server didn't name its region.
    var chart: TrendingChart?

    init(_ t: AurralTrending) {
        region = t.region
        chartName = t.songs?.playlistName
        chartPlaylistId = t.songs?.playlistId
        libraryPlaylistId = t.songs?.libraryPlaylistId
        songs = t.songs.map { $0.items.map(ChartSong.init) }
        daysAtTop = t.songs?.spotlight?.daysAtTop
        albums = t.albums.map { $0.map(ChartAlbum.init) }
        artists = t.artists.map { $0.map(ChartArtist.init) }
        genres = t.genres.map(GenreTile.init)
    }

    /// Each section this read didn't have keeps `older`'s.
    func keeping(_ older: TrendingSnapshot?) -> TrendingSnapshot {
        guard let older else { return self }
        var merged = self
        if merged.songs == nil {
            merged.songs = older.songs; merged.chartName = older.chartName; merged.chartPlaylistId = older.chartPlaylistId
            merged.libraryPlaylistId = older.libraryPlaylistId; merged.daysAtTop = older.daysAtTop
            merged.songsRegion = older.songsRegion; merged.showingServerInstead = older.showingServerInstead
            merged.chart = older.chart
        }
        if merged.albums == nil { merged.albums = older.albums }
        if merged.artists == nil { merged.artists = older.artists }
        if merged.genres.isEmpty { merged.genres = older.genres }
        return merged
    }

    var isEmpty: Bool { (songs ?? []).isEmpty && (albums ?? []).isEmpty && (artists ?? []).isEmpty && genres.isEmpty }
}

/// A recommended artist as last read.
struct RecommendedArtist: Codable, Hashable, Sendable {
    var mbid: String?
    var name: String
    var image: AurralImage?
    var tags: [String]
    var matchedTags: [String]
    var sourceArtists: [String]
    var supportingSeeds: [String]
    var depth: Int
    var firstDiscoveredAt: Date?
    var matchPercent: Int?

    init(_ a: AurralRecommendedArtist) {
        mbid = a.mbid?.rawValue; name = a.name; image = a.image; tags = Array(a.tags.prefix(8))
        matchedTags = Array(a.matchedTags.prefix(8)); sourceArtists = Array(a.sourceArtists.prefix(8))
        supportingSeeds = Array(a.supportingSeeds.prefix(8)); depth = a.discoveryDepth
        firstDiscoveredAt = a.firstDiscoveredAt; matchPercent = a.matchPercent
    }

    var artist: AurralRecommendedArtist {
        AurralRecommendedArtist(mbid: mbid.flatMap(MBID.init), name: name, image: image, tags: tags, matchedTags: matchedTags,
                                sourceArtists: sourceArtists, supportingSeeds: supportingSeeds, discoveryDepth: depth,
                                firstDiscoveredAt: firstDiscoveredAt, matchPercent: matchPercent)
    }
}

struct RecommendedSnapshot: Codable, Equatable, Sendable {
    var artists: [RecommendedArtist]
    var basedOn: [String]

    init(_ r: AurralRecommendations) {
        artists = r.artists.prefix(200).map(RecommendedArtist.init)
        basedOn = Array(r.basedOn.map(\.name).prefix(20))
    }

    func rails(now: Date, hidden: Set<String>, seedRows: Int = 3) -> RecommendedRails {
        RecommendedRails(artists: artists.map(\.artist), basedOn: basedOn, now: now, hidden: hidden, seedRows: seedRows)
    }
}

/// One Discover playlist on a shelf.
struct PlaylistSummary: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var trackCount: Int
    var artwork: AurralImage?
    var curator: String?

    init(_ s: AurralEditorialSummary) {
        id = s.id; name = s.name; description = s.description; trackCount = s.trackCount; artwork = s.artwork
        curator = s.curator
    }
}

struct EditorialShelf: Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var playlists: [PlaylistSummary]
}

/// The Discover playlists: For you, then a shelf per genre.
struct EditorialSnapshot: Codable, Equatable, Sendable {
    var forYou: [PlaylistSummary]
    var genres: [EditorialShelf]

    init(_ e: AurralEditorialShelf) {
        forYou = e.forYou.map(PlaylistSummary.init)
        genres = e.genres.map { EditorialShelf(id: $0.id, name: $0.name, playlists: $0.playlists.map(PlaylistSummary.init)) }
            .filter { !$0.playlists.isEmpty }
    }

    var isEmpty: Bool { forYou.isEmpty && genres.isEmpty }

    /// More playlists for you: one genre shelf, a different one each day (by the day's number).
    func shelfOfTheDay(_ now: Date, calendar: Calendar = .current) -> EditorialShelf? {
        guard !genres.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        return genres[day % genres.count]
    }
}
