import Foundation
import MagpieCore
import Search
import Testing
@testable import Magpie

/// Round 14 A5 fix round 1: the band's Songs part never dead-ends (I2), and an "Also in your library" row whose song
/// can't be fetched says so instead of doing nothing (M2).
@MainActor
@Suite struct SearchOutsideBandTests {
    private func album(_ n: Int) -> NotYetAlbum {
        NotYetAlbum(title: "A\(n)", artist: "X", mbid: MBID(String(format: "00000000-0000-4000-8000-%012d", n)))
    }

    @Test func songsShowWithMoreEvenWhenTheFirstAlbumsMatchedNothing() {
        var s = SearchSections()
        #expect(!SearchBand.shows(.songs, in: s))
        s.outside = OutsidePaging(query: "x", cursor: OutsideCursor(unreadAlbums: [album(1)]))
        #expect(SearchBand.shows(.songs, in: s), "no rows yet, but more albums to read")
        #expect(SearchCopy.more(.songs, hasRows: false) == "Look for songs on more albums")
        #expect(SearchCopy.more(.songs, hasRows: true) == "More songs")
        s.notYet.artists = [NotYetArtist(name: "Y")]
        #expect(SearchBand.shows(.artists, in: s))
        #expect(!SearchBand.shows(.albums, in: s))
    }

    @Test func anOwnedSongThatCantBeFetchedSaysSo() async {
        let model = SearchModel(search: { _, _ in .empty })
        var played: [String] = []
        await model.playOwned("s1", lookup: { _ in nil }, play: { played.append($0.id) })
        #expect(model.ownedFailed.contains("s1"))
        #expect(played.isEmpty)
        let song = Song(id: "s1", title: "T", artist: "A", album: "L", duration: 1)
        await model.playOwned("s1", lookup: { _ in song }, play: { played.append($0.id) })
        #expect(!model.ownedFailed.contains("s1"))
        #expect(played == ["s1"])
    }
}
