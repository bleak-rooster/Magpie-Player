import CarPlayUI
import Foundation
import LidarrKit
import MagpieCore
import Requests
import Testing
@testable import Magpie

/// Y5: what the find flow says on the phone (and, through the adapter, in the car).
@Suite struct FindFlowAppTests {
    static let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func findStatusLines() {
        #expect(FindCopy.status(.find) == "In your Finds")
        #expect(FindCopy.status(.adding(queued: true)) == "Adding when your server is free\u{2026}")
        #expect(FindCopy.status(.adding(queued: false)) == "Adding to your library\u{2026}")
        #expect(FindCopy.status(.inLibrary(.lossless)) == "In your library \u{00B7} Lossless")
        #expect(FindCopy.status(.inLibrary(.mp3Removed)) == "Waiting for a lossless copy")
        #expect(FindCopy.status(.inLibrary(.waiting(removedOn: nil))) == "In your library \u{00B7} lossless soon")
        let dated = FindCopy.status(.inLibrary(.waiting(removedOn: Self.date)))
        #expect(dated.hasPrefix("In your library \u{00B7} lossless soon. The MP3 is removed on "))
        #expect(dated.hasSuffix("unless a lossless copy turns up."))
        #expect(FindCopy.status(.needsAttention(.mp3)) == "Couldn't remove the MP3 \u{00B7} needs a look")
        #expect(FindCopy.status(.collision).contains("stays in your Finds"))
        for state: FindState in [.find, .adding(queued: true), .inLibrary(.lossless), .collision, .needsAttention(.keep)] {
            let text = FindCopy.status(state)
            #expect(!text.contains("Lidarr") && !text.contains("Navidrome"), "glossary: \(text)")
        }
    }

    /// Critic 9 / I7: with Lidarr's recycle bin unset, the page line and the confirmation say it can't be undone.
    @Test func recycleBinCopy() {
        #expect(FindCopy.status(.inLibrary(.waiting(removedOn: Self.date)), permanent: true).hasSuffix("This can't be undone."))
        #expect(!FindCopy.status(.inLibrary(.waiting(removedOn: Self.date)), permanent: false).contains("undone"))
        #expect(FindCopy.confirmMessage(permanent: true) == "This song leaves your library until a lossless copy arrives. This can't be undone.")
        #expect(FindCopy.confirmMessage(permanent: false) == "This song leaves your library until a lossless copy arrives.")
    }

    @Test func artistLineForFindsAndUnmatched() {
        let line = ArtistLidarrPresentation.make(.find(lidarrId: 42, state: .find), offline: false, changesAllowed: true, canAdd: true)
        #expect(line?.text == "In your Finds" && line?.action == nil)
        let unmatched = ArtistLidarrPresentation.make(.unmatched, offline: false, changesAllowed: true, canAdd: true)
        #expect(unmatched?.text == "Couldn't match this artist" && unmatched?.action == nil && unmatched?.hint == nil)
    }

    @Test func keepRepliesAndTheCar() {
        #expect(KeepCopy.message(.queued) == "Adding when your server is free\u{2026}")
        #expect(KeepCopy.message(for: RequestRunner.KeepError.collision).contains("already has a folder"))
        #expect(CPKeepResult(.queued) == .stillMoving)
        #expect(CPKeepResult(error: RequestRunner.KeepError.collision) == .notAFind)
    }

    @Test func requestLinesAfterAdd() {
        var r = MagpieRequest(recording: ExternalRecording(recordingMBID: nil, title: "S", artist: "A", source: .listenBrainz),
                              tier: .standard, createdAt: Self.date)
        r.state = .kept
        r.relinkPending = false
        var w = LosslessWatch(albumIds: [1], startedAt: Self.date, autoDelete: true, deadline: Self.date.addingTimeInterval(7 * 86_400))
        r.lossless = w
        #expect(RequestCopy.kept(r).hasPrefix("Kept \u{00B7} lossless soon. The MP3 is removed on "))
        w.removedAt = Self.date; r.lossless = w
        #expect(RequestCopy.kept(r) == "Waiting for a lossless copy")
        w.losslessAt = Self.date; r.lossless = w
        #expect(RequestCopy.kept(r) == RequestCopy.keptLossless)
        r.mp3NeedsAttention = true
        #expect(RequestCopy.group(r) == .attention)
    }
}
