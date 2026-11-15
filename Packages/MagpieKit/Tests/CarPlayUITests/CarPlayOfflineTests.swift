import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 28 O4 (owner, 2026-11-15): the car offline. A partial album or playlist says how much of it is on the phone
/// (D347), an empty offline list says nothing is downloaded (D348), car Home offline keeps Downloaded, Your flows and
/// Playlists in the car's order (D347), and long offline lists stay within the car's limits (D231).
@Suite struct CarPlayOfflineTests {
    func song(_ id: String) -> Song { Song(id: id, title: "T\(id)", artist: "A", album: "X", duration: 60) }

    // MARK: D347: "<n> of <m> on this iPhone"

    @Test func car_offlineAlbumPartialDetail() {
        let songs = [song("s1"), song("s2")]
        let partial = Album(id: "al1", name: "X", artist: "A", songCount: 10, duration: 120, songs: songs)
        let play = CarPlayRows.album(partial, playingId: nil, onPhone: true).first?.rows.first
        #expect(play?.title == "Play")
        #expect(play?.detail == "2 of 10 on this iPhone")
        // The whole album on the phone, or online: the song count as before.
        let whole = Album(id: "al1", name: "X", artist: "A", songCount: 2, duration: 120, songs: songs)
        #expect(CarPlayRows.album(whole, playingId: nil, onPhone: true).first?.rows.first?.detail == "2 songs")
        #expect(CarPlayRows.album(partial, playingId: nil).first?.rows.first?.detail == "2 songs")

        let list = Playlist(id: "p1", name: "Road", songCount: 7, duration: 120)
        #expect(CarPlayRows.playlist(list, songs: songs, playingId: nil, onPhone: true).first?.rows.first?.detail
                == "2 of 7 on this iPhone")
        #expect(CarPlayRows.playlist(list, songs: songs, playingId: nil).first?.rows.first?.detail == "2 songs")

        // A page built elsewhere (Downloads' album) gets the same line from the helper; never "0 of n" or "n of n".
        let downloaded = CarPlayRows.downloadedAlbum(partial, playingId: nil)
        #expect(CarPlayRows.onPhone(downloaded, songs: 2, total: 10).first?.rows.first?.detail == "2 of 10 on this iPhone")
        #expect(CarPlayRows.onPhone(downloaded, songs: 2, total: 2).first?.rows.first?.detail == "2 songs")
        #expect(CarPlayRows.partialDetail(onPhone: 0, total: 3) == nil)
        #expect(CarPlayRows.partialDetail(onPhone: 4, total: 4) == nil)
        #expect(CarPlayRows.partialDetail(onPhone: 1, total: 4) == "1 of 4 on this iPhone")
    }

    // MARK: D348: copy describes

    @Test func car_offlineEmptyListSaysNothingDownloaded() {
        let empty = CarPlayRows.state(.empty)
        let offline = CarPlayRows.offlineEmpty(empty)
        #expect(offline.flatMap(\.rows).map(\.title) == ["Nothing downloaded yet"])
        #expect(CarPlayRows.isPlaceholder(offline), "still a state row, so real rows replace it in place")
        // Anything else is left as it is: real rows, and the other states (Favourites keeps "You're offline").
        let rows = CarPlayRows.albums([Album(id: "a", name: "A", artist: "B", songCount: 1, duration: 1)])
        #expect(CarPlayRows.offlineEmpty(rows) == rows)
        #expect(CarPlayRows.offlineEmpty(CarPlayRows.state(.offline)) == CarPlayRows.state(.offline))
        // An empty offline list is never instructive (D12): no detail line.
        #expect(offline.flatMap(\.rows).allSatisfy { $0.detail == nil && $0.action == .none })
    }

    // MARK: D347: car Home offline

    @Test func car_offlineHomeShelves() {
        let phone = LayoutPreferences.defaultValue
        let prefs = CarPlayPreferences.defaultValue
        // The car's default list (build 13's) hides Playlists and Downloaded; offline both show, with Discover's flows.
        let offline = prefs.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: true)
        #expect(Set(offline) == [.downloaded, .discover, .playlists])
        let order = prefs.homeList(following: phone.home).entries.map(\.item.section)
        #expect(offline == order.filter { [.downloaded, .discover, .playlists].contains($0) }, "in the car's order")
        // Without Aurral no flows; Made for you never offline.
        let noAurral = prefs.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: false)
        #expect(Set(noAurral) == [.downloaded, .playlists])
        // The car's own order is followed.
        var own = prefs
        own.home = OrderedVisibility([.init(item: .playlists, visible: false), .init(item: .madeForYou, visible: true),
                                      .init(item: .downloaded, visible: true), .init(item: .discover, visible: true)])
        own = own.normalised()
        #expect(own.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: true)
                == [.playlists, .downloaded, .discover])
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
        #expect(first.first?.rows.first?.detail == "400 of 500 on this iPhone", "the line survives paging")
        #expect(first.flatMap(\.rows).last?.title == "More\u{2026}", "the rest is a page away (D231)")
    }
}
