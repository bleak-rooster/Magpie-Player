import CryptoKit
import Foundation

/// B1 (D122): outside pictures (an artist's, an album's cover) kept on the phone, one small file each (the picture as
/// shown, re-encoded), so a page that shows them again shows them at once. Only pictures that loaded are kept: a miss,
/// an outage or a load cut short leaves nothing, so the next look tries again. Files are named by a hash of the key (no
/// MBID or URL in the name), excluded from backup, and removed on sign-out.
///
/// Fix round (review 5): bounded in bytes as well as files; reading a picture marks it used, so the least recently
/// used go first; the folder is scanned only when the running total passes a cap, not on every save. Fix round
/// (review minor 1): `removeAll()` closes every cache made for the folder before it, so a load still in flight can't
/// write into the folder again after sign-out.
public final class OutsideArtDiskCache: @unchecked Sendable {
    public let directory: URL
    /// Files kept; past this (or `maxBytes`) the least recently used go until 80% is left.
    public let maxFiles: Int
    public let maxBytes: Int
    private let epoch: Int
    private let lock = NSLock()
    /// The folder's size as last scanned plus what was saved since (nil: not scanned yet).
    private var running: (files: Int, bytes: Int)?

    public init(directory: URL, maxFiles: Int = 3000, maxBytes: Int = 200 * 1024 * 1024) {
        self.directory = directory
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        epoch = Self.epochs.withLock { $0[directory.standardizedFileURL.path, default: 0] }
    }

    /// The size a picture is kept at (long side, pixels): the largest place one shows (the artist page's 180 pt header
    /// at @3x), whichever loader saved it (second fix round, re-review minor 1).
    public static let storedPixel = 600

    /// `Application Support/Magpie/OutsideArt` under `root`.
    public static func directory(root: URL) -> URL { root.appending(path: "Magpie/OutsideArt", directoryHint: .isDirectory) }

    /// Bumped by `removeAll()`: a cache made before it no longer writes.
    private static let epochs = OSAllocatedUnfairLockBox<[String: Int]>([:])

    private var isOpen: Bool { Self.epochs.withLock { $0[directory.standardizedFileURL.path, default: 0] } == epoch }

    private func url(_ key: OutsideArtKey) -> URL {
        let digest = SHA256.hash(data: Data(key.token.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    /// The saved picture's bytes, if any (at most `OutsideArtPolicy.maxBytes`). Marks it used.
    public func data(for key: OutsideArtKey) -> Data? {
        let file = url(key)
        guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= OutsideArtPolicy.maxBytes else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func save(_ data: Data, for key: OutsideArtKey) {
        guard !data.isEmpty, data.count <= OutsideArtPolicy.maxBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            let file = url(key)
            let replaced = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            try data.write(to: file, options: .atomic)
            if running == nil { running = scan().reduce((0, 0)) { ($0.0 + 1, $0.1 + $1.bytes) } }
            else if let replaced { running?.bytes += data.count - replaced }
            else { running?.files += 1; running?.bytes += data.count }
            if let r = running, r.files > maxFiles || r.bytes > maxBytes { trim() }
        } catch {}
    }

    /// Everything goes (sign-out), and every cache made for this folder before now stops writing.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        Self.epochs.withLock { $0[directory.standardizedFileURL.path, default: 0] += 1 }
        running = nil
        try? FileManager.default.removeItem(at: directory)
    }

    public var count: Int { scan().count }
    public var totalBytes: Int { scan().reduce(0) { $0 + $1.bytes } }

    private func scan() -> [(url: URL, bytes: Int, used: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.map { file in
            let values = try? file.resourceValues(forKeys: keys)
            return (file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }

    /// The least recently used go until 80% of both caps is left.
    private func trim() {
        var files = scan().sorted { $0.used < $1.used }
        var count = files.count, bytes = files.reduce(0) { $0 + $1.bytes }
        while !files.isEmpty, count > maxFiles * 8 / 10 || bytes > maxBytes * 8 / 10 {
            let oldest = files.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            count -= 1
            bytes -= oldest.bytes
        }
        running = (count, bytes)
    }
}

/// A value behind a lock (Sendable).
final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// B1: at most `limit` jobs at once; the rest wait their turn, a `visible` job before any `background` one (fix
/// round: a page on screen is never starved by a prefetch). A waiter that is cancelled leaves the queue.
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, priority: OutsideArtPriority, continuation: CheckedContinuation<Void, Error>)] = []
    /// The most that ran at once (tests).
    public private(set) var peak = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(priority: OutsideArtPriority = .visible, _ op: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { release() }
        return try await op()
    }

    private func acquire(_ priority: OutsideArtPriority) async throws {
        if running < limit {
            running += 1
            peak = max(peak, running)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiting.append((id, priority, c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        // The slot passes straight on: the first visible waiter, else the first one.
        guard let index = waiting.firstIndex(where: { $0.priority == .visible }) ?? waiting.indices.first else {
            running -= 1
            return
        }
        waiting.remove(at: index).continuation.resume()
    }
}

/// B1 (owner item 5): where an album's cover may come from once the release group's own front is missing, in order.
public struct OutsideCoverFallbacks: Sendable {
    /// A few of the release group's releases (MusicBrainz), each tried for its own front cover.
    public var releases: (@Sendable (MBID) async throws -> [MBID])?
    /// The cover Lidarr's album lookup names.
    public var lidarrCover: (@Sendable (MBID) async throws -> URL?)?
    /// Fix round (review 1, D125): a cover Aurral's catalog search names for the album (matched by its MBID), fetched
    /// through Aurral's image proxy: the picture's bytes.
    public var aurralCover: (@Sendable (MBID, OutsideAlbumHint) async throws -> Data?)?

    public init(releases: (@Sendable (MBID) async throws -> [MBID])? = nil,
                lidarrCover: (@Sendable (MBID) async throws -> URL?)? = nil,
                aurralCover: (@Sendable (MBID, OutsideAlbumHint) async throws -> Data?)? = nil) {
        self.releases = releases; self.lidarrCover = lidarrCover; self.aurralCover = aurralCover
    }

    /// Releases tried for their front, at most.
    public static let releasesTried = 3
}
