import Foundation
import Testing
@testable import MagpieCore

/// Round 14 A6: the Spotify-style Home's sections, their order and settings, the migration of saved layouts, the
/// filter chips, and which sections show in each setup (owner answers 4 and 9).
@Suite struct HomeLayoutTests {
    static let build13Order: [HomeSection] = [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites,
                                              .randomAlbums, .playlists, .genres, .downloaded, .discover]

    /// The plan's order: the greeting, chips and quick grid; Your flows; Recommended; New this week; Because you like;
    /// Jump back in; More playlists; Recently added, Favourites, Most played; Close to home, Further out; Trending;
    /// Charts by genre; then Recently downloaded, Random albums, Made for you, Playlists, Genres.
    static let newDefault: [HomeSection] = [.greeting, .filterChips, .quickAccess, .discover, .recommended, .newThisWeek,
                                            .becauseYouLike, .jumpBackIn, .morePlaylists, .recentlyAdded, .favourites,
                                            .mostPlayed, .closeToHome, .furtherOut, .trending, .genreCharts, .downloaded,
                                            .randomAlbums, .madeForYou, .playlists, .genres]

    @Test func defaultOrderIsThePlans() {
        let home = LayoutPreferences.defaultValue.home
        #expect(home.entries.map(\.item) == Self.newDefault)
        #expect(Set(HomeSection.allCases) == Set(Self.newDefault) && HomeSection.allCases.count == Self.newDefault.count)
        // Navidrome only (answer 9): greeting, quick grid, Jump back in, Recently added, Favourites, Most played, Made
        // for you, Playlists, Genres. Random albums and Recently downloaded stay off.
        #expect(Set(home.entries.filter { !$0.visible }.map(\.item)) == [.randomAlbums, .downloaded])
    }

    @Test func titlesAndStoredNames() {
        #expect(HomeSection.discover.rawValue == "discover", "the stored name stays for old layouts")
        #expect(HomeSection.discover.title == "Your flows")
        #expect(HomeSection.recommended.title == "Recommended for you")
        #expect(HomeSection.newThisWeek.title == "New this week")
        #expect(HomeSection.becauseYouLike.title == "Because you like")
        #expect(HomeSection.morePlaylists.title == "More playlists for you")
        #expect(HomeSection.closeToHome.title == "Close to home" && HomeSection.furtherOut.title == "Further out")
        #expect(HomeSection.trending.title == "Trending" && HomeSection.genreCharts.title == "Charts by genre")
        #expect(HomeSection.greeting.title == "Greeting" && HomeSection.filterChips.title == "Filters")
        #expect(HomeSection.quickAccess.title == "Quick access")
        #expect(HomeSection.allCases.allSatisfy { !$0.title.contains("Aurral") && !$0.title.contains("Lidarr") })
    }

    // MARK: Migration

