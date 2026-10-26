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

    public init(top: SearchItem? = nil, songs: [Song] = [], artists: [Artist] = [], albums: [Album] = [],
                notYet: NotYetSections = NotYetSections()) {
        self.top = top; self.songs = songs; self.artists = artists; self.albums = albums; self.notYet = notYet
    }

    public static let empty = SearchSections()

    /// Nothing from the library.
    public var libraryIsEmpty: Bool { top == nil && songs.isEmpty && artists.isEmpty && albums.isEmpty }

    /// Nothing at all, in either band.
    public var isEmpty: Bool { libraryIsEmpty && notYet.isEmpty }

    /// Sections from a library search. The top result is the best match for `query`: an exact name
    /// (artist, then album, then song), else a name that starts with it, else the first song.
    /// With no songs, the first artist or album stands in.
    public static func library(_ result: LibrarySearchResult, query: String) -> SearchSections {
        let q = fold(query)
        func pick(_ matches: (String) -> Bool) -> SearchItem? {
            if let a = result.artists.first(where: { matches(fold($0.name)) }) { return .artist(a) }
            if let a = result.albums.first(where: { matches(fold($0.name)) }) { return .album(a) }
            if let s = result.songs.first(where: { matches(fold($0.title)) }) { return .song(s) }
            return nil
        }
        let top = pick { $0 == q } ?? pick { $0.hasPrefix(q) }
            ?? result.songs.first.map(SearchItem.song)
            ?? result.artists.first.map(SearchItem.artist)
            ?? result.albums.first.map(SearchItem.album)
        return SearchSections(top: top, songs: result.songs, artists: result.artists, albums: result.albums)
    }

    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
