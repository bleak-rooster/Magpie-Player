import CryptoKit
import Foundation
import MagpieCore

// Round 24 (owner, 2026-11-08, item 10): "Change what's monitored" for any artist in Lidarr, Magpie's or the owner's,
// and "Clean up unmatched songs" afterwards (D237–D244). The owner's consent is written down here, in the ledger's
// monitoring book (`Ledger.monitoringBook`), before anything is sent; the gate's `performOwned` and `performCleanup` (`OwnedShape`)
// rules (`WriteConfinement+Owned.swift`) let a write through only when this record, checked against fresh Lidarr reads,
// says the owner asked for exactly it. The caller's live lists are never trusted.

/// One track file the owner's confirmation named: its Lidarr id, its album and its size at that moment (D243). A file
/// whose size has changed since is not the file the owner saw, so it is never deleted.
public struct OwnedFile: Sendable, Equatable, Hashable, Codable {
    public var id: Int
    public var albumId: Int
    public var size: Int64

    public init(id: Int, albumId: Int, size: Int64) {
        self.id = id; self.albumId = albumId; self.size = size
    }
}

/// An owner-approved change to one artist, saved before its first write and stepped through (each step saved before its
/// write, M6). Round 24 (owner, 2026-11-08): D237 (the change), D240 (reducing asks, Keep by default), D242 (the clean
/// up), D243 (the proofs the gate reads from it), D244 (Revert).
public struct MonitoringIntent: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// The artist moves onto one of Magpie's release-type profiles (D237, D238).
        case monitoringChange
        /// Files of albums that stopped being monitored go: the ones the confirmation named, nothing else (D242).
        case unmatchedCleanup
        /// The artist goes back to the profile recorded before Magpie's first change (D244).
        case revert
    }

    public enum Step: String, Sendable, Codable {
        /// Saved; nothing sent yet.
        case saved
        /// The albums falling out of the new set are unmonitored (read back).
        case unmonitored
        /// The profile is assigned (read back).
        case profileSet
        /// RefreshArtist sent; its command id is saved.
        case refreshSent
        /// Lidarr says the refresh completed.
        case refreshed
        /// The albums the new set brings in are monitored and searched for.
        case monitored
        /// A clean-up's deletes are under way (`deletedFileIds` so far).
        case deleting
        case done
        /// Couldn't be finished; nothing more is sent for it.
        case abandoned
        /// Fix round 1 I1 (a `sending` marker only): the intent is saved and Magpie's profile is being made or reused;
        /// its id is saved in `targetProfileId` before any change write.
        case profileCreated
        /// Fix round 1 M2 (a `sending` marker only): the AlbumSearch was sent; after a lost answer it is never sent again.
        case searchSent
    }

    public var id: UUID
    public internal(set) var kind: Kind
    /// The Lidarr server this belongs to (`LidarrClient.instanceScope`), stamped by the ledger.
    public var instance: String?
    public internal(set) var artistId: Int
    /// The artist's MusicBrainz id when the owner confirmed: Lidarr may hand a removed artist's id to another one.
    public internal(set) var artistMbid: MBID
    public var createdAt: Date
    /// The metadata profile the artist had before Magpie's first change: the owner's own, what Revert restores (D244).
    public internal(set) var previousProfileId: Int
    /// The profile this change assigns: one of Magpie's (`monitoringChange`) or `previousProfileId` (`revert`).
    public internal(set) var targetProfileId: Int?
    /// What the change monitors (`monitoringChange`): the gate monitors only albums these types list.
    public internal(set) var targetTypes: ReleaseTypes?
    /// The artist's albums when the owner confirmed (an album that appears with the refresh is one the new set brings in).
    public internal(set) var beforeAlbumIds: [Int]
    /// Monitored albums that fall out of the new set: only these are unmonitored.
    public internal(set) var unmonitorAlbumIds: [Int]
    /// Albums the refresh brought in, saved before they are monitored and searched for.
    public internal(set) var monitorAlbumIds: [Int]
    /// On reducing: true when the owner chose Keep them (the kept set is recorded once the change is done), false for
    /// Delete them (a clean-up of `files` follows the change).
    public internal(set) var keepFiles: Bool
    /// The files the confirmation named: what Delete them (or the clean-up) may delete, and nothing else.
    public internal(set) var files: [OwnedFile]
    /// Files left out because the owner favourited them, saved them to a playlist or keeps them on the phone (read by the
    /// app from Navidrome and the phone when the confirmation was made). Never deleted.
    public internal(set) var excludedFileIds: [Int]
    /// `confirmationHash(…)` of what the owner confirmed; the gate computes it again from this record.
    public internal(set) var confirmationHash: String?
    /// A clean-up's files gone so far.
    public var deletedFileIds: [Int]
    /// A clean-up's batch being sent (saved just before it), proven again from fresh reads after a lost answer.
    public var pendingFileIds: [Int]
    /// Fix round 3 H-L4: the batch (at most 50, of `monitorAlbumIds`) the next monitor or search covers, saved before it.
    public var monitorBatch: [Int]?
    public var refreshCommandId: Int?
    public var step: Step
    /// The step whose write is being sent (saved just before it); after a lost answer it is re-proven from a read.
    public var sending: Step?
    public var failures: Int
    public var finishedAt: Date?

    public var isOpen: Bool { step != .done && step != .abandoned }

    public init(kind: Kind, artistId: Int, artistMbid: MBID, previousProfileId: Int, targetProfileId: Int? = nil,
                targetTypes: ReleaseTypes? = nil, beforeAlbumIds: [Int] = [], unmonitorAlbumIds: [Int] = [],
                keepFiles: Bool = true, files: [OwnedFile] = [], excludedFileIds: [Int] = [], createdAt: Date,
                id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.artistId = artistId; self.artistMbid = artistMbid
        self.createdAt = createdAt; self.previousProfileId = previousProfileId; self.targetProfileId = targetProfileId
        self.targetTypes = targetTypes; self.beforeAlbumIds = beforeAlbumIds; self.unmonitorAlbumIds = unmonitorAlbumIds
        self.monitorAlbumIds = []; self.keepFiles = keepFiles; self.files = files; self.excludedFileIds = excludedFileIds
        self.deletedFileIds = []; self.pendingFileIds = []; self.step = .saved; self.failures = 0
        self.confirmationHash = kind == .unmatchedCleanup || !keepFiles
            ? Self.confirmationHash(artistId: artistId, files: files, excluded: excludedFileIds) : nil
    }

    /// What the owner confirmed, as a hash: the artist, every file (id, album, size) and every file left out, in a fixed
    /// order. The gate recomputes it from the record, so a record changed after the confirmation never deletes.
    public static func confirmationHash(artistId: Int, files: [OwnedFile], excluded: [Int]) -> String {
        let lines = ["artist \(artistId)"]
            + files.sorted { $0.id < $1.id }.map { "file \($0.id) album \($0.albumId) size \($0.size)" }
            + excluded.sorted().map { "kept \($0)" }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The record still matches the hash saved with it.
    public var matchesConfirmation: Bool {
        confirmationHash == Self.confirmationHash(artistId: artistId, files: files, excluded: excludedFileIds)
    }

    // MARK: Fix round 3 H-M2: the consent fields change only through these (nothing outside LidarrKit sets them)

    /// The Magpie profile made or reused after the intent was saved (fix round 1 I1): set once, for a change only.
    public mutating func recordProfile(_ id: Int) {
        guard kind == .monitoringChange, targetProfileId == nil, id > 0 else { return }
        targetProfileId = id
    }

    /// The albums the refresh brought in, set once, never ones that were there before.
    public mutating func recordMonitorAlbums(_ ids: [Int]) {
        guard kind == .monitoringChange, monitorAlbumIds.isEmpty else { return }
        monitorAlbumIds = ids.filter { !beforeAlbumIds.contains($0) }
    }

    /// Fix round 3 H-M3 / H-L3: files kept after all (a fresh keep list says the owner keeps them, or a check refused one):
    /// left out of the delete and the hash saved again. Only ever narrows: nothing is added to what may be deleted.
    public mutating func keepAlso(_ ids: [Int]) {
        let named = Set(files.map(\.id))
        let more = ids.filter { named.contains($0) && !excludedFileIds.contains($0) }
        guard !more.isEmpty, confirmationHash != nil else { return }
        excludedFileIds += more
        confirmationHash = Self.confirmationHash(artistId: artistId, files: files, excluded: excludedFileIds)
    }
}

