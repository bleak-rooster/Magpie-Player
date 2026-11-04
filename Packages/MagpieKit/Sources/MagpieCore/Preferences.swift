import Foundation

// MARK: - Choices

public enum HomeSection: String, CaseIterable, Codable, Hashable, Sendable {
    case jumpBackIn, madeForYou, recentlyAdded, mostPlayed, favourites, randomAlbums, playlists, genres, downloaded
    /// Round 12 Y6: Aurral's flow playlists, only while Aurral is set up. Round 14: titled "Your flows"; the stored
    /// name stays `discover`, so saved layouts keep it.
    case discover
    /// Round 14 A6 (Spotify-style Home): the top of the page. See `HomeLayout.swift`.
    case greeting, filterChips, quickAccess
    /// Round 14 A6: shelves provided through the app's `HomeAurralShelves` (round 14 A4), hidden until one is.
    case recommended, newThisWeek, becauseYouLike, morePlaylists, closeToHome, furtherOut, trending, genreCharts

    public var title: String {
        switch self {
        case .jumpBackIn: "Jump back in"
        case .madeForYou: "Made for you"
        case .recentlyAdded: "Recently added"
        case .mostPlayed: "Most played"
        case .favourites: "Favourites"
        case .randomAlbums: "Random albums"
        case .playlists: "Playlists"
        case .genres: "Genres"
        case .downloaded: "Recently downloaded"
        case .discover: "Your flows"
        case .greeting: "Greeting"
        case .filterChips: "Filters"
        case .quickAccess: "Quick access"
        case .recommended: "Recommended for you"
        case .newThisWeek: "New this week"
        case .becauseYouLike: "Because you like"
        case .morePlaylists: "More playlists for you"
        case .closeToHome: "Close to home"
        case .furtherOut: "Further out"
        case .trending: "Trending"
        case .genreCharts: "Charts by genre"
        }
    }
}

public enum LibraryRow: String, CaseIterable, Codable, Hashable, Sendable {
    case playlists, artists, albums, songs, genres, favourites, downloads, finds, requests
    /// Round 12 Y6: Aurral's flow playlists, only while Aurral is set up.
    case discover
    /// Round 14 A4 (D93): Aurral's charts and recommended artists, only while Aurral is set up and can give them;
    /// never in the car (CarPlay is unchanged this round).
    case trending, recommended

    /// Round 14 A4: rows a saved layout gains right after their default predecessor (Trending after Discover), not at
    /// the end.
    public static let insertedAfterPredecessor: Set<LibraryRow> = [.trending, .recommended]

    public var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .favourites: "Favourites"
        case .downloads: "Downloads"
        case .finds: "Finds"
        case .requests: "Requests"
        case .discover: "Discover"
        case .trending: "Trending"
        case .recommended: "Recommended"
        }
    }

    public var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .favourites: "heart"
        case .downloads: "arrow.down.circle"
        case .finds: "sparkles"
        case .requests: "tray.and.arrow.down"
        case .discover: "binoculars"
        case .trending: "chart.line.uptrend.xyaxis"
        case .recommended: "person.crop.circle.badge.plus"
        }
    }
}

/// Round 14 A4 fix round 1 (owner): whose top songs Trending shows. Stored as "automatic", "server" or an ISO 3166 code;
/// anything else reads as Automatic.
public enum ChartsCountry: Hashable, Sendable, Codable {
    /// The phone's region when there is a chart for it, else the server's.
    case automatic
    /// The server's own region (Aurral's chart).
    case server
    case country(String)

    public init(stored: String) {
        switch stored {
        case "server": self = .server
        case let code where code.count == 2 && code.allSatisfy({ $0.isASCII && $0.isLetter }): self = .country(code.uppercased())
        default: self = .automatic
        }
    }

