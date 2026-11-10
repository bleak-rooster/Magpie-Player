import Testing
@testable import Requests

/// Round 25 I fix (controller ruling, D249): a find the owner kept is in the main library and monitored, so its Top songs
/// keep to the library; a find still on trial shows every song.
@Suite struct TopSongsMonitoredStateTests {
    @Test func monitoredAndKeptFindsCount() {
        #expect(ArtistLidarrState.monitored(lidarrId: 1, searching: false).countsAsMonitoredForTopSongs)
        #expect(ArtistLidarrState.monitored(lidarrId: 1, searching: true).countsAsMonitoredForTopSongs)
        for lossless in [FindState.Lossless.lossless, .waiting(removedOn: nil), .mp3Removed] {
            #expect(ArtistLidarrState.find(lidarrId: 2, state: .inLibrary(lossless)).countsAsMonitoredForTopSongs, "kept find")
        }
    }

    @Test func trialFindsAndEverythingElseDoNot() {
        let others: [ArtistLidarrState] = [
            .find(lidarrId: 2, state: .find), .find(lidarrId: 2, state: .adding(queued: true)),
            .find(lidarrId: 2, state: .adding(queued: false)), .find(lidarrId: 2, state: .keptInFinds),
            .find(lidarrId: 2, state: .collision), .find(lidarrId: 2, state: .needsAttention(.keep)),
            .notMonitored(lidarrId: 3, magpieAdded: true), .notInLidarr(mbid: nil), .unmatched,
        ]
        for state in others { #expect(!state.countsAsMonitoredForTopSongs, "\(state)") }
    }
}
