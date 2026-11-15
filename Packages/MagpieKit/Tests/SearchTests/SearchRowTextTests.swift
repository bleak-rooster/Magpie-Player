import MagpieCore
import Search
import Testing

/// Round 28 S (owner, 2026-11-15): every song and album row in Search names the artist, "Song · <artist>" and
/// "Album · <artist>" (outside rows their kind), never a blank line or a dangling " · "; VoiceOver says "song by" and
/// "album by" (D338).
@Suite struct SearchRowTextTests {
    private func song(_ title: String = "Harbour Lights", artist: String) -> Song {
        Song(id: "s1", title: title, artist: artist, album: "Saltwater Hymns", duration: 215)
    }

    @Test func songDetail_namesTheArtist() {
        #expect(SearchRowText.songDetail(song(artist: "Corin Hale")) == "Song \u{00B7} Corin Hale")
        #expect(SearchRowText.songDetail(artist: "  Corin Hale \n") == "Song \u{00B7} Corin Hale")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func songDetail_emptyArtistReadsSong(_ artist: String) {
        #expect(SearchRowText.songDetail(song(artist: artist)) == "Song")
        #expect(SearchRowText.songDetail(artist: artist) == "Song")
    }

    @Test func albumDetail_namesTheArtist() {
        #expect(SearchRowText.albumDetail(artist: "Corin Hale") == "Album \u{00B7} Corin Hale")
        // A compilation: the library's own album artist (D338 keeps today's mapping).
        #expect(SearchRowText.albumDetail(artist: "Various Artists") == "Album \u{00B7} Various Artists")
    }

    @Test func albumDetail_outsideKind() {
        #expect(SearchRowText.albumDetail(artist: "Corin Hale", kind: "EP") == "EP \u{00B7} Corin Hale")
        #expect(SearchRowText.albumDetail(artist: "Corin Hale", kind: "Single") == "Single \u{00B7} Corin Hale")
        // No kind, or a blank one, is an album.
        #expect(SearchRowText.albumDetail(artist: "Corin Hale", kind: nil) == "Album \u{00B7} Corin Hale")
        #expect(SearchRowText.albumDetail(artist: "Corin Hale", kind: "  ") == "Album \u{00B7} Corin Hale")
    }

    @Test func albumDetail_emptyArtistNoDanglingDot() {
        for artist in ["", " ", "\t"] {
            #expect(SearchRowText.albumDetail(artist: artist) == "Album")
            #expect(SearchRowText.albumDetail(artist: artist, kind: "EP") == "EP")
            #expect(!SearchRowText.albumDetail(artist: artist, kind: "Single").contains("\u{00B7}"))
        }
    }

    @Test func labels_songByArtist() {
        #expect(SearchRowText.songLabel(song(artist: "Corin Hale")) == "Harbour Lights, song by Corin Hale")
        #expect(SearchRowText.songLabel(title: "Harbour Lights", artist: " ") == "Harbour Lights, song")
        #expect(SearchRowText.songLabel(song(artist: "")) == "Harbour Lights, song")
    }

    @Test func labels_albumByArtist() {
        #expect(SearchRowText.albumLabel(name: "Glasshouse", artist: "Corin Hale") == "Glasshouse, album by Corin Hale")
        #expect(SearchRowText.albumLabel(name: "Low Tide", artist: "Corin Hale", kind: "EP") == "Low Tide, EP by Corin Hale")
        #expect(SearchRowText.albumLabel(name: "Northern Rooms", artist: "Corin Hale", kind: "Single")
                == "Northern Rooms, single by Corin Hale")
        #expect(SearchRowText.albumLabel(name: "Glasshouse", artist: "") == "Glasshouse, album")
        #expect(SearchRowText.albumLabel(name: "Low Tide", artist: "  ", kind: "EP") == "Low Tide, EP")
    }
}
