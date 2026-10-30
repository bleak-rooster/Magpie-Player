import Foundation

// MARK: - Choices

public enum HomeSection: String, CaseIterable, Codable, Hashable, Sendable {
    case jumpBackIn, madeForYou, recentlyAdded, mostPlayed, favourites, randomAlbums, playlists, genres, downloaded

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
        case .downloaded: "Downloaded"
        }
    }
}

public enum LibraryRow: String, CaseIterable, Codable, Hashable, Sendable {
    case playlists, artists, albums, songs, genres, favourites, downloads, finds, requests

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
        }
    }
}

/// Opus is offered (D45): iOS 27 AVFoundation plays Navidrome's Ogg Opus stream, though Ogg durations are estimates.
public enum StreamQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case original, aac256, aac160, aac96, opus192, opus128, opus96, opus64, mp3_320, mp3_192

    /// The `format` parameter of `stream`: "raw", "aac", "opus" or "mp3".
    public var format: String {
        switch self {
        case .original: "raw"
        case .aac256, .aac160, .aac96: "aac"
        case .opus192, .opus128, .opus96, .opus64: "opus"
        case .mp3_320, .mp3_192: "mp3"
        }
    }

    /// The `maxBitRate` parameter in kbps; nil for Original.
    public var maxBitRate: Int? {
        switch self {
        case .original: nil
        case .aac256: 256
        case .aac160: 160
        case .aac96: 96
        case .opus192: 192
        case .opus128: 128
        case .opus96: 96
        case .opus64: 64
        case .mp3_320: 320
        case .mp3_192: 192
        }
    }

    public var title: String {
        switch self {
        case .original: "Original"
        case .aac256: "High · AAC 256 kbps"
        case .aac160: "Medium · AAC 160 kbps"
        case .aac96: "Low · AAC 96 kbps"
        case .opus192: "High · Opus 192 kbps"
        case .opus128: "Medium · Opus 128 kbps"
        case .opus96: "Low · Opus 96 kbps"
        case .opus64: "Very low · Opus 64 kbps"
        case .mp3_320: "MP3 320 kbps"
        case .mp3_192: "MP3 192 kbps"
        }
    }

    /// The qualities by codec, in enum order: what the pickers list under each codec heading.
    public static var groups: [(format: String, qualities: [StreamQuality])] {
        var result: [(format: String, qualities: [StreamQuality])] = []
        for quality in allCases {
            if let i = result.firstIndex(where: { $0.format == quality.format }) { result[i].qualities.append(quality) }
            else { result.append((quality.format, [quality])) }
        }
        return result
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
        guard let data, let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
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
        home: OrderedVisibility(HomeSection.allCases.map { .init(item: $0, visible: [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed].contains($0)) }),
        library: OrderedVisibility(LibraryRow.allCases.map { .init(item: $0, visible: true) }),
        showsRecentlyAdded: true)

    public var home: OrderedVisibility<HomeSection>
    public var library: OrderedVisibility<LibraryRow>
    public var showsRecentlyAdded: Bool

    public init(home: OrderedVisibility<HomeSection>, library: OrderedVisibility<LibraryRow>, showsRecentlyAdded: Bool) {
        self.home = home
        self.library = library
        self.showsRecentlyAdded = showsRecentlyAdded
    }

    /// Hides or shows a Library row; false (no change) when it would leave none of the always-available rows visible.
    @discardableResult
    public mutating func setLibraryRow(_ row: LibraryRow, visible: Bool) -> Bool {
        library.set(row, visible: visible, keepingOneOf: Self.alwaysAvailableRows)
    }

    /// Stored data keeps the "one Library row stays visible" rule too: with none showing, the defaults come back.
    public func normalised() -> LayoutPreferences {
        var library = library.normalised(against: Self.defaultValue.library)
        let required = Self.alwaysAvailableRows
        if !library.entries.contains(where: { required.contains($0.item) && $0.visible }) {
            for entry in Self.defaultValue.library.entries where entry.visible && required.contains(entry.item) {
                library.set(entry.item, visible: true, keepingOneOf: [])
            }
        }
        return LayoutPreferences(home: home.normalised(against: Self.defaultValue.home), library: library,
                                 showsRecentlyAdded: showsRecentlyAdded)
    }

    /// The Home sections to show, in the owner's order, for the phone and the car alike (the car shows Made for you too,
    /// T23): Made for you only with a ListenBrainz token; offline, Downloaded.
    public func visibleHomeSections(offline: Bool, hasListenBrainzToken: Bool) -> [HomeSection] {
        if offline { return [.downloaded] }
        return home.visibleItems.filter { $0 != .madeForYou || hasListenBrainzToken }
    }

    /// The Library rows to show, in the owner's order. Offline (the phone and the car alike): Downloads, which always
    /// shows, and Genres (read from the phone) when switched on. The car never shows Songs or Requests (spec §3).
    public func visibleLibraryRows(offline: Bool, findsSetUp: Bool, lidarrConnected: Bool, carPlay: Bool) -> [LibraryRow] {
        if offline {
            return library.entries.filter { $0.item == .downloads || ($0.item == .genres && $0.visible) }.map(\.item)
        }
        return library.visibleItems.filter { row in
            switch row {
            case .finds: findsSetUp
            case .requests: lidarrConnected && !carPlay
            case .songs: !carPlay
            default: true
            }
        }
    }
}

public struct PlaybackPreferences: PreferenceArea {
    public static let key = "magpie.prefs.playback"
    public static let defaultValue = PlaybackPreferences(wifi: .original, cellular: .aac160, replayGain: .track, sleepTimer: .m30)

    public var wifi: StreamQuality
    public var cellular: StreamQuality
    public var replayGain: ReplayGainMode
    public var sleepTimer: SleepTimerOption

    public func normalised() -> PlaybackPreferences { self }
}

public struct DownloadPreferences: PreferenceArea {
    public static let key = "magpie.prefs.downloads"
    public static let defaultValue = DownloadPreferences(
        quality: .original, overMobileData: false, concurrent: 2, preDownload: 3, keepRecentlyPlayed: true,
        cacheLimit: .gb2, downloadsLimit: .none, offlineMode: .automatic, keepFavourites: false)

    public var quality: StreamQuality
    public var overMobileData: Bool
    public var concurrent: Int
    public var preDownload: Int
    public var keepRecentlyPlayed: Bool
    public var cacheLimit: CacheLimit
    public var downloadsLimit: DownloadsLimit
    public var offlineMode: OfflineMode
    public var keepFavourites: Bool

    public func normalised() -> DownloadPreferences {
        var copy = self
        copy.concurrent = clamp(concurrent, 1...4)
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

    public static let standard = Preferences(layout: .defaultValue, playback: .defaultValue, downloads: .defaultValue,
                                             scrobbling: .defaultValue, genres: .defaultValue)

    public init(layout: LayoutPreferences, playback: PlaybackPreferences, downloads: DownloadPreferences,
                scrobbling: ScrobblePreferences, genres: GenrePreferences) {
        self.layout = layout
        self.playback = playback
        self.downloads = downloads
        self.scrobbling = scrobbling
        self.genres = genres
    }

    /// Every area through its own `normalised()`.
    public func normalised() -> Preferences {
        Preferences(layout: layout.normalised(), playback: playback.normalised(), downloads: downloads.normalised(),
                    scrobbling: scrobbling.normalised(), genres: genres.normalised())
    }
}
