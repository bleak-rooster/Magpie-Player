import Foundation
import MagpieCore
import Observation
import Playback
import UIKit

/// Bytes so far and bytes expected for a running download (P1, Downloading now).
struct DownloadProgress: Equatable {
    var received: Int64
    /// Nil when the server didn't say.
    var expected: Int64?

    var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

/// One row of Downloading now: a manual download running, waiting or failed.
struct DownloadActivityItem: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Its progress is read per row from `DownloadManager.progress` (review M4: a tick doesn't rebuild the list).
        case running
        /// Queued behind the others ("Waiting to start"), paused, waiting for Wi-Fi or a connection, or full.
        case waiting(DownloadStatus)
        case paused
        case queued
        case failed
    }

    let id: UUID
    let metadata: AudioMetadata
    let reason: DownloadReason
    let phase: Phase
    /// R1: what a stopped download already has, when it can resume from there.
    var partial: DownloadProgress?

    var text: String {
        switch phase {
        case .running: "Downloading"
        case let .waiting(status): status.text
        case .paused: partial.map(DownloadActivityCopy.paused) ?? "Paused"
        case .queued: "Waiting to start"
        case .failed: DownloadStatus.failed.text
        }
    }

    var symbol: String {
        switch phase {
        case .running: DownloadStatus.downloading(done: 0, total: 1).symbol
        case let .waiting(status): status.symbol
        case .paused: "pause.circle"
        case .queued: "clock"
        case .failed: DownloadStatus.failed.symbol
        }
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var isFailed: Bool { phase == .failed }
}

/// Holds `UIApplication.isIdleTimerDisabled` on while asked, and puts back what it was after (P1, "Keep screen on
/// while downloading"). Tests inject the getter and setter.
@MainActor
final class IdleTimerHold {
    private let read: @MainActor () -> Bool
    private let write: @MainActor (Bool) -> Void
    /// What the idle timer was before the hold; nil while not holding.
    private var saved: Bool?

    init(read: @escaping @MainActor () -> Bool = { UIApplication.shared.isIdleTimerDisabled },
         write: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.read = read
        self.write = write
    }

    var isHolding: Bool { saved != nil }

    func update(hold: Bool) {
        if hold, saved == nil {
            saved = read()
            write(true)
        } else if !hold, let saved {
            self.saved = nil
            write(saved)
        }
    }
}

/// Downloading now (P1): what is running, waiting and failed, with Cancel, Try again, Pause all and Cancel all, and
/// the foreground-only rule (downloads wait while Magpie is in the background) when "Download in the background" is
/// off (R1).
extension DownloadManager {
    /// Work that needs the network doesn't start: paused, or Magpie is in the background with "Download in the
    /// background" off.
    var isHeld: Bool { isPaused || (isInBackground && !preferencesNow.downloadInBackground) }

    /// Running downloads first, then waiting ones, then failed ones. Pre-downloads and re-downloads aren't listed.
    var activity: [DownloadActivityItem] {
        var running: [DownloadActivityItem] = [], waiting: [DownloadActivityItem] = []
        for job in jobs {
            guard case let .download(reason) = job.kind else { continue }
            let phase: DownloadActivityItem.Phase = switch job.state {
            case .running: .running
            case .waiting: .waiting(waitingStatus)
            case .queued, .blocked: isHeld ? .paused : .queued
            }
            let item = DownloadActivityItem(id: job.id, metadata: job.metadata, reason: reason, phase: phase,
                                            partial: partialProgress[job.id])
            if item.isRunning { running.append(item) } else { waiting.append(item) }
        }
        for job in stoppedByFull {
            guard case let .download(reason) = job.kind else { continue }
            waiting.append(DownloadActivityItem(id: job.id, metadata: job.metadata, reason: reason, phase: .waiting(.full)))
        }
        let failures = failed.compactMap { job -> DownloadActivityItem? in
            guard case let .download(reason) = job.kind else { return nil }
            return DownloadActivityItem(id: job.id, metadata: job.metadata, reason: reason, phase: .failed)
        }
        return running + waiting + failures
    }

