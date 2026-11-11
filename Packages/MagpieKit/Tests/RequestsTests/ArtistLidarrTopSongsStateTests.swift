import MagpieCore
import Testing
@testable import Requests

/// Round 26 K1 (owner, 2026-11-10; Q1 answered 2026-11-11): "in Lidarr" for Top songs is any artist Lidarr has, monitored
/// or not, and a find the owner kept; never a find still on trial, a name-only match or an artist Lidarr doesn't have
/// (D257). The answer is the Lidarr artist id the album step reads, or nil.
@Suite struct ArtistLidarrTopSongsStateTests {
    @Test func state_monitoredAndUnmonitoredQualify() {
        #expect(ArtistLidarrState.monitored(lidarrId: 1, searching: false).topSongsLidarrArtistId == 1)
        #expect(ArtistLidarrState.monitored(lidarrId: 1, searching: true).topSongsLidarrArtistId == 1)
        #expect(ArtistLidarrState.notMonitored(lidarrId: 3, magpieAdded: true).topSongsLidarrArtistId == 3)
        #expect(ArtistLidarrState.notMonitored(lidarrId: 4, magpieAdded: false).topSongsLidarrArtistId == 4)
    }

    @Test func state_keptFindsQualify() {
        for lossless in [FindState.Lossless.lossless, .waiting(removedOn: nil), .mp3Removed] {
            #expect(ArtistLidarrState.find(lidarrId: 2, state: .inLibrary(lossless)).topSongsLidarrArtistId == 2)
        }
        #expect(ArtistLidarrState.find(lidarrId: 5, state: .keptInFinds).topSongsLidarrArtistId == 5)
    }

    @Test func state_findOnTrialDoesNot() {
        let trials: [FindState] = [.find, .adding(queued: true), .adding(queued: false), .collision,
                                   .needsAttention(.keep), .needsAttention(.letGo), .needsAttention(.mp3)]
        for trial in trials {
            #expect(ArtistLidarrState.find(lidarrId: 2, state: trial).topSongsLidarrArtistId == nil, "\(trial)")
        }
    }

    @Test func state_notInLidarrAndUnmatchedDoNot() {
        #expect(ArtistLidarrState.notInLidarr(mbid: nil).topSongsLidarrArtistId == nil)
        #expect(ArtistLidarrState.notInLidarr(mbid: MBID("9c9f1380-2516-4fc9-a3e6-f9f61941d090")).topSongsLidarrArtistId == nil)
        #expect(ArtistLidarrState.unmatched.topSongsLidarrArtistId == nil)
    }
}

