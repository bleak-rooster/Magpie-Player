import Foundation
import MagpieCore

/// Round 24 (owner, 2026-11-08, D243): the safety proofs that replace "Magpie added it" for an artist the owner added.
/// The owner put his own artists in scope, so each write built by `performOwned` or `performCleanup` (`OwnedShape`) is proven here from the
/// ledger's monitoring book (the owner's consent, saved before any write) and the gate's own fresh Lidarr reads, never
/// from the caller:
///
/// - **The artist** (every write): Lidarr has it now, with the MusicBrainz id the intent recorded; its root folder is the
///   main root (a fresh root folder), its folder lies strictly inside it and inside no other root, and it isn't a find
///   (no `magpie-find` tag: a Finds artist keeps the Finds rules).
/// - **The intent**: exactly one open change (or Revert) for the artist; a clean-up: exactly one open clean-up whose
///   record still matches the hash of what the owner confirmed.
/// - `PUT /artist/editor`: exactly `{artistIds: [one], metadataProfileId}`, never `rootFolderPath`, `moveFiles` or
///   `monitored` (the allow list also refuses them); the profile is the intent's target, and either Magpie's by its name
///   in Lidarr now (`ReleaseTypes.profileName` of the intent's types, D238) or, for Revert, exactly the previous profile
///   a finished change recorded, while the artist is on a Magpie profile now (D244).
/// - RefreshArtist: the artist of an open change or Revert.
/// - `PUT /album/monitor false`: only albums of that artist the intent lists to unmonitor, of a type the intent's
///   release types leave out (read fresh), none a live Magpie request is using; `true` and AlbumSearch: only albums of that artist the refresh brought in (not there before), listed in
///   the intent (saved before the write) and of a type the intent's release types include (read fresh).
/// - `DELETE /trackfile/bulk` (clean-up): 1 to 50 distinct ids, all named by the intent and none it left out (favourited,
///   saved to a playlist, on the phone); each read fresh: that artist's, the album the intent recorded, the size it
///   recorded, strictly inside the main root and the artist's folder, and its album unmonitored now. Nothing for an
///   artist with a Try of Magpie's under way. Right before it goes the ledger is read again (`ownedCleanupLastCheck`).
/// - Never `DELETE /artist`, never a move, never a profile Magpie didn't make (the gate refuses those shapes outright).
/// A read that fails refuses (`unknown`): when in doubt, don't write.
extension WriteConfinement {
    /// At most this many track files in one clean-up delete.
    public static let maxCleanupFiles = 50

    /// The verdict for a Round 24 write; nil for every other write.
    func ownedCheck(_ write: Write, lidarr: LidarrClient) async -> Verdict? {
        switch write {
        case .ownedEditor, .ownedRefresh, .ownedSearch, .ownedMonitor, .ownedCleanup: break
        default: return nil
        }
        do {
            let book: MonitoringBook, entries: [LedgerEntry]
            do {
                book = try await ledger.monitoringBook
                entries = try await ledger.entries
            } catch { throw OwnedProof.Failure.unreadable }
            let proof = OwnedProof(book: book, entries: entries, lidarr: lidarr, roots: await roots())
            switch write {
            case .ownedEditor(let body):
                try await proof.editor(body)
            case .ownedRefresh(let artistId):
                let intent = try proof.changeIntent(artistId)
                // Fix round 1 I5: never while a Try of Magpie's is under way for the artist.
                guard !OwnedProof.hasLiveTry(artistId, in: entries) else { throw OwnedProof.Failure.refused("a Try of Magpie's is under way for the artist") }
                _ = try await proof.artist(intent)
            case .ownedMonitor(let ids, let monitored):
                try await proof.monitor(ids, monitored: monitored, search: false)
            case .ownedSearch(let ids):
                try await proof.monitor(ids, monitored: true, search: true)
            case .ownedCleanup(let ids, let intentId):
                let intent = try await proof.cleanup(ids, intentId: intentId)
                return .confined(artists: [intent.artistId], rule: .ownedCleanup(intent: intent.id, artistId: intent.artistId))
            default:
                return nil
            }
            return .confined(artists: [], rule: .other)
        } catch OwnedProof.Failure.refused(let why) {
            return .refused(why)
        } catch {
            return .unknown
        }
    }

