import Foundation
import MagpieCore

/// One search hit that can be the "Top result". Always a library item (D4).
public enum SearchItem: Hashable, Sendable {
    case song(Song)
    case artist(Artist)
    case album(Album)
}

/// An album that isn't in the library yet (from Lidarr's search).
public struct NotYetAlbum: Hashable, Sendable {
    public var title: String
    public var artist: String
    /// Release group MBID.
    public var mbid: MBID?
    public var artistMBID: MBID?
    public var year: Int?
    /// "Album", "EP", "Single", ...
    public var kind: String?

    public init(title: String, artist: String, mbid: MBID? = nil, artistMBID: MBID? = nil, year: Int? = nil,
                kind: String? = nil) {
        self.title = title; self.artist = artist; self.mbid = mbid; self.artistMBID = artistMBID
        self.year = year; self.kind = kind
    }
}

/// An artist with nothing in the library yet (from Lidarr's search).
public struct NotYetArtist: Hashable, Sendable {
    public var name: String
    public var mbid: MBID?

    public init(name: String, mbid: MBID? = nil) { self.name = name; self.mbid = mbid }
}

/// The "Not in your library" band: songs, albums and artists from outside the library, with
/// anything the library already has removed.
public struct NotYetSections: Equatable, Sendable {
    public var songs: [ExternalRecording]
    public var albums: [NotYetAlbum]
    public var artists: [NotYetArtist]

    public init(songs: [ExternalRecording] = [], albums: [NotYetAlbum] = [], artists: [NotYetArtist] = []) {
        self.songs = songs; self.albums = albums; self.artists = artists
    }

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }
}

/// What Search shows for a query, in display order: Top result, then the library's Songs, Artists and
/// Albums, then the "Not in your library" band. Library first, never interleaved (D4, review H3.2).
public struct SearchSections: Equatable, Sendable {
    public var top: SearchItem?
    public var songs: [Song]
    public var artists: [Artist]
    public var albums: [Album]
    public var notYet: NotYetSections
    /// Offline only (spec §6): cached songs that have played, "Recently played on this phone".
    public var recentlyPlayed: [Song]
    /// Where each library section is up to (round 12, plan item 3); nil when the results don't page (offline).
    public var paging: SearchPaging?

    public init(top: SearchItem? = nil, songs: [Song] = [], artists: [Artist] = [], albums: [Album] = [],
                notYet: NotYetSections = NotYetSections(), recentlyPlayed: [Song] = [], paging: SearchPaging? = nil) {
        self.top = top; self.songs = songs; self.artists = artists; self.albums = albums; self.notYet = notYet
        self.recentlyPlayed = recentlyPlayed; self.paging = paging
    }

    public static let empty = SearchSections()

    /// Nothing from the library.
    public var libraryIsEmpty: Bool { top == nil && songs.isEmpty && artists.isEmpty && albums.isEmpty }

    /// Nothing at all, in either band (or among the songs recently played on this phone).
    public var isEmpty: Bool { libraryIsEmpty && notYet.isEmpty && recentlyPlayed.isEmpty }

    /// Sections from a library search, each ordered by `SearchRanker` (best first; equal scores keep the server's
    /// order). The Top result is the best-scoring hit of any kind (on a tie an artist, then an album, then a song).
    ///
    /// - Parameter withSongsArtist: plan item 1.3: when the best hit is a song matched by its title and its artist
    ///   ("bloodbuzz the national"), its artist and album are shown as rows too, even though the server's artist
    ///   search found none.
    public static func library(_ result: LibrarySearchResult, query: String, withSongsArtist: Bool = false) -> SearchSections {
        let q = SearchRanker.Query(query)
        var songs = SearchRanker.rank(result.songs, q, SearchRanker.score)
        var artists = SearchRanker.rank(result.artists, q, SearchRanker.score)
        var albums = SearchRanker.rank(result.albums, q, SearchRanker.score)
        let top = SearchRanker.top(songs: songs, albums: albums, artists: artists, q)
        if withSongsArtist, case .song(let song) = top, SearchRanker.score(song, q).usesTitleAndArtist {
            if let id = song.artistId, !id.isEmpty, !song.artist.isEmpty,
               !artists.contains(where: { $0.id == id || SearchRanker.fold($0.name) == SearchRanker.fold(song.artist) }) {
                artists.insert(Artist(id: id, name: song.artist, albumCount: 0, coverArtId: "ar-\(id)"), at: 0)
            }
            if let id = song.albumId, !id.isEmpty, !song.album.isEmpty, !albums.contains(where: { $0.id == id }) {
                albums.insert(Album(id: id, name: song.album, artist: song.artist, artistId: song.artistId, songCount: 0,
                                    duration: 0, coverArtId: song.coverArtId), at: 0)
            }
        }
        // The same for an album Top result matched by its name and its artist ("hey jude beatles" with a Beatles
        // "Hey Jude" album): its artist is a row too (fix round 1).
        if withSongsArtist, case .album(let album) = top, SearchRanker.score(album, q).usesTitleAndArtist,
           let id = album.artistId, !id.isEmpty, !album.artist.isEmpty,
           !artists.contains(where: { $0.id == id || SearchRanker.fold($0.name) == SearchRanker.fold(album.artist) }) {
            artists.insert(Artist(id: id, name: album.artist, albumCount: 0, coverArtId: "ar-\(id)"), at: 0)
        }
        return SearchSections(top: top, songs: songs, artists: artists, albums: albums)
    }

    // MARK: - Paging (plan item 3)

    /// The section has another batch to load.
    public func hasMore(_ kind: LibraryKind) -> Bool { paging?.hasMore(kind) ?? false }

    /// A batch after the first has been loaded into the section.
    public func loadedMore(_ kind: LibraryKind) -> Bool { paging?.loadedMore(kind) ?? false }

    /// Adds a load-more's rows to the end of their section (ranked among themselves, so rows already on screen never
    /// move) and takes that section's paging state. Other sections and the Top result are left alone.
    public mutating func append(_ more: MoreResults) {
        guard var paging, let section = more.paging.sections[more.kind] else { return }
        let q = SearchRanker.Query(paging.query)
        switch more.kind {
        case .songs:
            let shown = Set(songs.map(\.id))
            songs += SearchRanker.rank(more.songs.filter { !shown.contains($0.id) }, q, SearchRanker.score)
        case .albums:
            let shown = Set(albums.map(\.id))
            albums += SearchRanker.rank(more.albums.filter { !shown.contains($0.id) }, q, SearchRanker.score)
        case .artists:
            let shown = Set(artists.map(\.id))
            artists += SearchRanker.rank(more.artists.filter { !shown.contains($0.id) }, q, SearchRanker.score)
        }
        paging.sections[more.kind] = section
        self.paging = paging
    }
}
