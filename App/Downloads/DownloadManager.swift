import Foundation
import MagpieCore
import Observation
import Playback

/// Runs downloads (kept until removed) and pre-downloads (cache) into the `AudioStore` (spec §6).
///
/// - At most `concurrent` fetches run at once.
/// - Manual downloads wait for Wi-Fi on mobile data unless "Download on mobile data" is on; a manual fetch in
///   flight when the network flips is cancelled and waits again. Pre-downloads never wait.
/// - Queued manual downloads survive a relaunch in `pending.json`: song metadata, reason and quality only. Stream
///   URLs carry Subsonic auth (`u`, `t`, `s`), so they are built at fetch time and never stored or logged.
/// - "Downloads are full" stops every queued manual download; nothing is evicted.
@MainActor @Observable
final class DownloadManager {
    static let coverSize = 600
    static let pendingName = "pending.json"

    /// A queued manual download as kept in `pending.json`.
    struct PendingJob: Codable, Equatable {
        var metadata: AudioMetadata
        var reason: DownloadReason
        var quality: StreamQuality
        var playlistId: String?
    }

    private enum Kind: Equatable { case download(DownloadReason), cache, replace }
    private enum State: Equatable { case queued, running(UUID), waiting }

    private struct Job {
        let id = UUID()
        var kind: Kind
        var metadata: AudioMetadata
        var quality: StreamQuality
        var playlistId: String?
        var state = State.queued

        var songId: String { metadata.songId }
        /// Pre-downloads are the only jobs that never wait for Wi-Fi.
        var isManual: Bool { kind != .cache }
        var isRunning: Bool { if case .running = state { true } else { false } }
    }

    let store: AudioStore
    var storeDirectory: URL { store.directory }
    /// Every stored song (downloads and cache), for playback to prefer over a stream.
    private(set) var localFiles: [String: URL] = [:]
    @ObservationIgnored var onLocalFilesChanged: (@MainActor () -> Void)?

    /// Mirror of the store's kinds, so `status` can answer synchronously.
    private var kinds: [String: AudioKind] = [:]
    private var jobs: [Job] = []
    /// Manual downloads stopped by "Downloads are full": `retryWaiting` queues them again, `remove` drops them.
    private var stoppedByFull: [Job] = []

    @ObservationIgnored private let fetcher: any AudioFetching
    @ObservationIgnored private let network: any NetworkStatusProviding
    @ObservationIgnored private let preferences: @MainActor () -> DownloadPreferences
    @ObservationIgnored private let streamURL: @MainActor (Song, StreamQuality) -> URL?
    @ObservationIgnored private let coverArtURL: @MainActor (String) -> URL?
    @ObservationIgnored private let limitBytes: (DownloadPreferences) -> Int64?
    /// Fetch runs (keyed by run id) and short store tasks; `settled()` waits for all of them.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var networkWatch: Task<Void, Never>?
    /// Covers to fetch once manual downloads may use the network.
    @ObservationIgnored private var pendingCovers: [String] = []
    @ObservationIgnored private var savedPending: [PendingJob] = []

    init(store: AudioStore, fetcher: any AudioFetching, network: any NetworkStatusProviding,
         preferences: @escaping @MainActor () -> DownloadPreferences,
         url: @escaping @MainActor (Song, StreamQuality) -> URL?,
         coverURL: @escaping @MainActor (String) -> URL?,
         limitBytes: @escaping (DownloadPreferences) -> Int64? = { $0.downloadsLimit.bytes }) {
        self.store = store
        self.fetcher = fetcher
        self.network = network
        self.preferences = preferences
        self.streamURL = url
        self.coverArtURL = coverURL
        self.limitBytes = limitBytes
    }

    deinit { networkWatch?.cancel() }

    /// Loads the store, mirrors its files and queues the manual downloads left from the last run.
    func start() async {
        await store.load()
        await refresh()
        if let saved = try? AtomicFile.read([PendingJob].self, from: pendingURL) {
            savedPending = saved
            for item in saved where !jobs.contains(where: { $0.songId == item.metadata.songId && $0.kind == .download(item.reason) }) {
                jobs.append(Job(kind: .download(item.reason), metadata: item.metadata, quality: item.quality,
                                playlistId: item.playlistId))
            }
        }
        networkWatch?.cancel()
        networkWatch = Task { [weak self, network] in
            let statuses = Observations { @MainActor in network.status }
            for await _ in statuses {
                guard let self else { return }
                self.networkChanged()
            }
        }
        pump()
    }

    // MARK: - Requests

