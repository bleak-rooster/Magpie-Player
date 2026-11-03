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
                                               .importing, .stalled, .failed, .couldntImport, .notStarted]
        #expect(LidarrDownloadsCopy.status(row(.couldntImport), limit: .oneMinute) == "Couldn't import")
        #expect(LidarrDownloadsCopy.status(row(.notStarted), limit: .oneMinute) == "Started by another app")
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

    /// Fix round 2: the two new sections' words, and the confirmation for a finished copy.
    @Test func couldntImportAndNotStartedCopy() {
        #expect(LidarrDownloadsCopy.couldntImportSection == "Couldn't import")
        #expect(LidarrDownloadsCopy.notStartedSection == "Started by another app")   // fix round 3: glossary
        #expect(!LidarrDownloadsCopy.notStartedFooter.isEmpty)
        #expect(LidarrDownloadsCopy.couldntImportConfirm == "Removes this copy so it isn't picked again, and looks for another.")
        for text in [LidarrDownloadsCopy.couldntImportConfirm, LidarrDownloadsCopy.footer, LidarrDownloadsCopy.couldntImportFooter,
                     LidarrDownloadsCopy.notStartedFooter, LidarrDownloadsCopy.confirmMessage(3)] {
            #expect(!text.lowercased().contains("blocklist"), "\(text)")
        }
        #expect(LidarrDownloadsCopy.summary([.notStartedByLidarr])
                == "Another app started that download, so it was left alone.")
    }

    /// Round 13 item 6 (D63): every row offers Restart; what it asks first depends on the row. Another app's download
    /// gets the flagged confirmation in the owner's plan's words; Restart all includes another app's only when chosen.
    @Test func restartAnythingAsksFirst() {
        #expect(LidarrDownloadsCopy.confirmOne(.none) == nil, "a stalled or failed copy restarts at once")
        #expect(LidarrDownloadsCopy.confirmOne(.foreign)
                == "This download wasn't started by your library \u{2014} it may belong to another app. Restart anyway?")
        #expect(LidarrDownloadsCopy.confirmOne(.couldntImport) == LidarrDownloadsCopy.couldntImportConfirm)
        #expect(LidarrDownloadsCopy.confirmOne(.stillGoing)?.contains("still going") == true)
        #expect(LidarrDownloadsCopy.confirmButton(.foreign) == "Restart anyway")
        #expect(LidarrDownloadsCopy.confirmButton(.stillGoing) == "Restart")
        #expect(LidarrDownloadsCopy.includeForeign(1) == "Also restart 1 started by another app")
        #expect(LidarrDownloadsCopy.includeForeign(3) == "Also restart 3 started by another app")
        #expect(LidarrDownloadsCopy.confirmMessage(3, foreign: 2).contains("unless you include them"))
        #expect(!LidarrDownloadsCopy.confirmMessage(3).contains("another app"))
        #expect(!LidarrDownloadsCopy.notStartedFooter.contains("leaves them alone"))
        #expect(!LidarrDownloadsCopy.couldntImportFooter.contains("leaves them alone"))
        for text in [LidarrDownloadsCopy.confirmOne(.foreign), LidarrDownloadsCopy.confirmOne(.stillGoing),
                     LidarrDownloadsCopy.confirmMessage(3, foreign: 2)].compactMap({ $0 }) {
            #expect(!text.lowercased().contains("blocklist") && !text.contains("Lidarr"), "\(text)")
        }
    }

    /// Z4 fix M1–M3, M5: the outcome of a removal with nothing to look for; Restart all's cap goes to Lidarr's own first
    /// and the second button says how many of another app's it will take; its wording when it's the only choice; a
    /// paused, waiting or unreachable copy's confirmation says what it's doing.
    @Test func restartAnythingReviewFixes() {
        #expect(LidarrDownloadsCopy.summary([.removedNothingToLookFor]) == "Removed. There was no album to look for.")
        #expect(LidarrDownloadsCopy.summary([.restarted, .removedNothingToLookFor])
                == "Restarted 1. Removed 1; there was no album to look for.")
        #expect(LidarrDownloadsCopy.foreignBatch(own: 0, foreign: 30) == 25)
        #expect(LidarrDownloadsCopy.foreignBatch(own: 20, foreign: 10) == 5)
        #expect(LidarrDownloadsCopy.foreignBatch(own: 25, foreign: 4) == 0)
        #expect(LidarrDownloadsCopy.foreignBatch(own: 40, foreign: 4) == 0)
        #expect(LidarrDownloadsCopy.includeForeign(3, alone: true) == "Restart 3 started by another app")
        #expect(LidarrDownloadsCopy.includeForeign(1, alone: true) == "Restart 1 started by another app")
        #expect(LidarrDownloadsCopy.includeForeign(3) == "Also restart 3 started by another app")
        #expect(LidarrDownloadsCopy.confirmOne(.stillGoing, phase: .downloading)?.contains("still going") == true)
        let paused = LidarrDownloadsCopy.confirmOne(.stillGoing, phase: .paused)
        #expect(paused?.hasPrefix("Paused.") == true && paused?.contains("still going") == false)
        #expect(LidarrDownloadsCopy.confirmOne(.stillGoing, phase: .queued)?.hasPrefix("Waiting to start.") == true)
        #expect(LidarrDownloadsCopy.confirmOne(.stillGoing, phase: .clientUnavailable)?
                    .hasPrefix("Can't reach the download app.") == true)
        #expect(LidarrDownloadsCopy.confirmOne(.foreign, phase: .paused) == LidarrDownloadsCopy.foreignConfirm)
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
