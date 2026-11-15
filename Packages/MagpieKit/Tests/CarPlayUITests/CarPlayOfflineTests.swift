import Foundation
import MagpieCore
import Testing
import Playback
@testable import CarPlayUI

/// Round 28 O4 (owner, 2026-11-15): the car offline. A partial album or playlist says how much of it is on the phone
/// (D347), an empty offline list says nothing is downloaded (D348), car Home offline keeps Downloaded, Your flows and
/// Playlists in the car's order (D347), and long offline lists stay within the car's limits (D231).
@Suite struct CarPlayOfflineTests {
    func song(_ id: String) -> Song { Song(id: id, title: "T\(id)", artist: "A", album: "X", duration: 60) }

    // MARK: D347: "<n> of <m> songs on this iPhone"

    @Test func car_offlineAlbumPartialDetail() {
        let songs = [song("s1"), song("s2")]
        let partial = Album(id: "al1", name: "X", artist: "A", songCount: 10, duration: 120, songs: songs)
        let play = CarPlayRows.album(partial, playingId: nil, onPhone: true).first?.rows.first
        #expect(play?.title == "Play")
        #expect(play?.detail == "2 of 10 songs on this iPhone")
        // The whole album on the phone, or online: the song count as before.
        let whole = Album(id: "al1", name: "X", artist: "A", songCount: 2, duration: 120, songs: songs)
        #expect(CarPlayRows.album(whole, playingId: nil, onPhone: true).first?.rows.first?.detail == "2 songs")
        #expect(CarPlayRows.album(partial, playingId: nil).first?.rows.first?.detail == "2 songs")

        let list = Playlist(id: "p1", name: "Road", songCount: 7, duration: 120)
        #expect(CarPlayRows.playlist(list, songs: songs, playingId: nil, onPhone: true).first?.rows.first?.detail
                == "2 of 7 songs on this iPhone")
        #expect(CarPlayRows.playlist(list, songs: songs, playingId: nil).first?.rows.first?.detail == "2 songs")

