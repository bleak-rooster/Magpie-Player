import Foundation
import LidarrKit
import MagpieCore

/// Keep (Task 6.2b): move a find's artist from the Finds root into the main root (G4, A3, A4).
///
/// Whether a find may be kept is decided from fresh Lidarr state, never from the request's mode alone (an
/// existing-artist album under a Finds artist is ledgered `.fallback`):
/// - the ledger says Magpie created the artist;
/// - the stored Finds root still checks out against fresh root folders, and the main root is one of them;
/// - the artist (fresh GET) carries `magpie-find` and its path is strictly inside the Finds root (a case-sensitive
///   `PathGuard` built from those root folders).
///
/// One Keep per artist at a time: no other request of the artist has a Keep under way and no ledger entry of the
/// artist says kept.
///
/// G4 destination: the editor moves the folder to `<main root>/<folder>`, where `folder` comes from Lidarr's
/// naming format and the artist's current name (lookup `folder`), not from the current folder. If that name differs
/// at all from the current folder's (byte for byte: a rename, a changed format, even case or accents), or a folder of either name already exists in the main
/// root (compared ignoring case, diacritics and width, so a case-insensitive or NFD volume can't hide the owner's
/// folder), only `magpie-find` comes off and the find stays where it is. Otherwise one `PUT /artist/editor` with
/// exactly the G4 body.
///
/// Lidarr saves the new path at once and moves the files in a `BulkMoveArtist` command, reverting the path if the
/// move fails (A3). So Keep waits for that command, then checks the artist path (strictly inside the main root)
/// and every track file on disk in the new folder (Lidarr's filesystem API; 3.2 leaves the track file records at
/// the old paths), with the find's folder gone from the Finds root, before it claims anything. Only then are both folders scanned and the song looked up again
/// by MBID in the folder it moved to.
///
/// M6: the Keep is saved (request and ledger) before every write, so a relaunch only follows it, never writes the
/// move twice. The ledger says "kept" from just before the write (Not for me refuses kept albums, G3.4) until the
/// Keep verifiably failed. A failed move puts back what the PUT changed (`magpie-find`, the quality profile, and the
/// artist path when Lidarr saved the new one but never moved the files), so the find can be kept again. What can't
/// be settled within the limits ends in "needs attention": the ledger keeps saying kept, nothing more is written.
extension RequestRunner {
    /// Where Keep moves finds, from the owner's Finds and Lidarr setup.
    public struct KeepSetup: Sendable, Equatable {
        /// The owner-confirmed Finds root (Lidarr's path, G2).
        public var findsRoot: String
        /// The main root folder new music goes into.
        public var mainRoot: String
        /// "Magpie Lossless": kept finds upgrade from Fast Start.
        public var losslessProfileId: Int
        public var findTagId: Int

        public init(findsRoot: String, mainRoot: String, losslessProfileId: Int, findTagId: Int) {
            self.findsRoot = findsRoot; self.mainRoot = mainRoot
            self.losslessProfileId = losslessProfileId; self.findTagId = findTagId
        }
    }

    public enum KeepOutcome: Sendable, Equatable {
        /// Moved into the main root and confirmed there; both folders were scanned.
        case moved
        /// The main root already had a folder for the artist: only `magpie-find` came off (G4).
        case keptInPlace
        /// Lidarr is still moving it; later ticks follow it (and never send it again).
        case stillMoving
    }

    public enum KeepError: Error, Equatable {
        /// "Allow Magpie to change Lidarr" is off (G1).
        case changesOff
        /// Finds or the lossless profile aren't set up.
        case notSetUp
        /// Lidarr, the ledger or the saved requests can't be read right now. Nothing was written.
        case unavailable
        /// Not a find Magpie may move (a precondition failed on fresh state). Nothing was written.
        case notAFind
        /// Lidarr refused or couldn't do the move. Nothing is kept; the find is as it was (or being put back).
        case moveFailed
        /// The Keep couldn't be settled from here; it needs the owner's look (`keepNeedsAttention`).
        case needsAttention
    }

