import Foundation
import MagpieCore
import Playback

/// Round 13 item 7 (D70): the one cache replacement under way. At most one is fetching or held at a time.
struct CacheRefreshState {
    struct Fetch {
        /// This fetch's identity (review I1): a stopped fetch's clean-up only ever touches its own state.
        let token: UUID
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
    /// Swapped-out audio still on disk, by song id: removed once playback can't be holding it (review M1).
    var oldFiles: [String: String] = [:]
}

/// Round 13 item 7 (D70): a song played from the cache at a quality other than the current network's target is
/// fetched again at the target, in the background, and swapped in on its next play.
///
/// - Only the cache: a download keeps the quality it was saved in (checked again by the store at the swap).
/// - On mobile data (or Low Data Mode) a copy better than the target plays as it is: only a lower bit rate, or a
///   transcode when the target is the original, is replaced. On Wi-Fi the copy matches the target exactly.
/// - Never mid-song: the new copy is held while playback holds the song (`isSongInUse`), and swapped in after; the
///   old file is removed only once playback can't be holding it.
/// - Never on mobile data when mobile downloads are off, never offline, never while downloads are paused or held in
///   the background. A network or target change stops a fetch the new conditions don't want.
/// - One at a time: while one is fetching or held, another mismatch waits for its own next play.
/// - The old copy goes only after the new one is verified (audio in the format asked for, an allowed extension,
///   AVFoundation confirms it plays) and stored (`AudioStore.replaceCache`).
extension DownloadManager {
    /// The song whose replacement is fetching (tests, diagnostics).
    var cacheRefreshSongId: String? { cacheRefresh.fetch?.songId }
    /// The song whose replacement waits to be swapped in.
    var pendingCacheSwapSongId: String? { cacheRefresh.held?.songId }

    static func cacheRefreshKey(_ songId: String, _ target: StreamQuality) -> String { songId + "|" + target.rawValue }

    /// Where a fetched copy waits for its swap: inside the scope (erased with it), swept at start.
    var cacheSwapDirectory: URL { store.directory.appending(path: "swap", directoryHint: .isDirectory) }

    /// Whether a cached copy at `from` should be replaced by one at `target` (owner ruling, review M4). On mobile data
    /// a better copy is kept: it costs no data and sounds better.
    nonisolated static func wantsReplacement(from: StreamQuality, target: StreamQuality, onMobile: Bool) -> Bool {
        guard from != target else { return false }
        guard onMobile else { return true }
        if target == .original { return true }   // the target needs the original's format
        if from == .original { return false }     // the original beats any transcode
        return (from.maxBitRate ?? 0) < (target.maxBitRate ?? 0)
    }

    /// Whether a response's type fits what was asked for (review M3): a server with transcoding off answers with the
    /// original, which mustn't be kept under the transcode's label. An unnamed type (octet-stream) is let through to
    /// the playable check.
    nonisolated static func bodyFits(_ target: StreamQuality, mimeType: String?) -> Bool {
        guard target != .original, let mime = mimeType?.lowercased() else { return true }
        let format: String? = switch mime {
        case "audio/ogg", "audio/opus": "opus"
        case "audio/aac", "audio/aacp", "audio/mp4", "audio/x-m4a": "aac"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "application/octet-stream": nil
        default: "other"
        }
        return format == nil || format == target.format
    }

    /// The app calls this as a song starts playing (and when the target changes while it plays). Fetches the song
    /// again at `target` when its stored copy is a cached one that should be replaced and the network allows it.
    func refreshCacheQuality(songId: String, target: StreamQuality) {
        guard isStarted, cacheRefresh.fetch == nil, cacheRefresh.held == nil else { return }
        guard kind(of: songId) == .cache, let from = localQualities[songId] else { return }
        let status = network.status
        guard Self.wantsReplacement(from: from, target: target, onMobile: status.isCellular || status.isConstrained)
        else { return }
        let key = Self.cacheRefreshKey(songId, target)
        guard !cacheRefresh.tried.contains(key), manualAllowed(preferencesNow), !isHeld else { return }
        // A download or pre-download of this song under way goes first.
        guard !activeRuns.values.contains(songId), !jobs.contains(where: { $0.songId == songId }) else { return }
        cacheRefresh.tried.insert(key)
        let token = UUID()
        cacheRefresh.fetch = .init(token: token, songId: songId, from: from, target: target)
        let task = track { [weak self] gen in
            await self?.runCacheRefresh(token: token, songId: songId, from: from, target: target, gen)
        }
        if cacheRefresh.fetch?.token == token { cacheRefresh.fetch?.task = task }
    }

