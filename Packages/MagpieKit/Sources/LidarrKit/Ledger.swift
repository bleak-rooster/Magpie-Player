import Foundation
import MagpieCore
import os

/// Where a request's album was brought in: the main root (fallback mode) or the confirmed Finds root.
public enum LedgerMode: String, Sendable, Codable {
    case fallback
    case finds
}

/// Y5 (C3): one lossy track file of a find, recorded when the owner taps Add to your library (Keep's intent), from the
/// files inside the Finds folder. Trackfile ids go stale after Lidarr's move, so the MP3 is found again later by its
/// path relative to the artist folder and its track (`foreignTrackId`), and only deleted at the same size.
public struct FindFile: Sendable, Equatable, Codable {
    public var id: Int
    public var albumId: Int
    public var foreignTrackId: String?
    /// The path below the artist folder (`Album (2001)/01 - Song.mp3`).
    public var relativePath: String
    public var size: Int64
    public var quality: String?

    public init(id: Int, albumId: Int, foreignTrackId: String?, relativePath: String, size: Int64, quality: String?) {
        self.id = id; self.albumId = albumId; self.foreignTrackId = foreignTrackId
        self.relativePath = relativePath; self.size = size; self.quality = quality
    }
}

/// Whether Magpie's monitor write for an entry reached Lidarr (fix rounds 3–4: "when in doubt, don't write").
public enum MonitorSend: String, Sendable, Codable {
    /// Verifiably not in Lidarr: refused by the gate before anything left the device, or a GET after a
    /// failed write showed the album still unmonitored. A retry may send it.
    case notSent
    /// May have reached Lidarr: recorded just before every send (so a crash mid-send leaves it), and kept
    /// when the answer was lost and a GET couldn't tell. Never re-sent, never undone.
    case unclear
    /// Succeeded, or a GET showed the album monitored.
    case applied
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
    /// The artist's MusicBrainz id when the entry was made. Lidarr can hand a deleted artist's id to another
    /// artist, so "Magpie created it" needs both the id and this MBID to match (`created(_:)`).
    public var artistMbid: MBID?
    /// The album was already monitored before Magpie touched it, so Cancel must not unmonitor it.
    public var wasMonitoredBefore: Bool
    /// Root folder the artist lived in when the request was made.
    public var root: String
    public var mode: LedgerMode
    /// Set when the owner kept the album, only once the Keep is confirmed (Y5: never before the write).
    public var keptAt: Date?
    /// Y5: a Keep of this artist is under way (saved before its write); cleared at the commit or when it verifiably
    /// didn't apply. Every reader that *refuses* on kept treats it as kept (`isKeptOrKeeping`, C5).
    public var keepIntentAt: Date?
    /// Y5 (C3): the find's lossy files as recorded at the Keep's intent: what the MP3 rule may later delete.
    public var findFiles: [FindFile]?
    /// The Lidarr server this entry belongs to (`LidarrClient.instanceScope`). Ids are only meaningful on
    /// that server; a `Ledger` scoped to another server never sees this entry.
    public var instance: String?
    /// Where Magpie's monitor write stands. Only applied entries may be undone. Entries saved without a known
    /// state (older files, round 2's `applied` flag, an unknown value) read as `unclear`: fail safe.
    public var send: MonitorSend
    /// The request that made this entry (its `RequestID` text), if any.
    public var requestId: String?
    /// Set when the request that made the entry finished and its clean-up is done: a closed entry says
    /// nothing about who monitors the album *now*, so it is never inherited.
    public var closedAt: Date?

    public init(lidarrArtistId: Int, albumId: Int?, rgMbid: MBID, createdArtist: Bool, wasMonitoredBefore: Bool,
                root: String, mode: LedgerMode, keptAt: Date? = nil, instance: String? = nil,
                send: MonitorSend = .unclear, requestId: String? = nil, closedAt: Date? = nil, artistMbid: MBID? = nil) {
        self.lidarrArtistId = lidarrArtistId; self.albumId = albumId; self.rgMbid = rgMbid; self.artistMbid = artistMbid
        self.createdArtist = createdArtist; self.wasMonitoredBefore = wasMonitoredBefore
        self.root = root; self.mode = mode; self.keptAt = keptAt; self.instance = instance
        self.send = send; self.requestId = requestId; self.closedAt = closedAt
    }

    public var isApplied: Bool { send == .applied }

    /// C5: kept, or a Keep under way. Every check that refuses on "kept" uses this.
    public var isKeptOrKeeping: Bool { keptAt != nil || keepIntentAt != nil }
    /// A confirmed Keep and nothing under way: what Bring in more and the kept-MP3 delete require.
    public var isConfirmedKept: Bool { keptAt != nil && keepIntentAt == nil }

    /// Magpie created `artist`: this entry says so, for the same Lidarr id *and* the same artist MBID. Lidarr may
    /// reuse a deleted artist's id for another artist; an entry without an MBID never counts (fails safe).
    public func created(_ artist: LidarrArtist) -> Bool {
        createdArtist && lidarrArtistId == artist.id && artistMbid != nil && artistMbid == artist.foreignArtistId
    }
    public var isOpen: Bool { closedAt == nil }