    func download(_ songs: [Song], reason: DownloadReason, playlist: DownloadedPlaylist? = nil, coverArtId: String? = nil) {
        if let playlist { track { [store] in await store.savePlaylist(playlist) } }
        if let coverArtId, !pendingCovers.contains(coverArtId) { pendingCovers.append(coverArtId) }
        let quality = preferences().normalised().quality
        // A song already stored still gets a job: it gains the reason without using the network.
        for song in songs {
            guard !jobs.contains(where: { $0.songId == song.id && $0.kind == .download(reason) }) else { continue }
            jobs.append(Job(kind: .download(reason), metadata: AudioMetadata(song), quality: quality,
                            playlistId: playlist?.id))
        }
        savePending()
        fetchCovers()
        pump()
    }

    /// Upcoming songs into the cache at the current network's quality; songs already stored are skipped.
    func preDownload(_ songs: [Song], quality: StreamQuality) {
        for song in songs where kinds[song.id] == nil && !jobs.contains(where: { $0.songId == song.id }) {
            jobs.append(Job(kind: .cache, metadata: AudioMetadata(song), quality: quality))
        }
        pump()
    }

    /// "Re-download at new quality": each stored song is fetched again and swapped in by `AudioStore.replace`.
    func redownload(songIds: [String], quality: StreamQuality) {
        track { [weak self, store] in
            for id in songIds {
                guard let entry = await store.entry(songId: id), let self else { continue }
                guard !self.jobs.contains(where: { $0.songId == id && $0.kind == .replace }) else { continue }
                self.jobs.append(Job(kind: .replace, metadata: entry.metadata, quality: quality))
            }
            self?.pump()
        }
    }

    /// Drops `reason` (and its queued downloads); songs left with no reason are deleted. Clears "Downloads are full".
    func remove(_ reason: DownloadReason) async {
        for job in jobs where job.kind == .download(reason) {
            if case let .running(run) = job.state { tasks[run]?.cancel() }
        }
        jobs.removeAll { $0.kind == .download(reason) }
        stoppedByFull = []
        savePending()
        await store.removeReason(reason)
        if case let .playlist(id) = reason { await store.removePlaylist(id: id) }
        await refresh()
        pump()
    }

    /// Queues again what waits for Wi-Fi and what "Downloads are full" stopped.
    func retryWaiting() {
        for var job in stoppedByFull {
            job.state = .queued
            jobs.append(job)
        }
        stoppedByFull = []
        for i in jobs.indices where jobs[i].state == .waiting { jobs[i].state = .queued }
        savePending()
        fetchCovers()
        pump()
    }

