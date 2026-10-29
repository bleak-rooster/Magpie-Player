import Foundation
import MagpieCore
import Observation
import Playback

/// Runs downloads (kept until removed) and pre-downloads (cache) into the `AudioStore` (spec §6).
///
/// - At most `concurrent` fetches run at once (a cancelled fetch counts until it has unwound).
/// - Manual downloads wait for Wi-Fi on mobile data unless "Download on mobile data" is on; a manual fetch in
///   flight when the network flips is cancelled and waits again. Pre-downloads never wait.
/// - Queued manual downloads survive a relaunch in `pending.json`: song metadata, reason and quality only. Stream
///   URLs carry Subsonic auth (`u`, `t`, `s`), so they are built at fetch time and never stored or logged.
/// - Only audio is stored and only images are saved as covers: a Subsonic error arrives as HTTP 200 with a JSON
///   or XML body, and is refused.
/// - "Downloads are full" stops every queued manual download; nothing is evicted.
/// - `cancelAll` bumps a generation: work that resumes after it drops its result instead of touching the store.
@MainActor @Observable
final class DownloadManager {
    static let coverSize = 600
    static let pendingName = "pending.json"

    /// The response was not the kind of file asked for (an error page or a Subsonic error body).
    enum DownloadError: Error, Equatable { case unexpectedContent }

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
        /// False for a song already stored (it only gains a reason) and once the bytes have arrived: a network
        /// flip then leaves the job alone.
        var needsNetwork = true

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
    /// Tests: runs after a song's bytes have arrived and before they are written to the store.
    @ObservationIgnored var beforeStoreForTesting: (@MainActor (_ songId: String) async -> Void)?

    /// Mirror of the store's kinds, so `status` can answer synchronously.
    private var kinds: [String: AudioKind] = [:]
    private var jobs: [Job] = []
    /// Manual downloads stopped by "Downloads are full", and ones that failed: `retryWaiting` queues them again.
    private var stoppedByFull: [Job] = []
    private var failed: [Job] = []

    @ObservationIgnored private let fetcher: any AudioFetching
    @ObservationIgnored private let network: any NetworkStatusProviding
    @ObservationIgnored private let preferences: @MainActor () -> DownloadPreferences
    @ObservationIgnored private let streamURL: @MainActor (Song, StreamQuality) -> URL?
    @ObservationIgnored private let coverArtURL: @MainActor (String) -> URL?
    @ObservationIgnored private let limitBytes: (DownloadPreferences) -> Int64?
    /// Job runs and short store tasks; `settled()` waits for all of them.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Job runs still unwinding, cancelled or not (run id → song id): these hold the concurrency slots.
    @ObservationIgnored private var activeRuns: [UUID: String] = [:]
    @ObservationIgnored private var generation = 0
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
        if let playlist {
            track { [weak self, store] gen in
                guard self?.isLive(gen) == true else { return }
                await store.savePlaylist(playlist)
            }
        }
        if let coverArtId, !pendingCovers.contains(coverArtId) { pendingCovers.append(coverArtId) }
        let quality = preferences().normalised().quality
        // A song already stored still gets a job: it gains the reason without using the network.
        for song in songs {
            failed.removeAll { $0.songId == song.id && $0.kind == .download(reason) }
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
        track { [weak self, store] gen in
            for id in songIds {
                guard let entry = await store.entry(songId: id), let self, self.isLive(gen) else { continue }
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
        failed.removeAll { $0.kind == .download(reason) }
        stoppedByFull = []
        savePending()
        await store.removeReason(reason)
        if case let .playlist(id) = reason { await store.removePlaylist(id: id) }
        await refresh()
        pump()
    }

    /// Queues again what waits for Wi-Fi, what failed and what "Downloads are full" stopped.
    func retryWaiting() {
        for var job in stoppedByFull + failed {
            job.state = .queued
            job.needsNetwork = true
            jobs.append(job)
        }
        stoppedByFull = []
        failed = []
        for i in jobs.indices where jobs[i].state == .waiting { jobs[i].state = .queued }
        savePending()
        fetchCovers()
        pump()
    }

    /// Stops everything (sign-out): fetches are cancelled, nothing queued is kept, and work still unwinding drops
    /// its result.
    func cancelAll() {
        generation += 1
        for task in tasks.values { task.cancel() }
        jobs = []
        stoppedByFull = []
        failed = []
        pendingCovers = []
        savePending()
    }

    /// Sign-out: once this returns nothing is left that could write into the store, so the scope can be erased.
    func cancelAllAndSettle() async {
        cancelAll()
        await settled()
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
        if failed.contains(where: { ids.contains($0.songId) }) { return .failed }
        return .none
    }

    /// Returns once every queued job has finished, failed or is waiting, and no task is left running.
    func settled() async {
        while let task = tasks.values.first { await task.value }
    }

    // MARK: - Scheduling

    private var pendingURL: URL { storeDirectory.appending(path: Self.pendingName) }

    static func isAudio(_ mimeType: String?) -> Bool {
        guard let mime = mimeType?.lowercased() else { return false }
        return mime.hasPrefix("audio/") || mime == "application/octet-stream"
    }

    static func isImage(_ mimeType: String?) -> Bool { mimeType?.lowercased().hasPrefix("image/") == true }

    private func isLive(_ gen: Int) -> Bool { gen == generation }

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
            for i in jobs.indices where jobs[i].isManual && jobs[i].needsNetwork {
                guard case let .running(run) = jobs[i].state else { continue }
                jobs[i].state = .waiting
                tasks[run]?.cancel()
            }
        }
        pump()
    }

