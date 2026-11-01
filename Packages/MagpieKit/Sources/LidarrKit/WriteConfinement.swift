import Foundation
import MagpieCore

/// Security FM1: the gate's own confinement of the writes that can delete, move or change an artist, so G3 and G4
/// don't rest on the runner's checks alone. A runner bug (wrong ids, a stale record, a wider body) is refused here.
///
/// Checked at the gate, from the ledger and the gate's own fresh Lidarr reads, never from anything the caller says:
/// - `PUT /artist/editor`: only for an artist the ledger says Magpie created; a `metadataProfileId` (R18) only names
///   one of Magpie's own profiles (Magpie Finds, or a name `ReleaseTypes.profileName` makes; read fresh). A body with `rootFolderPath` moves
///   only into the current main root (`moveFiles: true`, and only a tagged find now inside the Finds root), or
///   points back at the current Finds root (otherwise, which moves no files);
/// - `DELETE /artist/{id}`: only an artist Magpie created, nothing of it kept, carrying `magpie-find` and strictly
///   inside the Finds root right now;
/// - `DELETE /trackfile/{id}` and `/trackfile/bulk`: every id is read first; each must belong to such an artist and
///   lie strictly inside both the Finds root and that artist's folder;
/// - `PUT /album/monitor` (H2b fix 1): `monitored: true` only for albums the ledger has an entry for (Magpie records
///   each album before it monitors it: a Try, a Bring in more); `monitored: false` only for albums the ledger says
///   Magpie monitored (not monitored before) and that aren't kept. Ledger only, no Lidarr read;
/// - `DELETE /queue/{id}` (R17): only a download of a live Magpie request's own album, re-read from the queue
///   (`queueDelete`).
///
/// The gate runs confined writes one at a time, checks to answer (`LidarrWriteGate`), and reads the ledger's kept
/// state once more right before sending a delete.
///
/// The roots come from the owner's setup (`roots`), checked against Lidarr's fresh root folders: the main root must
/// be one of them, and the Finds root must still pass G2 (`PathGuard.findsRootStillValid`). The ledger must belong
/// to the same Lidarr as the gate. Anything that can't be read refuses the write (`WriteGateError.unconfirmed`).
public struct WriteConfinement: Sendable {
    /// What the owner set up, read on every confined write.
    public struct Roots: Sendable, Equatable {
        public var mainRoot: String?
        public var findsRoot: String?
        public var findTagId: Int?

        public init(mainRoot: String?, findsRoot: String?, findTagId: Int?) {
            self.mainRoot = mainRoot; self.findsRoot = findsRoot; self.findTagId = findTagId
        }
    }

    let ledger: Ledger
    let roots: @Sendable () async -> Roots
    /// R17: the ids (`RequestID` text) of Magpie's requests on their way right now; nil while they can't be known.
    /// Without it, queue deletes are refused.
    let liveRequests: (@Sendable () async -> Set<String>?)?

    public init(ledger: Ledger, roots: @escaping @Sendable () async -> Roots,
                liveRequests: (@Sendable () async -> Set<String>?)? = nil) {
        self.ledger = ledger
        self.roots = roots
        self.liveRequests = liveRequests
    }

    /// At most this many track files in one delete (each is read first).
    static let maxTrackFiles = 500

    enum Verdict: Equatable {
        /// May be sent. `artists`: the artists a delete touches, whose kept state is read again right before it goes.
        case confined(artists: Set<Int>)
        case refused(String)
        /// Something couldn't be read: not sent.
        case unknown
    }

    private struct Unreadable: Error {}
    private struct Refusal: Error { let reason: String }

    /// The writes the confinement decides, as the gate parsed them (`ForbiddenWrites.confined`).
    enum Write {
        /// `PUT /artist/editor` with this body.
        case editor([String: Any])
        /// `DELETE /artist/{id}`.
        case artistDelete(Int)
        /// `DELETE /trackfile/{id}` or `/trackfile/bulk`.
        case trackFileDelete([Int])
        /// `PUT /album/monitor`.
        case albumMonitor(albumIds: [Int], monitored: Bool)
        /// `DELETE /queue/{id}` (R17).
        case queueDelete(Int)
    }

    func check(_ write: Write, lidarr: LidarrClient) async -> Verdict {
        guard ledger.instance == lidarr.instanceScope else { return .refused("the ledger belongs to another Lidarr") }
        if case .queueDelete(let id) = write { return await queueDelete(id, lidarr: lidarr) }
        do {
            let entries: [LedgerEntry]
            do { entries = try await ledger.entries } catch { throw Unreadable() }
            let context = Context(entries: entries, lidarr: lidarr, roots: await roots())
            switch write {
            case .editor(let body):
                try await context.editor(body)
                return .confined(artists: [])
            case .artistDelete(let id):
                try await context.artistDelete(id)
                return .confined(artists: [id])
            case .trackFileDelete(let ids):
                return .confined(artists: try await context.trackFileDelete(ids))
            case .albumMonitor(let ids, let monitored):
                try context.albumMonitor(ids, monitored: monitored)
                return .confined(artists: [])
            case .queueDelete:
                return .unknown   // handled above
            }
        } catch let refusal as Refusal {
            return .refused(refusal.reason)
        } catch {
            return .unknown
        }
    }

