import CryptoKit
import Foundation
import MagpieCore

/// Downloaded and cached audio for one server scope (spec §6, §11).
///
/// Layout under `directory`:
/// - `<sha256(songId|quality)>.<ext>`: the audio, with its `AudioEntry` beside it as `<fileName>.json`;
/// - `index.json`: every entry and playlist (written atomically), rebuilt from the sidecars when unreadable;
/// - `playlists/<sha256(id)>.json` and `covers/<sha256(coverArtId)>.jpg`.
///
/// No path is made from a server string. Everything is kept out of backups and, on iOS, readable after the first
/// unlock so the car can play with the phone locked.
public actor AudioStore {
    /// `<root>/Magpie/Audio/<scope>`. `scope` is the app's own server-scope id, never a server string.
    public nonisolated let directory: URL
    private let now: @Sendable () -> Date
    private var index = Index()

    private struct Index: Codable, Equatable {
        var entries: [String: AudioEntry] = [:]
        var playlists: [String: DownloadedPlaylist] = [:]
    }

    static let indexName = "index.json"
    static let originalSuffixes: Set<String> = ["mp3", "flac", "m4a", "mp4", "aac", "wav", "aif", "aiff", "alac", "caf"]
    static let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/flac": "flac", "audio/x-flac": "flac",
                                 "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav",
                                 "audio/x-wav": "wav", "audio/aiff": "aiff", "audio/x-aiff": "aiff"]
    /// Every extension the store accepts: the Original allowlist plus the transcode formats.
    static let allowedExtensions = originalSuffixes.union(["mp3", "aac"])
    /// `<64 hex>.<ext>`: the only names the store writes for audio.
    static func isHashedName(_ name: String) -> Bool { name.wholeMatch(of: /[0-9a-f]{64}\.[a-z0-9]+/) != nil }

    /// `scope` must match `[A-Za-z0-9_-]{1,64}` (the app passes a hex digest); anything else is a programming
    /// error and stops here rather than writing outside `Magpie/Audio`.
    public init(root: URL, scope: String, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(Self.isValidScope(scope), "AudioStore scope must match [A-Za-z0-9_-]{1,64}")
        directory = root.appending(path: "Magpie/Audio").appending(path: scope, directoryHint: .isDirectory)
        self.now = now
    }

    // MARK: - Names

    static func isValidScope(_ scope: String) -> Bool { scope.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil }

    public static func fileName(songId: String, quality: StreamQuality, fileExtension: String) -> String {
        sha256(songId + "|" + quality.rawValue) + "." + fileExtension
    }

    /// Only extensions AVFoundation plays; nothing from the server is used unless it is on the allowlist. nil: a
    /// format Magpie can't play (or can't tell), which is refused rather than guessed.
    public static func fileExtension(quality: StreamQuality, suffix: String?, mimeType: String?) -> String? {
        switch quality.format {
        case "aac": return "aac"
        case "mp3": return "mp3"
        default: break
        }
        if let suffix = suffix?.lowercased(), originalSuffixes.contains(suffix) { return suffix }
        if let mime = mimeType?.lowercased(), let ext = mimeExtensions[mime] { return ext }
        return nil
    }

    /// An entry may only name the file its own song id and quality hash to, with an allowed extension.
    static func isValid(_ entry: AudioEntry) -> Bool {
        guard let dot = entry.fileName.lastIndex(of: ".") else { return false }
        let ext = String(entry.fileName[entry.fileName.index(after: dot)...])
        return allowedExtensions.contains(ext)
            && entry.fileName == fileName(songId: entry.songId, quality: entry.quality, fileExtension: ext)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading

    /// Reads the index and reconciles it with the files on disk (a damaged or stale index is repaired from the
    /// sidecars). Never throws.
    public func load() {
        guard FileManager.default.fileExists(atPath: directory.path) else { index = Index(); return }
        reconcile(with: try? AtomicFile.read(Index.self, from: indexURL))
    }

    public func entry(songId: String) -> AudioEntry? { index.entries[songId] }

    public func entries() -> [AudioEntry] { Array(index.entries.values) }

    public func localFiles() -> [String: URL] { index.entries.mapValues(url(for:)) }

    public func usage() -> AudioUsage {
        var usage = AudioUsage(downloadBytes: 0, cacheBytes: 0)
        for entry in index.entries.values {
            switch entry.kind {
            case .download: usage.downloadBytes += entry.size
            case .cache: usage.cacheBytes += entry.size
            }
        }
        return usage
    }

    // MARK: - Adding

    /// Moves `temporaryFile` in. A download for a song already cached keeps that file and becomes a download; a
    /// second entry for a stored song is never made (the new file is deleted).
    @discardableResult
    public func add(_ temporaryFile: URL, metadata: AudioMetadata, quality: StreamQuality, kind: AudioKind,
                    reason: DownloadReason?, fileExtension: String, downloadsLimit: Int64?) throws -> AudioEntry {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporaryFile) }   // moved in, or not wanted
        guard Self.allowedExtensions.contains(fileExtension) else { throw AudioStoreError.invalidFile }
        let reasons: Set<DownloadReason> = kind == .download ? Set([reason].compactMap { $0 }) : []

        if var existing = index.entries[metadata.songId] {
            guard kind == .download else { return existing }
            if existing.kind == .cache {
                try checkLimit(adding: existing.size, limit: downloadsLimit)
                existing.kind = .download
            }
            existing.reasons.formUnion(reasons)
            existing.metadata = metadata
            try store(existing)
            return existing
        }

        let size = try fileSize(temporaryFile)
        if kind == .download { try checkLimit(adding: size, limit: downloadsLimit) }
        try prepareDirectory()
        let name = Self.fileName(songId: metadata.songId, quality: quality, fileExtension: fileExtension)
        let destination = directory.appending(path: name)
        try? fm.removeItem(at: destination)   // a leftover with no entry
        try fm.moveItem(at: temporaryFile, to: destination)
        do { try protect(destination) } catch { try? fm.removeItem(at: destination); throw error }
        let entry = AudioEntry(songId: metadata.songId, quality: quality, fileName: name, size: size, kind: kind,
                               reasons: reasons, downloadedAt: now(), lastPlayed: nil, metadata: metadata)
        do { try store(entry) } catch { try? fm.removeItem(at: destination); throw error }
        return entry
    }

    /// Re-download: stores the new file first, then deletes the old one; kind, reasons and lastPlayed carry over.
    @discardableResult
    public func replace(songId: String, with temporaryFile: URL, quality: StreamQuality, fileExtension: String) throws -> AudioEntry {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporaryFile) }
        guard Self.allowedExtensions.contains(fileExtension) else { throw AudioStoreError.invalidFile }
        guard let old = index.entries[songId] else { throw AudioStoreError.unknownSong }
        let size = try fileSize(temporaryFile)
        try prepareDirectory()
        let name = Self.fileName(songId: songId, quality: quality, fileExtension: fileExtension)
        let destination = directory.appending(path: name)
        if name == old.fileName {
            _ = try fm.replaceItemAt(destination, withItemAt: temporaryFile)
        } else {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporaryFile, to: destination)
        }
        do {
            try protect(destination)
        } catch {
            // Same name: the old file is already gone, so the entry goes too. Otherwise the old one stays.
            try? fm.removeItem(at: destination)
            if name == old.fileName { remove(old); saveIndex() }
            throw error
        }
        var entry = old
        entry.quality = quality; entry.fileName = name; entry.size = size; entry.downloadedAt = now()
        try store(entry)
        if name != old.fileName { deleteFiles(of: old) }
        return entry
    }

    // MARK: - Reasons, plays and removal

    /// Adds `reason` to a stored song in one step; a cached song becomes a download only if it fits the downloads
    /// limit (nothing is evicted).
    public func promote(songId: String, reason: DownloadReason, downloadsLimit: Int64?) throws {
        guard var entry = index.entries[songId] else { throw AudioStoreError.unknownSong }
        if entry.kind == .cache {
            try checkLimit(adding: entry.size, limit: downloadsLimit)
            entry.kind = .download
        }
        entry.reasons.insert(reason)
        try store(entry)
    }

    /// Adds `reason` to stored songs; a cached song becomes a download.
    public func addReason(_ reason: DownloadReason, songIds: [String]) {
        for id in songIds {
            guard var entry = index.entries[id] else { continue }
            entry.kind = .download
            entry.reasons.insert(reason)
            try? store(entry)
        }
    }

    /// Drops `reason` from every download and deletes the ones left with none. Returns the deleted song ids.
    @discardableResult
    public func removeReason(_ reason: DownloadReason) -> [String] {
        var removed: [String] = []
        for var entry in index.entries.values where entry.kind == .download && entry.reasons.contains(reason) {
            entry.reasons.remove(reason)
            if entry.reasons.isEmpty {
                remove(entry); removed.append(entry.songId)
            } else {
                try? store(entry, writeIndex: false)
            }
        }
        saveIndex()
        return removed.sorted()
    }

    public func markPlayed(songId: String) {
        guard var entry = index.entries[songId] else { return }
        entry.lastPlayed = now()
        try? store(entry)
    }

    /// Removes the cache entries among `songIds` (downloads are left alone). Returns the removed ids.
    @discardableResult
    public func removeCache(songIds: Set<String>) -> [String] {
        let victims = index.entries.values.filter { $0.kind == .cache && songIds.contains($0.songId) }
        for entry in victims { remove(entry) }
        saveIndex()
        return victims.map(\.songId).sorted()
    }

    /// Removing all downloads also drops the saved playlists and covers that went with them.
    public func removeAll(kind: AudioKind) {
        for entry in index.entries.values where entry.kind == kind { remove(entry) }
        if kind == .download {
            index.playlists = [:]
            try? FileManager.default.removeItem(at: playlistsDirectory)
            try? FileManager.default.removeItem(at: coversDirectory)
        }
        saveIndex()
    }

    /// Sign-out: the whole scope goes.
    public func eraseScope() {
        try? FileManager.default.removeItem(at: directory)
        index = Index()
    }

    /// Removes cache entries, least recently played (or downloaded) first, skipping `protecting`, until the cache
    /// fits `limit`. Downloads are never evicted. Returns the evicted ids in order.
    @discardableResult
    public func evictCache(limit: Int64, protecting: Set<String>) -> [String] {
        var total = usage().cacheBytes
        guard total > limit else { return [] }
        let candidates = index.entries.values
            .filter { $0.kind == .cache && !protecting.contains($0.songId) }
            .sorted { ($0.lastPlayed ?? $0.downloadedAt, $0.songId) < ($1.lastPlayed ?? $1.downloadedAt, $1.songId) }
        var evicted: [String] = []
        for entry in candidates where total > limit {
            remove(entry)
            total -= entry.size
            evicted.append(entry.songId)
        }
        saveIndex()
        return evicted
    }

    // MARK: - Playlists and covers

    public func savePlaylist(_ playlist: DownloadedPlaylist) {
        index.playlists[playlist.id] = playlist
        try? prepareDirectory()
        try? AtomicFile.write(playlist, to: playlistURL(playlist.id))
        saveIndex()
    }

    public func playlists() -> [DownloadedPlaylist] { Array(index.playlists.values) }

    public func removePlaylist(id: String) {
        index.playlists[id] = nil
        try? FileManager.default.removeItem(at: playlistURL(id))
        saveIndex()
    }

    public func saveCover(_ data: Data, coverArtId: String) throws {
        try prepareDirectory()
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        let url = coverFileURL(coverArtId)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public func coverURL(coverArtId: String) -> URL? {
        let url = coverFileURL(coverArtId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    private var indexURL: URL { directory.appending(path: Self.indexName) }
    private var playlistsDirectory: URL { directory.appending(path: "playlists", directoryHint: .isDirectory) }
    private var coversDirectory: URL { directory.appending(path: "covers", directoryHint: .isDirectory) }
    private func playlistURL(_ id: String) -> URL { playlistsDirectory.appending(path: Self.sha256(id) + ".json") }
    private func coverFileURL(_ id: String) -> URL { coversDirectory.appending(path: Self.sha256(id) + ".jpg") }
    private func url(for entry: AudioEntry) -> URL { directory.appending(path: entry.fileName) }
    private func sidecarURL(_ fileName: String) -> URL { directory.appending(path: fileName + ".json") }

    private func checkLimit(adding size: Int64, limit: Int64?) throws {
        guard let limit else { return }
        if usage().downloadBytes + size > limit { throw AudioStoreError.downloadsFull }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw AudioStoreError.invalidFile
        }
        return Int64(size)
    }

    /// Creates `directory`, kept out of backups, and readable after first unlock on iOS.
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
    }

    private func protect(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }

    /// Writes the sidecar, then the index.
    private func store(_ entry: AudioEntry, writeIndex: Bool = true) throws {
        try AtomicFile.write(entry, to: sidecarURL(entry.fileName))
        index.entries[entry.songId] = entry
        if writeIndex { saveIndex() }
    }

    private func remove(_ entry: AudioEntry) {
        deleteFiles(of: entry)
        index.entries[entry.songId] = nil
    }

    private func deleteFiles(of entry: AudioEntry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        try? FileManager.default.removeItem(at: sidecarURL(entry.fileName))
    }

    private func saveIndex() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try AtomicFile.write(index, to: indexURL)
        } catch {
            // The sidecars still hold every entry; the next load rebuilds the index from them.
            Log.logger("audio").error("cannot write the audio index: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// Makes the index agree with the disk. The sidecar is written before the index, so a valid sidecar with its
    /// audio wins; an index entry without a sidecar is kept (and its sidecar rewritten) when its audio is there.
    /// Audio, sidecars and playlists with no valid entry are deleted, as are leftover `.tmp` files.
    private func reconcile(with loaded: Index?) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".tmp") { try? fm.removeItem(at: directory.appending(path: name)) }
        let audio = Set(names.filter { Self.isHashedName($0) })
        var entries: [String: AudioEntry] = [:]
        for sidecar in names where sidecar.hasSuffix(".json") && Self.isHashedName(String(sidecar.dropLast(5))) {
            let fileName = String(sidecar.dropLast(5))
            guard audio.contains(fileName),
                  let entry = try? AtomicFile.read(AudioEntry.self, from: directory.appending(path: sidecar)),
                  entry.fileName == fileName, Self.isValid(entry) else {
                try? fm.removeItem(at: directory.appending(path: sidecar))
                continue
            }
            // Two files for one song (a re-download cut short): the newer one wins; the other is deleted below.
            if let other = entries[entry.songId], other.downloadedAt >= entry.downloadedAt {
                try? fm.removeItem(at: directory.appending(path: sidecar))
                continue
            }
            if let other = entries[entry.songId] { try? fm.removeItem(at: sidecarURL(other.fileName)) }
            entries[entry.songId] = entry
        }
        for (key, entry) in loaded?.entries ?? [:]
        where entries[key] == nil && key == entry.songId && Self.isValid(entry) && audio.contains(entry.fileName) {
            entries[key] = entry
            try? AtomicFile.write(entry, to: sidecarURL(entry.fileName))
        }
        let kept = Set(entries.values.map(\.fileName))
        for name in audio.subtracting(kept) { try? fm.removeItem(at: directory.appending(path: name)) }

        var playlists: [String: DownloadedPlaylist] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: playlistsDirectory.path)) ?? [] {
            let url = playlistsDirectory.appending(path: name)
            if let playlist = try? AtomicFile.read(DownloadedPlaylist.self, from: url),
               name == Self.sha256(playlist.id) + ".json" {
                playlists[playlist.id] = playlist
            } else {
                try? fm.removeItem(at: url)
            }
        }
        for (key, playlist) in loaded?.playlists ?? [:] where playlists[key] == nil && key == playlist.id {
            playlists[key] = playlist
            try? AtomicFile.write(playlist, to: playlistURL(key))
        }

        index = Index(entries: entries, playlists: playlists)
        guard index != loaded else { return }
        Log.logger("audio").error("audio index repaired from disk: \(entries.count, privacy: .public) entries")
        saveIndex()
    }
}
