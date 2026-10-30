import Foundation
import MagpieCore
import Playback

/// Removing downloads, clearing the cache, and keeping the queued manual downloads in `pending.json`.
extension DownloadManager {
    /// Drops `reason` (and its queued, failed or full jobs); songs left with no reason are deleted.
    func remove(_ reason: DownloadReason) async {
        await remove(Removal(reason: reason, songIds: nil))
    }

    /// Drops `reason` from `songIds` only (a song gone from a downloaded playlist, or no longer a favourite).
    func remove(_ reason: DownloadReason, songIds: [String]) async {
        guard !songIds.isEmpty else { return }
        await remove(Removal(reason: reason, songIds: songIds))
    }

    /// A song's "Remove from this phone": every reason it's kept for goes, so it leaves the phone.
    func remove(songIds: Set<String>) async {
        var reasons: [DownloadReason] = []
        for id in songIds {
            for reason in await store.entry(songId: id)?.reasons ?? [] where !reasons.contains(reason) { reasons.append(reason) }
        }
        for job in jobs + stoppedByFull + failed where songIds.contains(job.songId) {
            if case let .download(reason) = job.kind, !reasons.contains(reason) { reasons.append(reason) }
        }
        for reason in reasons { await remove(reason, songIds: Array(songIds)) }
    }

    /// Only the jobs the removal names go, "Downloads are full" ones included. Other full jobs stay stopped, and are
    /// queued again only when the removal deleted songs (it freed room).
    private func remove(_ removal: Removal) async {
        if pendingUnread { removalsWhileUnread.append(removal) }   // also for the downloads pending.json holds
        let only = removal.songIds.map(Set.init)
        func matches(_ job: Job) -> Bool { job.kind == .download(removal.reason) && only?.contains(job.songId) != false }
        cancelRunning(where: matches)
        jobs.removeAll(where: matches)
        failed.removeAll(where: matches)
        stoppedByFull.removeAll(where: matches)
        if removal.songIds == nil, case let .playlist(id) = removal.reason { deferredPlaylists.removeAll { $0.id == id } }
        savePending()
        prunePartials()   // R1: a cancelled download leaves nothing part-way behind
        let freed = await applyRemoval(removal)
        await refresh()
        if freed { requeueStoppedByFull() }
        pump()
    }

    /// True when songs were deleted. A store that isn't ready yet holds the removal back (`resumeStoreWork`).
    @discardableResult
    func applyRemoval(_ removal: Removal) async -> Bool {
        do {
            let deleted = try await store.removeReason(removal.reason, songIds: removal.songIds)
            if removal.songIds == nil, case let .playlist(id) = removal.reason { try await store.removePlaylist(id: id) }
            return !deleted.isEmpty
        } catch {
            if !deferredRemovals.contains(removal) { deferredRemovals.append(removal) }
            blockedOnStore()
            return false
        }
    }

    /// Jobs stopped by "Downloads are full" are queued again (they stop again if there's still no room).
    func requeueStoppedByFull() {
        guard !stoppedByFull.isEmpty else { return }
        for var job in stoppedByFull {
            job.state = .queued
            job.needsNetwork = true
            jobs.append(job)
        }
        stoppedByFull = []
        savePending()
    }

    /// "Remove all downloads": every download (and re-download) stops, and every download goes with its playlists
    /// and covers. The cache stays. A store that isn't ready yet keeps them (the owner can try again).
    func removeAllDownloads() async {
        cancelRunning { $0.kind != .cache }
        jobs.removeAll { $0.kind != .cache }
        failed = []
        stoppedByFull = []
        pendingCovers = []
        deferredRemovals = []
        deferredPlaylists = []
        discardUnreadPending()
        savePending()
        prunePartials()
        do {
            try await store.removeAll(kind: .download)
        } catch {
            Log.logger("downloads").error("remove all failed: \(Log.category(of: error), privacy: .public)")
        }
        await refresh()
        pump()
    }

    /// "Clear cache": pre-downloads stop and every cached song goes. Downloads stay.
    func clearCache() async {
        cancelRunning { $0.kind == .cache }
        jobs.removeAll { $0.kind == .cache }
        prunePartials()
        do {
            try await store.removeAll(kind: .cache)
        } catch {
            Log.logger("downloads").error("clear cache failed: \(Log.category(of: error), privacy: .public)")
        }
        await refresh()
        pump()
    }

    /// Cancels the runs of the jobs that match; their results are then thrown away (`isCurrent`).
    func cancelRunning(where match: (Job) -> Bool) {
        for job in jobs where match(job) {
            if case let .running(run) = job.state { tasks[run]?.cancel() }
        }
    }

    // MARK: - pending.json

    /// Writes the queued and full manual downloads (ids, reason and quality: never a URL), or removes the file
    /// when there are none.
    func savePending() {
        guard isStarted else { return }   // the scope may still be being erased: `start` saves them
        if pendingUnread { loadPending() }
        guard !pendingUnread else { return }   // never written over before it has been read
        func pendingJob(_ job: Job, full: Bool) -> PendingJob? {
            guard case let .download(reason) = job.kind else { return nil }
            return PendingJob(metadata: job.metadata, reason: reason, quality: job.quality, playlistId: job.playlistId,
                              full: full ? true : nil)
        }
        let pending = jobs.compactMap { pendingJob($0, full: false) } + stoppedByFull.compactMap { pendingJob($0, full: true) }
        guard pending != savedPending else { return }
        savedPending = pending
        let url = pendingURL
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try AtomicFile.write(pending, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = url, directory = storeDirectory
            try file.setResourceValues(values)
            try directory.setResourceValues(values)
        } catch {
            Log.logger("downloads").error("cannot save queued downloads: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// Reads `pending.json` and queues its downloads (not ones a removal took meanwhile). A file that doesn't decode is
    /// ignored; one that can't be read yet is left alone (`pendingUnread`) and read again on the next save.
    func loadPending() {
        let url = pendingURL
        let data: Data
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { pendingUnread = false; return }
            data = try Data(contentsOf: url)
        } catch {
            if !pendingUnread {
                Log.logger("downloads").error("queued downloads not readable yet: \(Log.category(of: error), privacy: .public)")
            }
            pendingUnread = true
            return
        }
        pendingUnread = false
        let removals = removalsWhileUnread
        removalsWhileUnread = []
        guard let saved = try? JSONDecoder().decode([PendingJob].self, from: data) else { return }
        savedPending = saved
        for item in saved {
            let id = item.metadata.songId
            guard !removals.contains(where: { $0.reason == item.reason && $0.songIds?.contains(id) != false }),
                  !(jobs + stoppedByFull).contains(where: { $0.songId == id && $0.kind == .download(item.reason) })
            else { continue }
            let job = Job(kind: .download(item.reason), metadata: item.metadata, quality: item.quality,
                          playlistId: item.playlistId)
            if item.full == true { stoppedByFull.append(job) } else { jobs.append(job) }
        }
    }

    /// Every queued download goes (remove all, sign-out): an unread `pending.json` no longer needs reading first.
    func discardUnreadPending() {
        pendingUnread = false
        removalsWhileUnread = []
    }
}
