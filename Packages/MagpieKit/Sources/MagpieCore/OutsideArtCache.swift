import CryptoKit
import Foundation

/// B1 (D122): outside pictures (an artist's, an album's cover) kept on the phone, one small file each, so a page that
/// shows them again shows them at once. Only pictures that loaded are kept: a miss, an outage or a load cut short
/// leaves nothing, so the next look tries again. Files are named by a hash of the key (no MBID or URL in the name),
/// excluded from backup, and removed on sign-out.
public final class OutsideArtDiskCache: @unchecked Sendable {
    public let directory: URL
    /// Files kept; past this the oldest fifth goes.
    public let maxFiles: Int
    private let lock = NSLock()

    public init(directory: URL, maxFiles: Int = 3000) {
        self.directory = directory
        self.maxFiles = maxFiles
    }

    /// `Application Support/Magpie/OutsideArt` under `root`.
    public static func directory(root: URL) -> URL { root.appending(path: "Magpie/OutsideArt", directoryHint: .isDirectory) }

    private func url(_ key: OutsideArtKey) -> URL {
        let digest = SHA256.hash(data: Data(key.token.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    /// The saved picture's bytes, if any (at most `OutsideArtPolicy.maxBytes`).
    public func data(for key: OutsideArtKey) -> Data? {
        let file = url(key)
        guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= OutsideArtPolicy.maxBytes else { return nil }
        return data
    }

    public func save(_ data: Data, for key: OutsideArtKey) {
        guard !data.isEmpty, data.count <= OutsideArtPolicy.maxBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try data.write(to: url(key), options: .atomic)
            trimIfNeeded()
        } catch {}
    }

    /// Everything goes (sign-out).
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    public var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > maxFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(max(1, files.count / 5)) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// B1: at most `limit` jobs at once; the rest wait their turn (a waiter that is cancelled leaves the queue).
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// The most that ran at once (tests).
    public private(set) var peak = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            peak = max(peak, running)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiting.append((id, c))
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
        if waiting.isEmpty {
            running -= 1
        } else {
            peak = max(peak, running)
            waiting.removeFirst().continuation.resume()   // the slot passes straight on
        }
    }
}

/// B1 (owner, item 5): where an album's cover may come from once the release group's own front is missing, in order.
public struct OutsideCoverFallbacks: Sendable {
    /// A few of the release group's releases (MusicBrainz), each tried for its own front cover.
    public var releases: (@Sendable (MBID) async throws -> [MBID])?
    /// The cover Lidarr's album lookup names.
    public var lidarrCover: (@Sendable (MBID) async throws -> URL?)?

    public init(releases: (@Sendable (MBID) async throws -> [MBID])? = nil,
                lidarrCover: (@Sendable (MBID) async throws -> URL?)? = nil) {
        self.releases = releases; self.lidarrCover = lidarrCover
    }

    /// Releases tried for their front, at most.
    public static let releasesTried = 3
}
