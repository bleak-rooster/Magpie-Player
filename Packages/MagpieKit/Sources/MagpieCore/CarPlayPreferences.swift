import Foundation

// Round 13 items 10 and 11: Settings › CarPlay. The car's third tab (it replaced Finds) and the car's own Home, which is
// separate from the phone's and follows it until it is changed.

/// The car's third tab, between Library and Search.
public enum CarPlayTab: String, CaseIterable, Codable, Hashable, Sendable {
    case playlists, artists, albums, songs, genres, favourites, discover, downloads

    public var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .favourites: "Favourites"
        case .discover: "Discover"
        case .downloads: "Downloads"
        }
    }

    /// The tab's symbol (the phone's Library row symbol, filled where SF Symbols has one).
    public var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack.fill"
        case .songs: "music.note"
        case .genres: "guitars.fill"
        case .favourites: "heart.fill"
        case .discover: "binoculars.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    /// What Settings › CarPlay offers: Discover only while Aurral is set up.
    public static func choices(discoverSetUp: Bool) -> [CarPlayTab] {
        allCases.filter { $0 != .discover || discoverSetUp }
    }
}

/// One shelf the car's Home may show: the plan's nine, then Genres (as the car showed it before round 13).
public enum CarPlayHomeShelf: String, CaseIterable, Codable, Hashable, Sendable {
    case discover, playlists, recentlyAdded, downloaded, mostPlayed, jumpBackIn, favourites, randomAlbums, madeForYou
    /// Review (Z3): the car showed a Genres shelf before round 13; it stays an option.
    case genres

    /// The phone's Home section it reads (same raw value).
    public var section: HomeSection {
        switch self {
        case .discover: .discover
        case .playlists: .playlists
        case .recentlyAdded: .recentlyAdded
        case .downloaded: .downloaded
        case .mostPlayed: .mostPlayed
        case .jumpBackIn: .jumpBackIn
        case .favourites: .favourites
        case .randomAlbums: .randomAlbums
        case .madeForYou: .madeForYou
        case .genres: .genres
        }
    }

    /// The car keeps "Discover" (round 14 changes only the phone's Home, which calls it "Your flows").
    public var title: String { self == .discover ? "Discover" : section.title }

    init?(_ section: HomeSection) { self.init(rawValue: section.rawValue) }
}

public struct CarPlayPreferences: PreferenceArea {
    public static let key = "magpie.prefs.carplay"
    public static let defaultValue = CarPlayPreferences(thirdTab: .playlists, home: nil)
    /// The phone's default Home before round 14, which the car keeps following while the phone's is the default.
    static let build13Phone = OrderedVisibility(HomeSection.build13Order.map {
        .init(item: $0, visible: HomeSection.build13Visible.contains($0))
    })
    /// Shelves missing from a saved list come back hidden.
    static let hiddenShelves = OrderedVisibility(CarPlayHomeShelf.allCases.map { .init(item: $0, visible: false) })

    public var thirdTab: CarPlayTab
    /// The car's own Home; nil while it follows the phone's.
    public var home: OrderedVisibility<CarPlayHomeShelf>?

    public init(thirdTab: CarPlayTab, home: OrderedVisibility<CarPlayHomeShelf>?) {
        self.thirdTab = thirdTab
        self.home = home
    }

    public func normalised() -> CarPlayPreferences {
        CarPlayPreferences(thirdTab: thirdTab, home: home?.normalised(against: Self.hiddenShelves))
    }

    /// The tab shown: a saved Discover shows Playlists while Aurral isn't set up.
    public func tab(discoverSetUp: Bool) -> CarPlayTab {
        thirdTab == .discover && !discoverSetUp ? .playlists : thirdTab
    }

    /// The car's Home list: its own, else a copy of the phone's order and switches (without Genres).
    public func homeList(following phone: OrderedVisibility<HomeSection>) -> OrderedVisibility<CarPlayHomeShelf> {
        if let home { return home }
        // Round 14 (plan decision 10, D109): the car's Home doesn't change this round. While the phone's Home is the new
        // Spotify-style default, the car follows the default it had (build 13's order and switches).
        let phone = phone == HomeSection.defaultHome ? Self.build13Phone : phone
        let copied = phone.entries.compactMap { entry in
            CarPlayHomeShelf(entry.item).map { OrderedVisibility<CarPlayHomeShelf>.Entry(item: $0, visible: entry.visible) }
        }
        return OrderedVisibility(copied).normalised(against: Self.hiddenShelves)
    }

    /// The sections the car's Home shows, in order: as the phone's rule (`visibleHomeSections`), over the car's list.
    public func visibleHomeSections(phone: LayoutPreferences, offline: Bool, hasListenBrainzToken: Bool,
                                    discoverSetUp: Bool) -> [HomeSection] {
        if offline { return [.downloaded] }
        return homeList(following: phone.home).visibleItems.map(\.section)
            .filter { ($0 != .madeForYou || hasListenBrainzToken) && ($0 != .discover || discoverSetUp) }
    }
}