    /// How many rows Downloading now has, without building them or reading progress (the Settings row and the
    /// Library banner re-render only when a row comes or goes).
    var activityCount: Int {
        func isDownload(_ job: Job) -> Bool { if case .download = job.kind { true } else { false } }
        return jobs.count(where: isDownload) + stoppedByFull.count(where: isDownload) + failed.count(where: isDownload)
    }

    /// Manual downloads still to finish (running or waiting to run): the "Keep Magpie open" banner shows while true.
    var hasActiveDownloads: Bool { jobs.contains { $0.isManual } }

    /// Whether a manual download is fetching right now.
    var isDownloading: Bool { jobs.contains { $0.isManual && $0.isRunning } }

    // MARK: - Actions

    /// A row's Cancel: the song stops downloading for the reason it was asked for.
    func cancel(_ item: DownloadActivityItem) async {
        await remove(item.reason, songIds: [item.metadata.songId])
    }

    /// A failed row's Try again: that download alone is queued again.
    func retry(_ item: DownloadActivityItem) {
        guard let i = failed.firstIndex(where: { $0.id == item.id }) else { return }
        var job = failed.remove(at: i)
        job.state = .queued
        job.needsNetwork = true
        job.connectionAttempts = 0
        jobs.append(job)
        savePending()
        pump()
    }

    /// Cancel all (confirmed first): every download running, waiting or failed stops. What already arrived stays.
    func cancelAllActive() async {
        var byReason: [DownloadReason: [String]] = [:]
        for job in jobs + stoppedByFull + failed {
            guard case let .download(reason) = job.kind else { continue }
            byReason[reason, default: []].append(job.songId)
        }
        for (reason, songIds) in byReason.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            await remove(reason, songIds: songIds)
        }
    }

    /// Pause all: running downloads go back to the queue (no attempt counted) and nothing new starts.
    func pauseAll() {
        isPaused = true
        holdNetworkWork()
    }

    func resumeAll() {
        isPaused = false
        fetchCovers()
        pump()
    }

    /// The scene phase. With "Download in the background" on (R1) nothing stops, and every queued download is handed
    /// to the background session. Off (P1, foreground only): in the background, downloads and pre-downloads fetching go
    /// back to the queue without counting an attempt; they start again on return. Playback is untouched.
    func setPresence(active: Bool, background: Bool) {
        isAppActive = active
        guard background != isInBackground else { return }
        isInBackground = background
        if background, isHeld {
            holdNetworkWork()
        } else {
            fetchCovers()
            pump()
        }
    }

    /// Fetches in flight are cancelled back to queued: their run sees it is no longer current and drops its result
    /// without failing (`fail` is never reached, so no attempt counts). Jobs whose bytes are here finish storing.
    private func holdNetworkWork() {
        for i in jobs.indices where jobs[i].needsNetwork {
            guard case let .running(run) = jobs[i].state else { continue }
            jobs[i].state = .queued
            progress[jobs[i].id] = nil
            tasks[run]?.cancel()
        }
        pump()
    }

    /// Progress from the fetcher, for the run still current only.
    func noteProgress(_ id: UUID, _ run: UUID, received: Int64, expected: Int64) {
        guard isCurrent(id, run) else { return }
        let value = DownloadProgress(received: received, expected: expected > 0 ? expected : nil)
        if progress[id] != value { progress[id] = value }
    }

    // MARK: - Keep screen on

    /// Whether the idle timer should be held off: the setting is on, a download is fetching, and Magpie is open.
    var holdsScreenOn: Bool { preferencesNow.keepScreenOn && isDownloading && isAppActive && !isInBackground }

    /// Follows `holdsScreenOn` for as long as the manager runs.
    func watchKeepAwake() {
        keepAwakeWatch?.cancel()
        keepAwakeWatch = Task { [weak self] in
            let holds = Observations { @MainActor [weak self] in self?.holdsScreenOn ?? false }
            for await hold in holds {
                guard let self, !Task.isCancelled else { return }
                self.idleTimer.update(hold: hold)
            }
        }
    }

    /// The manager stops (sign-out): the idle timer goes back to what it was.
    func releaseKeepAwake() {
        keepAwakeWatch?.cancel()
        keepAwakeWatch = nil
        idleTimer.update(hold: false)
    }
}
