import Foundation

// Round 14 A6: the Spotify-style Home (plan "Home", owner answers 4 and 9): the sections' default order, what each
// needs, its card settings, the filter chips, and the migration of layouts saved by earlier builds.

/// A service a Home section needs. The editor lists such a section greyed with `needsLabel` while it is missing.
public enum HomeService: String, Hashable, Sendable {
    case aurral, lidarr, listenBrainz

    /// The editor's note (Settings may name the services, answer 9).
    public var needsLabel: String {
        switch self {
        case .aurral: "Needs Aurral"
        case .lidarr: "Needs Lidarr"
        case .listenBrainz: "Needs ListenBrainz"
        }
    }
}

extension HomeSection {
    /// The plan's order (D105): the greeting, chips and quick grid; Your flows; Recommended for you; New this week;
    /// Because you like; Jump back in; More playlists for you; Recently added, Favourites, Most played; Close to home,
    /// Further out; Trending; Charts by genre; then Recently downloaded, Random albums, Made for you, Playlists, Genres.
    public static let defaultOrder: [HomeSection] = [
        .greeting, .filterChips, .quickAccess, .discover, .recommended, .newThisWeek, .becauseYouLike, .jumpBackIn,
        .morePlaylists, .recentlyAdded, .favourites, .mostPlayed, .closeToHome, .furtherOut, .trending, .genreCharts,
        .downloaded, .randomAlbums, .madeForYou, .playlists, .genres,
    ]

    /// Off by default: Random albums, and Recently downloaded (which shows on its own offline). The rest is on, so a
    /// Navidrome-only Home is complete (answer 9).
    public static let offByDefault: Set<HomeSection> = [.randomAlbums, .downloaded]

    public static let defaultHome = OrderedVisibility(defaultOrder.map { .init(item: $0, visible: !offByDefault.contains($0)) })

    /// The service the section needs to show (Made for you: a ListenBrainz token).
    public var need: HomeService? {
        switch self {
        case .madeForYou: .listenBrainz
        case .discover: .aurral
        default: isProvided ? .aurral : nil
        }
    }

    /// Filled by the app's `HomeAurralShelves` provider (round 14 A4); hidden while it offers nothing.
    public var isProvided: Bool {
        switch self {
        case .recommended, .newThisWeek, .becauseYouLike, .morePlaylists, .closeToHome, .furtherOut, .trending,
             .genreCharts: true
        default: false
        }
    }

    /// Part of the page itself rather than a shelf: nothing is read for it.
    public var isChrome: Bool { self == .greeting || self == .filterChips }

    /// A shelf with a card size and an item count in the editor.
    public var hasCardSettings: Bool { !isChrome && self != .quickAccess }

    /// Has an item count in the editor (every shelf, and the quick grid).
    public var hasCountSetting: Bool { !isChrome }

    /// The section's look until the owner changes it: medium cards, 12 items; large cards for More playlists and
    /// Trending; the quick grid holds 8.
    public var defaultStyle: HomeSectionStyle {
        switch self {
        case .quickAccess: HomeSectionStyle(size: .small, count: HomeSectionStyle.quickAccessRange.upperBound)
        case .morePlaylists, .trending: HomeSectionStyle(size: .large, count: 12)
        default: HomeSectionStyle(size: .medium, count: 12)
        }
    }

    /// The order of the layout earlier builds (12, 13) saved by default, and its switches.
    static let build13Order: [HomeSection] = [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites,
                                              .randomAlbums, .playlists, .genres, .downloaded, .discover]
    static let build13Visible: Set<HomeSection> = [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .discover]

    /// A saved layout with the sections it lacks (D106). Duplicates go (the first wins). Then:
    /// - a layout in an earlier build's default order (never rearranged) takes the new order, keeping its switches,
    ///   and becomes the default outright when its switches are the old defaults too;
    /// - otherwise its order is kept, and each missing section goes in right after the nearest section that precedes
    ///   it in the default order (at the top when none does), with its default switch.
    /// A layout that lacks nothing is returned as it is (round 14 layouts are never migrated again).
    public static func migrated(_ stored: OrderedVisibility<HomeSection>) -> OrderedVisibility<HomeSection> {
        var seen = Set<HomeSection>()
        var entries = stored.entries.filter { seen.insert($0.item).inserted }
        let missing = defaultOrder.filter { !seen.contains($0) }
        guard !missing.isEmpty else { return OrderedVisibility(entries) }
        let items = entries.map(\.item)
        let oldItems = items.filter(build13Order.contains)
        let untouchedOrder = items.count == oldItems.count && oldItems.count >= build13Order.count - 1
            && oldItems == build13Order.filter(seen.contains)
        if untouchedOrder {
            let switches = Dictionary(entries.map { ($0.item, $0.visible) }, uniquingKeysWith: { a, _ in a })
            if entries.allSatisfy({ $0.visible == build13Visible.contains($0.item) }) { return defaultHome }
            return OrderedVisibility(defaultHome.entries.map { .init(item: $0.item, visible: switches[$0.item] ?? $0.visible) })
        }
        for section in missing {
            let visible = !offByDefault.contains(section)
            let before = defaultOrder.prefix { $0 != section }
            let anchor = before.reversed().first { item in entries.contains { $0.item == item } }
            let index = anchor.flatMap { item in entries.firstIndex { $0.item == item } }.map { $0 + 1 } ?? 0
            entries.insert(.init(item: section, visible: visible), at: index)
        }
        return OrderedVisibility(entries)
    }
}