    /// Stops everything (sign-out): fetches are cancelled and nothing queued is kept.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        jobs = []
        stoppedByFull = []
        pendingCovers = []
        savePending()
    }

    // MARK: - Status

    func status(for songIds: [String]) -> DownloadStatus {
        guard !songIds.isEmpty else { return .none }
        let ids = Set(songIds)
        let done = songIds.filter { kinds[$0] == .download }.count
        if done == songIds.count { return .downloaded }
        if stoppedByFull.contains(where: { ids.contains($0.songId) }) { return .full }
        let active = jobs.filter { $0.isManual && ids.contains($0.songId) }
        if active.contains(where: { $0.state == .waiting }) { return .waitingForWiFi }
        if !active.isEmpty { return .downloading(done: done, total: songIds.count) }
        return .none
    }

    /// Tests: returns once every queued job has finished, failed or is waiting.
    func settled() async {
        while let task = tasks.values.first { await task.value }
    }

    // MARK: - Scheduling

    private var pendingURL: URL { storeDirectory.appending(path: Self.pendingName) }

    /// Whether manual downloads may use the network right now.
    private func manualAllowed(_ prefs: DownloadPreferences) -> Bool {
        let status = network.status
        return status.isConnected && (!status.isCellular || prefs.overMobileData)
    }

    private func networkChanged() {
        let prefs = preferences().normalised()
        if manualAllowed(prefs) {
            for i in jobs.indices where jobs[i].state == .waiting { jobs[i].state = .queued }
            fetchCovers()
        } else {
            for i in jobs.indices where jobs[i].isManual {
                guard case let .running(run) = jobs[i].state else { continue }
                jobs[i].state = .waiting
                tasks[run]?.cancel()
            }
        }
        pump()
    }

    /// Starts queued jobs while there's room; manual ones that may not use the network wait instead. A song
    /// already in the store needs no network, so its job never waits.
    private func pump() {
        let prefs = preferences().normalised()
        let allowed = manualAllowed(prefs)
        var running = jobs.filter(\.isRunning).count
        for i in jobs.indices {
            guard jobs[i].state == .queued else { continue }
            let needsNetwork = jobs[i].kind == .replace || kinds[jobs[i].songId] == nil
            if jobs[i].isManual, needsNetwork, !allowed { jobs[i].state = .waiting; continue }
            guard running < prefs.concurrent else { continue }
            let songId = jobs[i].songId
            guard !jobs.contains(where: { $0.isRunning && $0.songId == songId }) else { continue }
            let run = UUID(), id = jobs[i].id
            jobs[i].state = .running(run)
            running += 1
            tasks[run] = Task { [weak self] in
                await self?.perform(id: id, run: run)
                self?.taskEnded(run)
            }
        }
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let key = UUID()
        tasks[key] = Task { [weak self] in
            await operation()
            self?.taskEnded(key)
        }
    }

    private func taskEnded(_ key: UUID) {
        tasks[key] = nil
        pump()
    }

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// False once the job was removed, cancelled or sent back to wait: its result is then thrown away.
    private func isCurrent(_ id: UUID, _ run: UUID) -> Bool { job(id)?.state == .running(run) }

    private func perform(id: UUID, run: UUID) async {
        guard let job = job(id) else { return }
        let prefs = preferences().normalised()

        // Already stored: a download only gains its reason (a cached song becomes a download, within the limit).
        if job.kind != .replace, let existing = await store.entry(songId: job.songId) {
            guard isCurrent(id, run) else { return }
            if case let .download(reason) = job.kind {
                if existing.kind == .cache, let limit = limitBytes(prefs),
                   await store.usage().downloadBytes + existing.size > limit {
                    stopForFull(id)
                    return
                }
                await store.addReason(reason, songIds: [job.songId])
                await refresh()
            }
            complete(id)
            return
        }

        guard let source = streamURL(job.metadata.song, job.quality) else { complete(id); return }
        let fetched: (file: URL, mimeType: String?)
        do {
            fetched = try await fetcher.fetch(source, allowsCellular: !job.isManual || prefs.overMobileData)
        } catch {
            guard isCurrent(id, run) else { return }   // sent back to wait, or removed
            Log.logger("downloads").error("download failed: \(Log.category(of: error), privacy: .public)")
            complete(id)
            return
        }
        guard isCurrent(id, run) else {
            try? FileManager.default.removeItem(at: fetched.file)   // no partial or unwanted file reaches the store
            return
        }
        let ext = AudioStore.fileExtension(quality: job.quality, suffix: job.metadata.suffix, mimeType: fetched.mimeType)
        do {
            switch job.kind {
            case let .download(reason):
                try await store.add(fetched.file, metadata: job.metadata, quality: job.quality, kind: .download,
                                    reason: reason, fileExtension: ext, downloadsLimit: limitBytes(prefs))
            case .cache:
                try await store.add(fetched.file, metadata: job.metadata, quality: job.quality, kind: .cache,
                                    reason: nil, fileExtension: ext, downloadsLimit: nil)
            case .replace:
                try await store.replace(songId: job.songId, with: fetched.file, quality: job.quality, fileExtension: ext)
            }
        } catch AudioStoreError.downloadsFull {
            stopForFull(id)
            return
        } catch {
            Log.logger("downloads").error("storing a download failed: \(Log.category(of: error), privacy: .public)")
        }
        await refresh()
        complete(id)
    }

    private func complete(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        savePending()
    }

    /// "Downloads are full": this job and every queued manual one stop; what already arrived stays.
    private func stopForFull(_ id: UUID) {
        let stopped = jobs.filter { $0.id == id || ($0.isManual && !$0.isRunning) }
        jobs.removeAll { job in stopped.contains { $0.id == job.id } }
        stoppedByFull += stopped
        savePending()
    }

    private func fetchCovers() {
        guard !pendingCovers.isEmpty, manualAllowed(preferences().normalised()) else { return }
        let ids = pendingCovers
        pendingCovers = []
        let allowsCellular = preferences().normalised().overMobileData
        for id in ids {
            guard let url = coverArtURL(id) else { continue }
            track { [store, fetcher] in
                guard await store.coverURL(coverArtId: id) == nil else { return }
                do {
                    let fetched = try await fetcher.fetch(url, allowsCellular: allowsCellular)
                    defer { try? FileManager.default.removeItem(at: fetched.file) }
                    try await store.saveCover(Data(contentsOf: fetched.file), coverArtId: id)
                } catch {
                    // A missing cover never fails the download.
                    Log.logger("downloads").error("cover failed: \(Log.category(of: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Mirrors and persistence

    private func refresh() async {
        let entries = await store.entries()
        let files = await store.localFiles()
        kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.songId, $0.kind) })
        if files != localFiles {
            localFiles = files
            onLocalFilesChanged?()
        }
    }

    /// Writes the queued manual downloads (ids, reason and quality: never a URL), or removes the file when none.
    private func savePending() {
        let pending = jobs.compactMap { job -> PendingJob? in
            guard case let .download(reason) = job.kind else { return nil }
            return PendingJob(metadata: job.metadata, reason: reason, quality: job.quality, playlistId: job.playlistId)
        }
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
}
