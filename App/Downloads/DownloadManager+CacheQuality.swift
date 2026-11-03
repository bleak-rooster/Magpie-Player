import Foundation
import MagpieCore
import Playback

/// Round 13 item 7 (D64): the one cache replacement under way. At most one is fetching or held at a time.
struct CacheRefreshState {
    struct Fetch {
        let songId: String
        let from: StreamQuality
        let target: StreamQuality
        /// The task's key in `tasks`, to cancel it by.
        var task: UUID?
    }

    struct Held {
        let songId: String
        let from: StreamQuality
        let target: StreamQuality
        let file: URL
        let fileExtension: String
    }

    var fetch: Fetch?
    var held: Held?
    /// `songId|target` tried this session (it failed, or wasn't a file to keep): never fetched again, so a song the
    /// server can't convert doesn't loop. A fetch stopped by the network or a new target may go again.
    var tried: Set<String> = []
}

/// Round 13 item 7 (D64): a song played from the cache at a quality other than the current network's target is
/// fetched again at the target, in the background, and swapped in on its next play.
///
/// - Only the cache: a download keeps the quality it was saved in (checked again by the store at the swap).
/// - Never mid-song: the new copy is held while playback holds the song (`isSongInUse`), and swapped in after.
/// - Never on mobile data when mobile downloads are off, never offline, never while downloads are paused or held in
///   the background. A network or target change stops a fetch the new conditions don't want.
/// - One at a time: while one is fetching or held, another mismatch waits for its own next play.
/// - The old file goes only after the new one is verified (audio, an allowed format, AVFoundation opens it) and
///   stored (`AudioStore.replaceCache`).
extension DownloadManager {
    /// The song whose replacement is fetching (tests, diagnostics).
    var cacheRefreshSongId: String? { cacheRefresh.fetch?.songId }
    /// The song whose replacement waits to be swapped in.
    var pendingCacheSwapSongId: String? { cacheRefresh.held?.songId }

    static func cacheRefreshKey(_ songId: String, _ target: StreamQuality) -> String { songId + "|" + target.rawValue }

    /// The app calls this as a song starts playing (and when the target changes while it plays). Fetches the song
    /// again at `target` when its stored copy is a cached one at another quality and the network allows it.
    func refreshCacheQuality(songId: String, target: StreamQuality) {
        guard isStarted, cacheRefresh.fetch == nil, cacheRefresh.held == nil else { return }
        guard kind(of: songId) == .cache, let from = localQualities[songId], from != target else { return }
        let key = Self.cacheRefreshKey(songId, target)
        guard !cacheRefresh.tried.contains(key), manualAllowed(preferencesNow), !isHeld else { return }
        // A download or pre-download of this song under way goes first.
        guard !activeRuns.values.contains(songId), !jobs.contains(where: { $0.songId == songId }) else { return }
        cacheRefresh.tried.insert(key)
        cacheRefresh.fetch = .init(songId: songId, from: from, target: target)
        let task = track { [weak self] gen in await self?.runCacheRefresh(songId: songId, from: from, target: target, gen) }
        if cacheRefresh.fetch?.songId == songId { cacheRefresh.fetch?.task = task }
    }

    /// The app calls this on each queue change: a held copy is swapped in once playback no longer holds its song,
    /// and dropped if it isn't at `target` any more.
    func applyCacheSwap(target: StreamQuality) {
        guard let held = cacheRefresh.held else { return }
        guard held.target == target else { dropHeldCacheCopy(); return }
        guard !isSongInUse(held.songId) else { return }
        cacheRefresh.held = nil
        track { [weak self, store] gen in
            guard let self, self.isLive(gen) else { try? FileManager.default.removeItem(at: held.file); return }
            do {
                try await store.replaceCache(songId: held.songId, from: held.from, with: held.file,
                                             quality: held.target, fileExtension: held.fileExtension)
            } catch {
                try? FileManager.default.removeItem(at: held.file)
                Log.logger("downloads").error("cache swap failed: \(Log.category(of: error), privacy: .public)")
                return
            }
            guard self.isLive(gen) else { return }
            await self.refresh()
        }
    }

