import CarPlayUI
import MagpieCore
import Testing

/// R19 in the car: an artist found by search opens the artist (its albums play from there, D12's depth budget), as an
/// album opens the album. Before, the car's search dropped artists altogether.
@Suite struct CarPlaySearchArtistsTests {
    private let artist = Artist(id: "ar1", name: "Aurora Field", albumCount: 2, coverArtId: "ar-ar1")
    private let album = Album(id: "al1", name: "Continuum", artist: "Aurora Field", songCount: 6, duration: 600)
    private let song = Song(id: "s1", title: "Drift", artist: "Aurora Field", album: "Continuum", duration: 60)

    @Test func searchTemplateListsArtistsThatOpenTheArtist() {
        let result = LibrarySearchResult(songs: [song], albums: [album], artists: [artist])
        let rows = CarPlayRows.searchItems(result)
        #expect(rows.map(\.id) == ["song.0.s1", "artist.ar1", "album.al1"], "library order: songs, artists, albums")
        let row = rows[1]
        #expect(row.title == "Aurora Field" && row.detail == "Artist \u{00B7} 2 albums")
        #expect(row.action == .open(.artist(id: "ar1", name: "Aurora Field")))
        #expect(row.artworkKey == "ar-ar1" && row.round)
        #expect(rows[2].action == .open(.album(id: "al1", title: "Continuum")))
        // Every library row acts: nothing is a dead tap (R20 §10).
        #expect(rows.allSatisfy { $0.action != RowAction.none })
    }

    @Test func recentSearchListHasAnArtistsSection() {
        let result = LibrarySearchResult(songs: [song], albums: [album], artists: [artist])
        let list = CarPlayRows.searchResults(result, playingId: nil)
        #expect(list.map(\.header) == ["Songs", "Artists", "Albums"])
        #expect(list[1].rows.first?.action == .open(.artist(id: "ar1", name: "Aurora Field")))
        // The artist page is within the depth budget from the search tab: its albums play (leaves).
        let page = CarPlayRows.artist(artist, albums: [album]).flatMap(\.rows)
        #expect(page.allSatisfy { if case .open = $0.action { false } else { true } })
    }
}
