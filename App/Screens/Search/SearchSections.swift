import Foundation
import MagpieCore

/// One search hit that can be the "Top result".
enum SearchItem: Hashable {
    case song(Song)
    case artist(Artist)
    case album(Album)
}

/// What Search shows for a query, in display order: Top result, then Songs, Artists, Albums.
///
/// M2 is library only. M4 adds a "Not in your library" band as one more field with an empty
/// default, so existing callers (the model builds it, the view lists it) keep working.
struct SearchSections: Equatable {
    var top: SearchItem?
    var songs: [Song] = []
    var artists: [Artist] = []
    var albums: [Album] = []

    static let empty = SearchSections()

    var isEmpty: Bool { top == nil && songs.isEmpty && artists.isEmpty && albums.isEmpty }

    /// Sections from a library search. The top result is the best match for `query`: an exact name
    /// (artist, then album, then song), else a name that starts with it, else the first song.
    /// With no songs, the first artist or album stands in.
    static func library(_ result: LibrarySearchResult, query: String) -> SearchSections {
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