    public var stored: String {
        switch self {
        case .automatic: "automatic"
        case .server: "server"
        case .country(let code): code
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(stored: (try? decoder.singleValueContainer().decode(String.self)) ?? "automatic")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}

public enum ReplayGainMode: String, CaseIterable, Codable, Hashable, Sendable { case off, track, album }

public enum SleepTimerOption: String, CaseIterable, Codable, Hashable, Sendable {
    case m15, m30, m45, m60, m90, endOfSong

    /// nil: stop at the end of the current song.
    public var seconds: TimeInterval? {
        switch self {
        case .m15: 15 * 60
        case .m30: 30 * 60
        case .m45: 45 * 60
        case .m60: 60 * 60
        case .m90: 90 * 60
        case .endOfSong: nil
        }
    }
}

public enum CacheLimit: String, CaseIterable, Codable, Hashable, Sendable {
    case mb500, gb1, gb2, gb5, gb10

    /// Decimal sizes.
    public var bytes: Int64 {
        switch self {
        case .mb500: 500_000_000
        case .gb1: 1_000_000_000
        case .gb2: 2_000_000_000
        case .gb5: 5_000_000_000
        case .gb10: 10_000_000_000
        }
    }
}

public enum DownloadsLimit: String, CaseIterable, Codable, Hashable, Sendable {
    case none, gb5, gb10, gb20, gb50

    /// nil: no limit.
    public var bytes: Int64? {
        switch self {
        case .none: nil
        case .gb5: 5_000_000_000
        case .gb10: 10_000_000_000
        case .gb20: 20_000_000_000
        case .gb50: 50_000_000_000
        }
    }
}

public enum OfflineMode: String, CaseIterable, Codable, Hashable, Sendable { case automatic, on, off }
public enum GenreViewMode: String, CaseIterable, Codable, Hashable, Sendable { case grouped, all }

// MARK: - Areas

/// One UserDefaults key per area. `decode` is the single lossy strategy: one bad field can't reset the others.
public protocol PreferenceArea: Codable, Hashable, Sendable {
    static var key: String { get }
    static var defaultValue: Self { get }
    func normalised() -> Self
}

extension PreferenceArea {
    /// 1. Not a JSON object: the default. 2. Start from the default as a JSON object. 3. Copy each stored key in and
    /// try to decode the merge; a key that breaks it gets its default back. 4. Return the result, normalised.
    public static func decode(_ data: Data?) -> Self {
        // Measured first: deeply nested stored data would overflow the stack in JSONSerialization (crash hunt 4).
        guard let data, let stored = JSONNesting.object(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultValue)) as? [String: Any]
        else { return defaultValue }
        var merged = defaults
        for (key, value) in stored where key != "version" {
            let before = merged[key]
            merged[key] = value
            if decoded(merged) == nil { merged[key] = before }
        }
        return (decoded(merged) ?? defaultValue).normalised()
    }

    /// Serialises a JSON object and decodes it as this area; nil when either step fails. `JSONSerialization` reads
    /// `-1e400` as -infinity, and writing that back raises an Objective-C exception no `try?` catches (crash hunt 4),
    /// so an object it can't write is refused first.
    private static func decoded(_ object: [String: Any]) -> Self? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// The JSON to store, with `"version": 1`. nil (logged, nothing to write) when encoding fails.
    public func encoded() -> Data? {
        do {
            let data = try JSONEncoder().encode(self)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object["version"] = 1
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            Log.logger("preferences").error("encoding \(Self.key, privacy: .public) failed: \(Log.category(of: error), privacy: .public)")
            return nil
        }
    }
}

private func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }

public struct LayoutPreferences: PreferenceArea {
    public static let key = "magpie.prefs.layout"
    public static let alwaysAvailableRows: Set<LibraryRow> = [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads]
    public static let defaultValue = LayoutPreferences(
        home: HomeSection.defaultHome,   // round 14 A6: the Spotify-style order (HomeLayout.swift)
        library: OrderedVisibility(LibraryRow.allCases.map { .init(item: $0, visible: true) }),
        showsRecentlyAdded: true)

