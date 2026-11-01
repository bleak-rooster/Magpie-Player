import Foundation
import MagpieCore
import Playback

/// R1: downloads that go on in the background and resume part-way. The partials live in the store's `partials`
/// folder, one key per song and quality; every job running, waiting, failed or stopped by "Downloads are full" keeps
/// its key, and anything else is removed (cancel, remove, sign-out, a relaunch).
extension DownloadManager {
    /// The scope the store belongs to (the app's own hex id): background tasks are named with it.
    var scope: String { store.directory.lastPathComponent }

    func fetchJob(_ job: Job) -> FetchJob {
        FetchJob(scope: scope, key: PartialDownloads.key(songId: job.songId, quality: job.quality),
                 isOriginal: job.quality == .original)
    }

    /// How many runs at once: P1's 1–6 while Magpie is open. In the background with "Download in the background" on,
    /// every queued download is handed to the session at once, since Magpie may not run again until they're done; the
    /// session runs `BackgroundAudioFetcher.maxConnections` at a time.
    func runCap(_ prefs: DownloadPreferences) -> Int {
        isInBackground && prefs.downloadInBackground ? .max : prefs.concurrent
    }

    /// The keys of every job Magpie still means to finish.
    private var liveKeys: Set<String> {
        Set((jobs + stoppedByFull + failed).map { PartialDownloads.key(songId: $0.songId, quality: $0.quality) })
    }

    /// Partials (and background tasks) no job wants any more go: a cancelled download leaves nothing behind.
    func prunePartials() {
        let keys = liveKeys
        if let backgroundFetcher {
            backgroundFetcher.retain(keys, scope: scope, partials: store.partialsDirectory)
        } else {
            PartialDownloads(directory: store.partialsDirectory).retain(only: keys)
        }
    }

    /// At start (a relaunch): the background tasks the system kept are taken up, and partials of jobs that weren't
    /// kept (pre-downloads, a download removed meanwhile) go. Not while `pending.json` is unread: its jobs aren't known.
    func reconcilePartials() async {
        guard !pendingUnread else { return }
        let keys = liveKeys
        if let backgroundFetcher {
            await backgroundFetcher.reconcile(keys, scope: scope, partials: store.partialsDirectory)
        } else {
            PartialDownloads(directory: store.partialsDirectory).retain(only: keys)
        }
        refreshPartials()
    }

    /// A run ended: what it left part-way shows on its row while it waits ("Paused · 2.1 of 8.4 MB").
    func notePartial(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else {
            if partialProgress[id] != nil { partialProgress[id] = nil }
            return
        }
        let value = PartialDownloads(directory: store.partialsDirectory)
            .progress(PartialDownloads.key(songId: job.songId, quality: job.quality))
            .map { DownloadProgress(received: $0.received, expected: $0.expected) }
        if partialProgress[id] != value { partialProgress[id] = value }
    }

    func refreshPartials() {
        for job in jobs { notePartial(job.id) }
    }

    /// A background launch's events are in: the files they delivered are stored before the system is told (at most
    /// `timeout`; a run still waiting on the network isn't waited for).
    func deliveriesSettled(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        try? await Task.sleep(for: .milliseconds(300))   // the delivered fetches resume first
        while storing > 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// "Keep Magpie open to finish downloading" shows only with "Download in the background" off (P1's rule).
    var showsKeepOpen: Bool { hasActiveDownloads && !preferencesNow.downloadInBackground }

    /// A download setting changed (mobile data, background): manual work that may no longer use the network stops
    /// keeping what it has, and a request made under the old rule isn't resumed under the new one.
    func downloadSettingsChanged() { networkChanged() }
}
