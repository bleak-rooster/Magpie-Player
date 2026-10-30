import Foundation
import MagpieCore
import MagpieTestSupport
import Testing

/// Crash hunt 4: whatever is stored under a preference key (another version's shape, a hand edit, a corrupt write),
/// every area decodes without trapping and comes back normalised, within its limits.
@Suite struct PreferencesFuzzTests {
    /// The keys each area knows, so the random documents hit real fields as well as unknown ones.
    static let keys = ["home", "library", "showsRecentlyAdded", "wifi", "cellular", "replayGain", "sleepTimer", "quality",
                       "overMobileData", "concurrent", "preDownload", "keepRecentlyPlayed", "cacheLimit", "downloadsLimit",
                       "offlineMode", "keepFavourites", "viaNavidrome", "viaListenBrainz", "rule", "percent", "minutesCap",
                       "mode", "assignments", "groupNames", "hidden", "customGroups", "id", "visible", "item", "version", "x"]
    static let words = ["original", "aac160", "opus64", "mp3_192", "track", "album", "off", "m30", "endOfSong", "gb2", "none",
                        "automatic", "on", "grouped", "all", "rock", "jazz", "genres", "downloads", "playlists", "songs",
                        "madeForYou", "downloaded", "finds", "requests"]

    /// A random JSON value, written as text (so it can hold `-1e400`, which JSONSerialization reads as -infinity).
    static func value(_ rng: inout SeededRNG, depth: Int) -> String {
        switch Int.random(in: 0..<(depth > 3 ? 4 : 7), using: &rng) {
        case 0: return JSONFuzzer.hostileNumbers.randomElement(using: &rng)!
        case 1: return Bool.random(using: &rng) ? "true" : "false"
        case 2: return "\"\(rng.chance(0.6) ? words.randomElement(using: &rng)! : JSONFuzzer.hostileStrings.randomElement(using: &rng)!)\""
        case 3: return rng.chance(0.5) ? "null" : String(Int.random(in: -20...20, using: &rng))
        case 4:
            // Now and then a long array of scalars (never long arrays inside long arrays).
            let long = rng.chance(0.05)
            let n = long ? 2_000 : Int.random(in: 0...6, using: &rng)
            return "[" + (0..<n).map { _ in value(&rng, depth: long ? 4 : depth + 1) }.joined(separator: ",") + "]"
        case 5:
            // An OrderedVisibility-shaped element.
            return #"{"id":"\#(words.randomElement(using: &rng)!)","visible":\#(value(&rng, depth: 4))}"#
        default: return object(&rng, depth: depth + 1)
        }
    }

    static func object(_ rng: inout SeededRNG, depth: Int) -> String {
        let n = Int.random(in: 0...8, using: &rng)
        return "{" + (0..<n).map { _ in
            let key = rng.chance(0.85) ? keys.randomElement(using: &rng)! : "k\(Int.random(in: 0...99, using: &rng))"
            return "\"\(key)\":\(value(&rng, depth: depth))"
        }.joined(separator: ",") + "}"
    }

    static func check(_ data: Data) {
        let layout = LayoutPreferences.decode(data)
        #expect(layout == layout.normalised())
        #expect(Set(layout.home.entries.map(\.item)) == Set(HomeSection.allCases) && layout.home.entries.count == HomeSection.allCases.count)
        #expect(Set(layout.library.entries.map(\.item)) == Set(LibraryRow.allCases))
        #expect(layout.library.entries.contains { LayoutPreferences.alwaysAvailableRows.contains($0.item) && $0.visible })

        let playback = PlaybackPreferences.decode(data)
        #expect(playback == playback.normalised())

        let downloads = DownloadPreferences.decode(data)
        #expect((1...4).contains(downloads.concurrent) && (0...10).contains(downloads.preDownload))

        let scrobbling = ScrobblePreferences.decode(data)
        #expect((10...90).contains(scrobbling.rule.percent) && scrobbling.rule.percent % 5 == 0)
        #expect(scrobbling.rule.minutes.map { (1...10).contains($0) } ?? true)
        for d in [-1.0, 0, 29, 30, 1e300, .infinity] { _ = scrobbling.rule.threshold(duration: d) }

        let genres = GenrePreferences.decode(data)
        #expect(genres == genres.normalised())
        #expect(genres.assignments.count <= GenrePreferences.maxAssignments && genres.groupNames.count <= GenrePreferences.maxGroupNames)
        #expect(genres.hidden.count <= GenrePreferences.maxHidden && genres.customGroups.count <= GenrePreferences.maxCustomGroups)
        // What decode gives can be stored and read back unchanged.
        #expect(LayoutPreferences.decode(layout.encoded()) == layout)
        #expect(GenrePreferences.decode(genres.encoded()) == genres)
    }

    /// 5,000 random documents, and 5,000 mutations of each area's stored defaults.
    @Test func randomStoredPreferencesAlwaysNormalise() {
        var rng = SeededRNG(seed: 0x9EF5)
        var fuzzer = JSONFuzzer(seed: 0x9EF6, hugeArrayCount: 100)
        fuzzer.maxBytes = 10_000   // stored preferences are small; big bodies are the clients' sweeps
        let seeds = [LayoutPreferences.defaultValue.encoded(), PlaybackPreferences.defaultValue.encoded(),
                     DownloadPreferences.defaultValue.encoded(), ScrobblePreferences.defaultValue.encoded(),
                     GenrePreferences.defaultValue.encoded()].compactMap { $0 }
        let seconds = FuzzClock.seconds {
            for _ in 0..<5_000 { Self.check(Data(Self.object(&rng, depth: 0).utf8)) }
            for i in 0..<5_000 { Self.check(fuzzer.mutate(seeds[i % seeds.count])) }
        }
        #expect(LayoutPreferences.decode(nil) == .defaultValue && GenrePreferences.decode(nil) == .defaultValue)
        #expect(seconds < 9, "took \(seconds) s")
    }
}