    /// Starts queued jobs while there's room; manual ones that may not use the network wait instead. A song
    /// already in the store needs no network, so its job never waits. One run per song at a time.
    private func pump() {
        let prefs = preferences().normalised()
        let allowed = manualAllowed(prefs)
        for i in jobs.indices {
            guard jobs[i].state == .queued else { continue }
            let needsNetwork = jobs[i].kind == .replace || kinds[jobs[i].songId] == nil
            if jobs[i].isManual, needsNetwork, !allowed { jobs[i].state = .waiting; continue }
            guard activeRuns.count < prefs.concurrent else { continue }
            let songId = jobs[i].songId
            guard !activeRuns.values.contains(songId) else { continue }
            let run = UUID(), id = jobs[i].id
            jobs[i].state = .running(run)
            jobs[i].needsNetwork = needsNetwork
            activeRuns[run] = songId
            tasks[run] = Task { [weak self] in
                await self?.perform(id: id, run: run)
                self?.taskEnded(run)
            }
        }
    }

    private func track(_ operation: @escaping @MainActor (_ generation: Int) async -> Void) {
        let key = UUID(), gen = generation
        tasks[key] = Task { [weak self] in
            await operation(gen)
            self?.taskEnded(key)
        }
    }

    private func taskEnded(_ key: UUID) {
        tasks[key] = nil
        activeRuns[key] = nil
        pump()
    }

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// False once the job was removed, cancelled or sent back to wait: its result is then thrown away.
    private func isCurrent(_ id: UUID, _ run: UUID) -> Bool { job(id)?.state == .running(run) }

    private func perform(id: UUID, run: UUID) async {
        guard let job = job(id) else { return }
        let gen = generation
        let prefs = preferences().normalised()

        // Already stored: a download only gains its reason (a cached song becomes a download, within the limit).
        if job.kind != .replace, await store.entry(songId: job.songId) != nil {
            guard isLive(gen), isCurrent(id, run) else { return }
            if case let .download(reason) = job.kind {
                do {
                    try await store.promote(songId: job.songId, reason: reason, downloadsLimit: limitBytes(prefs))
                } catch AudioStoreError.downloadsFull {
                    if isLive(gen) { stopForFull(id) }
                    return
                } catch {
                    if isLive(gen) { fail(id, error) }   // evicted in between
                    return
                }
                guard isLive(gen) else { return }
                await undoIfRemoved(id, reason, job.songId)
                await refresh()
            }
            complete(id)
            return
        }

        guard let source = streamURL(job.metadata.song, job.quality) else { fail(id, URLError(.badURL)); return }
        let fetched: (file: URL, mimeType: String?)
        do {
            fetched = try await fetcher.fetch(source, allowsCellular: !job.isManual || prefs.overMobileData)
        } catch {
            guard isLive(gen), isCurrent(id, run) else { return }   // sent back to wait, removed or signed out
            fail(id, error)
            return
        }
        // No partial, unwanted or non-audio file reaches the store.
        guard isLive(gen), isCurrent(id, run) else { discard(fetched.file); return }
        guard Self.isAudio(fetched.mimeType),
              let ext = AudioStore.fileExtension(quality: job.quality, suffix: job.metadata.suffix,
                                                 mimeType: fetched.mimeType) else {
            discard(fetched.file)
            fail(id, DownloadError.unexpectedContent)
            return
        }
        setNeedsNetwork(id, false)   // the bytes are here: a network flip no longer stops this job
        if let beforeStoreForTesting { await beforeStoreForTesting(job.songId) }
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
            if isLive(gen) { stopForFull(id) }
            return
        } catch {
            if isLive(gen) { fail(id, error) }
            return
        }
        guard isLive(gen) else { return }
        if case let .download(reason) = job.kind { await undoIfRemoved(id, reason, job.songId) }
        await refresh()
        complete(id)
    }

    /// `remove(reason)` dropped this job while its song was being written: take the reason back off this song,
    /// unless the song has been asked for again with the same reason since.
    private func undoIfRemoved(_ id: UUID, _ reason: DownloadReason, _ songId: String) async {
        guard job(id) == nil, isLive(generation),
              !jobs.contains(where: { $0.songId == songId && $0.kind == .download(reason) }) else { return }
        await store.removeReason(reason, songIds: [songId])
    }

    private func setNeedsNetwork(_ id: UUID, _ value: Bool) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].needsNetwork = value
    }

    private func discard(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    private func complete(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        savePending()
    }

    /// A manual job that failed shows "Couldn't download" until it's retried or removed; a pre-download just ends.
    private func fail(_ id: UUID, _ error: Error) {
        Log.logger("downloads").error("download failed: \(Log.category(of: error), privacy: .public)")
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        if job.isManual { failed.append(job) }
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
        let prefs = preferences().normalised()
        guard !pendingCovers.isEmpty, manualAllowed(prefs) else { return }
        let ids = pendingCovers
        pendingCovers = []
        for id in ids {
            guard let url = coverArtURL(id) else { continue }
            track { [weak self, store, fetcher] gen in
                guard await store.coverURL(coverArtId: id) == nil else { return }
                do {
                    let fetched = try await fetcher.fetch(url, allowsCellular: prefs.overMobileData)
                    defer { try? FileManager.default.removeItem(at: fetched.file) }
                    guard self?.isLive(gen) == true else { return }
                    guard Self.isImage(fetched.mimeType) else { throw DownloadError.unexpectedContent }
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