    public var home: OrderedVisibility<HomeSection>
    public var library: OrderedVisibility<LibraryRow>
    public var showsRecentlyAdded: Bool
    /// Round 11 R11: Artists lists only album artists (on, the default) or every artist, track-only ones too; the
    /// phone and the car alike.
    public var albumArtistsOnly: Bool
    /// Round 14 A6: each Home shelf's card size and item count, by the section's stored name; a section not here has
    /// its default (`HomeSection.defaultStyle`). See `style(for:)`.
    public var homeStyles: [String: HomeSectionStyle]
    /// Round 14 A6: how many "Because you like" rows Home shows (0–3; 0 hides the section).
    public var becauseYouLikeRows: Int
    /// Round 14 A4 fix round 1: Trending's country (Settings › Home & Library › Charts country).
    public var chartsCountry: ChartsCountry
    /// Round 14 A3 (owner answer 6): where every artist page's Top songs come from.
    public var artistTopSongs: ArtistTopSongsSource

    public init(home: OrderedVisibility<HomeSection>, library: OrderedVisibility<LibraryRow>, showsRecentlyAdded: Bool,
                albumArtistsOnly: Bool = true, homeStyles: [String: HomeSectionStyle] = [:],
                becauseYouLikeRows: Int = HomeSectionStyle.becauseYouLikeRange.upperBound,
                chartsCountry: ChartsCountry = .automatic, artistTopSongs: ArtistTopSongsSource = .automatic) {
        self.home = home
        self.library = library
        self.showsRecentlyAdded = showsRecentlyAdded
        self.albumArtistsOnly = albumArtistsOnly
        self.homeStyles = homeStyles
        self.becauseYouLikeRows = becauseYouLikeRows
        self.chartsCountry = chartsCountry
        self.artistTopSongs = artistTopSongs
    }

    /// Hides or shows a Library row; false (no change) when it would leave none of the always-available rows visible.
    @discardableResult
    public mutating func setLibraryRow(_ row: LibraryRow, visible: Bool) -> Bool {
        library.set(row, visible: visible, keepingOneOf: Self.alwaysAvailableRows)
    }

    /// Stored data keeps the "one Library row stays visible" rule too: with none showing, the defaults come back.
    public func normalised() -> LayoutPreferences {
        var library = library.normalised(against: Self.defaultValue.library,
                                         insertingAfterPredecessor: LibraryRow.insertedAfterPredecessor)
        let required = Self.alwaysAvailableRows
        if !library.entries.contains(where: { required.contains($0.item) && $0.visible }) {
            for entry in Self.defaultValue.library.entries where entry.visible && required.contains(entry.item) {
                library.set(entry.item, visible: true, keepingOneOf: [])
            }
        }
        return LayoutPreferences(home: HomeSection.migrated(home), library: library,
                                 showsRecentlyAdded: showsRecentlyAdded, albumArtistsOnly: albumArtistsOnly,
                                 homeStyles: HomeSectionStyle.normalised(homeStyles),
                                 becauseYouLikeRows: clamp(becauseYouLikeRows, HomeSectionStyle.becauseYouLikeRange),
                                 chartsCountry: chartsCountry, artistTopSongs: artistTopSongs)
    }

    /// The Home sections to show, in the owner's order, for the phone and the car alike (the car shows Made for you too,
    /// T23): Made for you only with a ListenBrainz token; offline, Downloaded.
    /// Y6: Discover only while Aurral is set up (`discoverSetUp`). Round 14 A6: a provided section (`isProvided`) only
    /// while Aurral is set up and its provider offers it (`outside`); Because you like not at 0 rows.
    public func visibleHomeSections(offline: Bool, hasListenBrainzToken: Bool, discoverSetUp: Bool = false,
                                    outside: Set<HomeSection> = []) -> [HomeSection] {
        if offline { return [.downloaded] }
        return home.visibleItems.filter { section in
            if section.isProvided { return discoverSetUp && outside.contains(section)
                                       && (section != .becauseYouLike || becauseYouLikeRows > 0) }
            return (section != .madeForYou || hasListenBrainzToken) && (section != .discover || discoverSetUp)
        }
    }