    /// Between checks of a move in progress.
    public static let keepPollInterval: Duration = .seconds(2)
    /// How long `keep` itself waits for the move before saying it is still moving.
    public static let keepInlineWait: TimeInterval = 90
    /// A move that hasn't shown up in Lidarr's command list this long after the write never started.
    public static let keepStartGrace: TimeInterval = 60
    /// While a move is still going after `keep` returned: checked at most this often.
    public static let keepCheckInterval: TimeInterval = 30
    /// The kept song is looked up again at most this often, and for this long after the move.
    public static let relinkInterval: TimeInterval = 15
    public static let relinkLimit: TimeInterval = 30 * 60
    /// A move still not finished this long after the write: followed no further (needs attention).
    public static let keepMoveLimit: TimeInterval = 30 * 60
    /// Restore writes before giving up (a 4xx gives up at once).
    public static let keepRestoreLimit = 5

    // MARK: - Bodies (A4: only the fields Keep changes)

    /// G4: exactly this, nothing else.
    struct MoveBody: Encodable, Sendable {
        var artistIds: [Int]
        var rootFolderPath: String
        var moveFiles: Bool
        var qualityProfileId: Int
        var tags: [Int]
        var applyTags: String
    }

    /// G4, destination exists: only `magpie-find` comes off.
    struct UntagBody: Encodable, Sendable {
        var artistIds: [Int]
        var tags: [Int]
        var applyTags: String
    }

    /// A failed move: put back what the PUT already changed. Nil fields are left out. `rootFolderPath` +
    /// `moveFiles: false` only when Lidarr saved the main root but the files never left the Finds folder: it points
    /// the artist back at them and moves nothing.
    struct RestoreBody: Encodable, Sendable {
        var artistIds: [Int]
        var rootFolderPath: String? = nil
        var moveFiles: Bool? = nil
        var qualityProfileId: Int? = nil
        var tags: [Int]? = nil
        var applyTags: String? = nil
    }

    // MARK: - Keep

    /// Keeps a ready find (see the type comment). Throws `KeepError`; nothing is claimed unless it returns.
    public func keep(_ id: RequestID) async throws -> KeepOutcome {
        guard !stopped, await load() else { throw KeepError.unavailable }
        guard let r = request(id) else { throw KeepError.notAFind }
        guard let artistId = r.keep?.artistId ?? r.lidarrArtistId else { throw KeepError.notAFind }
        // Not for me is deleting (or couldn't finish deleting) this artist's find: never move it meanwhile.
        if lettingGoArtists.contains(artistId)
            || list.contains(where: { $0.lidarrArtistId == artistId && ($0.notForMe != nil || $0.notForMeNeedsAttention) }) {
            throw KeepError.notAFind
        }
        // One Keep per artist: the whole artist moves.
        guard !keepingArtists.contains(artistId) else { return .stillMoving }
        keepingArtists.insert(artistId)
        defer { keepingArtists.remove(artistId) }
        // M6: already written. Only see how it went; never write it again.
        if r.keep != nil { return try await followKeep(id, inline: true) }
        guard r.state == .ready, !r.keepNeedsAttention else { throw KeepError.notAFind }
        if list.contains(where: { $0.id != id && $0.keep?.artistId == artistId }) { return .stillMoving }
        guard await gate.enabled else { throw KeepError.changesOff }
        guard let setup = await keepSetup() else { throw KeepError.notSetUp }

        let entries: [LedgerEntry]
        do { entries = try await ledger.entries.filter { $0.lidarrArtistId == artistId } } catch {
            throw KeepError.unavailable
        }
        guard entries.contains(where: \.createdArtist) else { throw KeepError.notAFind }
        // Kept already, or a Keep of it that isn't settled (needs attention): never a second move.
        guard !entries.contains(where: { $0.keptAt != nil }) else { throw KeepError.notAFind }
        let roots: [String], artist: LidarrArtist, commands: [CommandStatus]
        do {
            roots = try await lidarr.rootFolders().map(\.path)
            artist = try await lidarr.artist(id: artistId)
            commands = try await lidarr.commands()
        } catch LidarrError.http(status: 404) {
            throw KeepError.notAFind
        } catch {
            throw KeepError.unavailable
        }
        lastLidarrContact = now()
        guard Self.mayKeep(artist, request: r, setup: setup, roots: roots), let from = artist.path,
              let mbid = artist.foreignArtistId else {
            throw KeepError.notAFind
        }
        // Something is already moving this artist (not Magpie's Keep, or one whose record was lost): leave it.
        guard !commands.contains(where: { Self.isMove($0, of: artistId) && !Self.isFinished($0) }) else {
            throw KeepError.unavailable
        }
        // G4: where the editor would put it, and whether anything is there already.
        let named: String?, existing: [String]
        do {
            named = try await lidarr.artistLookup(mbid: mbid)?.folder
            existing = try await lidarr.directories(in: setup.mainRoot)
        } catch {
            throw KeepError.unavailable
        }
        let current = Self.lastComponent(from)
        let untagOnly = Self.mustStayInFinds(current: current, named: named, existing: existing.map(Self.lastComponent))

        let progress = KeepProgress(
            phase: untagOnly ? .untagging : .moving, startedAt: now(), artistId: artistId, fromPath: from,
            findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, findTagId: setup.findTagId,
            priorQualityProfileId: artist.qualityProfileId, commandBaseline: commands.map(\.id).max() ?? 0)
        // M6: the Keep is on disk, and the ledger says kept, before anything can reach Lidarr.
        do {
            try await setKept(artistId, at: now())
            await mutate(id) {
                $0.keep = progress
                $0.keepFailed = false
            }
            try await persist()
        } catch {
            await nothingKept(id, artistId)
            throw KeepError.unavailable
        }
        let body: any Encodable & Sendable = untagOnly
            ? UntagBody(artistIds: [artistId], tags: [setup.findTagId], applyTags: "remove")
            : MoveBody(artistIds: [artistId], rootFolderPath: setup.mainRoot, moveFiles: true,
                       qualityProfileId: setup.losslessProfileId, tags: [setup.findTagId], applyTags: "remove")
        do {
            _ = try await gate.send("PUT", "artist/editor", body: body)
        } catch let refusal as WriteGateError {
            await nothingKept(id, artistId)   // the gate throws before anything leaves the device
            switch refusal {
            case .disabled: throw KeepError.changesOff
            case .logUnavailable, .unconfirmed: throw KeepError.unavailable
            case .forbidden, .invalidRequest: throw KeepError.moveFailed
            }
        } catch let error where Self.isDefinitiveRejection(error) {
            await nothingKept(id, artistId)   // Lidarr answered 4xx: nothing applied
            throw KeepError.moveFailed
        } catch {
            // No answer (timeout, 5xx): it may have landed. Followed like a sent one; never sent again.
            Log.logger("requests").error("Keep: no answer from Lidarr; following the move")
            return try await followKeep(id, inline: true)
        }
        if untagOnly {
            await finishInPlace(id, artistId: artistId)
            return .keptInPlace
        }
        return try await followKeep(id, inline: true)
    }