        // A page built elsewhere (Downloads' album) gets the same line from the helper; never "0 of n" or "n of n".
        let downloaded = CarPlayRows.downloadedAlbum(partial, playingId: nil)
        #expect(CarPlayRows.onPhone(downloaded, songs: 2, total: 10).first?.rows.first?.detail == "2 of 10 songs on this iPhone")
        #expect(CarPlayRows.onPhone(downloaded, songs: 2, total: 2).first?.rows.first?.detail == "2 songs")
        #expect(CarPlayRows.partialDetail(onPhone: 0, total: 3) == nil)
        #expect(CarPlayRows.partialDetail(onPhone: 4, total: 4) == nil)
        #expect(CarPlayRows.partialDetail(onPhone: 1, total: 4) == "1 of 4 songs on this iPhone")
    }

    // MARK: D348: copy describes

    @Test func car_offlineEmptyListSaysNothingDownloaded() {
        let empty = CarPlayRows.state(.empty)
        let offline = CarPlayRows.offlineEmpty(empty, .downloads)
        #expect(offline.flatMap(\.rows).map(\.title) == ["Nothing downloaded yet"])
        #expect(CarPlayRows.isPlaceholder(offline), "still a state row, so real rows replace it in place")
        // Fix round 1 (design M1): with its symbol, and saying what isn't there for playlists and genres.
        #expect(offline.flatMap(\.rows).map(\.statusSymbol) == ["arrow.down.circle"])
        #expect(CarPlayRows.offlineEmpty(empty, .playlists).flatMap(\.rows).map(\.title) == ["No playlists on this iPhone"])
        #expect(CarPlayRows.offlineEmpty(empty, .genres).flatMap(\.rows).map(\.title) == ["No genres on this iPhone"])
        #expect(CarPlayRows.offlineEmptyKind(.downloads) == .downloads && CarPlayRows.offlineEmptyKind(.albums) == .downloads)
        #expect(CarPlayRows.offlineEmptyKind(.playlists) == .playlists && CarPlayRows.offlineEmptyKind(.discover) == .playlists)
        #expect(CarPlayRows.offlineEmptyKind(.genres) == .genres)
        #expect(CarPlayRows.offlineEmptyKind(.finds) == nil && CarPlayRows.offlineEmptyKind(.searchResults(query: "x")) == nil)
        // Anything else is left as it is: real rows, and the other states (Favourites keeps "You're offline").
        let rows = CarPlayRows.albums([Album(id: "a", name: "A", artist: "B", songCount: 1, duration: 1)])
        #expect(CarPlayRows.offlineEmpty(rows, .downloads) == rows)
        #expect(CarPlayRows.offlineEmpty(CarPlayRows.state(.offline), .downloads) == CarPlayRows.state(.offline))
        // An empty offline list is never instructive (D12): a title only.
        #expect(offline.flatMap(\.rows).allSatisfy { $0.detail == nil && $0.action == .none })
    }

    /// Fix round 1 (design M2): offline, car Home opens with a line saying so (not tappable); empty, it says nothing is
    /// downloaded under it.
    @Test func car_offlineHomeLine() {
        let album = Album(id: "a", name: "A", artist: "B", songCount: 1, duration: 1)
        let home = CarPlayRows.offlineHome(CarPlayRows.home([CPHomeShelf(section: .downloaded, items: [.album(album)])]))
        let first = home.first?.rows.first
        #expect(first?.title == "Offline \u{00B7} music on this iPhone" && first?.statusSymbol == "wifi.slash")
        #expect(first?.action == RowAction.none && home.count == 2)
        let empty = CarPlayRows.offlineHome(CarPlayRows.home([])).flatMap(\.rows).map(\.title)
        #expect(empty == ["Offline \u{00B7} music on this iPhone", "Nothing downloaded yet"])
    }

    /// Fix round 1 (design H4): offline, Up Next's songs not on the phone say so and do nothing.
    @Test func car_upNextOfflineRows() {
        let a = QueueEntryFixture.make("s1"), b = QueueEntryFixture.make("s2")
        let rows = CarPlayRows.upNext(current: a, upcoming: [b], playingId: "s1")
        let marked = CarPlayRows.upNextOffline(rows, notOnPhone: [b.id]).flatMap(\.rows)
        #expect(marked.map(\.detail) == ["A", "Not on this iPhone"])
        #expect(marked.map(\.statusSymbol) == [nil, "wifi.slash"])
        #expect(marked[0].action == .queueEntry(a.id) && marked[1].action == RowAction.none)
        #expect(CarPlayRows.upNextOffline(rows, notOnPhone: []) == rows)
    }

    /// Fix round 1 (design H5): an artist on the phone: their albums, then "Songs on this iPhone"; Play and Shuffle play
    /// exactly those.
    @Test func car_artistOnPhoneRows() {
        let own = [Song(id: "o1", title: "One", artist: "Low", album: "Things", duration: 60),
                   Song(id: "o2", title: "Two", artist: "Low", album: "Things", duration: 60)]
        let featured = [Song(id: "f1", title: "Guest", artist: "Low", album: "Sampler", duration: 60)]
        let album = Album(id: "al", name: "Things", artist: "Low", songCount: 2, duration: 120, songs: own)
        let artist = Artist(id: "ar", name: "Low", albumCount: 1)
        let page = CarPlayRows.artistOnPhone(artist, albums: [album], songs: featured, albumsOpen: true, downloadedPages: false)
        #expect(page.map(\.header) == [nil, "Albums", "Songs on this iPhone"])
        let rows = page.flatMap(\.rows)
        #expect(rows.map(\.title) == ["Play", "Shuffle", "Things", "Guest"])
        #expect(rows[0].action == .play(.songs(own + featured, startAt: 0)) && rows[1].action == .play(.shuffle(own + featured)))
        #expect(rows[2].action == .open(.album(id: "al", title: "Things")))
        #expect(rows[3].action == .play(.songs(own + featured, startAt: 2)))
        let downloads = CarPlayRows.artistOnPhone(artist, albums: [album], songs: [], albumsOpen: false, downloadedPages: true)
        #expect(downloads.map(\.header) == [nil, "Albums"])
        #expect(downloads.flatMap(\.rows)[2].action == .play(.songs(own, startAt: 0)))
        #expect(CarPlayRows.artistOnPhone(artist, albums: [], songs: [], albumsOpen: true, downloadedPages: true)
                == CarPlayRows.state(.empty))
    }

    // MARK: D347: car Home offline

    @Test func car_offlineHomeShelves() {
        let phone = LayoutPreferences.defaultValue
        let prefs = CarPlayPreferences.defaultValue
        // The car's default list (build 13's) hides Playlists and Downloaded and shows Discover. Fix round 1 (design
        // M5): offline Downloaded always shows, the others only as switched.
        let offline = prefs.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: true)
        #expect(Set(offline) == [.downloaded, .discover])
        let order = prefs.homeList(following: phone.home).entries.map(\.item.section)
        #expect(offline == order.filter { [.downloaded, .discover].contains($0) }, "in the car's order")
        // Without Aurral no flows; Made for you never offline.
        let noAurral = prefs.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: false)
        #expect(noAurral == [.downloaded])
        // The car's own order is followed.
        var own = prefs
        own.home = OrderedVisibility([.init(item: .playlists, visible: false), .init(item: .madeForYou, visible: true),
                                      .init(item: .downloaded, visible: true), .init(item: .discover, visible: true)])
        own = own.normalised()
        #expect(own.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: true)
                == [.downloaded, .discover], "Playlists switched off stays off")
        // Online: unchanged.
        #expect(own.visibleHomeSections(phone: phone, offline: false, hasListenBrainzToken: true, discoverSetUp: true)
                == [.madeForYou, .downloaded, .discover])
    }

    // MARK: D231 offline

    @Test func car_offlinePagingWithinLimits() {
        // 700 albums downloaded and a 400-song playlist on the phone, on a head unit allowing 12 rows in 4 sections.
        let albums = (0..<700).map { Album(id: "al\($0)", name: "Album \(String(format: "%04d", $0))", artist: "A",
                                           songCount: 1, duration: 1) }
        let lettered = CarPlayRows.albums(albums, maxItems: 12, maxSections: 4)
        let fitted = clamp(lettered, maxItems: 12, maxSections: 4)
        #expect(fitted.flatMap(\.rows).count <= 12 && fitted.count <= 4)
        let songs = (0..<400).map { song("s\($0)") }
        let page = CarPlayRows.playlist(Playlist(id: "p", name: "P", songCount: 500, duration: 1), songs: songs,
                                        playingId: nil, onPhone: true)
        let first = clamp(page, maxItems: 12, maxSections: 4)
        #expect(first.flatMap(\.rows).count <= 12 && first.count <= 4)
        #expect(first.first?.rows.first?.detail == "400 of 500 songs on this iPhone", "the line survives paging")
        #expect(first.flatMap(\.rows).last?.title == "More\u{2026}", "the rest is a page away (D231)")
    }
}

/// Queue entries for the Up Next rows (made by the queue itself).
enum QueueEntryFixture {
    static func make(_ id: String) -> QueueEntry {
        var queue = PlayQueue()
        queue.replace(with: [Song(id: id, title: id, artist: "A", album: "B", duration: 60)], startAt: 0)
        return queue.current!
    }
}
