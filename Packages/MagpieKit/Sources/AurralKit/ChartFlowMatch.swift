import Foundation
import MagpieCore

/// Round 27 D2 (owner item 16, 2026-11-14): a Trending row the chart's own flow holds plays the flow's song in full,
/// shown as a library row; a row whose song is still downloading says "On its way" (D317, D318).
///
/// A chart flow's songs are Aurral's copies in Discover's library, so the main-library lookup (`DiscoverRules.mainCopy`)
/// leaves them out by design. Here each chart row is matched to a song of the flow's Navidrome playlist:
/// 1. the flow's job whose artist and title equal the row's (folded: Magpie itself sent them, `ChartFlowPlan.tracks`),
///    then the playlist song that is that job's by D62/D203's rule: the same recording id, else the same artist and
///    title with the lengths within 3 s when both are known; exactly one, or none;
/// 2. else exactly one playlist song with the same artist (folded), the same title key (the app passes
///    `TopSongIdentity.titleKey`) and both lengths known and within 3 s.
/// A row whose job is pending or downloading and that matched no song is "on its way". Quality-upgrade jobs are never
/// a song's own (as `ChartFlowPlan.changes`). Pure, so it is tested on its own; nothing is sent anywhere.
public enum ChartFlowMatch {
    public struct Result: Equatable, Sendable {
        /// The flow's song for each matched row, by the row's index in the chart.
        public var songs: [Int: Song]
        /// Rows whose song the flow is still getting.
        public var onItsWay: Set<Int>

        public init(songs: [Int: Song] = [:], onItsWay: Set<Int> = []) { self.songs = songs; self.onItsWay = onItsWay }
    }

    /// Each chart row's song in the flow's playlist (`songs`), from the flow's jobs (`jobs`, the flow's only).
    public static func match(chart: [ChartFlowTrack], songs: [Song], jobs: [AurralJob],
                             titleKey: (String) -> String = DiscoverRules.normalised) -> Result {
        let ownJobs = jobs.filter { $0.upgradeForJobId == nil }
        var jobsByKey: [String: AurralJob] = [:]
        for job in ownJobs {
            let key = ChartFlowPlan.songKey(job.artistName, job.trackName)
            if !key.isEmpty, jobsByKey[key] == nil { jobsByKey[key] = job }
        }
        var result = Result()
        for (index, row) in chart.enumerated() {
            let job = jobsByKey[ChartFlowPlan.songKey(row.artistName, row.trackName)]
            if let job, let song = song(for: job, in: songs) {
                result.songs[index] = song
            } else if let song = strictSong(for: row, in: songs, titleKey: titleKey) {
                result.songs[index] = song
            } else if let status = job?.status?.lowercased(), status == "pending" || status == "downloading" {
                result.onItsWay.insert(index)
            }
        }
        return result
    }

    /// What a Trending row shows: the main library's copy first (today's rule), else the flow's song; "on its way"
    /// only for a row with neither.
    public static func combined(main: [Int: Song], flow: Result) -> (copies: [Int: Song], onItsWay: Set<Int>) {
        let copies = main.merging(flow.songs) { mainCopy, _ in mainCopy }
        return (copies, flow.onItsWay.filter { copies[$0] == nil })
    }

    /// The playlist song that is `job`'s: by recording id, else artist and title with the lengths within 3 s when both
    /// are known (D62/D203); exactly one.
    static func song(for job: AurralJob, in songs: [Song]) -> Song? {
        if let recording = job.trackMBID {
            let byId = unique(songs.filter { $0.recordingMBID == recording })
            if byId.count == 1 { return byId[0] }
        }
        let artist = DiscoverRules.normalised(job.artistName), title = DiscoverRules.normalised(job.trackName)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        let byText = unique(songs.filter { song in
            if let recording = song.recordingMBID, let track = job.trackMBID, recording != track { return false }
            guard DiscoverRules.normalised(song.artist) == artist, DiscoverRules.normalised(song.title) == title else { return false }
            if let duration = job.duration, duration > 0, song.duration > 0 {
                return abs(duration - song.duration) <= DiscoverRules.durationTolerance
            }
            return true
        })
        return byText.count == 1 ? byText[0] : nil
    }

    /// The one playlist song with the row's artist, title key and length (both known, within 3 s).
    static func strictSong(for row: ChartFlowTrack, in songs: [Song], titleKey: (String) -> String) -> Song? {
        guard let ms = row.durationMs, ms > 0 else { return nil }
        let length = TimeInterval(ms) / 1000
        let artist = DiscoverRules.normalised(row.artistName), title = titleKey(row.trackName)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        let found = unique(songs.filter { song in
            song.duration > 0 && abs(song.duration - length) <= DiscoverRules.durationTolerance
                && DiscoverRules.normalised(song.artist) == artist && titleKey(song.title) == title
        })
        return found.count == 1 ? found[0] : nil
    }

    private static func unique(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }
}
