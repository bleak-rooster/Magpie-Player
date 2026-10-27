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
/// Then `GET /filesystem` for `<main root>/<artist folder>`: if it exists, only `magpie-find` comes off and the
/// find stays where it is (G4). Otherwise one `PUT /artist/editor` with exactly the G4 body. Lidarr saves the new
/// path at once and moves the files in a `BulkMoveArtist` command, reverting the path if the move fails (A3), so
/// Keep waits for that command and then checks the artist path again before it claims anything. Only then are
/// both folders scanned and the song looked up again by MBID.
///
/// M6: the Keep is saved (request and ledger) before every write, so a relaunch only follows it, never writes the
/// move twice. The ledger says "kept" from just before the write (Not for me refuses kept albums, G3.4) until the
/// Keep verifiably failed. A failed move puts back what the PUT changed (`magpie-find`, the quality profile), so
/// the find can be kept again.
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

    /// A failed move: put back what the PUT already changed. Nil fields are left out.
    struct RestoreBody: Encodable, Sendable {
        var artistIds: [Int]
        var qualityProfileId: Int?
        var tags: [Int]?
        var applyTags: String?
    }

    // MARK: - Keep

    /// Keeps a ready find (see the type comment). Throws `KeepError`; nothing is claimed unless it returns.
    public func keep(_ id: RequestID) async throws -> KeepOutcome {
        guard !stopped, await load() else { throw KeepError.unavailable }
        guard !keeping.contains(id) else { return .stillMoving }   // a Keep for it is already under way
        guard let r = request(id) else { throw KeepError.notAFind }
        keeping.insert(id)
        defer { keeping.remove(id) }
        // M6: already written. Only see how it went; never write it again.
        if r.keep != nil { return try await followKeep(id, inline: true) }
        guard r.state == .ready, let artistId = r.lidarrArtistId else { throw KeepError.notAFind }
        guard await gate.enabled else { throw KeepError.changesOff }
        guard let setup = await keepSetup() else { throw KeepError.notSetUp }

        let created: Bool
        do { created = try await ledger.createdArtist(artistId) } catch { throw KeepError.unavailable }
        guard created else { throw KeepError.notAFind }
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
        guard Self.mayKeep(artist, request: r, setup: setup, roots: roots), let from = artist.path else {
            throw KeepError.notAFind
        }
        // Something is already moving this artist (not Magpie's Keep, or one whose record was lost): leave it.
        guard !commands.contains(where: { Self.isMove($0, of: artistId) && !Self.isFinished($0) }) else {
            throw KeepError.unavailable
        }
        let destination = Self.destination(of: from, in: setup.mainRoot)
        let exists: Bool
        do { exists = try await lidarr.filesystemExists(path: destination) } catch { throw KeepError.unavailable }

        let progress = KeepProgress(
            phase: exists ? .untagging : .moving, startedAt: now(), artistId: artistId, fromPath: from,
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
        let body: any Encodable & Sendable = exists
            ? UntagBody(artistIds: [artistId], tags: [setup.findTagId], applyTags: "remove")
            : MoveBody(artistIds: [artistId], rootFolderPath: setup.mainRoot, moveFiles: true,
                       qualityProfileId: setup.losslessProfileId, tags: [setup.findTagId], applyTags: "remove")
        do {
            _ = try await gate.send("PUT", "artist/editor", body: body)
        } catch let refusal as WriteGateError {
            await nothingKept(id, artistId)   // the gate throws before anything leaves the device
            switch refusal {
            case .disabled: throw KeepError.changesOff
            case .logUnavailable: throw KeepError.unavailable
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
        if exists {
            await finishInPlace(id)
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
                throw KeepError.moveFailed
            }
            switch await checkKeep(id, progress) {
            case .done(let outcome): return outcome
            case .failed: throw KeepError.moveFailed
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

    /// A3: done only when the move command completed and the artist path (fresh GET) is under the main root.
    /// Lidarr saves the new path before it moves anything, so the path alone proves nothing while a move runs.
    private func checkMove(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        let commands: [CommandStatus], artist: LidarrArtist
        do {
            commands = try await lidarr.commands()
            artist = try await lidarr.artist(id: p.artistId)
        } catch {
            return .pending   // can't tell now; checked again
        }
        lastLidarrContact = now()
        let mine = commands.filter { $0.id > p.commandBaseline && Self.isMove($0, of: p.artistId) }
        if mine.contains(where: { !Self.isFinished($0) }) { return .pending }
        let finished = mine.max { $0.id < $1.id }
        let started = now().timeIntervalSince(p.startedAt) >= Self.keepStartGrace
        let mover = PathGuard(findsRoot: p.mainRoot, otherRoots: [p.findsRoot], caseInsensitive: false)
        let inMain = artist.path.map(mover.isInside) ?? false
        if inMain, let path = artist.path,
           finished.map({ $0.status.lowercased() == "completed" }) ?? started {
            // Completed, or long gone from Lidarr's list (it prunes finished commands) with nothing moving now.
            await finishMove(id, p, to: path)
            return .done(.moved)
        }
        if finished == nil, !started { return .pending }   // not listed yet
        // Failed, reverted (Lidarr's RevertPath after an IOException) or never started.
        Log.logger("requests").error("Keep: the move didn't go through")
        await mutate(id) {
            $0.keep?.phase = .restoring
            $0.keepFailed = true
        }
        if let restoring = request(id)?.keep { await restore(id, restoring) }
        return .failed
    }

    /// Destination existed and the untag answer was lost: done once `magpie-find` is gone; not applied when it is
    /// still there after `keepStartGrace`.
    private func checkUntag(_ id: RequestID, _ p: KeepProgress) async -> KeepCheck {
        guard let artist = try? await lidarr.artist(id: p.artistId) else { return .pending }
        lastLidarrContact = now()
        if !artist.tags.contains(p.findTagId) {
            await finishInPlace(id)
            return .done(.keptInPlace)
        }
        guard now().timeIntervalSince(p.startedAt) >= Self.keepStartGrace else { return .pending }
        await nothingKept(id, p.artistId)
        await mutate(id) { $0.keepFailed = true }
        return .failed
    }

    /// Puts back `magpie-find` and the quality profile the PUT changed, if the artist is back inside the Finds
    /// root (fresh GETs). A failed write leaves the phase at `.restoring` for a later tick.
    private func restore(_ id: RequestID, _ p: KeepProgress) async {
        let artist: LidarrArtist, roots: [String]
        do {
            artist = try await lidarr.artist(id: p.artistId)
            roots = try await lidarr.rootFolders().map(\.path)
        } catch {
            return
        }
        lastLidarrContact = now()
        let finds = Self.findsGuard(findsRoot: p.findsRoot, mainRoot: p.mainRoot, roots: roots)
        if let path = artist.path, finds.isInside(path) {
            var body = RestoreBody(artistIds: [p.artistId])
            if !artist.tags.contains(p.findTagId) {
                body.tags = [p.findTagId]
                body.applyTags = "add"
            }
            if let prior = p.priorQualityProfileId, artist.qualityProfileId != prior { body.qualityProfileId = prior }
            if body.tags != nil || body.qualityProfileId != nil {
                do {
                    try await persist()
                    _ = try await gate.send("PUT", "artist/editor", body: body)
                } catch {
                    Log.logger("requests").error("Keep: putting the find back postponed")
                    return
                }
            }
            // A find again: Not for me may remove it later.
            try? await setKept(p.artistId, at: nil)
        }
        // Otherwise it isn't in the Finds folder: the ledger keeps saying kept, so nothing ever deletes it.
        await mutate(id) {
            $0.keep = nil
            $0.keepFailed = true
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
            }
        }
        do { try await library.rescanMoved(p.fromPath, path) } catch {
            Log.logger("requests").error("Keep: scan failed: \(Log.category(of: error), privacy: .public)")
        }
        for r in kept { await relink(r.id) }
    }

    private func finishInPlace(_ id: RequestID) async {
        await apply(id, .keep)
        await mutate(id) {
            $0.keep = nil
            $0.keepFailed = false
            $0.keptInPlace = true
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

    /// Looks the kept song up again by MBID. Found: the request's song id and file type are updated and
    /// `onRelinked` tells the app (queue entries, finds identity). Gives up `relinkLimit` after the move.
    func relink(_ id: RequestID) async {
        guard let r = request(id), r.relinkPending == true else { return }
        relinkChecks[id] = now()
        guard let recording = r.recording.recordingMBID ?? r.plan?.recordingMBID else {
            return await mutate(id) { $0.relinkPending = false }
        }
        let found: Song?
        do { found = try await library.keptSong(recording) } catch { found = nil }
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
        for r in list where r.keep != nil && !keeping.contains(r.id) {
            if let last = r.keep?.lastCheckAt, now().timeIntervalSince(last) < Self.keepCheckInterval { continue }
            keeping.insert(r.id)
            _ = try? await followKeep(r.id, inline: false)
            keeping.remove(r.id)
        }
        for r in list where r.relinkPending == true && !keeping.contains(r.id) {
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

    /// The Finds root, confined against every other fresh root folder and the main root; case-sensitive.
    static func findsGuard(findsRoot: String, mainRoot: String, roots: [String]) -> PathGuard {
        PathGuard(findsRoot: findsRoot, otherRoots: roots.filter { !sameBytes($0, findsRoot) } + [mainRoot],
                  caseInsensitive: false)
    }

    /// The same folder, byte for byte, after standardising.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        guard let x = PathGuard.standardize(a), let y = PathGuard.standardize(b) else { return false }
        return Array(x.utf8) == Array(y.utf8)
    }

    /// Where Lidarr moves the artist folder: the main root plus the folder's own name.
    static func destination(of artistPath: String, in mainRoot: String) -> String {
        let folder = artistPath.split(separator: "/").last.map(String.init) ?? ""
        let root = PathGuard.standardize(mainRoot) ?? mainRoot
        return (root == "/" ? "" : root) + "/" + folder
    }

    /// A `BulkMoveArtist` for this artist, or one whose artists can't be read (counted, to be safe).
    static func isMove(_ c: CommandStatus, of artistId: Int) -> Bool {
        c.name.lowercased() == "bulkmoveartist" && (c.artistIds.isEmpty || c.artistIds.contains(artistId))
    }

    static func isFinished(_ c: CommandStatus) -> Bool { finishedCommandStates.contains(c.status.lowercased()) }
}

extension RequestRunner.RestoreBody {
    init(artistIds: [Int]) { self.init(artistIds: artistIds, qualityProfileId: nil, tags: nil, applyTags: nil) }
}
