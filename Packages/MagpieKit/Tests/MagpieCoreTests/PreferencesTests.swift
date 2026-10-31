import Foundation
import Testing
@testable import MagpieCore

@Suite struct PreferencesTests {
    @Test func defaultsMatchSpec() {
        let p = Preferences.standard
        #expect(p.layout.home.entries.map(\.item) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites,
                                                      .randomAlbums, .playlists, .genres, .downloaded])
        #expect(p.layout.home.entries.map(\.visible) == [true, true, true, true, false, false, false, false, false])
        #expect(p.layout.library.entries.map(\.item) == LibraryRow.allCases && p.layout.library.entries.allSatisfy(\.visible))
        #expect(p.layout.showsRecentlyAdded)
        #expect(p.playback.wifi == .original && p.playback.cellular == .aacMedium && p.playback.replayGain == .track)
        #expect(p.playback.sleepTimer == .m30)
        let d = p.downloads
        #expect(d.quality == .original && !d.overMobileData && d.concurrent == 2 && d.preDownload == 3)
        #expect(d.keepRecentlyPlayed && d.cacheLimit == .gb2 && d.downloadsLimit == .none && d.offlineMode == .automatic)
        #expect(!d.keepFavourites)
        #expect(d.keepScreenOn, "P1: Keep screen on while downloading defaults on")
        #expect(p.scrobbling.viaNavidrome && !p.scrobbling.viaListenBrainz && p.scrobbling.rule == ScrobbleRule(percent: 50, minutes: 4))
        #expect(p.genres.mode == .grouped)
    }

    /// R5: every transcode choice is a format × High / Medium / Low preset, plus Original.
    @Test func presetsAreFormatTimesLevel() {
        #expect(StreamQuality.allCases == [.original, .aacHigh, .aacMedium, .aacLow, .opusHigh, .opusMedium, .opusLow,
                                           .mp3High, .mp3Medium, .mp3Low])
        #expect(StreamQuality.allCases.map(\.format) == ["raw", "aac", "aac", "aac", "opus", "opus", "opus", "mp3", "mp3", "mp3"])
        #expect(StreamQuality.allCases.map(\.maxBitRate) == [nil, 256, 160, 96, 320, 160, 96, 320, 192, 128])
        #expect(StreamQuality.allCases.map(\.level) == [nil, .high, .medium, .low, .high, .medium, .low, .high, .medium, .low])
        #expect([StreamQuality.mp3High, .aacMedium, .opusLow].map(\.title) == ["High · 320 kbps", "Medium · 160 kbps", "Low · 96 kbps"])
        #expect(StreamQuality.original.title == "Original")
        #expect([StreamQuality.original, .aacHigh, .opusMedium, .mp3Low].map(\.shortTitle)
                == ["Original", "AAC 256 kbps", "Opus 160 kbps", "MP3 128 kbps"])
        #expect(StreamQuality.groups.map(\.format) == ["raw", "aac", "opus", "mp3"])
        #expect(StreamQuality.groups.flatMap(\.qualities) == StreamQuality.allCases)
        // The stored names: a preset kept from before keeps its name, so it needs no migration.
        #expect(StreamQuality.allCases.map(\.rawValue) == ["original", "aac256", "aac160", "aac96", "opus320", "opus160",
                                                           "opus96", "mp3_320", "mp3_192", "mp3_128"])
    }

    /// R5: a saved bit rate that is no longer a preset moves to the nearest one of its format; a tie goes up.
    @Test func oldBitRatesMigrateToTheNearestPreset() throws {
        let cases: [(String, StreamQuality)] = [
            ("opus192", .opusMedium), ("opus128", .opusMedium), ("opus64", .opusLow), ("opus96", .opusLow),
            ("aac256", .aacHigh), ("aac160", .aacMedium), ("aac96", .aacLow), ("mp3_320", .mp3High), ("mp3_192", .mp3Medium),
            ("aac128", .aacMedium), ("mp3_256", .mp3High), ("mp3_160", .mp3Medium), ("opus240", .opusHigh), ("opus32", .opusLow),
        ]
        for (stored, expected) in cases {
            #expect(StreamQuality(migrating: stored) == expected, "\(stored)")
            let decoded = try JSONDecoder().decode(StreamQuality.self, from: Data("\"\(stored)\"".utf8))
            #expect(decoded == expected, "\(stored) decodes")
        }
        for unknown in ["vorbis96", "opus", "aac0", "opus999", "lossless-ultra", "mp3_x", ""] {
            #expect(StreamQuality(migrating: unknown) == nil, "\(unknown)")
        }
        let prefs = PlaybackPreferences.decode(Data(#"{"wifi":"opus128","cellular":"opus64","replayGain":"track","sleepTimer":"m30"}"#.utf8))
        #expect(prefs.wifi == .opusMedium && prefs.cellular == .opusLow)
        #expect(DownloadPreferences.decode(Data(#"{"quality":"opus192"}"#.utf8)).quality == .opusMedium)
        // Written back under the preset's own name.
        #expect(String(data: try JSONEncoder().encode(StreamQuality.opusMedium), encoding: .utf8) == "\"opus160\"")
    }

    @Test func opusAndOlderQualitiesDecode() throws {
        let decoded = PlaybackPreferences.decode(Data(#"{"wifi":"opus160","cellular":"aac160","replayGain":"track","sleepTimer":"m30"}"#.utf8))
        #expect(decoded.wifi == .opusMedium && decoded.cellular == .aacMedium)
        let unknown = PlaybackPreferences.decode(Data(#"{"wifi":"opus999","cellular":"mp3_192","replayGain":"track","sleepTimer":"m30"}"#.utf8))
        #expect(unknown.wifi == PlaybackPreferences.defaultValue.wifi && unknown.cellular == .mp3Medium)
    }

    /// R12: right = Add to queue, left = Play next, asking before replacing the queue off; settings saved before
    /// round 11 take these defaults, and an unknown action falls back on its own.
    @Test func swipeAndQueueReplaceDefaults() {
        let d = PlaybackPreferences.defaultValue
        #expect(d.swipeRight == .addToQueue && d.swipeLeft == .playNext && d.askBeforeReplacingQueue == false)
        #expect(SwipeAction.allCases == [.playNext, .addToQueue, .addToPlaylist, .download, .favourite, .none])
        let old = PlaybackPreferences.decode(Data(#"{"wifi":"original","cellular":"aac160","replayGain":"track","sleepTimer":"m30"}"#.utf8))
        #expect(old.swipeRight == .addToQueue && old.swipeLeft == .playNext && !old.askBeforeReplacingQueue)
        let custom = PlaybackPreferences.decode(Data(#"{"swipeRight":"download","swipeLeft":"teleport","askBeforeReplacingQueue":true}"#.utf8))
        #expect(custom.swipeRight == .download && custom.swipeLeft == .playNext && custom.askBeforeReplacingQueue)
        var p = d
        p.swipeLeft = .none
        #expect(PlaybackPreferences.decode(p.encoded()) == p)
    }

    @Test func corruptDataFallsBackToDefault() {
        #expect(LayoutPreferences.decode(Data("{not json".utf8)) == .defaultValue)
        #expect(DownloadPreferences.decode(nil) == .defaultValue)
    }

    @Test func oneBadFieldKeepsTheOthers() {
        let p = PlaybackPreferences.decode(Data(#"{"version":1,"wifi":"lossless-ultra","cellular":"mp3_192","replayGain":7}"#.utf8))
        #expect(p.wifi == .original && p.cellular == .mp3Medium && p.replayGain == .track)
        #expect(PlaybackPreferences.decode(Data(#"{"cellular":"vorbis96"}"#.utf8)).cellular == .aacMedium, "an unknown value falls back")
    }

    @Test func unknownAndDuplicateSectionsDropped() {
        let json = #"{"version":1,"home":[{"id":"mostPlayed","visible":true},{"id":"karaoke","visible":true},{"id":"mostPlayed","visible":false},{"id":42}]}"#
        let layout = LayoutPreferences.decode(Data(json.utf8))
        #expect(layout.home.entries.first == .init(item: .mostPlayed, visible: true))
        #expect(layout.home.entries.count == 9)
        #expect(layout.home.entries.filter { $0.item == .mostPlayed }.count == 1)
        #expect(layout.home.entries.first { $0.item == .favourites }?.visible == false, "missing items keep default visibility")
    }

    @Test func outOfRangeValuesClamp() {
        let d = DownloadPreferences.decode(Data(#"{"version":1,"concurrent":9,"preDownload":-1}"#.utf8))
        #expect(d.concurrent == 6 && d.preDownload == 0)
        #expect(DownloadPreferences.decode(Data(#"{"concurrent":6}"#.utf8)).concurrent == 6, "P1: 1–6")
        #expect(DownloadPreferences.decode(Data(#"{"concurrent":5,"keepScreenOn":false}"#.utf8)).keepScreenOn == false)
        #expect(ScrobbleRule(percent: 7, minutes: 0).normalised() == ScrobbleRule(percent: 10, minutes: 1))
        #expect(ScrobbleRule(percent: 52, minutes: 11).normalised() == ScrobbleRule(percent: 50, minutes: 10))
        #expect(ScrobbleRule(percent: 53, minutes: nil).normalised() == ScrobbleRule(percent: 55, minutes: nil))
    }

    @Test func neverRoundTrips() {
        var s = ScrobblePreferences.defaultValue
        s.rule = ScrobbleRule(percent: 90, minutes: nil)
        #expect(String(data: s.encoded()!, encoding: .utf8)!.contains(#""minutesCap":0"#))
        #expect(ScrobblePreferences.decode(s.encoded()).rule == ScrobbleRule(percent: 90, minutes: nil))
    }

    @Test func hostileGenrePreferencesAreCapped() {
        var g = GenrePreferences.defaultValue
        for i in 0..<500 { g.assignments[String(format: "g%03d", i)] = "rock"; g.groupNames[String(format: "n%03d", i)] = "x" }
        g.hidden = Set((0..<500).map { String(format: "h%03d", $0) })
        g.customGroups = (0..<500).map { "custom.\($0)" } + ["custom.0"]
        g.assignments[String(repeating: "a", count: 101)] = "rock"
        let n = GenrePreferences.decode(g.encoded())
        #expect(n.assignments.count == 64 && n.assignments.keys.sorted().first == "g000" && n.assignments.keys.sorted().last == "g063")
        #expect(n.groupNames.count == 32 && n.hidden.count == 64 && n.customGroups.count == 16)
        #expect(n.customGroups.first == "custom.0" && Set(n.customGroups).count == 16)
        #expect(!n.assignments.keys.contains { $0.count > 100 })
    }

    @Test func scrobbleThresholds() {
        let rule = ScrobbleRule.standard
        #expect(rule.threshold(duration: 200) == 100)
        #expect(rule.threshold(duration: 1000) == 240)
        #expect(rule.threshold(duration: 29) == nil)
        #expect(rule.threshold(duration: 30) == 15)
        #expect(rule.threshold(duration: 0) == 240)
        #expect(ScrobbleRule(percent: 90, minutes: nil).threshold(duration: 600) == 540)
        #expect(ScrobbleRule(percent: 50, minutes: nil).threshold(duration: 0) == nil)
    }

    @Test func scrobbleThresholdSurvivesAHandBuiltRule() {
        let huge = ScrobbleRule(percent: Int.max, minutes: Int.max)
        #expect(huge.threshold(duration: 0) == 600, "minutes clamp to 10 before they become seconds")
        #expect(huge.threshold(duration: 100) == 90, "percent clamps to 90")
        #expect(ScrobbleRule(percent: Int.min, minutes: Int.min).threshold(duration: 0) == 60)
    }

    @Test func orderedVisibilityEditing() {
        var v = LayoutPreferences.defaultValue.home
        v.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(v.visibleItems == [.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
        v.moveDown(.mostPlayed); #expect(v.entries.map(\.item).prefix(2) == [.jumpBackIn, .mostPlayed])
        v.moveUp(.jumpBackIn); #expect(v.entries.first?.item == .jumpBackIn, "moveUp at the top is a no-op")
        let shown = v.set(.favourites, visible: true, keepingOneOf: [])
        #expect(shown && v.visibleItems.contains(.favourites))
    }

    @Test func lastVisibleLibraryRowCannotBeHidden() {
        var l = LayoutPreferences.defaultValue.library
        let keep = LayoutPreferences.alwaysAvailableRows
        for row in [LibraryRow.playlists, .artists, .albums, .songs, .genres, .favourites] {
            let hidden = l.set(row, visible: false, keepingOneOf: keep)
            #expect(hidden)
        }
        let lastHidden = l.set(.downloads, visible: false, keepingOneOf: keep)
        #expect(!lastHidden)
        #expect(l.entries.first { $0.item == .downloads }?.visible == true)
        let findsHidden = l.set(.finds, visible: false, keepingOneOf: keep)
        #expect(findsHidden, "rows outside the required set hide freely")
    }

    @Test func visibleSectionRules() {
        let l = LayoutPreferences.defaultValue
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        // The car shows Made for you too (T23 ruling): one rule for the phone and the car.
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true) == [.downloaded])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: true, carPlay: true)
                == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: true, lidarrConnected: false, carPlay: false)
                == [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads, .finds])
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false) == [.genres, .downloads])
    }

    /// Offline (one rule for the phone and the car): Downloads, which always shows, and Genres (read from the phone)
    /// when it is switched on, in the owner's order.
    @Test func offlineLibraryRows() {
        var l = LayoutPreferences.defaultValue
        l.library.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)   // Downloads first
        for carPlay in [false, true] {
            #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: carPlay) == [.downloads, .genres])
        }
        l.setLibraryRow(.genres, visible: false)
        l.setLibraryRow(.downloads, visible: false)
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: false, lidarrConnected: false, carPlay: true) == [.downloads],
                "Downloads shows offline even when switched off; Genres doesn't")
    }

    @Test func qualityStreamParameters() {
        #expect(StreamQuality.original.format == "raw" && StreamQuality.original.maxBitRate == nil)
        #expect(StreamQuality.aacMedium.format == "aac" && StreamQuality.aacMedium.maxBitRate == 160)
        #expect(StreamQuality.mp3High.format == "mp3" && StreamQuality.mp3High.maxBitRate == 320)
    }

    @Test func extremeIntegersNeverTrapAndClamp() {
        for big in [Int.max, Int.min] {
            let rule = ScrobbleRule(percent: big, minutes: big).normalised()
            #expect(rule.percent == (big > 0 ? 90 : 10) && rule.minutes == (big > 0 ? 10 : 1))
            let d = DownloadPreferences.decode(Data(#"{"concurrent":\#(big),"preDownload":\#(big)}"#.utf8))
            #expect(d.concurrent == (big > 0 ? 6 : 1) && d.preDownload == (big > 0 ? 10 : 0))
            let s = ScrobblePreferences.decode(Data(#"{"rule":{"percent":\#(big),"minutesCap":\#(big)}}"#.utf8))
            #expect(s.rule == ScrobbleRule(percent: big > 0 ? 90 : 10, minutes: big > 0 ? 10 : 1))
        }
    }

    @Test func allHiddenStoredLibraryRestoresDefaults() {
        let rows = LibraryRow.allCases.map { #"{"id":"\#($0.rawValue)","visible":false}"# }.joined(separator: ",")
        let layout = LayoutPreferences.decode(Data(#"{"library":[\#(rows)]}"#.utf8))
        #expect(layout.library.visibleItems.contains { LayoutPreferences.alwaysAvailableRows.contains($0) })
        #expect(Set(layout.library.visibleItems) == LayoutPreferences.alwaysAvailableRows)
        var l = LayoutPreferences.defaultValue
        for row in [LibraryRow.playlists, .artists, .albums, .songs, .genres, .favourites] { l.setLibraryRow(row, visible: false) }
        let refused = l.setLibraryRow(.downloads, visible: false)
        #expect(!refused)
    }
}
