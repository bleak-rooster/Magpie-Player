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
        #expect(p.playback.wifi == .original && p.playback.cellular == .aac160 && p.playback.replayGain == .track)
        #expect(p.playback.sleepTimer == .m30)
        let d = p.downloads
        #expect(d.quality == .original && !d.overMobileData && d.concurrent == 2 && d.preDownload == 3)
        #expect(d.keepRecentlyPlayed && d.cacheLimit == .gb2 && d.downloadsLimit == .none && d.offlineMode == .automatic)
        #expect(!d.keepFavourites)
        #expect(p.scrobbling.viaNavidrome && !p.scrobbling.viaListenBrainz && p.scrobbling.rule == ScrobbleRule(percent: 50, minutes: 4))
        #expect(p.genres.mode == .grouped)
    }

    @Test func noOpusPresets() {
        #expect(StreamQuality.allCases == [.original, .aac256, .aac160, .aac96, .mp3_320, .mp3_192])
        #expect(Set(StreamQuality.allCases.map(\.format)) == ["raw", "aac", "mp3"])
    }

    @Test func corruptDataFallsBackToDefault() {
        #expect(LayoutPreferences.decode(Data("{not json".utf8)) == .defaultValue)
        #expect(DownloadPreferences.decode(nil) == .defaultValue)
    }

    @Test func oneBadFieldKeepsTheOthers() {
        let p = PlaybackPreferences.decode(Data(#"{"version":1,"wifi":"lossless-ultra","cellular":"mp3_192","replayGain":7}"#.utf8))
        #expect(p.wifi == .original && p.cellular == .mp3_192 && p.replayGain == .track)
        #expect(PlaybackPreferences.decode(Data(#"{"cellular":"opus64"}"#.utf8)).cellular == .aac160, "old Opus value falls back")
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
        #expect(d.concurrent == 4 && d.preDownload == 0)
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
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: false, carPlay: false) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true, carPlay: false) == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: false, hasListenBrainzToken: true, carPlay: true) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(l.visibleHomeSections(offline: true, hasListenBrainzToken: true, carPlay: false) == [.downloaded])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: false, lidarrConnected: true, carPlay: true)
                == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
        #expect(l.visibleLibraryRows(offline: false, findsSetUp: true, lidarrConnected: false, carPlay: false)
                == [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads, .finds])
        #expect(l.visibleLibraryRows(offline: true, findsSetUp: true, lidarrConnected: true, carPlay: false) == [.downloads])
    }

    @Test func qualityStreamParameters() {
        #expect(StreamQuality.original.format == "raw" && StreamQuality.original.maxBitRate == nil)
        #expect(StreamQuality.aac160.format == "aac" && StreamQuality.aac160.maxBitRate == 160)
        #expect(StreamQuality.mp3_320.format == "mp3" && StreamQuality.mp3_320.maxBitRate == 320)
    }

    @Test func extremeIntegersNeverTrapAndClamp() {
        for big in [Int.max, Int.min] {
            let rule = ScrobbleRule(percent: big, minutes: big).normalised()
            #expect(rule.percent == (big > 0 ? 90 : 10) && rule.minutes == (big > 0 ? 10 : 1))
            let d = DownloadPreferences.decode(Data(#"{"concurrent":\#(big),"preDownload":\#(big)}"#.utf8))
            #expect(d.concurrent == (big > 0 ? 4 : 1) && d.preDownload == (big > 0 ? 10 : 0))
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
