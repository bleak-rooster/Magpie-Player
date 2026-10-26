import Foundation
import MagpieCore
import os

/// Where a request's album was brought in: the main root (fallback mode) or the confirmed Finds root.
public enum LedgerMode: String, Sendable, Codable {
    case fallback
    case finds
}

/// What Magpie did for one album request (A2: tags are artist-level only, so album ownership lives here).
/// Deletes and unmonitors are only ever allowed for objects the ledger says Magpie created (G3, G6).
public struct LedgerEntry: Sendable, Equatable, Codable {
    public var lidarrArtistId: Int
    public var albumId: Int
    public var rgMbid: MBID
    /// Magpie added the artist (false: the artist was already in the owner's library).
    public var createdArtist: Bool
    /// The album was already monitored before Magpie touched it, so Cancel must not unmonitor it.
    public var wasMonitoredBefore: Bool
    /// Root folder the artist lived in when the request was made.
    public var root: String
    public var mode: LedgerMode
    /// Set when the owner kept the album.
    public var keptAt: Date?

    public init(lidarrArtistId: Int, albumId: Int, rgMbid: MBID, createdArtist: Bool, wasMonitoredBefore: Bool,
                root: String, mode: LedgerMode, keptAt: Date? = nil) {
        self.lidarrArtistId = lidarrArtistId; self.albumId = albumId; self.rgMbid = rgMbid
        self.createdArtist = createdArtist; self.wasMonitoredBefore = wasMonitoredBefore
        self.root = root; self.mode = mode; self.keptAt = keptAt
    }
}

/// The on-device record of every Lidarr album request Magpie made. One entry per album id.
/// Nothing is cached per instance: every call re-reads the file under a process-wide lock (like the change
/// log), so several `Ledger` values on the same file always agree. If the file cannot be read (e.g. before
/// first unlock), every call throws `LocalFileError.unavailable` and nothing is written, so callers refuse
/// ledger-dependent actions.
public actor Ledger {
    /// `Application Support/Magpie/lidarr-ledger.json`.
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory) -> URL {
        LocalFile.url("lidarr-ledger.json", in: directory)
    }

    /// Serialises read-modify-write of ledger files across all instances.
    private static let fileLock = OSAllocatedUnfairLock()

    private let fileURL: URL?
    /// Only used when `fileURL` is nil.
    private var memory: [LedgerEntry] = []

    /// `fileURL` nil keeps the ledger in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    private static func read(_ url: URL) throws -> [LedgerEntry] {
        try LocalFile.load([LedgerEntry].self, from: url, fallback: [], category: "ledger")
    }

    public var entries: [LedgerEntry] {
        get throws {
            guard let fileURL else { return memory }
            return try Self.fileLock.withLock { try Self.read(fileURL) }
        }
    }

    /// Adds the entry, or replaces the one for the same album. Saved before returning.
    public func record(_ e: LedgerEntry) throws {
        guard let fileURL else { memory = Self.upserting(e, into: memory); return }
        try Self.fileLock.withLock {
            try LocalFile.save(Self.upserting(e, into: try Self.read(fileURL)), to: fileURL)
        }
    }

    private static func upserting(_ e: LedgerEntry, into list: [LedgerEntry]) -> [LedgerEntry] {
        var next = list
        if let i = next.firstIndex(where: { $0.albumId == e.albumId }) { next[i] = e } else { next.append(e) }
        return next
    }

    public func entry(albumId: Int) throws -> LedgerEntry? {
        try entries.first { $0.albumId == albumId }
    }

    /// The newest entry for a release group (G7: dedupe by rgMbid before any add).
    public func entry(rgMbid: MBID) throws -> LedgerEntry? {
        try entries.last { $0.rgMbid == rgMbid }
    }
}
