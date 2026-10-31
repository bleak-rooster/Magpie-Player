import Foundation
import LidarrKit
import MagpieCore
import Requests
import Testing
@testable import Magpie

/// R16 + R20 (appraisal "R16 / Activity" and the Try sheet): a Ready find's request page offers Play, Keep, Not for
/// me…; Library › Requests rows for Ready finds get a leading Keep; the wait sheet's button is Done, with a footnote.
@MainActor
struct ReadyFindActionsTests {
    private let rg = MBID("f5093c06-23e3-404f-aeaa-40f72885ee3a")!
    private let artist = MBID("9c9f1380-2516-4fc9-a3e6-f9f61941d090")!
    private let recording = MBID("b1a9c0e9-d987-4042-ae91-78d6a3267d69")!

    private func find(state: RequestState = .ready, mode: LedgerMode = .finds, artistExisted: Bool = false)
        -> MagpieRequest {
        var request = MagpieRequest(recording: ExternalRecording(recordingMBID: recording, title: "Harbour Lights",
                                                                 artist: "Judie Tzuke", source: .listenBrainz),
                                    tier: .standard, createdAt: Date())
        request.state = state
        request.songId = "song-1"
        request.plan = Plan(recordingMBID: recording, releaseGroupMBID: rg, artistMBID: artist,
                            lidarrArtistId: artistExisted ? 7 : nil, mode: mode)
        request.lidarrArtistId = 7
        request.albumId = 31
        return request
    }

    @Test func aReadyFindOffersKeepAndNotForMe() {
        let request = find()
        #expect(ReadyFindActions.keep(request) == request.id)
        #expect(ReadyFindActions.notForMe(request) == request.id)
    }

    @Test func nothingWhileOnItsWayOrForASongThatWentStraightIntoTheLibrary() {
        #expect(ReadyFindActions.keep(find(state: .downloading(progress: 0.4))) == nil)
        #expect(ReadyFindActions.notForMe(find(state: .downloading(progress: 0.4))) == nil)
        #expect(ReadyFindActions.keep(find(mode: .fallback)) == nil, "not a find: nothing to keep")
        #expect(ReadyFindActions.notForMe(find(mode: .fallback)) == nil)
    }

    @Test func notForMeOnlyForANewArtistAndNeitherWhileOneIsUnderWay() {
        #expect(ReadyFindActions.keep(find(artistExisted: true)) != nil)
        #expect(ReadyFindActions.notForMe(find(artistExisted: true)) == nil, "the artist was there before")
        var stuck = find()
        stuck.keepNeedsAttention = true
        #expect(ReadyFindActions.keep(stuck) == nil)
        #expect(ReadyFindActions.notForMe(stuck) == nil)
        var noSong = find()
        noSong.songId = nil
        #expect(ReadyFindActions.keep(noSong) == nil)
    }

    @Test func theWaitSheetSaysDoneWithItsFootnote() {
        #expect(TrySheet.closeTitle == "Done", "never Leave, which reads as abandon")
        #expect(RequestCopy.keepBrowsing == "You can keep browsing. It plays next when it's here.")
        #expect(RequestCopy.notForMeAsks == "Not for me…")
    }
}