/// A Home shelf's card size (D107).
public enum HomeCardSize: String, CaseIterable, Codable, Hashable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// A Home shelf's settings: its card size and how many items it shows.
public struct HomeSectionStyle: Codable, Hashable, Sendable {
    public var size: HomeCardSize
    public var count: Int

    /// Items a shelf can show; the editor offers `counts`.
    public static let countRange = 4...20
    public static let counts = [4, 6, 8, 10, 12, 16, 20]
    /// The quick grid's tiles (two columns).
    public static let quickAccessRange = 4...8
    public static let quickAccessCounts = [4, 6, 8]
    public static let becauseYouLikeRange = 0...3

    public init(size: HomeCardSize, count: Int) {
        self.size = size
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case size, count }

    /// Lossy: an unknown size is medium, a missing or odd count is 12 (clamped later).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decode(HomeCardSize.self, forKey: .size)) ?? .medium
        count = (try? c.decode(Int.self, forKey: .count)) ?? 12
    }

    /// Stored settings made safe: unknown sections dropped, counts clamped (the quick grid to 8).
    static func normalised(_ styles: [String: HomeSectionStyle]) -> [String: HomeSectionStyle] {
        var result: [String: HomeSectionStyle] = [:]
        for (key, style) in styles {
            guard let section = HomeSection(rawValue: key), section.hasCountSetting else { continue }
            let range = section == .quickAccess ? quickAccessRange : countRange
            result[key] = HomeSectionStyle(size: style.size, count: min(max(style.count, range.lowerBound), range.upperBound))
        }
        return result
    }
}

extension LayoutPreferences {
    /// `section`'s card size and count: the owner's, else its default.
    public func style(for section: HomeSection) -> HomeSectionStyle {
        homeStyles[section.rawValue] ?? section.defaultStyle
    }

    public mutating func setStyle(_ style: HomeSectionStyle, for section: HomeSection) {
        homeStyles[section.rawValue] = style == section.defaultStyle ? nil : style
    }

    /// Home as by default: the order, the switches, every shelf's settings and Because you like's rows.
    public var isDefaultHome: Bool {
        home == Self.defaultValue.home && homeStyles.isEmpty && becauseYouLikeRows == Self.defaultValue.becauseYouLikeRows
    }

    /// "Reset to default order" on Home: everything `isDefaultHome` checks. The Library is left alone.
    public mutating func resetHome() {
        home = Self.defaultValue.home
        homeStyles = [:]
        becauseYouLikeRows = Self.defaultValue.becauseYouLikeRows
    }
}

/// Home's filter chips (D108): All · Discover · Recommended · Your library. A chip narrows the page to its sections;
/// the greeting and the chips always stay.
public enum HomeFilter: String, CaseIterable, Hashable, Sendable {
    case all, discover, recommended, library

    public var title: String {
        switch self {
        case .all: "All"
        case .discover: "Discover"
        case .recommended: "Recommended"
        case .library: "Your library"
        }
    }

    /// Whether `section` shows under this chip.
    public func includes(_ section: HomeSection) -> Bool {
        if section.isChrome || self == .all { return true }
        return Self.chip(of: section) == self
    }

    /// `sections` narrowed to this chip, in order.
    public func apply(_ sections: [HomeSection]) -> [HomeSection] { sections.filter(includes) }

    /// The chips worth offering for what Home shows: All, and each other chip with a section on Home (so Discover and
    /// Recommended hide without Aurral).
    public static func offered(for sections: [HomeSection]) -> [HomeFilter] {
        allCases.filter { filter in filter == .all || sections.contains { !$0.isChrome && chip(of: $0) == filter } }
    }

    private static func chip(of section: HomeSection) -> HomeFilter {
        switch section {
        case .discover, .morePlaylists, .trending, .genreCharts: .discover
        case .recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut: .recommended
        default: .library
        }
    }
}