/// Fix round 3 H-L1: byte sizes added without trapping (a size near `Int64.max` from a server saturates).
public enum ByteTotal {
    public static func of(_ sizes: [Int64]) -> Int64 {
        sizes.reduce(Int64(0)) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(max(0, size))
            return overflow ? Int64.max : sum
        }
    }
}

/// D241: Keep them, recorded once the change is done: the albums that stopped being monitored and their files at that
/// moment. "Clean up unmatched songs" (D242) offers only these files, while their album is still unmonitored.
public struct UnmonitoredKept: Sendable, Equatable, Codable {
    public var instance: String?
    public var artistId: Int
    public var artistMbid: MBID
    public internal(set) var albumIds: [Int]
    public internal(set) var files: [OwnedFile]
    public var recordedAt: Date

    public init(artistId: Int, artistMbid: MBID, albumIds: [Int], files: [OwnedFile], recordedAt: Date) {
        self.artistId = artistId; self.artistMbid = artistMbid; self.albumIds = albumIds; self.files = files
        self.recordedAt = recordedAt
    }
}

/// The ledger's monitoring book: every intent and kept set, of every Lidarr (each stamped with its own).
public struct MonitoringBook: Sendable, Equatable, Codable {
    public var intents: [MonitoringIntent]
    public var kept: [UnmonitoredKept]