    /// Checks a written Keep until it settles or, `inline`, `keepInlineWait` passes (then `.stillMoving`).
    func followKeep(_ id: RequestID, inline: Bool) async throws -> KeepOutcome {
        let deadline = now().addingTimeInterval(inline ? Self.keepInlineWait : 0)
        while true {
            guard !stopped, let r = request(id) else { throw KeepError.unavailable }
            guard let progress = r.keep else {
                if r.state == .kept { return r.keptInPlace ? .keptInPlace : .moved }
                throw r.keepNeedsAttention ? KeepError.needsAttention : KeepError.moveFailed
            }
            switch await checkKeep(id, progress) {
            case .done(let outcome): return outcome
            case .failed: throw request(id)?.keepNeedsAttention == true ? KeepError.needsAttention : KeepError.moveFailed
            case .pending:
                await mutate(id) { $0.keep?.lastCheckAt = self.now() }
                guard now() < deadline else { return .stillMoving }
                await sleep(Self.keepPollInterval)
            }
        }
    }

    enum KeepCheck { case pending, done(KeepOutcome), failed }

    private func checkKeep(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        switch p.phase {
        case .moving: return await checkMove(id, p)
        case .untagging: return await checkUntag(id, p)
        case .restoring:
            await restore(id, p)
            return .failed
        }
    }