    /// R17: `DELETE /queue/{id}` only removes a download Magpie's own live request is waiting on. From the ledger, the
    /// live requests and a fresh read of the whole queue (never from the caller):
    /// - the queue lists item `id` now, with an album and an artist, still downloading before import (fix round 1 I1:
    ///   never a copy that's complete, waiting to import, importing or blocked);
    /// - every queue row of the same download (`downloadId`; fix round 1 I2) has an open ledger entry for its album and
    ///   artist, for a request that is live right now, applied, not kept, and saying Magpie monitored the album
    ///   (`wasMonitoredBefore == false`) or added its artist; a row without a download id can't be shown to be
    ///   Magpie's alone and is refused.
    /// The queue only, before import: it never touches library files, and nothing of the owner's own downloads.
    func queueDelete(_ id: Int, lidarr: LidarrClient) async -> Verdict {
        guard let liveRequests else { return .refused("queue deletes need Magpie's live requests") }
        guard let live = await liveRequests() else { return .unknown }
        let entries: [LedgerEntry]
        do { entries = try await ledger.entries } catch { return .unknown }
        let mine = entries.filter { e in
            e.isOpen && e.isApplied && e.keptAt == nil && e.albumId != nil
                && (e.createdArtist || !e.wasMonitoredBefore) && e.requestId.map(live.contains) == true
        }
        guard !mine.isEmpty else { return .refused("no live request of Magpie's has a download") }
        let items: [QueueItem]
        do {
            items = try await lidarr.queueDetails(albumIds: [])   // the whole queue: every album of the download
        } catch {
            return .unknown
        }
        guard let item = items.first(where: { $0.id == id }) else {
            return .refused("not one of Magpie's downloads in the queue now")
        }
        guard item.isDownloadingBeforeImport else { return .refused("that copy is past downloading") }
        guard let downloadId = item.downloadId else { return .refused("the queue doesn't say which download it is") }
        for row in items where row.downloadId == downloadId {
            guard let albumId = row.albumId, let artistId = row.artistId,
                  mine.contains(where: { $0.albumId == albumId && $0.lidarrArtistId == artistId }) else {
                return .refused("not one of Magpie's downloads in the queue now")
            }
            // A plain album entry is the album's only one (`Ledger.record`); an owner's monitor before Magpie's never
            // passes.
            guard !entries.contains(where: { $0.albumId == albumId && ($0.wasMonitoredBefore && !$0.createdArtist) }) else {
                return .refused("the owner monitored this album")
            }
        }
        return .confined(artists: [])
    }

    /// Right before a delete is sent: none of `artists` is kept in the ledger now. Nil: the ledger can't be read.
    func stillUnkept(_ artists: Set<Int>) async -> Bool? {
        guard !artists.isEmpty else { return true }
        guard let entries = try? await ledger.entries else { return nil }
        return !entries.contains { artists.contains($0.lidarrArtistId) && $0.keptAt != nil }
    }

    /// One confined write's view: the ledger as read, the owner's roots, and fresh Lidarr reads (cached per write).
    private final class Context {
        let entries: [LedgerEntry]
        let lidarr: LidarrClient
        let roots: Roots
        private var freshRoots: [String]?
        private var artists: [Int: LidarrArtist] = [:]

        init(entries: [LedgerEntry], lidarr: LidarrClient, roots: Roots) {
            self.entries = entries; self.lidarr = lidarr; self.roots = roots
        }

        /// The ledger says Magpie created the artist Lidarr has under this id now (same MBID: ids can be reused).
        func created(_ artistId: Int) async throws -> Bool {
            guard entries.contains(where: { $0.lidarrArtistId == artistId && $0.createdArtist }) else { return false }
            let fresh = try await artist(artistId)
            return entries.contains { $0.created(fresh) }
        }

        func kept(_ artistId: Int) -> Bool {
            entries.contains { $0.lidarrArtistId == artistId && $0.keptAt != nil }
        }

        /// A 404 refuses (nothing there to confine); any other failure is unreadable.
        private func read<T>(_ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch LidarrError.http(status: 404) {
                throw Refusal(reason: "Lidarr doesn't have it")
            } catch {
                throw Unreadable()
            }
        }

        func lidarrRoots() async throws -> [String] {
            if let freshRoots { return freshRoots }
            let read = try await read { try await lidarr.rootFolders().map(\.path) }
            freshRoots = read
            return read
        }

        func artist(_ id: Int) async throws -> LidarrArtist {
            if let known = artists[id] { return known }
            let read = try await read { try await lidarr.artist(id: id) }
            artists[id] = read
            return read
        }