    /// The app calls this on each queue change: a held copy is swapped in once playback no longer holds its song,
    /// and dropped if it isn't at `target` any more. Old files playback has let go of are removed.
    func applyCacheSwap(target: StreamQuality) {
        removeReleasedOldFiles()
        guard let held = cacheRefresh.held else { return }
        guard held.target == target else { dropHeldCacheCopy(); return }
        guard !isSongInUse(held.songId) else { return }
        cacheRefresh.held = nil
        track { [weak self, store] gen in
            guard let self, self.isLive(gen) else { try? FileManager.default.removeItem(at: held.file); return }
            let swap: AudioStore.CacheReplacement?
            do {
                swap = try await store.replaceCache(songId: held.songId, from: held.from, with: held.file,
                                                    quality: held.target, fileExtension: held.fileExtension)
            } catch {
                try? FileManager.default.removeItem(at: held.file)
                Log.logger("downloads").error("cache swap failed: \(Log.category(of: error), privacy: .public)")
                return
            }
            guard self.isLive(gen) else { return }
            await self.refresh()   // playback now finds the new copy
            // The song may have entered playback since the check: its old file then stays until it lets go.
            if let old = swap?.oldFileName {
                self.cacheRefresh.oldFiles[held.songId] = old
                self.removeReleasedOldFiles()
            }
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

    /// At start: copies held when Magpie last stopped are gone with it (review M5).
    func sweepCacheSwapDirectory() {
        try? FileManager.default.removeItem(at: cacheSwapDirectory)
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

    private func removeReleasedOldFiles() {
        let released = cacheRefresh.oldFiles.filter { !isSongInUse($0.key) }
        guard !released.isEmpty else { return }
        for id in released.keys { cacheRefresh.oldFiles[id] = nil }
        track { [store] _ in
            for name in released.values { await store.removeUnreferencedAudio(fileName: name) }
        }
    }

    /// Whether the fetch `token` is still the one wanted (not stopped, replaced or signed out).
    private func isCurrentCacheRefresh(_ token: UUID, _ gen: Int) -> Bool {
        isLive(gen) && !Task.isCancelled && cacheRefresh.fetch?.token == token
    }

    private func runCacheRefresh(token: UUID, songId: String, from: StreamQuality, target: StreamQuality,
                                 _ gen: Int) async {
        defer { if isLive(gen), cacheRefresh.fetch?.token == token { cacheRefresh.fetch = nil } }
        guard let entry = await store.entry(songId: songId), entry.kind == .cache, entry.quality == from,
              isCurrentCacheRefresh(token, gen),
              let source = streamURL(entry.metadata.song, target) else { return }
        let fetched: (file: URL, mimeType: String?)
        do {
            fetched = try await fetcher.fetch(source, allowsCellular: preferencesNow.overMobileData)
        } catch {
            Log.logger("downloads").error("cache refresh failed: \(Log.category(of: error), privacy: .public)")
            return
        }
        let fm = FileManager.default
        guard isCurrentCacheRefresh(token, gen), Self.isAudio(fetched.mimeType),
              Self.bodyFits(target, mimeType: fetched.mimeType),
              let ext = AudioStore.fileExtension(quality: target, suffix: entry.metadata.suffix, mimeType: fetched.mimeType)
        else { try? fm.removeItem(at: fetched.file); return }
        // Named with its format, so AVFoundation can tell what it is, and kept out of the index until the swap.
        let holding = cacheSwapDirectory
        let file = holding.appending(path: UUID().uuidString + "." + ext)
        do {
            try fm.createDirectory(at: holding, withIntermediateDirectories: true)
            try fm.moveItem(at: fetched.file, to: file)
        } catch {
            try? fm.removeItem(at: fetched.file)
            return
        }
        guard await Self.isConfirmedPlayable(file, load: loadPlayableForCheck), isCurrentCacheRefresh(token, gen) else {
            try? fm.removeItem(at: file)
            return
        }
        cacheRefresh.fetch = nil
        cacheRefresh.held = .init(songId: songId, from: from, target: target, file: file, fileExtension: ext)
        applyCacheSwap(target: target)
    }

    /// Review M2: the strict check a replacement must pass before an old copy goes. Unlike `isPlayableFile` (which
    /// keeps a file it can't judge), anything short of AVFoundation confirming it plays is a no.
    nonisolated static func isConfirmedPlayable(_ url: URL, load: @Sendable (URL) async throws -> Bool) async -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        let head = try? handle.read(upToCount: 16)
        try? handle.close()
        guard head?.isEmpty == false else { return false }
        return (try? await load(url)) == true
    }
}