    /// A3: done only when the move command completed (or is long gone from Lidarr's list, which prunes finished
    /// commands) with nothing moving now, the artist path is under the main root, and every track file is on disk
    /// in the new folder (`filesMoved`).
    /// Lidarr saves the new path before it moves anything, so the artist path alone proves nothing.
    private func checkMove(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        let commands: [CommandStatus], artist: LidarrArtist
        do {
            commands = try await lidarr.commands()
            artist = try await lidarr.artist(id: p.artistId)
        } catch {
            return await stillPending(id, p)   // can't tell now; checked again
        }
        lastLidarrContact = now()
        let mine = commands.filter { $0.id > p.commandBaseline && Self.isMove($0, of: p.artistId) }
        if mine.contains(where: { !Self.isFinished($0) }) { return await stillPending(id, p) }
        let finished = mine.max { $0.id < $1.id }
        let started = now().timeIntervalSince(p.startedAt) >= Self.keepStartGrace
        let main = Self.mainGuard(p)
        let inMain = artist.path.map(main.isInside) ?? false
        if inMain, finished.map({ $0.status.lowercased() == "completed" }) ?? started {
            guard let files = try? await lidarr.trackFiles(artistId: p.artistId), let path = artist.path,
                  let moved = await filesMoved(p, to: path, files: files) else { return await stillPending(id, p) }
            if moved {
                await finishMove(id, p, to: path)
                return .done(.moved)
            }
            // The filesystem may lag the command a little: give it time before deciding.
            guard let since = p.filesUnsettledSince else {
                await mutate(id) { $0.keep?.filesUnsettledSince = self.now() }
                return .pending
            }
            guard now().timeIntervalSince(since) >= Self.keepStartGrace else { return await stillPending(id, p) }
            if await filesNeverLeft(p, artistPath: path, files: files) == true {
                // Lidarr saved the main root but never moved the files (a restart orphaned the move): not kept.
                Log.logger("requests").error("Keep: the files never left the Finds folder")
                return await beginRestore(id, revertPath: true)
            }
            Log.logger("requests").error("Keep: the files aren't where Lidarr says")
            await needsAttention(id)
            return .failed
        }
        if finished == nil, !started { return .pending }   // not listed yet
        // Failed, reverted (Lidarr's RevertPath after an IOException) or never started.
        Log.logger("requests").error("Keep: the move didn't go through")
        return await beginRestore(id, revertPath: false)
    }

    /// Every track file is on disk (Lidarr's filesystem) inside the artist's new folder, and the find's folder is
    /// gone from the Finds root. Lidarr 3.2 leaves the track file paths at the old folder after a move (verified on
    /// the dev stack), so each one is looked for at its place under the new folder. Nil: can't tell right now.
    private func filesMoved(_ p: KeepProgress, to artistPath: String, files: [TrackFile]) async -> Bool? {
        let main = Self.mainGuard(p)
        let source = PathGuard(findsRoot: p.fromPath, otherRoots: [p.mainRoot], caseInsensitive: false)
        guard main.isInside(artistPath), !files.isEmpty else { return false }
        var expected: [String] = []
        for file in files {
            if main.isInside(file.path) {
                expected.append(file.path)
            } else if source.isInside(file.path), let base = PathGuard.standardize(p.fromPath),
                      let full = PathGuard.standardize(file.path) {
                expected.append(artistPath + full.dropFirst(base.count))
            } else {
                return false
            }
        }
        guard expected.allSatisfy(main.isInside) else { return false }
        do {
            for (folder, wanted) in Dictionary(grouping: expected, by: { ($0 as NSString).deletingLastPathComponent }) {
                let present = Set(try await lidarr.files(in: folder))
                guard wanted.allSatisfy(present.contains) else { return false }
            }
            let inFinds = try await lidarr.directories(in: p.findsRoot)
            return !inFinds.contains { Self.sameBytes($0, p.fromPath) }
        } catch {
            return nil
        }
    }