        /// The Finds root, confined against every other fresh root and the main root (case-sensitive), and the
        /// `magpie-find` tag. Refused when Finds isn't set up or its root no longer checks out.
        func findsGuard() async throws -> (guard: PathGuard, tag: Int) {
            guard let finds = roots.findsRoot, let main = roots.mainRoot, let tag = roots.findTagId else {
                throw Refusal(reason: "Finds isn't set up")
            }
            let fresh = try await lidarrRoots()
            guard PathGuard.findsRootStillValid(finds, main: main, roots: fresh) else {
                throw Refusal(reason: "the Finds root isn't a confirmed Lidarr root folder")
            }
            let others = fresh.filter { !Self.sameBytes($0, finds) } + [main]
            return (PathGuard(findsRoot: finds, otherRoots: others, caseInsensitive: false), tag)
        }

        /// Created by Magpie, tagged `magpie-find`, and strictly inside the Finds root now. Returns its folder.
        func findArtist(_ id: Int) async throws -> (path: String, guard: PathGuard) {
            guard try await created(id) else { throw Refusal(reason: "not an artist Magpie added") }
            let (finds, tag) = try await findsGuard()
            let artist = try await artist(id)
            guard artist.tags.contains(tag), let path = artist.path, finds.isInside(path) else {
                throw Refusal(reason: "the artist isn't a find in the Finds folder")
            }
            return (path, finds)
        }

        func artistDelete(_ id: Int) async throws {
            guard !kept(id) else { throw Refusal(reason: "the artist is kept") }
            _ = try await findArtist(id)
        }

        /// Returns the artists the files belong to.
        func trackFileDelete(_ ids: [Int]) async throws -> Set<Int> {
            var artists = Set<Int>()
            guard !ids.isEmpty, ids.count <= WriteConfinement.maxTrackFiles else {
                throw Refusal(reason: "track file delete needs 1 to \(WriteConfinement.maxTrackFiles) ids")
            }
            let fresh = try await lidarrRoots()
            for id in ids {
                let file = try await read { try await lidarr.trackFile(id: id) }
                guard file.id == id, let artistId = file.artistId else { throw Refusal(reason: "track file without an artist") }
                guard !kept(artistId) else { throw Refusal(reason: "the artist is kept") }
                let (folder, finds) = try await findArtist(artistId)
                let artistGuard = PathGuard(findsRoot: folder,
                                            otherRoots: fresh.filter { !Self.sameBytes($0, roots.findsRoot ?? "") }
                                                + [roots.mainRoot].compactMap { $0 },
                                            caseInsensitive: false)
                guard finds.isInside(file.path), artistGuard.isInside(file.path) else {
                    throw Refusal(reason: "a track file outside the find's folder")
                }
                artists.insert(artistId)
            }
            return artists
        }

        func albumMonitor(_ ids: [Int], monitored: Bool) throws {
            for id in ids {
                let entry = entries.filter { $0.albumId == id }
                guard !entry.isEmpty else { throw Refusal(reason: "not an album Magpie asked for") }
                if !monitored {
                    guard entry.allSatisfy({ !$0.wasMonitoredBefore && $0.keptAt == nil }) else {
                        throw Refusal(reason: "Magpie only unmonitors albums it monitored and nobody kept")
                    }
                }
            }
        }

        func editor(_ body: [String: Any]) async throws {
            let value = { (name: String) in body.first { $0.key.lowercased() == name }?.value }
            guard let ids = value("artistids") as? [Any], ids.count == 1, let id = (ids[0] as? NSNumber)?.intValue else {
                throw Refusal(reason: "the artist editor changes one artist")
            }
            guard try await created(id) else { throw Refusal(reason: "not an artist Magpie added") }
            if let profile = (value("metadataprofileid") as? NSNumber)?.intValue {
                // R18: only to one of Magpie's own metadata profiles, by its name in Lidarr now.
                let profiles = try await read { try await lidarr.metadataProfiles() }
                guard let name = profiles.first(where: { $0.id == profile })?.name,
                      ReleaseTypes.isMagpieMetadataProfile(name) else {
                    throw Refusal(reason: "only Magpie's own metadata profiles")
                }
            }
            guard let target = value("rootfolderpath") as? String else { return }
            if let move = value("movefiles") as? NSNumber, move.boolValue {
                // Keep: a tagged find in the Finds folder moves into the main root, nowhere else.
                guard let main = roots.mainRoot, Self.sameBytes(target, main),
                      try await lidarrRoots().contains(where: { Self.sameBytes($0, main) }) else {
                    throw Refusal(reason: "files only move into the main root folder")
                }
                _ = try await findArtist(id)
            } else {
                // Keep's restore: points the artist back at the Finds root; no files move.
                _ = try await findsGuard()
                guard let finds = roots.findsRoot, Self.sameBytes(target, finds) else {
                    throw Refusal(reason: "an artist is only pointed back at the Finds root folder")
                }
            }
        }

        static func sameBytes(_ a: String, _ b: String) -> Bool {
            guard let x = PathGuard.standardize(a), let y = PathGuard.standardize(b) else { return false }
            return Array(x.utf8) == Array(y.utf8)
        }
    }
}
