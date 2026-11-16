import Foundation
import MagpieCore
import Testing

/// Round 28 O3 (owner, 2026-11-15, item 1: "In offline mode, only downloaded songs are visible within albums, artists,
/// songs, etc."): Library and Home keep their rows offline, each showing only what's on the phone; rows that need a
/// server hide (D340, amends spec §6 / Task 14's "Library shows only Downloads", "Home shows Downloaded").
@Suite struct OfflineLayoutTests {
    /// Library offline, in the owner's order: Playlists, Artists, Albums, Songs, Genres, Discover (with Aurral set up),
    /// Downloads (always).
    @Test func layout_offlineLibraryRowsKeepTheOwnersOrder() {
        var l = LayoutPreferences.defaultValue
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false, discoverSetUp: true)
                == [.playlists, .artists, .albums, .songs, .genres, .downloads, .discover])
        l.library.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)   // Downloads first
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: false)
                == [.downloads, .playlists, .artists, .albums, .songs, .genres])
        // Switched off: off offline too, except Downloads, which always shows.
        l.setLibraryRow(.artists, visible: false)
        l.setLibraryRow(.downloads, visible: false)
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: false)
                == [.downloads, .playlists, .albums, .songs, .genres])
    }

    /// Offline hides every row that needs a server: Favourites, Finds, Requests, Trending, Recommended; Discover without
    /// Aurral. The car follows the same rule (its Songs and Requests rules unchanged).
    @Test func layout_offlineHidesServerRows() {
        let l = LayoutPreferences.defaultValue
        for carPlay in [false, true] {
            let rows = l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: carPlay,
                                            discoverSetUp: true, trendingSetUp: true, recommendedSetUp: true)
            #expect(Set(rows).isDisjoint(with: [.favourites, .finds, .requests, .trending, .recommended]))
            #expect(rows.contains(.songs), "the car shows Songs too (round 13)")
        }
        let noAurral = l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false)
        #expect(!noAurral.contains(.discover), "no flows offline without Aurral")
    }

    /// Fix round 1 (design M7, amends D340): with favourites kept downloaded, Favourites stays offline (phone only).
    @Test func layout_offlineFavouritesWhenKeptOnThePhone() {
        let l = LayoutPreferences.defaultValue
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                     favouritesOnPhone: true)
                == [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads])
        #expect(!l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: false).contains(.favourites))
    }

    /// Home offline: the greeting, the quick grid, Recently downloaded (always), Your flows (with Aurral) and Playlists,
    /// in the owner's order and switches; nothing else.
    @Test func layout_offlineHomeSections() {
        var l = LayoutPreferences.defaultValue
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true)
                == [.greeting, .quickAccess, .downloaded, .playlists])
        let outside: Set<HomeSection> = [.recommended, .trending]
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true, discoverSetUp: true, outside: outside)
                == [.greeting, .quickAccess, .discover, .downloaded, .playlists])
        // The owner's switches hold, except Recently downloaded, which shows offline on its own (as before).
        l.home.set(.playlists, visible: false, keepingOneOf: [])
        l.home.set(.quickAccess, visible: false, keepingOneOf: [])
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: false, discoverSetUp: true)
                == [.greeting, .discover, .downloaded])
        // The owner's order holds.
        l.home.set(.playlists, visible: true, keepingOneOf: [])
        let from = l.home.entries.firstIndex { $0.item == .playlists }!
        l.home.move(fromOffsets: IndexSet(integer: from), toOffset: 0)
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: false)
                == [.playlists, .greeting, .downloaded])
    }
}