    /// Lidarr's records and its filesystem agree that nothing moved, so the restore may point the artist back at
    /// the find's folder (`moveFiles: false`): the artist folder's name is byte-for-byte the find folder's (so the
    /// point-back lands exactly on `fromPath`); every track file is recorded inside `fromPath` and is on disk there;
    /// that folder is still in the Finds root; and the main root has no folder of either name. Nil: can't tell now.
    /// Proven again before every point-back write.
    private func filesNeverLeft(_ p: KeepProgress, artistPath: String, files: [TrackFile]) async -> Bool? {
        let source = PathGuard(findsRoot: p.fromPath, otherRoots: [p.mainRoot], caseInsensitive: false)
        let folder = Self.lastComponent(p.fromPath), newFolder = Self.lastComponent(artistPath)
        guard Array(folder.utf8) == Array(newFolder.utf8), !files.isEmpty,
              files.allSatisfy({ source.isInside($0.path) }) else { return false }
        do {
            for (dir, wanted) in Dictionary(grouping: files.map(\.path), by: { ($0 as NSString).deletingLastPathComponent }) {
                let present = Set(try await lidarr.files(in: dir))
                guard wanted.allSatisfy(present.contains) else { return false }
            }
            let inMain = try await lidarr.directories(in: p.mainRoot).map(Self.lastComponent)
            let inFinds = try await lidarr.directories(in: p.findsRoot)
            return !inMain.contains { Self.looselyEqual($0, folder) || Self.looselyEqual($0, newFolder) }
                && inFinds.contains { Self.sameBytes($0, p.fromPath) }
        } catch {
            return nil
        }
    }

    /// Can't settle it now: try again later, until `keepMoveLimit` after the write (then needs attention).
    private func notYet(_ id: RequestID, _ p: KeepProgress) async {
        guard now().timeIntervalSince(p.startedAt) >= Self.keepMoveLimit else { return }
        Log.logger("requests").error("Keep: couldn't put the find back in time")
        await needsAttention(id)
    }

    /// Still moving: pending, until `keepMoveLimit` after the write (then needs attention).
    private func stillPending(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        guard now().timeIntervalSince(p.startedAt) >= Self.keepMoveLimit else { return .pending }
        Log.logger("requests").error("Keep: the move didn't finish in time")
        await needsAttention(id)
        return .failed
    }

    private func beginRestore(_ id: RequestID, revertPath: Bool) async -> KeepCheck {
        await mutate(id) {
            $0.keep?.phase = .restoring
            $0.keep?.revertPath = revertPath ? true : nil
            $0.keepFailed = true
        }
        if let restoring = request(id)?.keep { await restore(id, restoring) }
        return .failed
    }

    /// Destination existed and the untag answer was lost: done once `magpie-find` is gone; not applied when it is
    /// still there after `keepStartGrace`.
    private func checkUntag(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        guard let artist = try? await lidarr.artist(id: p.artistId) else { return await stillPending(id, p) }
        lastLidarrContact = now()
        if !artist.tags.contains(p.findTagId) {
            await finishInPlace(id, artistId: p.artistId)
            return .done(.keptInPlace)
        }
        guard now().timeIntervalSince(p.startedAt) >= Self.keepStartGrace else { return .pending }
        await nothingKept(id, p.artistId)
        await mutate(id) { $0.keepFailed = true }
        return .failed
    }

    /// Puts back what the PUT changed, from fresh GETs: `magpie-find`, the quality profile and, with `revertPath`,
    /// the artist path (to the Finds root, no files moved). Done when the artist is a find in the Finds folder
    /// again. A write that fails without an answer waits for a later tick; a 4xx, `keepRestoreLimit` writes, or an
    /// artist that is neither back in Finds nor (with `revertPath`) in the main root end in needs attention.
    private func restore(_ id: RequestID, _ p: KeepProgress) async {
        for _ in 0..<2 {
            guard let p = request(id)?.keep, p.phase == .restoring else { return }
            let artist: LidarrArtist, roots: [String]
            do {
                artist = try await lidarr.artist(id: p.artistId)
                roots = try await lidarr.rootFolders().map(\.path)
            } catch {
                return await notYet(id, p)
            }
            lastLidarrContact = now()
            let finds = Self.findsGuard(findsRoot: p.findsRoot, mainRoot: p.mainRoot, roots: roots)
            var body = RestoreBody(artistIds: [p.artistId])
            guard let path = artist.path else { return await needsAttention(id) }
            if finds.isInside(path) {
                // Back in Finds, but only exactly where it was counts (Lidarr's record must match the files).
                guard Self.sameBytes(path, p.fromPath) else { return await needsAttention(id) }
            } else {
                // Not in the Finds folder: only a proven never-moved artist is pointed back; otherwise the ledger
                // keeps saying kept, so nothing ever deletes it.
                guard p.revertPath == true, Self.mainGuard(p).isInside(path) else { return await needsAttention(id) }
                let files: [TrackFile]
                do { files = try await lidarr.trackFiles(artistId: p.artistId) } catch { return await notYet(id, p) }
                switch await filesNeverLeft(p, artistPath: path, files: files) {
                case true?: break
                case nil: return await notYet(id, p)
                case false?: return await needsAttention(id)
                }
                body.rootFolderPath = p.findsRoot
                body.moveFiles = false
            }
            if !artist.tags.contains(p.findTagId) {
                body.tags = [p.findTagId]
                body.applyTags = "add"
            }
            if let prior = p.priorQualityProfileId, artist.qualityProfileId != prior { body.qualityProfileId = prior }
            guard body.tags != nil || body.qualityProfileId != nil || body.rootFolderPath != nil else {
                // A find again: Not for me may remove it later.
                try? await setKept(p.artistId, at: nil)
                return await mutate(id) {
                    $0.keep = nil
                    $0.keepFailed = true
                }
            }
            guard (p.restoreAttempts ?? 0) < Self.keepRestoreLimit else { return await needsAttention(id) }
            await mutate(id) { $0.keep?.restoreAttempts = (p.restoreAttempts ?? 0) + 1 }
            do {
                try await persist()
                _ = try await gate.send("PUT", "artist/editor", body: body)
            } catch let error where error is WriteGateError || Self.isDefinitiveRejection(error) {
                Log.logger("requests").error("Keep: putting the find back was refused")
                return await needsAttention(id)
            } catch {
                Log.logger("requests").error("Keep: putting the find back postponed")
                return await notYet(id, p)
            }
        }
    }

