import Foundation
import LidarrKit
import Requests
import Testing
@testable import Magpie

/// Y4 (round 12 item 6): the words of Settings › New music › Downloads in Lidarr. Every state is text plus a symbol
/// (D3), and a tap's outcome reads plainly.
@MainActor @Suite struct LidarrDownloadsAppTests {
    private func row(_ phase: LidarrDownloads.Phase, progress: Double? = nil) -> LidarrDownloads.Row {
        let item = QueueItem(id: 1, albumId: 2, size: 100, sizeleft: 50)
        return LidarrDownloads.Row(id: 1, item: item, section: .active, phase: phase, canRestart: false, artist: "A",
                                   album: "B", client: nil, progress: progress, message: nil)
    }

    @Test func everyPhaseHasTextAndSymbol() {
        let phases: [LidarrDownloads.Phase] = [.downloading, .queued, .waitingToImport, .importing, .stalled, .failed]
        for phase in phases {
            #expect(!LidarrDownloadsCopy.status(row(phase), limit: .oneMinute).isEmpty)
            #expect(!LidarrDownloadsCopy.symbol(phase).isEmpty)
        }
        #expect(LidarrDownloadsCopy.status(row(.downloading, progress: 0.456), limit: .oneMinute) == "Downloading 46%")
        #expect(LidarrDownloadsCopy.status(row(.stalled), limit: .fiveMinutes) == "No progress for 5 minutes or more")
        #expect(Set(phases.map(LidarrDownloadsCopy.symbol)).count == phases.count)
    }

    @Test func confirmationSaysTheCap() {
        #expect(LidarrDownloadsCopy.confirmTitle(1) == "Restart 1 download?")
        #expect(LidarrDownloadsCopy.confirmTitle(3) == "Restart 3 downloads?")
        #expect(LidarrDownloadsCopy.confirmTitle(40) == "Restart 25 downloads?")
        #expect(!LidarrDownloadsCopy.confirmMessage(10).contains("25"))
        #expect(LidarrDownloadsCopy.confirmMessage(40).contains("first 25"))
    }

    @Test func outcomesReadPlainly() {
        #expect(LidarrDownloadsCopy.summary([]) == nil)
        #expect(LidarrDownloadsCopy.summary([.restarted]) == "Restarted.")
        #expect(LidarrDownloadsCopy.summary([.restarted, .restarted, .refused("importing")])
                == "Restarted 2. One is importing or done, so it was left alone.")
        #expect(LidarrDownloadsCopy.summary([.limitReached]) == "Magpie has already tried five copies of that request.")
        #expect(LidarrDownloadsCopy.summary([.restarted, .changesOff]) == LidarrDownloadsCopy.changesOff)
        #expect(LidarrDownloadsCopy.summary([.gone, .gone]) == "2 had already left the list.")
        #expect(LidarrDownloadsCopy.summary([.unavailable])?.contains("Try again") == true)
    }
}
