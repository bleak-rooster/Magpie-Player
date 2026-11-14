import Foundation
import MagpieCore
import Observation
import Playback

/// Local files first, pre-download and cache upkeep (spec §6, Task 13). The player streams a song from the phone
/// whenever it is there (`NavidromeStreamURLs` reads `localFiles`); this keeps the next songs there.
extension AppModel {
    /// The cache's size limit in bytes (tests override it).
    var cacheLimitBytes: Int64 { cacheLimitOverride ?? preferences.downloads.cacheLimit.bytes }

    /// What the watcher acts on: the current entry, the engine's window after it, and the settings it uses.
    struct PreDownloadSnapshot: Equatable, Sendable {
        var current: QueueEntry?
        var upcoming: [QueueEntry]
        var count: Int
        var keepRecentlyPlayed: Bool
        var cacheLimit: CacheLimit
        /// Round 27 P (D280): how pre-downloads run alongside the song playing now.
        var pacing: PreDownloadPacing = .normal
    }

    /// Round 27 P (owner item 11, 2026-11-14, D280): pre-downloads give way to a converted stream on mobile data, which
    /// otherwise shared the link with up to three other transfers (and the server with as many conversions) from its
    /// first second.
    enum PreDownloadPacing: Equatable, Sendable {
        /// Wi-Fi, or the song plays from the phone or as the original: as before (`concurrent` at once).
        case normal
        /// A converted song's first 15 s on mobile data: none start.
        case hold
        /// After those 15 s (or once a shorter song ends): one at a time.
        case oneAtATime
    }

    /// How long a converted song on mobile data plays before the first pre-download starts.
    static let preDownloadGrace: TimeInterval = 15

    /// The pacing for a song playing from `currentURL` at `position` (`ended`: it played to its end) over `status`.
    /// Mobile data counts Low Data Mode, as the stream quality does.
    static func preDownloadPacing(currentURL: URL?, status: NetworkStatus, position: TimeInterval, ended: Bool)
        -> PreDownloadPacing {
        guard let currentURL, status.isCellular || status.isConstrained, !currentURL.isFileURL,
              currentURL.scheme == "http" || currentURL.scheme == "https",
              !NavidromeStreamURLs.isOriginalStream(currentURL) else { return .normal }
        return ended || position >= preDownloadGrace ? .oneAtATime : .hold
    }

    /// How many pre-downloads the manager may run at once under `pacing` (`DownloadManager.cacheRunCap`). The whole
    /// plan is still handed over: the manager starts the first it accepts, and any job ending (landed or failed) lets
    /// the next one start (fix round 1, I1).
    static func cacheRunCap(_ pacing: PreDownloadPacing) -> Int? {
        switch pacing {
        case .normal: nil
        case .hold: 0
        case .oneAtATime: 1
        }
    }

    /// The pacing now. Reads the position only for a converted stream on mobile data, and only until the grace has
    /// passed for this entry (fix round 1, M5): after that the watcher isn't woken by every tick.
    private var currentPreDownloadPacing: PreDownloadPacing {
        let status = network.status
        guard status.isCellular || status.isConstrained, let url = player.currentURL else { return .normal }
        _ = player.lastFallbackSongId   // a switch to the original changes the URL: look again
        let past = Self.preDownloadPacing(currentURL: url, status: status, position: Self.preDownloadGrace, ended: true)
        if past == .oneAtATime, let last = preDownloadSnapshot, last.pacing == .oneAtATime,
           last.current?.id == player.queue.current?.id {
            return .oneAtATime   // already past the grace for this entry: no need to read the position again
        }
        return Self.preDownloadPacing(currentURL: url, status: status, position: player.position, ended: player.hasEnded)
    }

    /// Engine window (QC): the engine is handed as many upcoming songs as are pre-downloaded, at least its own 3 and
    /// at most 10, so a song is decided local or streamed as it enters the window.
    func applyEngineWindow() {
        let k = EngineWindow.size(preDownload: preferences.downloads.preDownload)
        guard k != player.lookahead else { return }
        player.lookahead = k
        player.upcomingURLsChanged()
    }

