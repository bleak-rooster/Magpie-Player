import Foundation
import Testing
@testable import MagpieCore

/// Round 14 A4 (D93): Library › Trending and Recommended. They sit after Discover, migrate into saved layouts right
/// after Discover, show only while Aurral is set up and can give them, and never reach the car (CarPlay is unchanged).
@Suite struct Round14LibraryRowsTests {
    @Test func theNewRowsSitAfterDiscover() {
        let rows = LayoutPreferences.defaultValue.library.entries.map(\.item)
        let discover = try! #require(rows.firstIndex(of: .discover))
        #expect(rows[discover + 1] == .trending && rows[discover + 2] == .recommended)
        #expect(LibraryRow.trending.title == "Trending" && LibraryRow.recommended.title == "Recommended")
        #expect(!LibraryRow.trending.symbol.isEmpty && !LibraryRow.recommended.symbol.isEmpty)
    }

    @Test func hiddenUntilAurralCanGiveThem() {
        let l = LayoutPreferences.defaultValue
        let none = l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: false)
        #expect(!none.contains(.trending) && !none.contains(.recommended))
        // Aurral set up, but it can't give them (2.10, or not read yet): hidden.
        let old = l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                       discoverSetUp: true)
        #expect(old.suffix(1) == [.discover])
        let both = l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                        discoverSetUp: true, trendingSetUp: true, recommendedSetUp: true)
        #expect(both.suffix(3) == [.discover, .trending, .recommended])
        // Each on its own capability; never without Aurral set up.
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                     discoverSetUp: true, trendingSetUp: true).suffix(2) == [.discover, .trending])
        #expect(!l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                      trendingSetUp: true, recommendedSetUp: true).contains(.trending))
        // Never in the car, never offline.
        let car = l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: false, carPlay: true,
                                       discoverSetUp: true, trendingSetUp: true, recommendedSetUp: true)
        #expect(car.last == .discover)
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: false,
                                     discoverSetUp: true, trendingSetUp: true, recommendedSetUp: true) == [.genres, .downloads])
    }

    /// A layout saved before round 14 (rearranged: Discover moved to the top, Songs hidden) gains both rows right after
    /// Discover, visible, and keeps everything else as it was.
    @Test func savedLayoutsGainThemAfterDiscover() throws {
        let saved = #"{"version":1,"showsRecentlyAdded":true,"library":[{"id":"discover","visible":true},{"id":"playlists","visible":true},{"id":"artists","visible":true},{"id":"albums","visible":true},{"id":"songs","visible":false},{"id":"genres","visible":true},{"id":"favourites","visible":true},{"id":"downloads","visible":true},{"id":"finds","visible":true},{"id":"requests","visible":true}]}"#
        let layout = LayoutPreferences.decode(Data(saved.utf8))
        #expect(layout.library.entries.map(\.item)
                == [.discover, .trending, .recommended, .playlists, .artists, .albums, .songs, .genres, .favourites,
                    .downloads, .finds, .requests])
        #expect(layout.library.entries.first { $0.item == .songs }?.visible == false)
        #expect(layout.library.entries.first { $0.item == .trending }?.visible == true)
        // Saved again and read back: unchanged (no second migration).
        let again = LayoutPreferences.decode(try #require(layout.encoded()))
        #expect(again.library == layout.library)
        // An owner who moved Trending away keeps it there.
        var moved = layout
        moved.library.move(fromOffsets: IndexSet(integer: 1), toOffset: moved.library.entries.count)
        #expect(LayoutPreferences.decode(try #require(moved.encoded())).library.entries.last?.item == .trending)
    }

    /// A build 11 layout (before Discover): Discover goes last as before, the new rows after it.
    @Test func aLayoutWithoutDiscoverGetsAllThreeAtTheEnd() {
        let saved = #"{"library":[{"id":"albums","visible":true},{"id":"playlists","visible":true}]}"#
        let items = LayoutPreferences.decode(Data(saved.utf8)).library.entries.map(\.item)
        #expect(items.prefix(2) == [.albums, .playlists])
        #expect(items.suffix(3) == [.discover, .trending, .recommended])
        #expect(Set(items) == Set(LibraryRow.allCases))
    }
}
