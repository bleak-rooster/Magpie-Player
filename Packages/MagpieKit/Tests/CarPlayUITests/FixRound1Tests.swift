import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Y2 fix round 1: artist pages open their albums when the depth allows (I2), Made for you gets Play and Shuffle, and
/// albums past the car's read cap say so.
@Suite struct FixRound1Tests {
    let songs = [Song(id: "s1", title: "One", artist: "A", album: "X", duration: 60)]

    @Test func artistAlbumsOpenOnlyWhenTheDepthAllows() {
        let artist = Artist(id: "ar1", name: "A", albumCount: 1)
        let albums = [Album(id: "al1", name: "X", artist: "A", songCount: 1, duration: 60)]
        let open = CarPlayRows.artist(artist, albums: albums, albumsOpen: true).flatMap(\.rows)
        #expect(open.last?.action == .open(.album(id: "al1", title: "X")))
        let leaf = CarPlayRows.artist(artist, albums: albums, albumsOpen: false).flatMap(\.rows)
        #expect(leaf.last?.action == .play(.album(id: "al1", shuffled: false)))

        let onPhone = [Album(id: "al1", name: "X", artist: "A", songCount: 1, duration: 60, songs: songs)]
        let dOpen = CarPlayRows.downloadedArtist(artist, albums: onPhone, albumsOpen: true).flatMap(\.rows)
        #expect(dOpen.last?.action == .open(.downloadedAlbum(id: "al1", title: "X")))
        let dLeaf = CarPlayRows.downloadedArtist(artist, albums: onPhone, albumsOpen: false).flatMap(\.rows)
        #expect(dLeaf.last?.action == .play(.songs(songs, startAt: 0)))
    }

    @Test func madeForYouStartsWithPlayAndShuffle() {
        let outside = ExternalRecording(title: "E", artist: "S", source: .listenBrainz)
        let rows = CarPlayRows.madeForYou([.song(songs[0]), .notYet(outside)], offer: .next, playingId: nil).flatMap(\.rows)
        #expect(rows.prefix(2).map(\.title) == ["Play", "Shuffle"])
        #expect(rows.prefix(2).map(\.action) == [.play(.songs(songs, startAt: 0)), .play(.shuffle(songs))])
        let none = CarPlayRows.madeForYou([.notYet(outside)], offer: .next, playingId: nil).flatMap(\.rows)
        #expect(!none.contains { $0.title == "Play" }, "nothing in the library to play")
    }

    @Test func albumsPastTheCapSaySo() {
        let albums = (0..<4).map { Album(id: "al\($0)", name: "A\($0)", artist: "X", songCount: 1, duration: 1) }
        let sections = CarPlayRows.albums(albums, maxItems: 10, maxSections: 10, total: 9)
        #expect(sections.flatMap(\.rows).last?.title == "Showing 4 of 9")
        #expect(sections.flatMap(\.rows).count <= 10)
        let letters = CarPlayRows.albums(albums, maxItems: 4, maxSections: 10, total: 9)
        #expect(letters.flatMap(\.rows).last?.title == "Showing 4 of 9")
        #expect(letters.flatMap(\.rows).count <= 4, "the note takes one of the car's rows")
        #expect(!CarPlayRows.albums(albums, total: 4).flatMap(\.rows).contains { $0.title.hasPrefix("Showing") })
    }
}
