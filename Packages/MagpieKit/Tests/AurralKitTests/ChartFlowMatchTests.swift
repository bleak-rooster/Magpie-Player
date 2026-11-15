import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 27 D2 (owner item 16, 2026-11-14): a Trending row the chart's flow holds plays the flow's song: matched by the
/// flow's job (artist and title as Magpie sent them) then D62/D203's rule to the playlist song, else exactly one
/// playlist song with the same artist, title key and length within 3 s; a main-library copy first (D317, D318).
@Suite struct ChartFlowMatchTests {
    static func row(_ artist: String, _ title: String, _ seconds: Int? = 200) -> ChartFlowTrack {
        ChartFlowTrack(artistName: artist, trackName: title, albumName: nil, durationMs: seconds.map { $0 * 1000 })
    }

    static func song(_ id: String, _ artist: String, _ title: String, _ seconds: TimeInterval = 200,
                     recording: String? = nil) -> Song {
        Song(id: id, title: title, artist: artist, album: "A", duration: seconds, recordingMBID: recording.flatMap(MBID.init))
    }

    static func job(_ id: String, _ artist: String, _ title: String, status: String = "done", recording: String? = nil,
                    seconds: Int? = 200, upgradeOf: String? = nil) -> AurralJob {
        var j = AurralJob(id: id, flowId: "pl-chart", artistName: artist, trackName: title,
                          trackMBID: recording.flatMap(MBID.init), durationMs: seconds.map { $0 * 1000 }, status: status)
        j.upgradeForJobId = upgradeOf
        return j
    }

    static let rec1 = "11111111-1111-4111-8111-111111111111"

    @Test func match_byJobThenSong() throws {
        // The job (as Magpie sent it) names the recording; the playlist song carries it under another title spelling.
        let chart = [Self.row("Mallee Fowl", "Harbour Lights"), Self.row("Stub Arrows", "Paper Moon")]
        let jobs = [Self.job("j1", "Mallee Fowl", "Harbour Lights", recording: Self.rec1),
                    Self.job("j2", "Stub Arrows", "Paper Moon")]
        let songs = [Self.song("s1", "Mallee Fowl", "Harbour Lights (2024 Mix)", 260, recording: Self.rec1),
                     Self.song("s2", "Stub Arrows", "Paper Moon", 201)]
        let result = ChartFlowMatch.match(chart: chart, songs: songs, jobs: jobs)
        #expect(result.songs[0]?.id == "s1", "by the job's recording id, whatever the length")
        #expect(result.songs[1]?.id == "s2", "by the job's artist and title within 3 s")
        #expect(result.onItsWay.isEmpty)
        // A quality-upgrade job is never the song's own.
        let upgrade = ChartFlowMatch.match(chart: [Self.row("Mallee Fowl", "Harbour Lights")], songs: songs,
                                           jobs: [Self.job("j9", "Mallee Fowl", "Harbour Lights", recording: Self.rec1,
                                                           upgradeOf: "j1")])
        #expect(upgrade.songs[0] == nil, "its title and length don't match on their own")
    }

    @Test func match_byStrictTitleAndThreeSeconds() {
        // No job for the row: one playlist song, same artist, the same title key ("Radio Edit" is housekeeping when the
        // app's key says so; the default key folds case and accents), length within 3 s.
        let chart = [Self.row("Ana Frango Elétrico", "Electric Fruit", 180), Self.row("Mallee Fowl", "Dusk", 180),
                     Self.row("Mallee Fowl", "Dawn", nil)]
        let songs = [Self.song("s1", "ana frango eletrico", "ELECTRIC FRUIT", 182),
                     Self.song("s2", "Mallee Fowl", "Dusk", 184),     // 4 s apart
                     Self.song("s3", "Mallee Fowl", "Dawn", 180)]     // the row's length unknown
        let result = ChartFlowMatch.match(chart: chart, songs: songs, jobs: [])
        #expect(result.songs[0]?.id == "s1")
        #expect(result.songs[1] == nil, "more than 3 s apart")
        #expect(result.songs[2] == nil, "both lengths must be known")
        // The title key is the caller's (the app passes TopSongIdentity.titleKey).
        let keyed = ChartFlowMatch.match(chart: [Self.row("Mallee Fowl", "Dusk (Radio Edit)", 180)],
                                         songs: [Self.song("s4", "Mallee Fowl", "Dusk", 181)], jobs: [],
                                         titleKey: { $0.replacingOccurrences(of: " (Radio Edit)", with: "").lowercased() })
        #expect(keyed.songs[0]?.id == "s4")
    }

    @Test func match_ambiguousSkips() {
        let chart = [Self.row("Mallee Fowl", "Dusk", 180)]
        let two = [Self.song("s1", "Mallee Fowl", "Dusk", 180), Self.song("s2", "Mallee Fowl", "Dusk", 181)]
        #expect(ChartFlowMatch.match(chart: chart, songs: two, jobs: []).songs.isEmpty)
        // A job that matches two playlist songs by name (no recording id) settles nothing either.
        let jobs = [Self.job("j1", "Mallee Fowl", "Dusk", seconds: nil)]
        #expect(ChartFlowMatch.match(chart: chart, songs: two, jobs: jobs).songs.isEmpty)
        // Another artist's song of the same name is never it.
        #expect(ChartFlowMatch.match(chart: chart, songs: [Self.song("s3", "Stub Arrows", "Dusk", 180)], jobs: []).songs.isEmpty)
    }

    @Test func match_onItsWay() {
        let chart = [Self.row("Mallee Fowl", "Dusk"), Self.row("Stub Arrows", "Paper Moon"), Self.row("Wren", "Gone"),
                     Self.row("Wren", "Never Sent")]
        let jobs = [Self.job("j1", "Mallee Fowl", "Dusk", status: "pending"),
                    Self.job("j2", "Stub Arrows", "Paper Moon", status: "Downloading"),
                    Self.job("j3", "Wren", "Gone", status: "failed")]
        let result = ChartFlowMatch.match(chart: chart, songs: [], jobs: jobs)
        #expect(result.onItsWay == [0, 1])
        #expect(result.songs.isEmpty)
    }

    @Test func match_mainLibraryCopyFirst() {
        let main = [0: Self.song("lib-1", "Mallee Fowl", "Dusk")]
        let flow = ChartFlowMatch.Result(songs: [0: Self.song("aur-1", "Mallee Fowl", "Dusk"),
                                                 1: Self.song("aur-2", "Stub Arrows", "Paper Moon")],
                                         onItsWay: [2])
        let rows = ChartFlowMatch.combined(main: main, flow: flow)
        #expect(rows.copies[0]?.id == "lib-1", "the main library's copy wins")
        #expect(rows.copies[1]?.id == "aur-2")
        #expect(rows.onItsWay == [2])
        // A row with a main copy is never "on its way".
        let both = ChartFlowMatch.combined(main: [2: Self.song("lib-2", "Wren", "Gone")], flow: flow)
        #expect(both.onItsWay.isEmpty && both.copies[2]?.id == "lib-2")
    }
}
