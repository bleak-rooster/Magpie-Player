import Foundation
import MagpieCore

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
public actor Ledger {
    /// `Application Support/Magpie/lidarr-ledger.json`.
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory) -> URL {
        LocalFile.url("lidarr-ledger.json", in: directory)
    }

    private let fileURL: URL?
    public private(set) var entries: [LedgerEntry]

    /// `fileURL` nil keeps the ledger in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        self.entries = fileURL.map { LocalFile.load([LedgerEntry].self, from: $0, fallback: [], category: "ledger") } ?? []
    }

    /// Adds the entry, or replaces the one for the same album. Saved before returning.
    public func record(_ e: LedgerEntry) throws {
        var next = entries
        if let i = next.firstIndex(where: { $0.albumId == e.albumId }) { next[i] = e } else { next.append(e) }
        if let fileURL { try LocalFile.save(next, to: fileURL) }
        entries = next
    }

    public func entry(albumId: Int) -> LedgerEntry? {
        entries.first { $0.albumId == albumId }
    }
}
