import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import LidarrKit
@testable import Search
@testable import MatchIndex

/// Crash hunt 4: each crash the fuzzers found, reduced to the smallest input that trapped.
@Suite struct HostileDataRegressionTests {
    // MARK: - Preferences: a stored number out of Double's range

    /// `JSONSerialization` reads `-1e400` as -infinity; writing the merged object back raised
    /// NSInvalidArgumentException ("Invalid number value (infinite) in JSON write"), which no `try?` catches.
    @Test func preferencesWithAnInfiniteNumberFallBackToDefaults() {
        for text in [#"{"concurrent":-1e400}"#, #"{"rule":{"percent":-1e400,"minutesCap":2}}"#,
                     #"{"assignments":{"rock":-1e400}}"#, #"{"home":[{"item":"genres","visible":-1e400}]}"#,
                     #"{"wifi":[-1e400]}"#, #"{"x":{"y":[1,2,-1e400]}}"#] {
            let data = Data(text.utf8)
            #expect(DownloadPreferences.decode(data) == DownloadPreferences.defaultValue)
            #expect(ScrobblePreferences.decode(data) == ScrobblePreferences.defaultValue)
            #expect(GenrePreferences.decode(data) == GenrePreferences.defaultValue)
            #expect(LayoutPreferences.decode(data) == LayoutPreferences.defaultValue)
            #expect(PlaybackPreferences.decode(data) == PlaybackPreferences.defaultValue)
        }
        // The other keys still decode around the bad one.
        let mixed = DownloadPreferences.decode(Data(#"{"concurrent":-1e400,"preDownload":7}"#.utf8))
        #expect(mixed.concurrent == DownloadPreferences.defaultValue.concurrent && mixed.preDownload == 7)
    }

    // MARK: - Lidarr: integral numbers beyond Int

    /// `Int(1e300)` trapped in `KeyedDecodingContainer.int`: a row whose id is out of range is dropped, other rows stay.
    @Test func lidarrIdsOutOfIntRangeDropTheRow() async throws {
        let transport = MockTransport()
        transport.stub(pathSuffix: "/api/v1/tag", body: Data(#"[{"id":1e300,"label":"a"},{"id":-1e300,"label":"b"},{"id":9.3e18,"label":"c"},{"id":7,"label":"d"}]"#.utf8))
        let lidarr = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: transport)
        let tags = try await lidarr.tags()
        #expect(tags == [LidarrTag(id: 7, label: "d")])
    }

    /// `Int64(1e300)` trapped on a root folder's `freeSpace`: an out-of-range size reads as unknown.
    @Test func lidarrFreeSpaceOutOfRangeIsUnknown() async throws {
        let transport = MockTransport()
        transport.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/m","freeSpace":1e300},{"id":2,"path":"/n","freeSpace":-1e19},{"id":3,"path":"/o","freeSpace":5.5e9}]"#.utf8))
        let lidarr = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: transport)
        let folders = try await lidarr.rootFolders()
        #expect(folders.map(\.id) == [1, 2, 3])
        #expect(folders.map(\.freeSpace) == [nil, nil, 5_500_000_000])
    }

    /// `JSONValue.intValue` trapped on an integral double beyond Int (`"id": 1e300` in a profile or a POST answer).
    @Test func jsonValueIntegralDoubleOutOfRangeIsNotAnInt() {
        #expect(JSONValue.double(1e300).intValue == nil)
        #expect(JSONValue.double(-1e300).intValue == nil)
        #expect(JSONValue.double(9_223_372_036_854_775_808).intValue == nil)   // 2^63
        #expect(JSONValue.double(42).intValue == 42)
        #expect(JSONValue.double(-9_223_372_036_854_775_808).intValue == Int.min)
    }

    // MARK: - Deeply nested documents (stack overflow on a 512 KB thread)

    static func nested(_ depth: Int, objects: Bool = true, in inner: String = "1") -> Data {
        Data((String(repeating: objects ? #"{"x":"# : "[", count: depth) + inner + String(repeating: objects ? "}" : "]", count: depth)).utf8)
    }

    /// `JSONSerialization` recurses once per nested object with no depth limit: about 500 levels overflow a
    /// cooperative thread's 512 KB stack (SIGBUS). `/system/plugins` and `config/mediamanagement` are read with it.
    @Test func lidarrDeeplyNestedAnswersDontOverflow() async throws {
        let transport = MockTransport()
        let deep = Self.nested(5_000)
        let deepArray = Data(("[" + String(decoding: Self.nested(5_000), as: UTF8.self) + "]").utf8)
        transport.stub(pathSuffix: "/api/v1/system/plugins", body: deepArray)
        transport.stub(pathSuffix: "/api/v1/config/mediamanagement", body: deep)
        let lidarr = LidarrClient(base: URL(string: "https://music.example/lidarr")!, apiKey: "k", transport: transport)
        #expect(try await lidarr.pluginTexts() == [])
        #expect(try await lidarr.recycleBin() == nil)
    }

    @Test func preferencesDeeplyNestedDontOverflow() {
        let data = Data((#"{"concurrent":3,"x":"# + String(decoding: Self.nested(5_000), as: UTF8.self) + "}").utf8)
        #expect(DownloadPreferences.decode(data) == DownloadPreferences.defaultValue)
    }

    /// `JSONValue` (raw Lidarr documents) recursed once per level, as deep as `JSONDecoder` allows.
    @Test func jsonValueDeepDocumentsDontOverflow() async throws {
        for depth in [100, 400, 511, 600, 5_000] {
            for objects in [true, false] {
                let data = Self.nested(depth, objects: objects)
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    _ = try? JSONEncoder().encode(value)
                    _ = BodySummary.make(try? JSONEncoder().encode(value), apiKey: "k", limit: 100)
                }
            }
        }
    }

    // MARK: - Normalising a run of flags (watchdog)

    /// `range(of:options: .backwards)` is quadratic on a run of regional indicators (flag emoji): 20,000 flags in an
    /// artist name took about 3 s per `Normalize.name`, and the car's "Try it next" normalises up to 100 search
    /// results' artists on the main actor (`bridgeMix`), so a hostile server could trip the watchdog.
    @Test func normalisingAFlagRunIsLinear() {
        let flags = String(repeating: "🇬🇧", count: 20_000)
        let seconds = FuzzClock.seconds {
            _ = Normalize.key(artist: flags, title: flags + " - Live")
            _ = Normalize.hasVersionAside(flags + " – Acoustic")
            _ = ArtistNotYet.titleKey(flags + " - Deluxe Edition")
        }
        #expect(seconds < 0.5, "took \(seconds) s")
        // Same answers as before: the last dash splits, in the order " - ", " – ", " — ".
        #expect(Normalize.name("A - B - Remastered 2011") == "a b")
        #expect(Normalize.name("Halo - Live") == "halo live")
        #expect(Normalize.hasVersionAside("Halo – Acoustic") && !Normalize.hasVersionAside("Halo - Remastered"))
        #expect(ArtistNotYet.titleKey("🇬🇧 Album - Deluxe Edition") == Normalize.name("🇬🇧 Album"))
        #expect(ArtistNotYet.titleKey("Album — Remix - Deluxe") == Normalize.name("Album — Remix"))
    }

    // MARK: - Genre groups: counts that overflow when summed

    /// The group's album and song counts were summed with `+`, which traps on overflow (a server reporting
    /// `9223372036854775807` for two genres of one group). The sums saturate.
    @Test func genreGroupCountsSaturate() {
        let genres = [Genre(name: "Rock", songCount: .max, albumCount: .max),
                      Genre(name: "Indie Rock", songCount: .max, albumCount: 5),
                      Genre(name: "Jazz", songCount: .min, albumCount: .min),
                      Genre(name: "Bebop", songCount: -1, albumCount: .min)]
        let sections = GenreGroups.grouped(genres, preferences: .defaultValue)
        let rock = try? #require(sections.first { $0.group.id == "rock" })
        #expect(rock?.albumCount == .max && rock?.songCount == .max)
        let jazz = try? #require(sections.first { $0.group.id == "jazz" })
        #expect(jazz?.albumCount == .min && jazz?.songCount == .min)
    }
}
