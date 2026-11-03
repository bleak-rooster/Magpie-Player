import Foundation
import Testing
@testable import MagpieCore

/// Round 13 items 10 and 11: Settings › CarPlay. The car's third tab (Finds is gone) and the car's own Home, which
/// follows the phone's Home until it is changed.
@Suite struct CarPlayPreferencesTests {
    @Test func defaultsArePlaylistsAndThePhonesHome() {
        let car = Preferences.standard.carPlay
        #expect(car.thirdTab == .playlists)
        #expect(car.home == nil, "follows the phone's Home until changed")
        #expect(CarPlayTab.allCases == [.playlists, .artists, .albums, .songs, .genres, .favourites, .discover, .downloads])
        #expect(CarPlayTab.allCases.map(\.title) == ["Playlists", "Artists", "Albums", "Songs", "Genres", "Favourites",
                                                     "Discover", "Downloads"])
    }

    /// The plan's nine shelves, in its order (Genres isn't one of them).
    @Test func theCarsHomeOffersNineShelves() {
        #expect(CarPlayHomeShelf.allCases.map(\.title) == ["Discover", "Playlists", "Recently added", "Recently downloaded",
                                                           "Most played", "Jump back in", "Favourites", "Random albums",
                                                           "Made for you"])
        #expect(CarPlayHomeShelf.allCases.map(\.section) == [.discover, .playlists, .recentlyAdded, .downloaded, .mostPlayed,
                                                             .jumpBackIn, .favourites, .randomAlbums, .madeForYou])
    }

    /// The default copies the phone's layout: its order and switches, without Genres.
    @Test func followingThePhoneCopiesItsOrderAndSwitches() {
        var phone = LayoutPreferences.defaultValue
        phone.home.moveDown(.jumpBackIn)   // madeForYou, jumpBackIn, …
        phone.home.set(.genres, visible: true, keepingOneOf: [])
        phone.home.set(.playlists, visible: true, keepingOneOf: [])
        let car = CarPlayPreferences.defaultValue
        let list = car.homeList(following: phone.home)
        #expect(list.entries.map(\.item) == [.madeForYou, .jumpBackIn, .recentlyAdded, .mostPlayed, .favourites,
                                             .randomAlbums, .playlists, .downloaded, .discover])
        #expect(car.visibleHomeSections(phone: phone, offline: false, hasListenBrainzToken: true, discoverSetUp: true)
                == [.madeForYou, .jumpBackIn, .recentlyAdded, .mostPlayed, .playlists, .discover])
    }

    /// Once changed, the car keeps its own list: the phone's changes don't move it.
    @Test func aChangedHomeIsTheCarsOwn() {
        var car = CarPlayPreferences.defaultValue
        var list = car.homeList(following: LayoutPreferences.defaultValue.home)
        list.moveUp(.playlists)
        list.set(.playlists, visible: true, keepingOneOf: [])
        list.set(.jumpBackIn, visible: false, keepingOneOf: [])
        car.home = list
        var phone = LayoutPreferences.defaultValue
        phone.home.set(.randomAlbums, visible: true, keepingOneOf: [])
        let shown = car.visibleHomeSections(phone: phone, offline: false, hasListenBrainzToken: false, discoverSetUp: false)
        #expect(shown == [.recentlyAdded, .mostPlayed, .playlists], "no token: no Made for you; no Aurral: no Discover")
        #expect(!shown.contains(.randomAlbums))
        #expect(car.visibleHomeSections(phone: phone, offline: true, hasListenBrainzToken: true, discoverSetUp: true)
                == [.downloaded], "offline the car shows what's on the phone, as the phone does")
    }

    @Test func savedAndReadBack() throws {
        var car = CarPlayPreferences.defaultValue
        car.thirdTab = .artists
        var list = car.homeList(following: LayoutPreferences.defaultValue.home)
        list.moveDown(.discover)
        car.home = list
        let data = try #require(car.encoded())
        #expect(CarPlayPreferences.decode(data) == car)
        #expect(CarPlayPreferences.decode(Data(#"{"thirdTab":"finds"}"#.utf8)) == .defaultValue, "an unknown tab: the default")
        let partial = CarPlayPreferences.decode(Data(#"{"home":[{"id":"playlists","visible":true},{"id":"genres","visible":true}]}"#.utf8))
        #expect(partial.home?.entries.first == .init(item: .playlists, visible: true))
        #expect(partial.home?.entries.count == CarPlayHomeShelf.allCases.count, "missing shelves come back, hidden")
        #expect(partial.home?.entries.dropFirst().allSatisfy { !$0.visible } == true)
    }

    /// Discover is a choice only while Aurral is set up; a saved Discover without it shows Playlists.
    @Test func discoverFallsBackToPlaylistsWithoutAurral() {
        var car = CarPlayPreferences.defaultValue
        car.thirdTab = .discover
        #expect(car.tab(discoverSetUp: true) == .discover)
        #expect(car.tab(discoverSetUp: false) == .playlists)
        #expect(CarPlayTab.choices(discoverSetUp: false) == [.playlists, .artists, .albums, .songs, .genres, .favourites,
                                                             .downloads])
        #expect(CarPlayTab.choices(discoverSetUp: true).contains(.discover))
    }
}
