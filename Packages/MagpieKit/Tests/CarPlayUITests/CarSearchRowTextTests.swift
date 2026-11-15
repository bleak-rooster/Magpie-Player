import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 28 S fix round 1 (design H1, M4): the car's search rows follow the phone's Search wording (D338): "Song ·
/// <artist>" and "Album · <artist>", the kind alone when the artist is blank (never a dangling " · ", a blank line or
/// "Unknown artist"). Rows elsewhere in the car keep their own lines.
@Suite struct CarSearchRowTextTests {
    private let named = Song(id: "s1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 215)
    private let blank = Song(id: "s2", title: "Untitled Sketch", artist: "  ", album: "Demos", duration: 90)
    private let album = Album(id: "al1", name: "Glasshouse", artist: "Corin Hale", songCount: 10, duration: 2400)
    private let blankAlbum = Album(id: "al2", name: "Demos", artist: "", songCount: 3, duration: 400)
    private let outside = ExternalRecording(title: "Quiet Hours", artist: " ", source: .lidarr)
    private let outsideNamed = ExternalRecording(title: "Northern Rooms", artist: "Corin Hale", source: .lidarr)

    private func detail(_ rows: [CPRowModel], _ id: String) -> String? {
        rows.first { $0.id.hasPrefix(id) }?.detail
    }

    @Test func searchItems_blankArtistNoDanglingDot() {
        let rows = CarPlayRows.searchItems(LibrarySearchResult(songs: [named, blank], albums: [album, blankAlbum]),
                                           notYet: [outside, outsideNamed], offer: .next)
        #expect(detail(rows, "song.0.") == "Song \u{00B7} Corin Hale")
        #expect(detail(rows, "song.1.") == "Song")
        #expect(detail(rows, "album.al1") == "Album \u{00B7} Corin Hale")
        #expect(detail(rows, "album.al2") == "Album")
        #expect(detail(rows, "notyet.0.") == "Not in your library \u{00B7} Try")
        #expect(detail(rows, "notyet.1.") == "Not in your library \u{00B7} Try \u{00B7} Corin Hale")
        for row in rows {
            let text = row.detail ?? ""
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(row.id) has a blank line")
            #expect(!text.hasSuffix("\u{00B7}") && !text.hasSuffix("\u{00B7} ") && !text.contains("\u{00B7}  "),
                    "\(row.id): \(text)")
            #expect(!text.contains("Unknown artist"), "\(row.id): \(text)")
        }
    }

    @Test func searchResults_sectionedRowsNameTheArtist() {
        let sections = CarPlayRows.searchResults(LibrarySearchResult(songs: [named, blank], albums: [album, blankAlbum]),
                                                 notYet: [outside], offer: .unavailable,
                                                 onTheirWay: [:], playingId: nil)
        let rows = sections.flatMap(\.rows)
        #expect(detail(rows, "song.0.") == "Song \u{00B7} Corin Hale")
        #expect(detail(rows, "song.1.") == "Song")
        #expect(detail(rows, "album.al1") == "Album \u{00B7} Corin Hale")
        #expect(detail(rows, "album.al2") == "Album")
        #expect(detail(rows, "notyet.0.") == "Not in your library")
        // A request on its way with no artist: its status alone.
        let live = CarPlayRows.searchResults(LibrarySearchResult(), notYet: [outside], offer: .next,
                                             onTheirWay: [0: "Downloading"], playingId: nil).flatMap(\.rows)
        #expect(detail(live, "notyet.0.") == "Downloading")
    }

    /// Outside Search, the car's rows are as before: the library's album list shows the artist alone, and Made for
    /// you's not-yet songs keep "Unknown artist".
    @Test func otherCarRowsUnchanged() {
        let albums = CarPlayRows.albums([album]).flatMap(\.rows)
        #expect(albums.first { $0.id == "album.al1" }?.detail == "Corin Hale")
        let mfy = CarPlayRows.madeForYou([.notYet(outside)], offer: .unavailable, playingId: nil).flatMap(\.rows)
        #expect(mfy.last?.detail == "Not in your library \u{00B7} Unknown artist")
    }
}