    /// A build-13 layout the owner never changed becomes the new default.
    @Test func untouchedBuild13LayoutBecomesTheNewDefault() {
        let json = #"{"version":1,"home":["# + Self.build13Order.map {
            #"{"id":"\#($0.rawValue)","visible":\#([.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .discover].contains($0))}"#
        }.joined(separator: ",") + "]}"
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.home == LayoutPreferences.defaultValue.home)
    }

    /// The build-13 order with the switches changed: the new order, the owner's switches kept.
    @Test func build13SwitchesAreKept() {
        let json = #"{"version":1,"home":["# + Self.build13Order.map {
            #"{"id":"\#($0.rawValue)","visible":\#([.randomAlbums, .discover].contains($0))}"#
        }.joined(separator: ",") + "]}"
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.home.entries.map(\.item) == Self.newDefault)
        #expect(layout.home.entries.first { $0.item == .jumpBackIn }?.visible == false)
        #expect(layout.home.entries.first { $0.item == .randomAlbums }?.visible == true)
        #expect(layout.home.entries.first { $0.item == .recommended }?.visible == true, "new sections take their default")
    }

    /// A rearranged build-13 layout keeps its order; each new section goes in after its default predecessor (the
    /// header at the top), visible as by default.
    @Test func rearrangedBuild13LayoutKeepsItsOrder() {
        let order: [HomeSection] = [.mostPlayed, .genres, .jumpBackIn, .madeForYou, .recentlyAdded, .favourites,
                                    .randomAlbums, .playlists, .downloaded, .discover]
        let json = #"{"version":1,"home":["# + order.map {
            #"{"id":"\#($0.rawValue)","visible":\#($0 != .favourites)}"#
        }.joined(separator: ",") + "]}"
        let layout = LayoutPreferences.decode(Data(json.utf8))
        let items = layout.home.entries.map(\.item)
        #expect(items == [.greeting, .filterChips, .quickAccess, .mostPlayed, .closeToHome, .furtherOut, .trending,
                          .genreCharts, .genres, .jumpBackIn, .morePlaylists, .madeForYou, .recentlyAdded, .favourites,
                          .randomAlbums, .playlists, .downloaded, .discover, .recommended, .newThisWeek, .becauseYouLike])
        let old = items.filter { order.contains($0) }
        #expect(old == order, "the owner's order is kept")
        #expect(layout.home.entries.first { $0.item == .favourites }?.visible == false)
        #expect(layout.home.entries.first { $0.item == .randomAlbums }?.visible == true)
        #expect(layout.home.entries.first { $0.item == .trending }?.visible == true)
    }

    /// A build-11 layout (no Discover yet), rearranged: Discover comes back after the quick grid.
    @Test func layoutWithoutDiscoverGainsIt() {
        let order: [HomeSection] = [.recentlyAdded, .jumpBackIn, .madeForYou, .mostPlayed, .favourites, .randomAlbums,
                                    .playlists, .genres, .downloaded]
        let json = #"{"home":["# + order.map { #"{"id":"\#($0.rawValue)","visible":true}"# }.joined(separator: ",") + "]}"
        let items = LayoutPreferences.decode(Data(json.utf8)).home.entries.map(\.item)
        #expect(Array(items.prefix(8)) == [.greeting, .filterChips, .quickAccess, .discover, .recommended, .newThisWeek,
                                           .becauseYouLike, .recentlyAdded])
        #expect(items.count == HomeSection.allCases.count)
    }

    /// A round-14 layout is never migrated again: the owner's placement of the new sections stays.
    @Test func round14LayoutIsLeftAlone() {
        var layout = LayoutPreferences.defaultValue
        layout.home.move(fromOffsets: IndexSet(integer: 0), toOffset: layout.home.entries.count)   // greeting last
        let decoded = LayoutPreferences.decode(layout.encoded())
        #expect(decoded.home == layout.home)
    }

    // MARK: Per-section settings

    @Test func sectionSettingsDefaultsAndPersist() {
        var layout = LayoutPreferences.defaultValue
        #expect(layout.style(for: .recentlyAdded) == HomeSectionStyle(size: .medium, count: 12))
        #expect(layout.style(for: .quickAccess).count == 8)
        #expect(layout.style(for: .trending).size == .large)
        #expect(layout.becauseYouLikeRows == 3)
        layout.setStyle(HomeSectionStyle(size: .small, count: 6), for: .recentlyAdded)
        layout.becauseYouLikeRows = 1
        let decoded = LayoutPreferences.decode(layout.encoded())
        #expect(decoded.style(for: .recentlyAdded) == HomeSectionStyle(size: .small, count: 6))
        #expect(decoded.becauseYouLikeRows == 1)
        #expect(!decoded.isDefaultHome)
        var reset = decoded
        reset.resetHome()
        #expect(reset.isDefaultHome && reset.home == LayoutPreferences.defaultValue.home)
        #expect(reset.style(for: .recentlyAdded) == HomeSectionStyle(size: .medium, count: 12))
        #expect(reset.becauseYouLikeRows == 3)
        #expect(reset.library == decoded.library, "Reset on Home leaves the Library alone")
    }

    @Test func hostileSectionSettingsClamp() {
        let json = #"{"homeStyles":{"recentlyAdded":{"size":"huge","count":-4},"trending":{"size":"small","count":900},"#
            + #""karaoke":{"size":"small","count":4},"quickAccess":{"size":"large","count":30}},"becauseYouLikeRows":17}"#
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.style(for: .recentlyAdded) == HomeSectionStyle(size: .medium, count: HomeSectionStyle.countRange.lowerBound))
        #expect(layout.style(for: .trending) == HomeSectionStyle(size: .small, count: HomeSectionStyle.countRange.upperBound))
        #expect(layout.style(for: .quickAccess).count == 8, "the quick grid holds at most 8")
        #expect(layout.homeStyles["karaoke"] == nil, "an unknown section is dropped")
        #expect(layout.becauseYouLikeRows == 3)
        #expect(LayoutPreferences.decode(Data(#"{"becauseYouLikeRows":-1}"#.utf8)).becauseYouLikeRows == 0)
        #expect(LayoutPreferences.decode(Data(#"{"homeStyles":7}"#.utf8)).homeStyles.isEmpty, "a bad field keeps its default")
    }

    @Test func whichSectionsHaveSettings() {
        #expect(!HomeSection.greeting.hasCardSettings && !HomeSection.filterChips.hasCardSettings)
        #expect(!HomeSection.quickAccess.hasCardSettings && HomeSection.quickAccess.hasCountSetting)
        #expect(HomeSection.recentlyAdded.hasCardSettings && HomeSection.trending.hasCardSettings)
        #expect(!HomeSection.becauseYouLike.hasCountSetting || HomeSection.becauseYouLike.hasCardSettings)
    }

    // MARK: Setups

    /// Answer 9: each setup's Home. Sections needing a missing service never show; Navidrome only is complete.
    @Test func sectionsPerSetup() {
        let l = LayoutPreferences.defaultValue
        let navidrome = l.visibleHomeSections(offline: false, hasListenBrainzToken: false)
        #expect(navidrome == [.greeting, .filterChips, .quickAccess, .jumpBackIn, .recentlyAdded, .favourites, .mostPlayed,
                              .playlists, .genres])
        let outside: Set<HomeSection> = [.recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut,
                                         .morePlaylists, .trending, .genreCharts]
        // Aurral set up, but nothing provides its shelves yet: only Your flows joins.
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false, discoverSetUp: true)
                == [.greeting, .filterChips, .quickAccess, .discover, .jumpBackIn, .recentlyAdded, .favourites,
                    .mostPlayed, .playlists, .genres])
        let all = l.visibleHomeSections(offline: false, hasListenBrainzToken: true, discoverSetUp: true, outside: outside)
        #expect(all == Self.newDefault.filter { ![.randomAlbums, .downloaded].contains($0) })
        // Provided shelves never show without Aurral (signed out).
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false, discoverSetUp: false, outside: outside)
                == navidrome)
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true, discoverSetUp: true, outside: outside)
                == [.downloaded])
        var none = l
        none.becauseYouLikeRows = 0
        #expect(!none.visibleHomeSections(offline: false, hasListenBrainzToken: false, discoverSetUp: true, outside: outside)
            .contains(.becauseYouLike), "0 rows hides Because you like")
    }

    @Test func needs() {
        #expect(HomeSection.trending.need == .aurral && HomeSection.discover.need == .aurral)
        #expect(HomeSection.jumpBackIn.need == nil && HomeSection.greeting.need == nil)
        #expect(HomeService.aurral.needsLabel == "Needs Aurral" && HomeService.lidarr.needsLabel == "Needs Lidarr")
        #expect(HomeSection.madeForYou.need == .listenBrainz)
    }

    // MARK: Filter chips

    @Test func chipsNarrowToTheirSections() {
        let shown = Self.newDefault
        #expect(HomeFilter.all.apply(shown) == shown)
        #expect(HomeFilter.discover.apply(shown) == [.greeting, .filterChips, .discover, .morePlaylists, .trending, .genreCharts])
        #expect(HomeFilter.recommended.apply(shown) == [.greeting, .filterChips, .recommended, .newThisWeek, .becauseYouLike,
                                                        .closeToHome, .furtherOut])
        #expect(HomeFilter.library.apply(shown) == [.greeting, .filterChips, .quickAccess, .jumpBackIn, .recentlyAdded,
                                                    .favourites, .mostPlayed, .downloaded, .randomAlbums, .madeForYou,
                                                    .playlists, .genres])
        #expect(HomeFilter.allCases.map(\.title) == ["All", "Discover", "Recommended", "Your library"])
    }

    /// A chip shows only when one of its sections is on Home: without Aurral, All and Your library.
    @Test func chipsForMissingServicesHide() {
        let navidrome: [HomeSection] = [.greeting, .filterChips, .quickAccess, .jumpBackIn, .recentlyAdded]
        #expect(HomeFilter.offered(for: navidrome) == [.all, .library])
        #expect(HomeFilter.offered(for: navidrome + [.discover]) == [.all, .discover, .library])
        #expect(HomeFilter.offered(for: Self.newDefault) == HomeFilter.allCases)
    }
}