    /// The Keep can't be settled from here: stop following it, write nothing more. The ledger keeps saying kept.
    private func needsAttention(_ id: RequestID) async {
        await mutate(id) {
            $0.keep = nil
            $0.keepFailed = true
            $0.keepNeedsAttention = true
        }
    }

    /// The move is confirmed: this request and every other ready request for the artist are kept; both folders
    /// are scanned (A3); the songs are looked up again by MBID.
    private func finishMove(_ id: RequestID, _ p: KeepProgress, to path: String) async {
        let kept = list.filter { $0.lidarrArtistId == p.artistId && ($0.id == id || ($0.state == .ready && $0.keep == nil)) }
        for r in kept {
            await apply(r.id, .keep)
            await mutate(r.id) {
                $0.keep = nil
                $0.keepFailed = false
                $0.relinkPending = true
                $0.movedAt = self.now()
                $0.movedTo = path
            }
        }
        do { try await library.rescanMoved(p.fromPath, path) } catch {
            Log.logger("requests").error("Keep: scan failed: \(Log.category(of: error), privacy: .public)")
        }
        for r in kept { await relink(r.id) }
    }

    /// Kept where it is: this request and every other ready request of the (now untagged) artist.
    private func finishInPlace(_ id: RequestID, artistId: Int) async {
        let kept = list.filter { $0.lidarrArtistId == artistId && ($0.id == id || ($0.state == .ready && $0.keep == nil)) }
        for r in kept {
            await apply(r.id, .keep)
            await mutate(r.id) {
                $0.keep = nil
                $0.keepFailed = false
                $0.keptInPlace = true
            }
        }
    }

    /// Nothing reached Lidarr (or it verifiably didn't apply): the request and ledger are as before the Keep.
    private func nothingKept(_ id: RequestID, _ artistId: Int) async {
        try? await setKept(artistId, at: nil)
        await mutate(id) { $0.keep = nil }
    }

    /// Sets (or clears) `keptAt` on every ledger entry of the artist: Keep moves the whole artist.
    private func setKept(_ artistId: Int, at date: Date?) async throws {
        for var entry in try await ledger.entries where entry.lidarrArtistId == artistId && entry.keptAt != date {
            entry.keptAt = date
            try await ledger.record(entry)
        }
    }

    // MARK: - After the move (A3: re-resolve song ids by MBID)

