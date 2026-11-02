import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 12 items 2c (Play and Shuffle on every album, artist and playlist page), 2d (Now Playing's album and artist
/// links) and the owner's depth ruling (D12: within CarPlay's template depth of 5).
@Suite struct PlayShuffleAndLinksTests {
    let songs = [Song(id: "s1", title: "One", artist: "A", album: "X", duration: 60),
                 Song(id: "s2", title: "Two", artist: "A", album: "X", duration: 60)]

    func firstTwo(_ sections: [CPSectionModel]) -> [CPRowModel] { Array(sections.flatMap(\.rows).prefix(2)) }

    // MARK: 2c

    @Test func albumPagesStartWithPlayThenShuffle() {
        let album = Album(id: "al1", name: "X", artist: "A", songCount: 2, duration: 120, songs: songs)
        for sections in [CarPlayRows.album(album, playingId: nil), CarPlayRows.downloadedAlbum(album, playingId: nil)] {
            let rows = firstTwo(sections)
            #expect(rows.map(\.title) == ["Play", "Shuffle"])
            #expect(rows[0].action == .play(.songs(songs, startAt: 0)), "in order, from the first song")
        }
        #expect(firstTwo(CarPlayRows.album(album, playingId: nil))[1].action == .play(.album(id: "al1", shuffled: true)))
        #expect(firstTwo(CarPlayRows.downloadedAlbum(album, playingId: nil))[1].action == .play(.shuffle(songs)))
    }

    @Test func playlistPagesStartWithPlayThenShuffle() {
        let rows = firstTwo(CarPlayRows.playlist(Playlist(id: "p1", name: "Mix", songCount: 2, duration: 120), songs: songs,
                                                 playingId: nil))
        #expect(rows.map(\.title) == ["Play", "Shuffle"])
        #expect(rows.map(\.action) == [.play(.songs(songs, startAt: 0)), .play(.shuffle(songs))])
    }

    @Test func artistPagesStartWithPlayThenShuffle() {
        let artist = Artist(id: "ar1", name: "A", albumCount: 1)
        let rows = firstTwo(CarPlayRows.artist(artist, albums: [Album(id: "al1", name: "X", artist: "A", songCount: 2,
                                                                       duration: 120)]))
        #expect(rows.map(\.title) == ["Play", "Shuffle"])
        #expect(rows.map(\.action) == [.play(.artistInOrder(id: "ar1")), .play(.artistShuffle(id: "ar1"))])

        let downloaded = firstTwo(CarPlayRows.downloadedArtist(artist, albums: [Album(id: "al1", name: "X", artist: "A",
                                                                                      songCount: 2, duration: 120, songs: songs)]))
        #expect(downloaded.map(\.title) == ["Play", "Shuffle"])
        #expect(downloaded.map(\.action) == [.play(.songs(songs, startAt: 0)), .play(.shuffle(songs))])
    }

    // MARK: Depth (owner ruling)

    /// Tab → letters → group → page is 4 browse screens; Now Playing makes 5, CarPlay's limit for audio apps.
    @Test func theDeepestPathStaysWithinFive() {
        var nav = CPNavigator()
        let artists = (0..<30).map { Artist(id: "ar\($0)", name: "A\($0)", albumCount: 1) }
        let letters = CarPlayRows.artists(artists, maxItems: 12, maxSections: 12)
        let pushedLetters = nav.push(.artists); #expect(pushedLetters)
        guard case .open(let group) = letters[0].rows[0].action, case .letterGroup(_, let sections) = group else {
            Issue.record("letters screen"); return
        }
        let pushedGroup = nav.push(group); #expect(pushedGroup)
        guard case .open(let page) = sections[0].rows[0].action else { Issue.record("the page opens"); return }
        let pushedPage = nav.push(page); #expect(pushedPage)
        #expect(nav.depth == 4 && nav.depth == CPNavigator.maxBrowseDepth)
        let pushedDeeper = nav.push(.album(id: "x", title: "X")); #expect(!pushedDeeper, "nothing deeper")
        #expect(nav.depth + 1 <= CPNavigator.carPlayTemplateDepthLimit, "Now Playing on top fits")
        #expect(CPNavigator.carPlayTemplateDepthLimit == 5)
    }

    // MARK: 2d

    @Test func nowPlayingLinksOnline() {
        let song = Song(id: "s1", title: "One", artist: "Air", artistId: "ar1", album: "Moon", albumId: "al1", duration: 60)
        let links = CarPlayRows.nowPlayingLinks(song, offline: false, albumOnPhone: false, artistOnPhone: false)
        #expect(links.album == .album(id: "al1", title: "Moon"))
        #expect(links.artist == .artist(id: "ar1", name: "Air"))
        #expect(links.isEmpty == false)

        let albumOnly = Song(id: "s2", title: "Two", artist: "Air", album: "Moon", albumId: "al1", duration: 60)
        let one = CarPlayRows.nowPlayingLinks(albumOnly, offline: false, albumOnPhone: false, artistOnPhone: false)
        #expect(one.album != nil && one.artist == nil)
        #expect(CarPlayRows.nowPlayingLinks(nil, offline: false, albumOnPhone: false, artistOnPhone: false).isEmpty)
    }

    /// Offline (R10 on the phone): the downloaded page, or nothing.
    @Test func nowPlayingLinksOffline() {
        let song = Song(id: "s1", title: "One", artist: "Air", artistId: "ar1", album: "Moon", albumId: "al1", duration: 60)
        let none = CarPlayRows.nowPlayingLinks(song, offline: true, albumOnPhone: false, artistOnPhone: false)
        #expect(none.isEmpty)
        let both = CarPlayRows.nowPlayingLinks(song, offline: true, albumOnPhone: true, artistOnPhone: true)
        #expect(both.album == .downloadedAlbum(id: "al1", title: "Moon"))
        #expect(both.artist == .downloadedArtist(id: "ar1", name: "Air"))
    }
}