    private enum CodingKeys: String, CodingKey {
        case lidarrArtistId, albumId, rgMbid, createdArtist, wasMonitoredBefore, root, mode, keptAt, instance
        case send, requestId, closedAt, artistMbid, keepIntentAt, findFiles
    }

    /// Fix round 4: a missing or unknown `send` decodes as `unclear`, never as applied. That includes entries
    /// from round 2 (`applied: true/false`, no `send`) and from round 3 (no `send` meant applied): pre-release,
    /// so they are not trusted for an undo.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lidarrArtistId = try c.decode(Int.self, forKey: .lidarrArtistId)
        albumId = try c.decodeIfPresent(Int.self, forKey: .albumId)
        rgMbid = try c.decode(MBID.self, forKey: .rgMbid)
        createdArtist = try c.decode(Bool.self, forKey: .createdArtist)
        wasMonitoredBefore = try c.decode(Bool.self, forKey: .wasMonitoredBefore)
        root = try c.decode(String.self, forKey: .root)
        mode = try c.decode(LedgerMode.self, forKey: .mode)
        keptAt = try c.decodeIfPresent(Date.self, forKey: .keptAt)
        instance = try c.decodeIfPresent(String.self, forKey: .instance)
        send = ((try? c.decodeIfPresent(String.self, forKey: .send)) ?? nil).flatMap(MonitorSend.init(rawValue:))
            ?? .unclear
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        artistMbid = try? c.decodeIfPresent(MBID.self, forKey: .artistMbid)
        keepIntentAt = try? c.decodeIfPresent(Date.self, forKey: .keepIntentAt)
        findFiles = try? c.decodeIfPresent([FindFile].self, forKey: .findFiles)
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
        // Y5 fix I4: a record that replaces an entry (the same album, or the placeholder it supersedes) never drops the
        // Keep's state: a kept time, a Keep under way or the find's file record is carried over when the new entry has
        // none. Only `update(artistId:)` clears them (the Keep's own commit and clean-up).
        var e = e
        for old in list where old.instance == e.instance && replaces(e, old) {
            if e.keptAt == nil { e.keptAt = old.keptAt }
            if e.keepIntentAt == nil { e.keepIntentAt = old.keepIntentAt }
            if e.findFiles == nil { e.findFiles = old.findFiles }
        }
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

    private static func replaces(_ e: LedgerEntry, _ old: LedgerEntry) -> Bool {
        if let albumId = e.albumId, old.albumId == albumId { return true }
        return old.albumId == nil && old.lidarrArtistId == e.lidarrArtistId && old.rgMbid == e.rgMbid
    }

    /// I10: changes every entry of this server for the artist in one read-modify-write and one save, so a crash
    /// leaves either all of them changed or none (Keep's intent and commit). Returns how many changed.
    @discardableResult
    public func update(artistId: Int, _ change: (inout LedgerEntry) -> Void) throws -> Int {
        guard let fileURL else {
            var n = 0
            memory = Self.changing(memory, artistId: artistId, instance: instance, &n, change)
            return n
        }
        return try withoutActuallyEscaping(change) { change in
            try Self.fileLock.withLockUnchecked {
                var n = 0
                let next = Self.changing(try Self.read(fileURL), artistId: artistId, instance: instance, &n, change)
                if n > 0 { try LocalFile.save(next, to: fileURL) }
                return n
            }
        }
    }

    private static func changing(_ list: [LedgerEntry], artistId: Int, instance: String?, _ changed: inout Int,
                                 _ change: (inout LedgerEntry) -> Void) -> [LedgerEntry] {
        var out: [LedgerEntry] = []
        for old in list {
            guard old.instance == instance, old.lidarrArtistId == artistId else { out.append(old); continue }
            var e = old
            change(&e)
            e.instance = instance
            if e != old { changed += 1 }
            out.append(e)
        }
        return out
    }

    public func entry(albumId: Int) throws -> LedgerEntry? {
        try entries.first { $0.albumId == albumId }
    }

    /// The newest entry for a release group (G7: dedupe by rgMbid before any add).
    public func entry(rgMbid: MBID) throws -> LedgerEntry? {
        try entries.last { $0.rgMbid == rgMbid }
    }

    /// Sign-out (V-fix): forgets the entries of every Lidarr whose entries are all closed (finished requests,
    /// nothing left to undo or follow up). A Lidarr with any open entry keeps all of its entries: the owner may
    /// reconnect it. The file goes once nothing is left; an unreadable file is left alone.
    public static func forgetFinished(in directory: URL = URL.applicationSupportDirectory) {
        let url = defaultURL(in: directory)
        fileLock.withLock {
            guard FileManager.default.fileExists(atPath: url.path), let all = try? read(url) else { return }
            let open = Set(all.filter(\.isOpen).map { $0.instance ?? "" })
            let kept = all.filter { open.contains($0.instance ?? "") }
            guard kept.count < all.count else { return }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? LocalFile.save(kept, to: url)
            }
        }
    }

    /// Whether Magpie created this artist on this server (same id and same MBID, `LedgerEntry.created`).
    public func createdArtist(_ artist: LidarrArtist) throws -> Bool {
        try entries.contains { $0.created(artist) }
    }
}