    /// The Library rows to show, in the owner's order. Offline (the phone and the car alike): Downloads, which always
    /// shows, and Genres (read from the phone) when switched on. The car never shows Requests (spec §3); round 13: Songs
    /// shows in the car too (it opens on letter groups).
    /// Y6: Discover only while Aurral is set up (`discoverSetUp`), in the car too. Round 14 A4: Trending and Recommended
    /// only while Aurral is set up and can give them (`trendingSetUp`, `recommendedSetUp`), never in the car.
    public func visibleLibraryRows(offline: Bool, findsSetUp: Bool, lidarrConnected: Bool, carPlay: Bool,
                                   discoverSetUp: Bool = false, trendingSetUp: Bool = false,
                                   recommendedSetUp: Bool = false) -> [LibraryRow] {
        if offline {
            return library.entries.filter { $0.item == .downloads || ($0.item == .genres && $0.visible) }.map(\.item)
        }
        return library.visibleItems.filter { row in
            switch row {
            case .finds: findsSetUp
            case .requests: lidarrConnected && !carPlay
            case .discover: discoverSetUp
            case .trending: discoverSetUp && trendingSetUp && !carPlay
            case .recommended: discoverSetUp && recommendedSetUp && !carPlay
            default: true
            }
        }
    }
}

/// What a swipe on a song row does (round 11 R12, Settings › Playback › Swipe actions).
public enum SwipeAction: String, CaseIterable, Codable, Hashable, Sendable {
    case playNext, addToQueue, addToPlaylist, download, favourite, none
}

public struct PlaybackPreferences: PreferenceArea {
    public static let key = "magpie.prefs.playback"
    public static let defaultValue = PlaybackPreferences(wifi: .original, cellular: .aacMedium, replayGain: .track, sleepTimer: .m30,
                                                         swipeRight: .addToQueue, swipeLeft: .playNext,
                                                         askBeforeReplacingQueue: false)

    public var wifi: StreamQuality
    public var cellular: StreamQuality
    public var replayGain: ReplayGainMode
    public var sleepTimer: SleepTimerOption
    /// R12: a song row's leading-edge (swipe right) and trailing-edge (swipe left) actions.
    public var swipeRight: SwipeAction
    public var swipeLeft: SwipeAction
    /// R12: tapping to play asks before it replaces a queue of more than one song (never in the car).
    public var askBeforeReplacingQueue: Bool

    public func normalised() -> PlaybackPreferences { self }
}

public struct DownloadPreferences: PreferenceArea {
    public static let key = "magpie.prefs.downloads"
    public static let defaultValue = DownloadPreferences(
        quality: .original, overMobileData: false, concurrent: 2, preDownload: 3, keepRecentlyPlayed: true,
        cacheLimit: .gb2, downloadsLimit: .none, offlineMode: .automatic, keepFavourites: false,
        keepScreenOn: true, downloadInBackground: true)

    public var quality: StreamQuality
    public var overMobileData: Bool
    public var concurrent: Int
    public var preDownload: Int
    public var keepRecentlyPlayed: Bool
    public var cacheLimit: CacheLimit
    public var downloadsLimit: DownloadsLimit
    public var offlineMode: OfflineMode
    public var keepFavourites: Bool
    /// "Keep screen on while downloading" (P1): the idle timer is off only while downloads run and Magpie is open.
    public var keepScreenOn: Bool
    /// "Download in the background" (R1): downloads go on with Magpie closed or the phone locked. Off brings back
    /// P1's foreground-only rule.
    public var downloadInBackground: Bool

    /// "Downloads at the same time" (P1: 1–6).
    public static let concurrentRange = 1...6

    public func normalised() -> DownloadPreferences {
        var copy = self
        copy.concurrent = clamp(concurrent, Self.concurrentRange)
        copy.preDownload = clamp(preDownload, 0...10)
        return copy
    }
}

/// When a play counts: `percent` of the song, capped at `minutes` (nil: Never, the percentage alone).
public struct ScrobbleRule: Codable, Hashable, Sendable {
    public var percent: Int
    public var minutes: Int?

    public static let standard = ScrobbleRule(percent: 50, minutes: 4)

    public init(percent: Int, minutes: Int?) { self.percent = percent; self.minutes = minutes }

    private enum CodingKeys: String, CodingKey { case percent, minutesCap }

