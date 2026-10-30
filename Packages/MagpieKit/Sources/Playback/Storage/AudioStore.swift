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
    /// Reads a file; tests inject one that fails like protected data before first unlock.
    private let reader: @Sendable (URL) throws -> Data
    /// Whether protected data can be read now (the app passes UIApplication's answer; false before first unlock).
    private let isProtectedDataAvailable: @Sendable () -> Bool
    /// The shortest gap between two retries of a reconcile that couldn't read its files.
    private let retryInterval: TimeInterval
    private var index = Index()
    /// The last reconcile met a file it could not read yet (protected data before first unlock). Until a retry
    /// succeeds the store is read-only: reads serve the stand-in index, every write throws `notReady`.
    private var reconcilePending = false
    private var lastAttempt: Date?

    private struct Index: Codable, Equatable {
        var entries: [String: AudioEntry] = [:]
        var playlists: [String: DownloadedPlaylist] = [:]
    }

    static let indexName = "index.json"
    static let originalSuffixes: Set<String> = ["mp3", "flac", "m4a", "mp4", "aac", "wav", "aif", "aiff", "alac", "caf"]
    static let mimeExtensions = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/flac": "flac", "audio/x-flac": "flac",
                                 "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav",
                                 "audio/x-wav": "wav", "audio/aiff": "aiff", "audio/x-aiff": "aiff"]
    static let oggMimeTypes: Set<String> = ["audio/ogg", "audio/opus"]
    /// Every extension the store accepts: the Original allowlist plus the transcode formats.
    static let allowedExtensions = originalSuffixes.union(["mp3", "aac", "ogg"])
    /// `<64 hex>.<ext>`: the only names the store writes for audio.
    static func isHashedName(_ name: String) -> Bool { name.wholeMatch(of: /[0-9a-f]{64}\.[a-z0-9]+/) != nil }

    /// `scope` must match `[A-Za-z0-9_-]{1,64}` (the app passes a hex digest); anything else is a programming
    /// error and stops here rather than writing outside `Magpie/Audio`.
    public init(root: URL, scope: String, now: @escaping @Sendable () -> Date = { Date() },
                isProtectedDataAvailable: @escaping @Sendable () -> Bool = { true }) {
        self.init(root: root, scope: scope, now: now, isProtectedDataAvailable: isProtectedDataAvailable,
                  read: { try Data(contentsOf: $0) })
    }

    init(root: URL, scope: String, now: @escaping @Sendable () -> Date = { Date() },
         isProtectedDataAvailable: @escaping @Sendable () -> Bool = { true }, retryInterval: TimeInterval = 30,
         read: @escaping @Sendable (URL) throws -> Data) {
        precondition(Self.isValidScope(scope), "AudioStore scope must match [A-Za-z0-9_-]{1,64}")
        directory = root.appending(path: "Magpie/Audio").appending(path: scope, directoryHint: .isDirectory)
        self.now = now
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.retryInterval = retryInterval
        self.reader = read
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
        case "opus": return "ogg"   // Navidrome serves Ogg Opus (D45)
        default: break
        }
        // Ogg may hold Vorbis or FLAC, which AVFoundation may not play: Original accepts it only as a `.opus` source (D45).
        if let mime = mimeType?.lowercased(), oggMimeTypes.contains(mime) {
            return suffix?.lowercased() == "opus" ? "ogg" : nil
        }
        if suffix?.lowercased() == "opus" { return "ogg" }
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
    /// sidecars). Never throws. When a file can't be read yet (before first unlock) nothing on disk is touched, and
    /// the store tries again on its next use.
    public func load() {
        let wasPending = reconcilePending
        reconcilePending = false
        lastAttempt = now()
        guard FileManager.default.fileExists(atPath: directory.path) else { index = Index(); return }
        reconcile()
        if reconcilePending, !wasPending {
            Log.logger("audio").error("audio files not readable yet; read-only until they are")
        }
    }

    /// Whether writes are accepted (false until a reconcile has read every file).
    public func isReady() -> Bool { retryLoad(); return !reconcilePending }

    /// The app calls this on `protectedDataDidBecomeAvailableNotification`: retries at once.
    public func protectedDataDidBecomeAvailable() {
        if reconcilePending { load() }
    }

    public func entry(songId: String) -> AudioEntry? { retryLoad(); return index.entries[songId] }

    public func entries() -> [AudioEntry] { retryLoad(); return Array(index.entries.values) }

    public func localFiles() -> [String: URL] { retryLoad(); return index.entries.mapValues(url(for:)) }

    public func usage() -> AudioUsage {
        retryLoad()
        var usage = AudioUsage(downloadBytes: 0, cacheBytes: 0)
        for entry in index.entries.values {
            switch entry.kind {
            case .download: usage.downloadBytes = Self.sum(usage.downloadBytes, entry.size)
            case .cache: usage.cacheBytes = Self.sum(usage.cacheBytes, entry.size)
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
        try ensureReady()
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
        let sidecar = sidecarURL(name)
        if fm.fileExists(atPath: destination.path) || fm.fileExists(atPath: sidecar.path) {
            // Files reconcile kept but couldn't use (a sidecar it couldn't read or decode). Never demote them to
            // cache; a download replaces them with fresh bytes of the same song and quality.
            guard kind == .download else { throw AudioStoreError.invalidFile }
            try? fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporaryFile, to: destination)
        do { try protect(destination) } catch { try? fm.removeItem(at: destination); throw error }
        let entry = AudioEntry(songId: metadata.songId, quality: quality, fileName: name, size: size, kind: kind,
                               reasons: reasons, downloadedAt: now(), lastPlayed: nil, metadata: metadata)
        do { try store(entry) } catch { try? fm.removeItem(at: destination); throw error }
        return entry
    }

    /// Re-download: stores the new file first, then deletes the old one; kind, reasons and lastPlayed carry over. A
    /// download whose new file would take the downloads past `downloadsLimit` is refused (`downloadsFull`).
    @discardableResult
    public func replace(songId: String, with temporaryFile: URL, quality: StreamQuality, fileExtension: String,
                        downloadsLimit: Int64? = nil) throws -> AudioEntry {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporaryFile) }
        try ensureReady()
        guard Self.allowedExtensions.contains(fileExtension) else { throw AudioStoreError.invalidFile }
        guard let old = index.entries[songId] else { throw AudioStoreError.unknownSong }
        let size = try fileSize(temporaryFile)
        // A download's bigger new file must fit the limit in place of the old one; refused, the old file stays.
        let oldSize = max(0, old.size)
        if old.kind == .download, size > oldSize { try checkLimit(adding: size - oldSize, limit: downloadsLimit) }
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
    /// `albumCoverArtId`: the album's cover, recorded when the song is downloaded with its album (Task 14).
    /// `albumSongCount`: the album's song count, recorded with it (P1 marks).
    public func promote(songId: String, reason: DownloadReason, downloadsLimit: Int64?,
                        albumCoverArtId: String? = nil, albumSongCount: Int? = nil) throws {
        try ensureReady()
        guard var entry = index.entries[songId] else { throw AudioStoreError.unknownSong }
        if let albumCoverArtId { entry.metadata.albumCoverArtId = albumCoverArtId }
        if let albumSongCount { entry.metadata.albumSongCount = albumSongCount }
        if entry.kind == .cache {
            try checkLimit(adding: entry.size, limit: downloadsLimit)
            entry.kind = .download
        }
        entry.reasons.insert(reason)
        try store(entry)
    }

    /// Adds `reason` to stored songs; a cached song becomes a download.
    public func addReason(_ reason: DownloadReason, songIds: [String]) throws {
        try ensureReady()
        for id in songIds {
            guard var entry = index.entries[id] else { continue }
            entry.kind = .download
            entry.reasons.insert(reason)
            try? store(entry)
        }
    }

    /// Drops `reason` from every download and deletes the ones left with none. Returns the deleted song ids.
    @discardableResult
    public func removeReason(_ reason: DownloadReason) throws -> [String] {
        try removeReason(reason, songIds: nil)
    }

    /// The same, for `songIds` only (nil: every song).
    @discardableResult
    public func removeReason(_ reason: DownloadReason, songIds: [String]?) throws -> [String] {
        try ensureReady()
        let only = songIds.map(Set.init)
        var removed: [String] = []
        for var entry in index.entries.values
        where entry.kind == .download && entry.reasons.contains(reason) && only?.contains(entry.songId) != false {
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

    public func markPlayed(songId: String) throws {
        try ensureReady()
        guard var entry = index.entries[songId] else { return }
        entry.lastPlayed = now()
        try? store(entry)
    }

    /// Removes the cache entries among `songIds` (downloads are left alone). Returns the removed ids.
    @discardableResult
    public func removeCache(songIds: Set<String>) throws -> [String] {
        try ensureReady()
        let victims = index.entries.values.filter { $0.kind == .cache && songIds.contains($0.songId) }
        for entry in victims { remove(entry) }
        saveIndex()
        return victims.map(\.songId).sorted()
    }

    /// Removing all downloads also drops the saved playlists and covers that went with them.
    public func removeAll(kind: AudioKind) throws {
        try ensureReady()
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
        reconcilePending = false
    }

    /// `removeCache`, sparing the songs `sparing` answers at removal time: what playback holds can change while the
    /// call waits its turn.
    @discardableResult
    public func removeCache(songIds: Set<String>, sparing: @Sendable () async -> Set<String>) async throws -> [String] {
        try ensureReady()
        let spared = await sparing()
        return try removeCache(songIds: songIds.subtracting(spared))
    }

    /// `evictCache`, with the protected songs read at removal time.
    @discardableResult
    public func evictCache(limit: Int64, protecting: @Sendable () async -> Set<String>) async throws -> [String] {
        try ensureReady()
        let protected = await protecting()
        return try evictCache(limit: limit, protecting: protected)
    }

    /// Removes cache entries, least recently played (or downloaded) first, skipping `protecting`, until the cache
    /// fits `limit`. Downloads are never evicted. Returns the evicted ids in order.
    @discardableResult
    public func evictCache(limit: Int64, protecting: Set<String>) throws -> [String] {
        try ensureReady()
        var total = usage().cacheBytes
        guard total > limit else { return [] }
        let candidates = index.entries.values
            .filter { $0.kind == .cache && !protecting.contains($0.songId) }
            .sorted { ($0.lastPlayed ?? $0.downloadedAt, $0.songId) < ($1.lastPlayed ?? $1.downloadedAt, $1.songId) }
        var evicted: [String] = []
        for entry in candidates where total > limit {
            remove(entry)
            total -= min(total, max(0, entry.size))
            evicted.append(entry.songId)
        }
        saveIndex()
        return evicted
    }

    // MARK: - Playlists and covers

    public func savePlaylist(_ playlist: DownloadedPlaylist) throws {
        try ensureReady()
        index.playlists[playlist.id] = playlist
        try? prepareDirectory()
        try? AtomicFile.write(playlist, to: playlistURL(playlist.id))
        saveIndex()
    }

    public func playlists() -> [DownloadedPlaylist] { retryLoad(); return Array(index.playlists.values) }

    public func removePlaylist(id: String) throws {
        try ensureReady()
        index.playlists[id] = nil
        try? FileManager.default.removeItem(at: playlistURL(id))
        saveIndex()
    }

    public func saveCover(_ data: Data, coverArtId: String) throws {
        try ensureReady()
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

    /// Where the cover for `coverArtId` is saved when it is, from any context and without touching the disk (the
    /// caller reads it off the main actor; a missing file reads as no image).
    public nonisolated func coverPath(coverArtId: String) -> URL { coverFileURL(coverArtId) }

    // MARK: - Private

    private var indexURL: URL { directory.appending(path: Self.indexName) }
    private var playlistsDirectory: URL { directory.appending(path: "playlists", directoryHint: .isDirectory) }
    private nonisolated var coversDirectory: URL { directory.appending(path: "covers", directoryHint: .isDirectory) }
    private func playlistURL(_ id: String) -> URL { playlistsDirectory.appending(path: Self.sha256(id) + ".json") }
    private nonisolated func coverFileURL(_ id: String) -> URL { coversDirectory.appending(path: Self.sha256(id) + ".jpg") }
    private func url(for entry: AudioEntry) -> URL { directory.appending(path: entry.fileName) }
    private func sidecarURL(_ fileName: String) -> URL { directory.appending(path: fileName + ".json") }

    private func checkLimit(adding size: Int64, limit: Int64?) throws {
        guard let limit else { return }
        if Self.sum(usage().downloadBytes, size) > limit { throw AudioStoreError.downloadsFull }
    }

    /// Adds a recorded size to a total. A damaged sidecar or index can claim any size, and it stands when its file
    /// can't be sized (before first unlock, or a directory where the audio should be): a negative one counts as 0
    /// and a sum that would overflow stays at `Int64.max`, over any real limit, instead of trapping.
    static func sum(_ total: Int64, _ size: Int64) -> Int64 {
        let (result, overflow) = total.addingReportingOverflow(max(0, size))
        return overflow ? .max : result
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

    /// Retries a pending reconcile at most once per `retryInterval` (and at once when protected data arrives).
    private func retryLoad() {
        guard reconcilePending else { return }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < retryInterval { return }
        load()
    }

    private func ensureReady() throws {
        retryLoad()
        if reconcilePending { throw AudioStoreError.notReady }
    }

    /// `unreadable`: protected data isn't available yet, so try again later. `unusable`: it can't be read for any
    /// other reason (EIO, a directory where a file should be). `undecodable`: it read but isn't a valid record.
    /// Unusable and undecodable files are kept, never adopted, and don't hold up the rest.
    private enum ReadResult<T> { case value(T), undecodable, unusable, unreadable }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> ReadResult<T> {
        let data: Data
        do {
            data = try reader(url)
        } catch {
            return Self.isPermissionError(error) && !isProtectedDataAvailable() ? .unreadable : .unusable
        }
        do { return .value(try JSONDecoder().decode(type, from: data)) } catch { return .undecodable }
    }

    /// The error a protected file gives before first unlock (Foundation's, or the POSIX one beneath it).
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// A temporary file `AtomicFile` leaves when the store's own write was cut short (never `pending.json`'s).
    static func isStoreTemp(_ name: String) -> Bool {
        name.wholeMatch(of: /\.(index\.json|[0-9a-f]{64}(\.[a-z0-9]+)?\.json)\.[0-9A-Fa-f-]{36}\.tmp/) != nil
    }

    /// Makes the index agree with the disk, failing safe:
    /// - a file that can't be read (before first unlock) stops the whole pass with nothing changed on disk;
    /// - a sidecar that reads but doesn't decode is left alone, with its audio (it is not adopted);
    /// - something is deleted only on positive evidence: audio with no sidecar and no index entry (a write cut
    ///   short), a valid sidecar whose audio is gone, the older of two files for one song, a store temp file.
    /// A valid sidecar wins over the index (it is written first); an index entry is kept, and its sidecar rewritten,
    /// when its audio is there but the sidecar isn't usable. Sizes are taken from the files.
    private func reconcile() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return abort(nil, audio: nil) }
        let audio = Set(names.filter { Self.isHashedName($0) })

        var loaded: Index?
        if names.contains(Self.indexName) {
            switch read(Index.self, from: indexURL) {
            case .unreadable: return abort(nil, audio: audio)
            case .unusable, .undecodable: loaded = nil
            case let .value(value): loaded = value
            }
        }

        var deletions: [URL] = names.filter(Self.isStoreTemp).map { directory.appending(path: $0) }
        var sidecarWrites: [String: AudioEntry] = [:]
        var entries: [String: AudioEntry] = [:]
        var unusable = Set<String>()   // sidecars that read or decode badly: never rewritten here
        let sidecars = names.filter { $0.hasSuffix(".json") && Self.isHashedName(String($0.dropLast(5))) }
        for sidecar in sidecars.sorted() {
            let fileName = String(sidecar.dropLast(5))
            switch read(AudioEntry.self, from: directory.appending(path: sidecar)) {
            case .unreadable:
                return abort(loaded, audio: audio)
            case .unusable:
                unusable.insert(fileName)   // not even rewritten: the file system had trouble with it
                continue
            case .undecodable:
                continue   // kept, with its audio: no evidence either way (a valid index entry heals it)
            case let .value(entry):
                guard entry.fileName == fileName, Self.isValid(entry) else { continue }
                guard audio.contains(fileName) else { deletions.append(sidecarURL(fileName)); continue }
                if let other = entries[entry.songId] {
                    // Two files for one song (a re-download cut short): the newer one wins.
                    let older = other.downloadedAt >= entry.downloadedAt ? entry : other
                    entries[entry.songId] = older == entry ? other : entry
                    deletions += [url(for: older), sidecarURL(older.fileName)]
                } else {
                    entries[entry.songId] = entry
                }
            }
        }
        let deleted = Set(deletions.map(\.lastPathComponent))
        for (key, entry) in loaded?.entries ?? [:]
        where entries[key] == nil && key == entry.songId && Self.isValid(entry) && audio.contains(entry.fileName)
            && !deleted.contains(entry.fileName) {
            entries[key] = entry
            sidecarWrites[key] = entry
        }
        for name in unusable { if let key = sidecarWrites.first(where: { $0.value.fileName == name })?.key { sidecarWrites[key] = nil } }
        let kept = Set(entries.values.map(\.fileName))
        for name in audio where !kept.contains(name) && !names.contains(name + ".json") {
            deletions.append(directory.appending(path: name))   // audio with no sidecar at all, and no index entry
        }
        for (key, entry) in entries {
            guard let size = try? url(for: entry).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) != entry.size else { continue }
            var resized = entry
            resized.size = Int64(size)
            entries[key] = resized
            sidecarWrites[key] = resized
        }

        var playlists: [String: DownloadedPlaylist] = [:]
        var playlistWrites: [DownloadedPlaylist] = []
        if fm.fileExists(atPath: playlistsDirectory.path) {
            guard let playlistNames = try? fm.contentsOfDirectory(atPath: playlistsDirectory.path) else {
                return abort(loaded, audio: audio)
            }
            for name in playlistNames {
                let url = playlistsDirectory.appending(path: name)
                if Self.isStoreTemp(name) { deletions.append(url); continue }
                guard name.wholeMatch(of: /[0-9a-f]{64}\.json/) != nil else { continue }
                switch read(DownloadedPlaylist.self, from: url) {
                case .unreadable: return abort(loaded, audio: audio)
                case .unusable, .undecodable: continue
                case let .value(playlist): if name == Self.sha256(playlist.id) + ".json" { playlists[playlist.id] = playlist }
                }
            }
        }
        for (key, playlist) in loaded?.playlists ?? [:] where playlists[key] == nil && key == playlist.id {
            playlists[key] = playlist
            playlistWrites.append(playlist)
        }

        // Everything was read: only now does anything on disk change.
        for url in deletions { try? fm.removeItem(at: url) }
        for entry in sidecarWrites.values { try? AtomicFile.write(entry, to: sidecarURL(entry.fileName)) }
        for playlist in playlistWrites { try? AtomicFile.write(playlist, to: playlistURL(playlist.id)) }
        index = Index(entries: entries, playlists: playlists)
        guard index != loaded else { return }
        Log.logger("audio").error("audio index repaired from disk: \(entries.count, privacy: .public) entries")
        saveIndex()
    }

    /// Nothing could be checked: serve what the index (if it read) says is there, change nothing, retry later.
    /// The store is read-only meanwhile, so nothing is decided from this stand-in.
    private func abort(_ loaded: Index?, audio: Set<String>?) {
        reconcilePending = true
        index = Index(entries: (loaded?.entries ?? [:]).filter { key, entry in
            key == entry.songId && Self.isValid(entry) && audio?.contains(entry.fileName) != false
        }, playlists: loaded?.playlists ?? [:])
    }
}
