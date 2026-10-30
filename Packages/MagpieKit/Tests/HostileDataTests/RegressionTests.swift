import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import LidarrKit
@testable import Search

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