    /// The target quality changed (network, settings): a fetch or a held copy for another target goes.
    func cacheTargetChanged(_ target: StreamQuality) {
        if let fetch = cacheRefresh.fetch, fetch.target != target { stopCacheFetch() }
        if let held = cacheRefresh.held, held.target != target { dropHeldCacheCopy() }
    }

    /// The network changed: a fetch the network no longer allows stops (it may go again on a later play).
    func stopCacheRefreshIfNotAllowed() {
        guard cacheRefresh.fetch != nil, !manualAllowed(preferencesNow) else { return }
        stopCacheFetch()
    }

    /// Sign-out, Clear cache: nothing fetching or held is kept.
    func dropCacheRefresh() {
        stopCacheFetch()
        dropHeldCacheCopy()
    }

    // MARK: - Private

    private func stopCacheFetch() {
        guard let fetch = cacheRefresh.fetch else { return }
        cacheRefresh.fetch = nil
        cacheRefresh.tried.remove(Self.cacheRefreshKey(fetch.songId, fetch.target))
        if let task = fetch.task { tasks[task]?.cancel() }
    }

    private func dropHeldCacheCopy() {
        guard let held = cacheRefresh.held else { return }
        cacheRefresh.held = nil
        try? FileManager.default.removeItem(at: held.file)
    }

    /// Whether `songId`'s fetch is still the one wanted (not stopped, replaced or signed out).
    private func isCurrentCacheRefresh(_ songId: String, _ target: StreamQuality, _ gen: Int) -> Bool {
        isLive(gen) && !Task.isCancelled && cacheRefresh.fetch?.songId == songId && cacheRefresh.fetch?.target == target
    }

    private func runCacheRefresh(songId: String, from: StreamQuality, target: StreamQuality, _ gen: Int) async {
        defer {
            if isLive(gen), cacheRefresh.fetch?.songId == songId, cacheRefresh.fetch?.target == target {
                cacheRefresh.fetch = nil
            }
        }
        guard let entry = await store.entry(songId: songId), entry.kind == .cache, entry.quality == from,
              isCurrentCacheRefresh(songId, target, gen),
              let source = streamURL(entry.metadata.song, target) else { return }
        let fetched: (file: URL, mimeType: String?)
        do {
            fetched = try await fetcher.fetch(source, allowsCellular: preferencesNow.overMobileData)
        } catch {
            Log.logger("downloads").error("cache refresh failed: \(Log.category(of: error), privacy: .public)")
            return
        }
        let fm = FileManager.default
        guard isCurrentCacheRefresh(songId, target, gen), Self.isAudio(fetched.mimeType),
              let ext = AudioStore.fileExtension(quality: target, suffix: entry.metadata.suffix, mimeType: fetched.mimeType)
        else { try? fm.removeItem(at: fetched.file); return }
        // Named with its format, so AVFoundation can tell what it is, and kept out of the store until the swap.
        let holding = fm.temporaryDirectory.appending(path: "MagpieCacheSwap", directoryHint: .isDirectory)
        let file = holding.appending(path: UUID().uuidString + "." + ext)
        do {
            try fm.createDirectory(at: holding, withIntermediateDirectories: true)
            try fm.moveItem(at: fetched.file, to: file)
        } catch {
            try? fm.removeItem(at: fetched.file)
            return
        }
        guard await Self.isPlayableFile(file, load: loadPlayableForCheck), isCurrentCacheRefresh(songId, target, gen) else {
            try? fm.removeItem(at: file)
            return
        }
        cacheRefresh.fetch = nil
        cacheRefresh.held = .init(songId: songId, from: from, target: target, file: file, fileExtension: ext)
        applyCacheSwap(target: target)
    }
}
