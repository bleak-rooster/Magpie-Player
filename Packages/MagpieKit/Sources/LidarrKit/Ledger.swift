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
///
/// `albumId` is nil for an artist-level entry: Magpie created the artist, but Lidarr hasn't listed the album
/// yet (its refresh after the add is asynchronous). It is replaced by the album entry once the album is known.
public struct LedgerEntry: Sendable, Equatable, Codable {
    public var lidarrArtistId: Int
    public var albumId: Int?
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
    /// The Lidarr server this entry belongs to (`LidarrClient.instanceScope`). Ids are only meaningful on
    /// that server; a `Ledger` scoped to another server never sees this entry.
    public var instance: String?

    public init(lidarrArtistId: Int, albumId: Int?, rgMbid: MBID, createdArtist: Bool, wasMonitoredBefore: Bool,
                root: String, mode: LedgerMode, keptAt: Date? = nil, instance: String? = nil) {
        self.lidarrArtistId = lidarrArtistId; self.albumId = albumId; self.rgMbid = rgMbid
        self.createdArtist = createdArtist; self.wasMonitoredBefore = wasMonitoredBefore
        self.root = root; self.mode = mode; self.keptAt = keptAt; self.instance = instance
    }
}

/// The on-device record of every Lidarr album request Magpie made. One entry per (server, album id), plus
/// artist-level entries for artists Magpie created whose album isn't listed yet.
///
/// A ledger is scoped to one Lidarr server (`instance`): it stamps what it records and ignores every entry
/// from another server, so ids from the dev stack can never steer writes on the owner's Lidarr.
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
    /// The server this ledger reads and writes for; nil = unscoped (sees only unstamped entries).
    public nonisolated let instance: String?
    /// Only used when `fileURL` is nil.
    private var memory: [LedgerEntry] = []

    /// `fileURL` nil keeps the ledger in memory only.
    public init(fileURL: URL?, instance: String? = nil) {
        self.fileURL = fileURL
        self.instance = instance
    }

    private static func read(_ url: URL) throws -> [LedgerEntry] {
        try LocalFile.load([LedgerEntry].self, from: url, fallback: [], category: "ledger")
    }

    private func all() throws -> [LedgerEntry] {
        guard let fileURL else { return memory }
        return try Self.fileLock.withLock { try Self.read(fileURL) }
    }

    /// This server's entries.
    public var entries: [LedgerEntry] {
        get throws { try all().filter { $0.instance == instance } }
    }

    /// Adds the entry (stamped with this ledger's server), or replaces this server's entry for the same album.
    /// An album entry also replaces the artist-level entry for the same artist and release group.
    public func record(_ e: LedgerEntry) throws {
        let stamped = { var x = e; x.instance = self.instance; return x }()
        guard let fileURL else { memory = Self.upserting(stamped, into: memory); return }
        try Self.fileLock.withLock {
            try LocalFile.save(Self.upserting(stamped, into: try Self.read(fileURL)), to: fileURL)
        }
    }

    private static func upserting(_ e: LedgerEntry, into list: [LedgerEntry]) -> [LedgerEntry] {
        var next = list.filter { old in
            guard old.instance == e.instance else { return true }
            if let albumId = e.albumId {
                if old.albumId == albumId { return false }
                // The album is known now: drop the artist-level placeholder it replaces.
                return !(old.albumId == nil && old.lidarrArtistId == e.lidarrArtistId && old.rgMbid == e.rgMbid)
            }
            return !(old.albumId == nil && old.lidarrArtistId == e.lidarrArtistId && old.rgMbid == e.rgMbid)
        }
        next.append(e)
        return next
    }

    public func entry(albumId: Int) throws -> LedgerEntry? {
        try entries.first { $0.albumId == albumId }
    }

    /// The newest entry for a release group (G7: dedupe by rgMbid before any add).
    public func entry(rgMbid: MBID) throws -> LedgerEntry? {
        try entries.last { $0.rgMbid == rgMbid }
    }

    /// Whether Magpie created this artist on this server.
    public func createdArtist(_ lidarrArtistId: Int) throws -> Bool {
        try entries.contains { $0.lidarrArtistId == lidarrArtistId && $0.createdArtist }
    }
}
