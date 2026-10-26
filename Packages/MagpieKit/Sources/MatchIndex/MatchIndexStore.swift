import CryptoKit
import Foundation
import MagpieCore
import NavidromeKit

/// The library's match index: loaded from the last snapshot at launch, rebuilt in the background from
/// `/api/song` (pages of 1000, sorted by id, `missing` songs skipped by the client) and saved again.
/// Reads never wait for a refresh: `index` is whatever was last complete.
public actor MatchIndexStore {
    public static let pageSize = 1000

    /// Fetches songs `[start, end)` and the library's total song count.
    public typealias PageFetcher = @Sendable (_ start: Int, _ end: Int) async throws -> (songs: [Song], total: Int)

    struct Snapshot: Codable {
        static let currentVersion = 1
        var version: Int
        var savedAt: Date
        var index: MatchIndex
    }

    public private(set) var index: MatchIndex = .empty
    /// When the current index was built (from the network or the snapshot); nil while empty.
    public private(set) var builtAt: Date?
    private let fileURL: URL?
    private var refreshing: Task<Void, Error>?

    /// `fileURL` nil keeps the index in memory only.
    /// The most pages one refresh reads (2,000,000 songs): a server that never ends a library can't loop forever.
    public static let defaultMaxPages = 2000
    private let maxPages: Int

    public init(fileURL: URL?, maxPages: Int = MatchIndexStore.defaultMaxPages) {
        self.fileURL = fileURL
        self.maxPages = maxPages
    }

    /// Where the snapshot for one server and account lives: Application Support/Magpie/MatchIndex/<hash>.json.
    /// The name is a hash, so neither the address nor the user name appears on disk.
    public static func snapshotURL(server: String, user: String,
                                   in directory: URL = URL.applicationSupportDirectory) -> URL {
        let digest = SHA256.hash(data: Data("\(server)|\(user)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "Magpie/MatchIndex/\(digest.prefix(32)).json")
    }

    /// Loads the saved snapshot if there is one and nothing newer is in memory. A damaged or
    /// old-format snapshot is ignored (the next refresh replaces it).
    @discardableResult
    public func loadSnapshot() -> Bool {
        guard builtAt == nil, let fileURL else { return false }
        do {
            guard let snap = try AtomicFile.read(Snapshot.self, from: fileURL),
                  snap.version == Snapshot.currentVersion else { return false }
            index = snap.index
            builtAt = snap.savedAt
            return true
        } catch {
            Log.logger("matchindex").error("snapshot unreadable; will rebuild")
            return false
        }
    }

    public func refresh(using client: NavidromeClient) async throws {
        try await refresh { start, end in try await client.songsPage(start: start, end: end) }
    }

    /// Pages through the whole library, then swaps in the new index and saves it. A failure part-way
    /// keeps the previous index. Concurrent calls share one refresh; cancelling the caller that
    /// started it cancels it.
    public func refresh(fetchPage: @escaping PageFetcher) async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.rebuild(fetchPage) }
        refreshing = task
        defer { refreshing = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func rebuild(_ fetchPage: PageFetcher) async throws {
        var songs: [Song] = []
        var seen = Set<String>()
        var start = 0
        for pageNumber in 1...maxPages {
            try Task.checkCancellation()
            let page = try await fetchPage(start, start + Self.pageSize)
            let fresh = page.songs.filter { seen.insert($0.id).inserted }
            songs.append(contentsOf: fresh)
            start += Self.pageSize
            // `songs` may be short of a page when the server skipped missing files, so page by position.
            if start >= page.total { break }
            // A server that ignores `_start`/`_end` (same page, or the whole library, every time) adds nothing new.
            if pageNumber > 1, !page.songs.isEmpty, fresh.isEmpty { break }
            if pageNumber == maxPages {
                Log.logger("matchindex").warning("stopped at \(self.maxPages, privacy: .public) pages; keeping what was read")
            }
        }
        let built = MatchIndex(songs: songs)
        try Task.checkCancellation()   // erased (signed out) meanwhile
        let now = Date()
        index = built
        builtAt = now
        if let fileURL {
            do {
                try AtomicFile.write(Snapshot(version: Snapshot.currentVersion, savedAt: now, index: built), to: fileURL)
                try Self.excludeFromBackup(fileURL)
            } catch {
                Log.logger("matchindex").error("snapshot not saved: \(Log.category(of: error), privacy: .public)")
            }
        }
    }

    /// The snapshot is library metadata the app can rebuild: keep it (and its folder) out of device
    /// backups. Set after every write, since the atomic replace swaps in a new file.
    static func excludeFromBackup(_ fileURL: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = fileURL, dir = fileURL.deletingLastPathComponent()
        try file.setResourceValues(values)
        try dir.setResourceValues(values)
    }

    /// Forgets the index and deletes the snapshot (sign-out).
    public func erase() {
        refreshing?.cancel()
        index = .empty
        builtAt = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