    public init(intents: [MonitoringIntent] = [], kept: [UnmonitoredKept] = []) {
        self.intents = intents; self.kept = kept
    }

    /// The open intents of an artist.
    public func open(artistId: Int) -> [MonitoringIntent] { intents.filter { $0.artistId == artistId && $0.isOpen } }

    public func kept(artistId: Int) -> UnmonitoredKept? { kept.first { $0.artistId == artistId } }

    // MARK: Fix round 3 H-M2: the kept set changes only through these

    /// Keep them, once the change is done: its files and their albums merged into the artist's kept set.
    public mutating func recordKept(from change: MonitoringIntent, at date: Date) {
        guard change.kind == .monitoringChange, change.keepFiles, !change.files.isEmpty else { return }
        let old = kept(artistId: change.artistId).flatMap { $0.artistMbid == change.artistMbid ? $0 : nil }
        var files = old?.files ?? []
        for f in change.files where !files.contains(where: { $0.id == f.id }) { files.append(f) }
        let albums = Set(old?.albumIds ?? []).union(change.files.map(\.albumId)).sorted()
        kept.removeAll { $0.artistId == change.artistId }
        kept.append(UnmonitoredKept(artistId: change.artistId, artistMbid: change.artistMbid, albumIds: albums, files: files,
                                    recordedAt: date))
    }

    /// Files and albums leave the artist's kept set (deleted; or, fix round 3 H-M1, an album the new choice monitors
    /// again). The set goes once it holds no file.
    public mutating func forgetKept(artistId: Int, files gone: Set<Int> = [], albums: Set<Int> = []) {
        guard var set = kept(artistId: artistId) else { return }
        set.files.removeAll { gone.contains($0.id) || albums.contains($0.albumId) }
        set.albumIds = set.albumIds.filter { album in set.files.contains { $0.albumId == album } }
        kept.removeAll { $0.artistId == artistId }
        if !set.files.isEmpty { kept.append(set) }
    }

    /// Fix round 3 H-M1: Revert puts the artist back as it was: nothing of it stays offered for clean-up.
    public mutating func forgetKept(artistId: Int) { kept.removeAll { $0.artistId == artistId } }
}