    /// Right before a clean-up's delete goes: its intent is still open and no Try of Magpie's has started for the artist.
    /// Nil: the ledger can't be read.
    func ownedCleanupLastCheck(_ id: UUID, artistId: Int) async -> Bool? {
        guard let book = try? await ledger.monitoringBook, let entries = try? await ledger.entries else { return nil }
        return book.intents.contains { $0.id == id && $0.isOpen && $0.kind == .unmatchedCleanup && $0.artistId == artistId }
            && !OwnedProof.hasLiveTry(artistId, in: entries)
    }
}

/// One owned write's proofs: the book and ledger as read, the owner's roots, and fresh Lidarr reads.
private struct OwnedProof {
    enum Failure: Error { case refused(String), unreadable }

    let book: MonitoringBook
    let entries: [LedgerEntry]
    let lidarr: LidarrClient
    let roots: WriteConfinement.Roots

    /// A 404 refuses (nothing there to change); any other failure is unreadable.
    func read<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch LidarrError.http(status: 404) {
            throw Failure.refused("Lidarr doesn't have it")
        } catch {
            throw Failure.unreadable
        }
    }

    static func sameBytes(_ a: String, _ b: String) -> Bool {
        guard let x = PathGuard.standardize(a), let y = PathGuard.standardize(b) else { return false }
        return Array(x.utf8) == Array(y.utf8)
    }

    /// A request of Magpie's is under way for the artist (an open entry nobody has kept): nothing is deleted.
    static func hasLiveTry(_ artistId: Int, in entries: [LedgerEntry]) -> Bool {
        entries.contains { $0.lidarrArtistId == artistId && $0.isOpen && !$0.isConfirmedKept }
    }

    /// Fix round 1 M3: a positive whole number from the body (never a boolean, never a fraction), or nil.
    static func positiveInt(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.int64Value > 0,
              Double(n.int64Value) == n.doubleValue else { return nil }
        return Int(exactly: n.int64Value)
    }

    /// The artist's one open change or Revert.
    func changeIntent(_ artistId: Int) throws -> MonitoringIntent {
        let open = book.open(artistId: artistId).filter { $0.kind != .unmatchedCleanup }
        guard open.count == 1, let intent = open.first else {
            throw Failure.refused("no change the owner confirmed is open for this artist")
        }
        return intent
    }

    /// The artist proofs (see the type comment). Returns its folder and a guard of the main root.
    func artist(_ intent: MonitoringIntent) async throws -> (artist: LidarrArtist, folder: String, main: PathGuard) {
        guard let main = roots.mainRoot else { throw Failure.refused("no main root folder") }
        let fresh = try await read { try await lidarr.rootFolders().map(\.path) }
        guard fresh.contains(where: { Self.sameBytes($0, main) }) else {
            throw Failure.refused("the main root isn't a Lidarr root folder")
        }
        let others = fresh.filter { !Self.sameBytes($0, main) } + [roots.findsRoot].compactMap { $0 }
        let mainGuard = PathGuard(findsRoot: main, otherRoots: others, caseInsensitive: false)
        let artist = try await read { try await lidarr.artist(id: intent.artistId) }
        guard artist.id == intent.artistId, artist.foreignArtistId == intent.artistMbid else {
            throw Failure.refused("not the artist the owner confirmed")
        }
        guard let rootFolder = artist.rootFolderPath, Self.sameBytes(rootFolder, main),
              let folder = artist.path, mainGuard.isInside(folder) else {
            throw Failure.refused("the artist isn't in the main root folder")
        }
        if let tag = roots.findTagId, artist.tags.contains(tag) { throw Failure.refused("a find keeps the Finds rules") }
        return (artist, folder, mainGuard)
    }

    func editor(_ body: [String: Any]) async throws {
        let value = { (name: String) in body.first { $0.key.lowercased() == name }?.value }
        guard Set(body.keys.map { $0.lowercased() }) == ["artistids", "metadataprofileid"], body.count == 2,
              let ids = value("artistids") as? [Any], ids.count == 1, let artistId = Self.positiveInt(ids[0]),
              let profile = Self.positiveInt(value("metadataprofileid")) else {
            throw Failure.refused("a monitoring change sets one artist's metadata profile and nothing else")
        }
        guard !Self.hasLiveTry(artistId, in: entries) else { throw Failure.refused("a Try of Magpie's is under way for the artist") }
        let intent = try changeIntent(artistId)
        guard intent.targetProfileId == profile else { throw Failure.refused("not the profile the owner confirmed") }
        let (artist, _, _) = try await self.artist(intent)
        let profiles = try await read { try await lidarr.metadataProfiles() }
        switch intent.kind {
        case .monitoringChange:
            // D238: one of Magpie's own profiles, the very one the intent's release types name.
            guard let name = profiles.first(where: { $0.id == profile })?.name, ReleaseTypes.isMagpieMetadataProfile(name),
                  let types = intent.targetTypes, name == types.profileName else {
                throw Failure.refused("only the Magpie profile for the release types the owner chose")
            }
        case .revert:
            // D244: back to the profile a change recorded before it moved the artist, while it is on Magpie's now.
            guard profile == intent.previousProfileId, profiles.contains(where: { $0.id == profile }),
                  book.intents.contains(where: { $0.kind == .monitoringChange && $0.artistId == artistId && !$0.isOpen
                                                 && $0.previousProfileId == profile }) else {
                throw Failure.refused("only the profile recorded before Magpie's change")
            }
            guard let current = profiles.first(where: { $0.id == artist.metadataProfileId })?.name,
                  ReleaseTypes.isMagpieMetadataProfile(current) else {
                throw Failure.refused("the artist isn't on one of Magpie's profiles now")
            }
        case .unmatchedCleanup:
            throw Failure.refused("a clean-up doesn't change the profile")
        }
    }

    /// The album ids' artist (all one artist), its open change, and its albums read fresh.
    private func albumsOfOneArtist(_ ids: [Int]) async throws -> (MonitoringIntent, [LidarrAlbum]) {
        guard !ids.isEmpty, ids.count <= WriteConfinement.maxTrackFiles, Set(ids).count == ids.count else {
            throw Failure.refused("a monitor needs 1 to \(WriteConfinement.maxTrackFiles) distinct albums")
        }
        guard let artistId = try await read({ try await lidarr.album(id: ids[0]) }).artistId else {
            throw Failure.refused("an album without an artist")
        }
        let intent = try changeIntent(artistId)
        _ = try await artist(intent)
        let albums = try await read { try await lidarr.albums(artistId: artistId) }
        guard ids.allSatisfy({ id in albums.contains { $0.id == id && ($0.artistId ?? artistId) == artistId } }) else {
            throw Failure.refused("an album of another artist")
        }
        return (intent, albums)
    }

    func monitor(_ ids: [Int], monitored: Bool, search: Bool) async throws {
        let (intent, albums) = try await albumsOfOneArtist(ids)
        guard intent.kind == .monitoringChange else { throw Failure.refused("only a monitoring change monitors albums") }
        if !monitored {
            guard Set(ids).isSubset(of: intent.unmonitorAlbumIds) else {
                throw Failure.refused("only albums the owner chose to stop monitoring")
            }
            guard !ids.contains(where: { id in entries.contains { $0.albumId == id && $0.isOpen && !$0.isConfirmedKept } }) else {
                throw Failure.refused("a request of Magpie's is using that album")
            }
            // Only albums the owner's choice leaves out (read fresh): what falls out, nothing it still includes.
            guard let types = intent.targetTypes, ids.allSatisfy({ id in
                albums.first { $0.id == id }.map { !types.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes) } == true
            }) else {
                throw Failure.refused("only albums the owner's choice leaves out")
            }
            return
        }
        guard let types = intent.targetTypes, Set(ids).isSubset(of: intent.monitorAlbumIds),
              Set(ids).isDisjoint(with: intent.beforeAlbumIds) else {
            throw Failure.refused("only albums the new choice brought in")
        }
        for id in ids {
            guard let album = albums.first(where: { $0.id == id }),
                  types.includes(albumType: album.albumType, secondaryTypes: album.secondaryTypes) else {
                throw Failure.refused("an album the owner's choice doesn't include")
            }
            if search, !album.monitored { throw Failure.refused("a search only for an album just monitored") }
        }
    }

    /// Fix round 1 I2: `file` (id, album and size) is in the artist's kept set, or in a finished `monitoringChange` whose
    /// owner chose Delete them, with its album among the albums that change unmonitored and not one it left out (m1).
    static func keptOrConfirmed(_ file: OwnedFile, artistId: Int, in book: MonitoringBook) -> Bool {
        if book.kept(artistId: artistId)?.files.contains(file) == true { return true }
        return book.intents.contains { change in
            change.kind == .monitoringChange && change.artistId == artistId && change.step == .done && !change.keepFiles
                && change.files.contains(file) && change.unmonitorAlbumIds.contains(file.albumId)
                && !change.excludedFileIds.contains(file.id)
        }
    }

    func cleanup(_ ids: [Int], intentId: UUID) async throws -> MonitoringIntent {
        guard !ids.isEmpty, ids.count <= WriteConfinement.maxCleanupFiles, Set(ids).count == ids.count else {
            throw Failure.refused("a clean-up deletes 1 to \(WriteConfinement.maxCleanupFiles) files at a time")
        }
        let first = try await read { try await lidarr.trackFile(id: ids[0]) }
        guard first.id == ids[0], let artistId = first.artistId else { throw Failure.refused("a track file without an artist") }
        let open = book.open(artistId: artistId).filter { $0.kind == .unmatchedCleanup }
        guard open.count == 1, let intent = open.first, intent.id == intentId else {
            throw Failure.refused("no clean-up the owner confirmed is open for this artist")
        }
        guard intent.matchesConfirmation else { throw Failure.refused("the clean-up isn't what the owner confirmed") }
        // Fix round 2: exactly the batch the runner saved before the call (the gate built the request from it).
        guard Set(ids) == Set(intent.pendingFileIds), ids.count == intent.pendingFileIds.count else {
            throw Failure.refused("only the clean-up's saved batch")
        }
        let named = Dictionary(intent.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let excluded = Set(intent.excludedFileIds)
        guard ids.allSatisfy({ named[$0] != nil && !excluded.contains($0) }) else {
            throw Failure.refused("only files the owner's confirmation named")
        }
        guard !Self.hasLiveTry(artistId, in: entries) else { throw Failure.refused("a Try of Magpie's is under way for the artist") }
        let (artist, folder, mainGuard) = try await artist(intent)
        // Fix round 3 H-M1: the newest finished change the artist is still on must leave the file's album type out (a
        // later choice that monitors that type again, or a Revert, ends the clean-up of it).
        let current = book.intents.filter {
            $0.kind == .monitoringChange && $0.artistId == artistId && $0.step == .done && $0.targetProfileId != nil
        }.max { $0.createdAt < $1.createdAt }
        guard let current, current.targetProfileId == artist.metadataProfileId, let types = current.targetTypes else {
            throw Failure.refused("the artist isn't on the profile of Magpie's last change now")
        }
        let inside = PathGuard(findsRoot: folder, otherRoots: [], caseInsensitive: false)
        let albums = try await read { try await lidarr.albums(artistId: artistId) }
        for id in ids {
            guard let recorded = named[id] else { throw Failure.refused("only files the owner's confirmation named") }
            // Fix round 1 I2: only a file the owner kept on reducing (the kept set), or one a finished Delete them change
            // named, of an album that change unmonitored; never one the intent alone names.
            guard Self.keptOrConfirmed(recorded, artistId: artistId, in: book) else {
                throw Failure.refused("only songs kept on reducing, or named by a change the owner confirmed")
            }
            var file = first
            if id != first.id { file = try await read { try await lidarr.trackFile(id: id) } }
            guard file.id == id, file.artistId == artistId, file.albumId == recorded.albumId else {
                throw Failure.refused("not the file the owner confirmed")
            }
            guard let size = file.size, size == recorded.size else { throw Failure.refused("the file changed") }
            guard mainGuard.isInside(file.path), inside.isInside(file.path) else {
                throw Failure.refused("a file outside the artist's folder")
            }
            guard let album = albums.first(where: { $0.id == recorded.albumId }), !album.monitored else {
                throw Failure.refused("a file of an album that is monitored now")
            }
            guard !types.includes(albumType: album.albumType, secondaryTypes: album.secondaryTypes) else {
                throw Failure.refused("a file of an album the current choice includes")
            }
        }
        return intent
    }
}
