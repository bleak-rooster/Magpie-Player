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
/// - `DELETE /trackfile/{id}` and `/trackfile/bulk`: every id is read first. One rule per call (Y5 C4):
///   - **findDelete**: each must belong to such an artist and lie strictly inside both the Finds root and that
///     artist's folder;
///   - **keptLossyDelete** (Y5, the MP3 rule): each must belong to an artist Magpie created whose Keep is confirmed
///     (`keptAt`, no intent), now strictly inside the main root, sit at `<artist folder>/<relativePath>` of a `FindFile`
///     the ledger recorded for the same album, be that file's track (`foreignTrackId`), keep its recorded size, and
///     have a lossy quality (`isLossy`; anything unknown refuses);
///   ids needing both rules refuse;
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

    /// Which rule let a confined write through: each has its own last-moment ledger check (`lastCheck`, C4).
    enum Rule: Equatable, Sendable {
        /// An artist delete or a find's file delete: none of its artists may be kept or keeping.
        case findDelete
        /// A kept find's MP3 (Y5): every artist must still be confirmed kept with no Keep under way.
        case keptLossyDelete
        /// Everything else (editor, album monitor, queue delete): no last-moment check.
        case other
    }

    enum Verdict: Equatable {
        /// May be sent. `artists`: the artists a delete touches, whose kept state is read again right before it goes
        /// by `rule`'s own check.
        case confined(artists: Set<Int>, rule: Rule)
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
        /// Y5 fix I9: `POST /command` AlbumSearch (its album ids) or RefreshArtist (its artist id).
        case command(name: String, albumIds: [Int], artistId: Int?)
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
                return .confined(artists: [], rule: .other)
            case .artistDelete(let id):
                try await context.artistDelete(id)
                return .confined(artists: [id], rule: .findDelete)
            case .trackFileDelete(let ids):
                if try await context.trackFileRule(ids) == .keptLossyDelete {
                    return .confined(artists: try await context.keptLossyDelete(ids), rule: .keptLossyDelete)
                }
                return .confined(artists: try await context.trackFileDelete(ids), rule: .findDelete)
            case .albumMonitor(let ids, let monitored):
                try context.albumMonitor(ids, monitored: monitored)
                return .confined(artists: [], rule: .other)
            case .queueDelete:
                return .unknown   // handled above
            case .command(let name, let albumIds, let artistId):
                // Y5 fix I9: a search can make Lidarr grab and replace files, so only albums the ledger knows (Magpie
                // recorded each before it monitored or searched it); a refresh only for an artist the ledger knows.
                switch name.lowercased() {
                case "albumsearch":
                    guard !albumIds.isEmpty, albumIds.allSatisfy({ id in entries.contains { $0.albumId == id } }) else {
                        return .refused("a search only for albums Magpie asked for")
                    }
                case "refreshartist":
                    guard let artistId, entries.contains(where: { $0.lidarrArtistId == artistId }) else {
                        return .refused("a refresh only for an artist Magpie asked for")
                    }
                default:
                    break
                }
                return .confined(artists: [], rule: .other)
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
            e.isOpen && e.isApplied && !e.isKeptOrKeeping && e.albumId != nil
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
        return .confined(artists: [], rule: .other)
    }

    /// Right before a confined write is sent, the ledger once more, by rule (C4). findDelete: none of `artists` is
    /// kept or keeping now. keptLossyDelete: every one is still confirmed kept, no Keep under way. Nil: the ledger
    /// can't be read.
    func lastCheck(_ rule: Rule, _ artists: Set<Int>) async -> Bool? {
        guard !artists.isEmpty, rule != .other else { return true }
        guard let entries = try? await ledger.entries else { return nil }
        switch rule {
        case .findDelete:
            return !entries.contains { artists.contains($0.lidarrArtistId) && $0.isKeptOrKeeping }
        case .keptLossyDelete:
            return artists.allSatisfy { Self.confirmedKept($0, in: entries) }
        case .other:
            return true
        }
    }

    /// The artist's Keep is confirmed: some entry says kept, and none has a Keep under way.
    public static func confirmedKept(_ artistId: Int, in entries: [LedgerEntry]) -> Bool {
        let mine = entries.filter { $0.lidarrArtistId == artistId }
        return mine.contains { $0.keptAt != nil } && !mine.contains { $0.keepIntentAt != nil }
    }

    /// M2: the qualities a kept find's MP3 may have (Lidarr's names). Lossless or unknown qualities refuse.
    public static func isLossy(_ quality: String?) -> Bool {
        guard let q = quality?.trimmingCharacters(in: .whitespaces) else { return false }
        return q.hasPrefix("MP3-") || q.hasPrefix("AAC-") || q.hasPrefix("OGG Vorbis") || q == "WMA"
            || q.lowercased().hasPrefix("opus")
    }

    /// M3: two paths are the same file for the MP3 rule: standardised, and equal ignoring case and Unicode form.
    public static func looselySame(_ a: String, _ b: String) -> Bool {
        func fold(_ s: String) -> String? {
            let parts = s.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            return (s.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
        }
        guard let x = fold(a), let y = fold(b) else { return false }
        return x == y
    }

    /// The path of `file` below `folder` (loose prefix match, M3); nil when it isn't inside.
    public static func relative(_ file: String, under folder: String) -> String? {
        guard let f = PathGuard.standardize(file), let d = PathGuard.standardize(folder) else { return nil }
        let fc = f.precomposedStringWithCanonicalMapping, dc = d.precomposedStringWithCanonicalMapping
        let prefix = dc.hasSuffix("/") ? dc : dc + "/"
        guard fc.lowercased().hasPrefix(prefix.lowercased()), fc.count > prefix.count else { return nil }
        return String(fc.dropFirst(prefix.count))
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

        /// C5: kept, or a Keep under way.
        func kept(_ artistId: Int) -> Bool {
            entries.contains { $0.lidarrArtistId == artistId && $0.isKeptOrKeeping }
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
                let file = try await trackFile(id)
                guard let artistId = file.artistId else { throw Refusal(reason: "track file without an artist") }
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

        /// C4: which rule a track file delete falls under. Every file is read: a file of a tagged find inside the Finds
        /// root is findDelete, any other keptLossyDelete. Both in one call refuse (each rule is then checked in full).
        func trackFileRule(_ ids: [Int]) async throws -> Rule {
            guard !ids.isEmpty, ids.count <= WriteConfinement.maxTrackFiles else {
                throw Refusal(reason: "track file delete needs 1 to 500 ids")
            }
            var finds = 0
            for id in ids {
                let file = try await trackFile(id)
                guard let artistId = file.artistId else { throw Refusal(reason: "track file without an artist") }
                let artist = try await artist(artistId)
                if let findsRoot = roots.findsRoot, let tag = roots.findTagId, let path = artist.path, artist.tags.contains(tag) {
                    let others = try await lidarrRoots().filter { !Self.sameBytes($0, findsRoot) } + [roots.mainRoot].compactMap { $0 }
                    if PathGuard(findsRoot: findsRoot, otherRoots: others, caseInsensitive: false).isInside(path) { finds += 1 }
                }
            }
            guard finds == 0 || finds == ids.count else {
                throw Refusal(reason: "a find's files and a kept find's files in one delete")
            }
            return finds == 0 ? .keptLossyDelete : .findDelete
        }

        private var files: [Int: TrackFile] = [:]
        private var tracks: [Int: [LidarrTrack]] = [:]

        func trackFile(_ id: Int) async throws -> TrackFile {
            if let known = files[id] { return known }
            let read = try await read { try await lidarr.trackFile(id: id) }
            guard read.id == id else { throw Refusal(reason: "Lidarr answered for another track file") }
            files[id] = read
            return read
        }

        func albumTracks(_ albumId: Int) async throws -> [LidarrTrack] {
            if let known = tracks[albumId] { return known }
            let read = try await read { try await lidarr.tracks(albumId: albumId) }
            tracks[albumId] = read
            return read
        }

        /// Y5 keptLossyDelete (see the type comment). Returns the artists.
        func keptLossyDelete(_ ids: [Int]) async throws -> Set<Int> {
            guard let main = roots.mainRoot else { throw Refusal(reason: "no main root folder") }
            let fresh = try await lidarrRoots()
            guard fresh.contains(where: { Self.sameBytes($0, main) }) else {
                throw Refusal(reason: "the main root isn't a Lidarr root folder")
            }
            let mainGuard = PathGuard(findsRoot: main, otherRoots: fresh.filter { !Self.sameBytes($0, main) },
                                      caseInsensitive: false)
            var artists = Set<Int>()
            for id in ids {
                let file = try await trackFile(id)
                guard let artistId = file.artistId, let albumId = file.albumId else {
                    throw Refusal(reason: "track file without an artist or album")
                }
                guard try await created(artistId) else { throw Refusal(reason: "not an artist Magpie added") }
                guard WriteConfinement.confirmedKept(artistId, in: entries) else {
                    throw Refusal(reason: "only a kept find's files")
                }
                let artist = try await artist(artistId)
                guard let folder = artist.path, mainGuard.isInside(folder) else {
                    throw Refusal(reason: "the artist isn't in the main root folder")
                }
                guard WriteConfinement.isLossy(file.quality) else { throw Refusal(reason: "only a lossy file") }
                guard mainGuard.isInside(file.path), let relative = WriteConfinement.relative(file.path, under: folder) else {
                    throw Refusal(reason: "a track file outside the artist's folder")
                }
                // Y5 fix I1: the record may sit on more than one entry of the artist; one *distinct* record must match,
                // and copies that disagree (size, track) refuse.
                let matching = entries.filter { $0.lidarrArtistId == artistId }.flatMap { $0.findFiles ?? [] }
                    .filter { $0.albumId == albumId && WriteConfinement.looselySame($0.relativePath, relative) }
                var recorded: [FindFile] = []
                for f in matching where !recorded.contains(where: { $0.size == f.size && $0.foreignTrackId == f.foreignTrackId }) {
                    recorded.append(f)
                }
                guard recorded.count == 1, let find = recorded.first else {
                    throw Refusal(reason: "not a file Magpie's find brought in")
                }
                guard let size = file.size, size == find.size else { throw Refusal(reason: "the file changed") }
                let track = try await albumTracks(albumId).first { $0.trackFileId == id }
                guard let foreign = find.foreignTrackId, track?.foreignTrackId == foreign else {
                    throw Refusal(reason: "not the find's track")
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
                    guard entry.allSatisfy({ !$0.wasMonitoredBefore && !$0.isKeptOrKeeping }) else {
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