    /// A `minutesCap` of 0 means Never.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decode(Int.self, forKey: .percent)
        let cap = try c.decode(Int.self, forKey: .minutesCap)
        minutes = cap == 0 ? nil : cap
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(percent, forKey: .percent)
        try c.encode(minutes ?? 0, forKey: .minutesCap)
    }

    /// Percent 10…90 rounded to the nearest 5 (half up); minutes 1…10 or nil.
    public func normalised() -> ScrobbleRule {
        ScrobbleRule(percent: (clamp(percent, 10...90) + 2) / 5 * 5, minutes: minutes.map { clamp($0, 1...10) })
    }

    /// Seconds of listening after which the play counts; nil when it never does (under 30 s). A hand-built rule is
    /// clamped to the ranges `normalised()` allows (without the rounding), so its minutes can't overflow.
    public func threshold(duration: TimeInterval) -> TimeInterval? {
        let cap = minutes.map { Double(clamp($0, 1...10) * 60) }
        if duration >= 30 {
            let share = duration * Double(clamp(percent, 10...90)) / 100
            return cap.map { min(share, $0) } ?? share
        }
        if duration > 0 { return nil }
        return cap
    }
}

public struct ScrobblePreferences: PreferenceArea {
    public static let key = "magpie.prefs.scrobbling"
    public static let defaultValue = ScrobblePreferences(viaNavidrome: true, viaListenBrainz: false, rule: .standard)

    public var viaNavidrome: Bool
    public var viaListenBrainz: Bool
    public var rule: ScrobbleRule

    public func normalised() -> ScrobblePreferences {
        var copy = self
        copy.rule = rule.normalised()
        return copy
    }
}

public struct GenrePreferences: PreferenceArea {
    public static let key = "magpie.prefs.genres"
    public static let defaultValue = GenrePreferences(mode: .grouped, assignments: [:], groupNames: [:], hidden: [], customGroups: [])
    public static let maxAssignments = 64
    public static let maxGroupNames = 32
    public static let maxCustomGroups = 16
    public static let maxHidden = 64
    public static let maxTextLength = 100

    public var mode: GenreViewMode
    public var assignments: [String: String]
    public var groupNames: [String: String]
    public var hidden: Set<String>
    public var customGroups: [String]

    /// Hostile or runaway stored data is capped: over-long text is dropped, then the first entries in key order stay.
    public func normalised() -> GenrePreferences {
        let limit = Self.maxTextLength
        func capped(_ map: [String: String], _ count: Int) -> [String: String] {
            let kept = map.filter { $0.key.count <= limit && $0.value.count <= limit }.sorted { $0.key < $1.key }.prefix(count)
            return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        var seen = Set<String>()
        let groups = customGroups.filter { $0.count <= limit && seen.insert($0).inserted }.prefix(Self.maxCustomGroups)
        return GenrePreferences(mode: mode,
                                assignments: capped(assignments, Self.maxAssignments),
                                groupNames: capped(groupNames, Self.maxGroupNames),
                                hidden: Set(hidden.filter { $0.count <= limit }.sorted().prefix(Self.maxHidden)),
                                customGroups: Array(groups))
    }
}

public struct Preferences: Hashable, Sendable {
    public var layout: LayoutPreferences
    public var playback: PlaybackPreferences
    public var downloads: DownloadPreferences
    public var scrobbling: ScrobblePreferences
    public var genres: GenrePreferences
    /// Round 13: Settings › CarPlay (the third tab and the car's Home).
    public var carPlay: CarPlayPreferences

    public static let standard = Preferences(layout: .defaultValue, playback: .defaultValue, downloads: .defaultValue,
                                             scrobbling: .defaultValue, genres: .defaultValue)

    public init(layout: LayoutPreferences, playback: PlaybackPreferences, downloads: DownloadPreferences,
                scrobbling: ScrobblePreferences, genres: GenrePreferences, carPlay: CarPlayPreferences = .defaultValue) {
        self.layout = layout
        self.playback = playback
        self.downloads = downloads
        self.scrobbling = scrobbling
        self.genres = genres
        self.carPlay = carPlay
    }

    /// Every area through its own `normalised()`.
    public func normalised() -> Preferences {
        Preferences(layout: layout.normalised(), playback: playback.normalised(), downloads: downloads.normalised(),
                    scrobbling: scrobbling.normalised(), genres: genres.normalised(), carPlay: carPlay.normalised())
    }
}
