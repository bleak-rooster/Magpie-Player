import Foundation
import LidarrKit
import Requests
import Testing
@testable import Magpie

/// Y4 (round 12 item 6): the words of Settings › Downloads in Lidarr. Every state is text plus a symbol (D3), a tap's
/// outcome reads plainly, and the page is a top-level Settings row while Lidarr is connected (fix round 1 I3).
@MainActor @Suite struct LidarrDownloadsAppTests {
    private func row(_ phase: LidarrDownloads.Phase, progress: Double? = nil, speed: Double? = nil,
                     stall: LidarrDownloads.StallReason? = nil) -> LidarrDownloads.Row {
        let item = QueueItem(id: 1, albumId: 2, size: 100, sizeleft: 50)
        return LidarrDownloads.Row(id: 1, item: item, section: .active, phase: phase, stall: stall, canRestart: false,
                                   artist: "A", album: "B", client: nil, progress: progress, speed: speed, message: nil)
    }

    @Test func everyPhaseHasTextAndSymbol() {
        let phases: [LidarrDownloads.Phase] = [.downloading, .queued, .paused, .clientUnavailable, .waitingToImport,
                                               .importing, .stalled, .failed]
        for phase in phases {
            #expect(!LidarrDownloadsCopy.status(row(phase), limit: .oneMinute).isEmpty)
            #expect(!LidarrDownloadsCopy.symbol(phase).isEmpty)
        }
        #expect(Set(phases.map(LidarrDownloadsCopy.symbol)).count == phases.count)
        #expect(LidarrDownloadsCopy.status(row(.downloading, progress: 0.456), limit: .oneMinute) == "Downloading 46%")
        #expect(LidarrDownloadsCopy.status(row(.downloading, progress: 0.5, speed: 2_500_000), limit: .oneMinute)
                == "Downloading 50% · 2.5 MB/s")
        #expect(LidarrDownloadsCopy.status(row(.paused), limit: .oneMinute) == "Paused")
        #expect(LidarrDownloadsCopy.status(row(.clientUnavailable), limit: .oneMinute) == "Can't reach the download app")
        #expect(LidarrDownloadsCopy.status(row(.stalled, stall: .noProgress), limit: .fiveMinutes)
                == "No progress for 5 minutes or more")
        #expect(LidarrDownloadsCopy.status(row(.stalled, stall: .lidarr), limit: .oneMinute) == "Stalled")
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
        #expect(LidarrDownloadsCopy.summary([.restarted, .restarted, .importingOrDone])
                == "Restarted 2. One is importing or done, so it was left alone.")
        #expect(LidarrDownloadsCopy.summary([.skipped]) == "It started moving again, so it was left alone.")
        #expect(LidarrDownloadsCopy.summary([.restarted, .skipped, .skipped])
                == "Restarted 1. 2 started moving again, so they were left alone.")
        #expect(LidarrDownloadsCopy.summary([.limitReached]) == "Magpie has already tried five copies of that request.")
        #expect(LidarrDownloadsCopy.summary([.magpieBusy]) == "Magpie is bringing that album home right now, so it was left alone.")
        #expect(LidarrDownloadsCopy.summary([.unnamed])?.contains("doesn't say which download") == true)
        #expect(LidarrDownloadsCopy.summary([.logUnavailable])?.contains("change log") == true)
        #expect(LidarrDownloadsCopy.summary([.refused("x")]) == "Lidarr's list changed, so one was left alone.")
        #expect(LidarrDownloadsCopy.summary([.restarted, .changesOff]) == LidarrDownloadsCopy.changesOff)
        #expect(LidarrDownloadsCopy.summary([.gone, .gone]) == "2 had already left the list.")
        #expect(LidarrDownloadsCopy.summary([.unavailable])?.contains("Try again") == true)
    }

    /// I3: "Downloads in Lidarr" is a top-level Settings row, only while Lidarr is connected.
    @Test func topLevelRowWhileConnected() {
        #expect(SettingsPage.topLevel(lidarrConnected: false)
                == [.account, .playback, .downloads, .scrobbling, .homeAndLibrary, .appearance, .requests, .about])
        #expect(SettingsPage.topLevel(lidarrConnected: true)
                == [.account, .playback, .downloads, .scrobbling, .homeAndLibrary, .appearance, .requests,
                    .lidarrDownloads, .about])
        #expect(SettingsView.identifier(.lidarrDownloads) == "settings-lidarr-downloads")
        #expect(LidarrDownloadsCopy.attention(nil).text == "Stalled and failed downloads")
        #expect(LidarrDownloadsCopy.attention(0).text == "Nothing stalled or failed")
        #expect(LidarrDownloadsCopy.attention(2).text == "2 need attention")
    }
}