    /// Looks the kept song up again by MBID in the folder it moved to. Found: the request's song id and file type
    /// are updated and `onRelinked` tells the app (queue entries, finds identity). Gives up `relinkLimit` after
    /// the move.
    func relink(_ id: RequestID) async {
        guard let r = request(id), r.relinkPending == true else { return }
        relinkChecks[id] = now()
        guard let recording = r.recording.recordingMBID ?? r.plan?.recordingMBID, let folder = r.movedTo else {
            return await mutate(id) { $0.relinkPending = false }
        }
        let found: Song?
        do { found = try await library.keptSong(recording, folder) } catch { found = nil }
        guard let song = found else {
            if now().timeIntervalSince(r.movedAt ?? r.updatedAt) >= Self.relinkLimit {
                await mutate(id) { $0.relinkPending = false }
            }
            return
        }
        let before = r.songId
        await mutate(id) {
            $0.songId = song.id
            $0.songSuffix = song.suffix
            $0.relinkPending = false
        }
        if let updated = request(id) { onRelinked(updated, before, song) }
    }

    /// `tick()`: follows Keeps still settling (at most every `keepCheckInterval`) and looks kept songs up again.
    func followKeeps() async {
        for r in list {
            guard let artistId = r.keep?.artistId, !keepingArtists.contains(artistId) else { continue }
            // A last check "in the future" (the clock went back) is due now.
            if let last = r.keep?.lastCheckAt, (0..<Self.keepCheckInterval).contains(now().timeIntervalSince(last)) { continue }
            keepingArtists.insert(artistId)
            _ = try? await followKeep(r.id, inline: false)
            keepingArtists.remove(artistId)
        }
        for r in list where r.relinkPending == true {
            if let artistId = r.lidarrArtistId, keepingArtists.contains(artistId) { continue }
            if let last = relinkChecks[r.id], now().timeIntervalSince(last) < Self.relinkInterval { continue }
            await relink(r.id)
        }
    }

    // MARK: - Preconditions

    /// G4 on fresh state (see the type comment).
    static func mayKeep(_ artist: LidarrArtist, request r: MagpieRequest, setup: KeepSetup, roots: [String]) -> Bool {
        guard findsRootStillValid(setup.findsRoot, main: setup.mainRoot, roots: roots),
              roots.contains(where: { sameBytes($0, setup.mainRoot) }) else { return false }
        if let expected = r.plan?.artistMBID, artist.foreignArtistId != expected { return false }
        guard artist.tags.contains(setup.findTagId), let path = artist.path else { return false }
        return findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots).isInside(path)
    }

    /// G4: the move would land somewhere other than a fresh folder of the find's own name: Lidarr's folder name is
    /// unknown or differs from the current one at all (byte for byte), or a folder of either name is in the main
    /// root already, compared loosely (case, diacritics, width; Swift `==` already treats NFC and NFD alike) so a
    /// near match counts as existing. Both only keep more finds in place.
    static func mustStayInFinds(current: String, named: String?, existing: [String]) -> Bool {
        // Strict: any drift in Lidarr's name (even case or accents) means the folder would change. Untag only.
        guard let named, Array(named.utf8) == Array(current.utf8) else { return true }
        return existing.contains { looselyEqual($0, current) || looselyEqual($0, named) }
    }

    static func looselyEqual(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        return fold(a) == fold(b)
    }

    static func lastComponent(_ path: String) -> String {
        PathGuard.byteComponents(path).last ?? ""   // FL1: split on the byte `/`
    }

    /// The Finds root, confined against every other fresh root folder and the main root; case-sensitive.
    static func findsGuard(findsRoot: String, mainRoot: String, roots: [String]) -> PathGuard {
        PathGuard(findsRoot: findsRoot, otherRoots: roots.filter { !sameBytes($0, findsRoot) } + [mainRoot],
                  caseInsensitive: false)
    }

    /// Strictly inside the main root (and not inside the Finds root), byte-exact.
    static func mainGuard(_ p: KeepProgress) -> PathGuard {
        PathGuard(findsRoot: p.mainRoot, otherRoots: [p.findsRoot], caseInsensitive: false)
    }

    /// The same folder, byte for byte, after standardising.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        guard let x = PathGuard.standardize(a), let y = PathGuard.standardize(b) else { return false }
        return Array(x.utf8) == Array(y.utf8)
    }

    /// A `BulkMoveArtist` for this artist, or one whose artists can't be read (counted, to be safe).
    static func isMove(_ c: CommandStatus, of artistId: Int) -> Bool {
        c.name.lowercased() == "bulkmoveartist" && (c.artistIds.isEmpty || c.artistIds.contains(artistId))
    }

    static func isFinished(_ c: CommandStatus) -> Bool { finishedCommandStates.contains(c.status.lowercased()) }
}