    /// Watches the queue for this session's manager. On each change of the current song or the songs after it:
    /// pre-download the next ones not on the phone, mark the current one played, drop the songs just played from the
    /// cache when "Keep recently played" is off, and evict the cache down to its limit (never the current song or
    /// the window after it). Finds are pre-downloaded like any song.
    func watchQueueForPreDownload() {
        preDownloadWatch?.cancel()
        guard let manager = downloads else { return }
        preDownloadWatch = Task { [weak self, player] in
            let snapshots = Observations { @MainActor [weak self] in
                let prefs = self?.preferences.downloads ?? .defaultValue
                return PreDownloadSnapshot(current: player.queue.current,
                                           upcoming: player.queue.upcoming(limit: max(player.lookahead, prefs.preDownload)),
                                           count: prefs.preDownload, keepRecentlyPlayed: prefs.keepRecentlyPlayed,
                                           cacheLimit: prefs.cacheLimit,
                                           pacing: self?.currentPreDownloadPacing ?? .normal)   // R27 P (D280)
            }
            var previous: PreDownloadSnapshot?
            for await snapshot in snapshots where snapshot != previous {
                guard let self, self.downloads === manager else { return }
                self.queueChanged(snapshot, previous: previous, manager: manager)
                previous = snapshot
                self.preDownloadSnapshot = snapshot
            }
        }
    }

    /// A pre-download landed: once they pause for `cacheEvictionDebounce`, evict the cache down to its limit, so it
    /// can't stay over it until the next song change.
    func preDownloadLanded() {
        guard let manager = downloads else { return }
        cacheEviction?.cancel()
        let delay = cacheEvictionDebounce
        cacheEviction = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.downloads === manager else { return }
            self.runCacheUpkeep(manager: manager, markPlayed: nil, gone: [], protecting: [])
        }
    }

    private func queueChanged(_ snapshot: PreDownloadSnapshot, previous: PreDownloadSnapshot?, manager: DownloadManager) {
        let plan = PreDownloadPlan.songs(upcoming: snapshot.upcoming.map(\.song), count: snapshot.count,
                                         isLocal: { manager.localFiles[$0] != nil })
        // R27 P (D280): set before the plan, which pumps under it (setting the cap alone starts nothing, N1).
        manager.cacheRunCap = Self.cacheRunCap(snapshot.pacing)
        manager.preDownload(isOffline ? [] : plan, quality: currentStreamQuality)   // offline: nothing to fetch from

        let current = snapshot.current?.song.id
        let currentChanged = snapshot.current?.id != previous?.current?.id
        let protecting = Set([current].compactMap { $0 } + snapshot.upcoming.map(\.song.id))
        let played = previous.map { Self.songsPlayed(from: $0, to: snapshot) } ?? []
        // Offline nothing leaves the cache: it can't come back until the server does.
        let gone = snapshot.keepRecentlyPlayed || isOffline ? [] : played.subtracting(protecting)
        runCacheUpkeep(manager: manager, markPlayed: currentChanged ? current : nil, gone: gone, protecting: protecting)
        cacheQualityQueueChanged(current: current, currentChanged: currentChanged, manager: manager)   // round 13 item 7
    }

    /// Marks `markPlayed` played, drops `gone` from the cache, and evicts the cache to its limit. Upkeeps run one after
    /// another; each removal spares `protecting` and what playback holds at that moment (the current song and the
    /// engine's window), since a new queue may have started while this one waited. Store writes throw `notReady`
    /// before first unlock: upkeep then waits for the next change.
    private func runCacheUpkeep(manager: DownloadManager, markPlayed: String?, gone: Set<String>, protecting: Set<String>) {
        let prior = cacheUpkeep
        cacheUpkeep = Task { [weak self, player, store = manager.store] in
            await prior?.value
            @MainActor func live() -> Bool {
                guard !Task.isCancelled, let self else { return false }
                return self.downloads === manager
            }
            #if DEBUG
            if let hook = self?.beforeCacheUpkeepForTesting { await hook() }
            #endif
            guard live() else { return }
            let spared: @Sendable () async -> Set<String> = { @MainActor in protecting.union(player.windowSongIds) }
            if let markPlayed { try? await store.markPlayed(songId: markPlayed) }
            var removed: [String] = []
            if !gone.isEmpty, live() { removed += (try? await store.removeCache(songIds: gone, sparing: spared)) ?? [] }
            let limit = self?.cacheLimitBytes ?? 0
            if live() { removed += (try? await store.evictCache(limit: limit, protecting: spared)) ?? [] }
            if !removed.isEmpty, live() { await manager.refresh() }
        }
    }

    /// The songs that stopped being current between two snapshots: the old current one, and those skipped over on the
    /// way to the new one when several changes arrived together. None while the current entry is the same.
    static func songsPlayed(from old: PreDownloadSnapshot, to new: PreDownloadSnapshot) -> Set<String> {
        guard let was = old.current, was.id != new.current?.id else { return [] }
        let skipped = new.current.flatMap { now in old.upcoming.firstIndex { $0.id == now.id } }
            .map { old.upcoming[..<$0].map(\.song.id) } ?? []
        return Set([was.song.id] + skipped)
    }
}
