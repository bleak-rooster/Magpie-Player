import Foundation
import LidarrKit
import MagpieCore

/// Not for me (Task 6.2c): deletes a find's album from the Finds folder (G3, A16). It deletes files on the owner's
/// Lidarr, so every step is proven again from fresh Lidarr state immediately before it is sent:
/// - the request is a ready Finds-mode find of an artist Magpie added (never an existing-artist row or a fallback
///   request, G6), with no Keep under way, kept or needing a look on any request of the artist, and no other
///   request still bringing the album in;
/// - the ledger says Magpie created the artist and the album request, and nothing of the artist is kept (G3.1, G3.4);
/// - Lidarr's album with that id is still the request's release group (security FL2);
/// - the stored Finds root still checks out against fresh root folders; the artist (fresh GET) carries
///   `magpie-find`; its folder and every track file of the artist are strictly inside the Finds root and inside the
///   artist's own folder (a case-sensitive, byte-exact `PathGuard` built from those root folders, G3.2, G3.3);
/// - every file to delete is on disk where Lidarr records it (Lidarr's filesystem listing): Lidarr 3.2 leaves track
///   file paths stale after a move (seen on the dev stack in Task 6.2b), so the records alone prove nothing;
/// - no move of the artist is running in Lidarr;
/// - Lidarr's recycle bin: when it is unset the owner must have confirmed "This deletes the files permanently."
///
/// Then (A16): `DELETE /trackfile/bulk {trackFileIds}` (one `DELETE /trackfile/{id}` at a time when Lidarr has no
/// bulk route), `PUT /album/monitor {monitored: false}`, and `DELETE /artist/{id}?deleteFiles=false&
/// addImportListExclusion=false` only when Magpie created the artist, no other request needs it, Lidarr records no
/// file and no other monitored album for it, and its folder holds no file at all on disk.
///
/// M6: the Not for me is saved before every write. A lost answer is never followed by the same write until a fresh
/// proof says what is still there. Writes are bounded (`writeBudget`, `notForMeUnansweredLimit`) and so is time
/// (`notForMeLimit`): what can't be finished ends in "needs attention" and nothing more is written. Keep and Not for
/// me share the per-artist guard (`keepingArtists`), so they never run together on one artist.
extension RequestRunner {
    public enum NotForMeOutcome: Sendable, Equatable {
        /// The album's files are deleted and it is unmonitored (and the artist removed when nothing else was left).
        case removed
        /// Lidarr couldn't be reached partway; later ticks finish it, proving each step again first.
        case stillGoing
    }

    public enum NotForMeError: Error, Equatable {
        /// "Allow Magpie to change Lidarr" is off (G1). Nothing was written.
        case changesOff
        /// Finds isn't set up. Nothing was written.
        case notSetUp
        /// Lidarr, the ledger or the saved requests can't be read right now. Nothing was written.
        case unavailable
        /// Not a find Magpie may delete (a precondition failed on fresh state). Nothing was written.
        case notAFind
        /// Lidarr's recycle bin is unset but the owner didn't confirm a permanent delete. Nothing was written.
        case confirmAgain
        /// Lidarr refused the delete. Nothing was removed.
        case failed
        /// It couldn't be finished from here; it needs the owner's look (`notForMeNeedsAttention`).
        case needsAttention
    }

    /// What the confirm sheet needs (G3.5), read without writing anything.
    public struct NotForMeCheck: Sendable, Equatable {
        /// Lidarr's recycle bin is unset: the sheet says "This deletes the files permanently."
        public var permanent: Bool
        public var albumTitle: String?
    }

    /// How long `notForMe` itself keeps at it while Lidarr can't be read, before saying it is still going.
    public static let notForMeInlineWait: TimeInterval = 60
    /// A Not for me still not finished this long after it started: followed no further (needs attention).
    public static let notForMeLimit: TimeInterval = 30 * 60
    /// Writes whose answer is lost before it needs attention.
    public static let notForMeUnansweredLimit = 3
    /// While a Not for me is still going after `notForMe` returned: checked at most this often.
    public static let notForMeCheckInterval: TimeInterval = 30
    /// Folders looked into under the artist folder before removing the artist; more and the artist stays.
    static let artistFolderWalkLimit = 50

    // MARK: - Bodies

    struct TrackFileIdsBody: Encodable, Sendable {
        var trackFileIds: [Int]
    }

    private struct UnmonitorBody: Encodable, Sendable {
        var albumIds: [Int]
        var monitored: Bool
    }

    // MARK: - Entry points

    /// For the confirm sheet: proves the find may be deleted and reads the recycle bin. Writes nothing.
    public func notForMeCheck(_ id: RequestID) async throws -> NotForMeCheck {
        guard !stopped, await load() else { throw NotForMeError.unavailable }
        guard let r = request(id), let candidate = letGoCandidate(r) else { throw NotForMeError.notAFind }
        guard !artistBusy(candidate.artist) else { throw NotForMeError.unavailable }
        guard await gate.enabled else { throw NotForMeError.changesOff }
        guard let setup = await keepSetup() else { throw NotForMeError.notSetUp }
        switch await proveLetGo(r, artistId: candidate.artist, albumId: candidate.album, setup: setup, artistPath: nil) {
        case .yes(let proof): return NotForMeCheck(permanent: proof.permanent, albumTitle: r.albumTitle)
        case .no: throw NotForMeError.notAFind
        case .unknown: throw NotForMeError.unavailable
        }
    }

    /// Deletes the find's album (see the type comment) after the owner confirmed. `permanentConfirmed`: the sheet
    /// said "This deletes the files permanently." Throws `NotForMeError`; nothing is claimed unless it returns.
    public func notForMe(_ id: RequestID, permanentConfirmed: Bool) async throws -> NotForMeOutcome {
        guard !stopped, await load() else { throw NotForMeError.unavailable }
        guard let r = request(id) else { throw NotForMeError.notAFind }
        // M6: already under way: only follow it (each step proven again); never start it twice.
        if let p = r.notForMe {
            guard !artistBusy(p.artistId) else { return .stillGoing }
            hold(p.artistId)
            defer { release(p.artistId) }
            return try await followNotForMe(id, inline: true)
        }
        guard let (artistId, albumId) = letGoCandidate(r).map({ ($0.artist, $0.album) }) else {
            throw NotForMeError.notAFind
        }
        guard !artistBusy(artistId) else { throw NotForMeError.unavailable }
        hold(artistId)
        defer { release(artistId) }
        guard await gate.enabled else { throw NotForMeError.changesOff }
        guard let setup = await keepSetup() else { throw NotForMeError.notSetUp }
        // Anything of the artist may have changed during the awaits: the request-level checks again.
        guard let fresh = request(id), letGoCandidate(fresh) != nil else { throw NotForMeError.notAFind }

        let proof: LetGoProof
        switch await proveLetGo(fresh, artistId: artistId, albumId: albumId, setup: setup, artistPath: nil) {
        case .yes(let p): proof = p
        case .no: throw NotForMeError.notAFind
        case .unknown: throw NotForMeError.unavailable
        }
        guard !proof.permanent || permanentConfirmed else { throw NotForMeError.confirmAgain }
        guard let path = proof.artist.path else { throw NotForMeError.notAFind }
        let progress = NotForMeProgress(
            phase: .deleting, startedAt: now(), artistId: artistId, albumId: albumId, artistPath: path,
            findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, findTagId: setup.findTagId,
            permanentConfirmed: permanentConfirmed,
            writeBudget: proof.albumFiles.count + Self.notForMeUnansweredLimit + 3)
        // M6: on disk before anything can reach Lidarr.
        await mutate(id) { $0.notForMe = progress }
        do { try await persist() } catch {
            await mutate(id) { $0.notForMe = nil }
            throw NotForMeError.unavailable
        }
        return try await followNotForMe(id, inline: true)
    }

    private func hold(_ artistId: Int) {
        keepingArtists.insert(artistId)
        lettingGoArtists.insert(artistId)
    }

    private func release(_ artistId: Int) {
        keepingArtists.remove(artistId)
        lettingGoArtists.remove(artistId)
    }

    /// `tick()`: follows Not for mes still going (at most every `notForMeCheckInterval`).
    func followNotForMes() async {
        for r in list {
            guard let p = r.notForMe, !artistBusy(p.artistId) else { continue }
            // A last check "in the future" (the clock went back) is due now.
            if let last = p.lastCheckAt, (0..<Self.notForMeCheckInterval).contains(now().timeIntervalSince(last)) { continue }
            hold(p.artistId)
            _ = try? await followNotForMe(r.id, inline: false)
            release(p.artistId)
        }
    }

    // MARK: - Steps

    enum LetGoStep { case next, pending, done, stopped(NotForMeError) }

    /// Runs the steps until done, stopped, or (`inline`) `notForMeInlineWait` passes while Lidarr can't be read.
    func followNotForMe(_ id: RequestID, inline: Bool) async throws -> NotForMeOutcome {
        let deadline = now().addingTimeInterval(inline ? Self.notForMeInlineWait : 0)
        while true {
            guard !stopped, let r = request(id) else { throw NotForMeError.unavailable }
            guard let p = r.notForMe else {
                if r.state == .dismissed { return .removed }
                throw r.notForMeNeedsAttention ? NotForMeError.needsAttention : NotForMeError.failed
            }
            guard now().timeIntervalSince(p.startedAt) < Self.notForMeLimit else {
                Log.logger("requests").error("Not for me: didn't finish in time")
                await letGoNeedsAttention(id)
                throw NotForMeError.needsAttention
            }
            let step: LetGoStep
            switch p.phase {
            case .deleting: step = await deleteFiles(id, r, p)
            case .unmonitoring: step = await unmonitor(id, p)
            case .removingArtist: step = await removeArtist(id, r, p)
            }
            switch step {
            case .next:
                continue
            case .done:
                await finishNotForMe(id, p)
                return .removed
            case .stopped(let error):
                throw error
            case .pending:
                await mutate(id) { $0.notForMe?.lastCheckAt = self.now() }
                guard now() < deadline else { return .stillGoing }
                await sleep(Self.keepPollInterval)
            }
        }
    }

    /// A16 step 1, proven again (G3) right before every delete: the album's track files that are still there.
    private func deleteFiles(_ id: RequestID, _ r: MagpieRequest, _ p: NotForMeProgress) async -> LetGoStep {
        let proof: LetGoProof
        switch await proveLetGo(r, artistId: p.artistId, albumId: p.albumId, setup: Self.setup(p), artistPath: p.artistPath) {
        case .unknown: return .pending
        case .no: return await stop(id, .notAFind, wasSent: p.sent)
        case .yes(let fresh): proof = fresh
        }
        guard !proof.permanent || p.permanentConfirmed else { return await stop(id, .confirmAgain, wasSent: p.sent) }
        let ids = proof.albumFiles.map(\.id)
        guard let first = ids.first else {
            await mutate(id) { $0.notForMe?.phase = .unmonitoring }
            return .next
        }
        guard await spend(id, p) else { return await stop(id, .needsAttention, wasSent: p.sent) }
        // M6: saved before the write; if it can't be saved, nothing is sent and it waits.
        do { try await persist() } catch { return .pending }
        do {
            if p.oneByOne == true {
                _ = try await gate.send("DELETE", "trackfile/\(first)", body: nil)
            } else {
                _ = try await gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: ids))
            }
            return .next
        } catch WriteGateError.unconfirmed {
            // Final fix 2 A-M2: the gate couldn't check it (a read failed); nothing was sent. Later, bounded by the
            // write budget and the time limit, like Keep's restore.
            Log.logger("requests").error("Not for me: the delete postponed (couldn't be checked)")
            return .pending
        } catch let refusal as WriteGateError {
            // Nothing left the device.
            return await stop(id, Self.error(for: refusal), wasSent: p.sent)
        } catch let error where Self.isDefinitiveRejection(error) {
            if case .http(let status)? = error as? LidarrError, status == 404 || status == 405 {
                // No bulk route (or a file already went): one at a time, each proven again first.
                if p.oneByOne != true {
                    await mutate(id) { $0.notForMe?.oneByOne = true }
                } else {
                    await mutate(id) { $0.notForMe?.unanswered += 1 }
                }
                return .next
            }
            // Received and refused: this delete applied nothing.
            Log.logger("requests").error("Not for me: Lidarr refused the delete")
            return await stop(id, .failed, wasSent: p.sent)
        } catch {
            // No answer: it may have landed. Proven again (what is still there) before anything is sent again.
            Log.logger("requests").error("Not for me: no answer to the delete; checking again")
            await mutate(id) { $0.notForMe?.unanswered += 1 }
            return .next
        }
    }

    /// A16 step 2: unmonitor the album if Lidarr still has it monitored (the ledger said Magpie monitored it).
    private func unmonitor(_ id: RequestID, _ p: NotForMeProgress) async -> LetGoStep {
        let albums: [LidarrAlbum]
        do { albums = try await lidarr.albums(artistId: p.artistId) } catch { return .pending }
        lastLidarrContact = now()
        guard albums.contains(where: { $0.id == p.albumId && $0.monitored }) else {
            await mutate(id) { $0.notForMe?.phase = .removingArtist }
            return .next
        }
        guard await spend(id, p) else { return await stop(id, .needsAttention, wasSent: true) }
        // M6: saved before the write; if it can't be saved, nothing is sent and it waits.
        do { try await persist() } catch { return .pending }
        do {
            _ = try await gate.send("PUT", "album/monitor", body: UnmonitorBody(albumIds: [p.albumId], monitored: false))
            return .next
        } catch WriteGateError.unconfirmed {
            // A-M2: not checked (the ledger couldn't be read), nothing sent: later, bounded.
            Log.logger("requests").error("Not for me: unmonitoring postponed (couldn't be checked)")
            return .pending
        } catch let error where error is WriteGateError || Self.isDefinitiveRejection(error) {
            Log.logger("requests").error("Not for me: unmonitoring the album was refused")
            return await stop(id, .needsAttention, wasSent: true)
        } catch {
            await mutate(id) { $0.notForMe?.unanswered += 1 }
            return .next
        }
    }

    /// A16 step 3: the artist goes only when it may (`mayRemoveArtist`); otherwise it stays and Not for me is done.
    private func removeArtist(_ id: RequestID, _ r: MagpieRequest, _ p: NotForMeProgress) async -> LetGoStep {
        switch await mayRemoveArtist(r, p) {
        case .unknown: return .pending
        case .no: return .done
        case .yes: break
        }
        guard await spend(id, p) else { return await stop(id, .needsAttention, wasSent: true) }
        // M6: saved before the write; if it can't be saved, nothing is sent and it waits.
        do { try await persist() } catch { return .pending }
        // R23 (D191–D194; fix round 1 M3): only once nothing before the artist's DELETE can stop it.
        await cleanSlateBeforeRemoving(artistId: p.artistId, for: id)
        do {
            _ = try await gate.send("DELETE", "artist/\(p.artistId)?deleteFiles=false&addImportListExclusion=false",
                                    body: nil)
            return .done
        } catch let error where error is WriteGateError || Self.isDefinitiveRejection(error) {
            // The album is gone and unmonitored: that was the Not for me. The artist just stays.
            Log.logger("requests").error("Not for me: the artist stays (removing it was refused)")
            return .done
        } catch {
            // No answer: a fresh GET says whether it went (`mayRemoveArtist` sees a 404 as gone).
            await mutate(id) { $0.notForMe?.unanswered += 1 }
            return .next
        }
    }

    /// Counts one more write against the budgets; false when either is spent. Marks the Not for me as sent (saved
    /// before the write, so a relaunch after a cut-off send treats it as maybe applied).
    private func spend(_ id: RequestID, _ p: NotForMeProgress) async -> Bool {
        guard p.writes < p.writeBudget, p.unanswered < Self.notForMeUnansweredLimit else {
            Log.logger("requests").error("Not for me: out of tries")
            return false
        }
        await mutate(id) {
            $0.notForMe?.writes += 1
            $0.notForMe?.sent = true
        }
        return true
    }

    /// `wasSent` false (no write reached Lidarr, or Lidarr refused the only one): nothing changed, so the Not for
    /// me is simply off and `error` says why. Otherwise: needs attention, and nothing more is written.
    private func stop(_ id: RequestID, _ error: NotForMeError, wasSent: Bool) async -> LetGoStep {
        guard wasSent else {
            await mutate(id) { $0.notForMe = nil }
            return .stopped(error)
        }
        await letGoNeedsAttention(id)
        return .stopped(.needsAttention)
    }

    private func letGoNeedsAttention(_ id: RequestID) async {
        await mutate(id) {
            $0.notForMe = nil
            $0.notForMeNeedsAttention = true
        }
    }

    /// Done: this request and every other ready request on the album are dismissed (their clean-up closes the ledger
    /// entries), and the library is scanned so the songs leave it.
    private func finishNotForMe(_ id: RequestID, _ p: NotForMeProgress) async {
        let done = list.filter {
            $0.id == id || ($0.albumId == p.albumId && $0.lidarrArtistId == p.artistId && $0.state == .ready
                            && $0.notForMe == nil && $0.keep == nil)
        }
        for r in done {
            await mutate(r.id) { $0.notForMe = nil }
            await apply(r.id, .notForMe)
        }
        do { try await library.startScan() } catch {
            Log.logger("requests").error("Not for me: scan failed: \(Log.category(of: error), privacy: .public)")
        }
    }

    private static func error(for refusal: WriteGateError) -> NotForMeError {
        switch refusal {
        case .disabled: .changesOff
        case .logUnavailable, .unconfirmed: .unavailable
        case .forbidden, .invalidRequest: .failed
        }
    }

    /// Keep's setup shape, from what the Not for me saved (the lossless profile plays no part here).
    private static func setup(_ p: NotForMeProgress) -> KeepSetup {
        KeepSetup(findsRoot: p.findsRoot, mainRoot: p.mainRoot, losslessProfileId: 0, findTagId: p.findTagId)
    }

    // MARK: - Preconditions

    enum Proven<T> { case yes(T), no, unknown }

    struct LetGoProof {
        var artist: LidarrArtist
        /// The album's track files, each proven on disk where Lidarr records it.
        var albumFiles: [TrackFile]
        /// Lidarr's recycle bin is unset.
        var permanent: Bool
    }

    /// What the requests alone must say (G6, G3.4): the artist and album, or nil when Not for me isn't offered.
    /// Round 18: a find whose plan named the artist (a second song of a find artist, or round 17's next release) counts
    /// too: Finds mode is only ever set for an artist the ledger says Magpie created, inside the Finds root
    /// (`isFindNow`), and `proveLetGo` proves all of it again on fresh state.
    func letGoCandidate(_ r: MagpieRequest) -> (artist: Int, album: Int)? {
        guard r.state == .ready, r.isFind, let plan = r.plan,
              let artist = r.lidarrArtistId, let album = r.albumId else { return nil }
        // Anything of the artist kept, being kept, being let go, or needing a look: never.
        let busy = list.contains {
            $0.lidarrArtistId == artist
                && ($0.state == .kept || $0.keep != nil || $0.keepNeedsAttention || $0.notForMe != nil
                    || $0.notForMeNeedsAttention)
        }
        // Another request still bringing this album in: its files aren't finished yet.
        let arriving = list.contains {
            $0.id != r.id && $0.isActive && ($0.albumId == album || $0.plan?.releaseGroupMBID == plan.releaseGroupMBID)
        }
        return busy || arriving ? nil : (artist, album)
    }

    /// G3 on fresh state (see the type comment). `artistPath`: the folder proven before the first write, which
    /// the artist must still have. `.unknown`: something couldn't be read right now.
    func proveLetGo(_ r: MagpieRequest, artistId: Int, albumId: Int, setup: KeepSetup,
                    artistPath: String?) async -> Proven<LetGoProof> {
        let entries: [LedgerEntry]
        do { entries = try await ledger.entries.filter { $0.lidarrArtistId == artistId } } catch { return .unknown }
        guard entries.contains(where: \.createdArtist), !entries.contains(where: \.isKeptOrKeeping),
              let entry = entries.first(where: { $0.albumId == albumId }), !entry.wasMonitoredBefore,
              entry.rgMbid == r.plan?.releaseGroupMBID else { return .no }
        let roots: [String], artist: LidarrArtist, commands: [CommandStatus], albums: [LidarrAlbum]
        let albumFiles: [TrackFile], artistFiles: [TrackFile], recycleBin: String?
        do {
            roots = try await lidarr.rootFolders().map(\.path)
            artist = try await lidarr.artist(id: artistId)
            albums = try await lidarr.albums(artistId: artistId)
            commands = try await lidarr.commands()
            albumFiles = try await lidarr.trackFiles(albumId: albumId)
            artistFiles = try await lidarr.trackFiles(artistId: artistId)
            recycleBin = try await lidarr.recycleBin()
        } catch LidarrError.http(status: 404) {
            return .no
        } catch {
            return .unknown
        }
        lastLidarrContact = now()
        guard entries.contains(where: { $0.created(artist) }),   // the same artist, not a reused id
              Self.mayKeep(artist, request: r, setup: setup, roots: roots), let path = artist.path else { return .no }
        // FL2: the album id is still the request's release group (a refresh can re-create rows and reuse an id).
        guard albums.contains(where: { $0.id == albumId && $0.foreignAlbumId == entry.rgMbid }) else { return .no }
        if let artistPath, !Self.sameBytes(path, artistPath) { return .no }
        guard !commands.contains(where: { Self.isMove($0, of: artistId) && !Self.isFinished($0) }) else { return .no }
        let finds = Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots)
        let folder = Self.artistGuard(path, setup: setup, roots: roots)
        guard (artistFiles + albumFiles).allSatisfy({ finds.isInside($0.path) && folder.isInside($0.path) }),
              albumFiles.allSatisfy({ $0.albumId == nil || $0.albumId == albumId }) else { return .no }
        // On disk where Lidarr records each file (its records can be stale).
        do {
            for (dir, wanted) in Dictionary(grouping: albumFiles.map(\.path), by: { ($0 as NSString).deletingLastPathComponent }) {
                let present = Set(try await lidarr.files(in: dir).map { Array($0.utf8) })
                guard wanted.allSatisfy({ present.contains(Array($0.utf8)) }) else { return .no }
            }
        } catch {
            return .unknown
        }
        return .yes(LetGoProof(artist: artist, albumFiles: albumFiles, permanent: recycleBin == nil))
    }

    /// A16 / ruling 6: the artist may go only when Magpie created it (ledger) and nothing is kept; no other request
    /// of it is under way, ready, kept or let go of; a fresh GET still shows it a find in the same folder; Lidarr
    /// records no track file and no other monitored album for it; and its folder holds no file on disk. A 404:
    /// it is gone already (`.no`, nothing to send).
    /// Tests (critic test 1): whether the artist-removal check would allow it.
    func mayRemoveArtistAllowed(_ r: MagpieRequest, _ p: NotForMeProgress) async -> Bool {
        if case .yes = await mayRemoveArtist(r, p) { return true }
        return false
    }

    // MARK: - A late import after a stop (round 20)

    /// Round 20 (owner: stopped, then the album arrived anyway): a search still running at the stop can grab, and a copy
    /// that is already complete is never interrupted, so Lidarr may import a stopped find's album after all. Once the
    /// queue holds nothing of it, those files are let go as Not for me lets a find go: every precondition proven again
    /// (`proveLetGo`: Magpie created the artist, it is a find inside the Finds folder, nothing of it kept, each file on
    /// disk where Lidarr records it), then `DELETE trackfile/bulk` through the gate (findDelete). Only for a find; an
    /// artist the owner had is never touched. True: settled (nothing left, or not provably Magpie's to delete).
    func removeLateImport(_ id: RequestID, albumId: Int, artistId: Int) async -> Bool {
        guard let r = request(id), r.isFind else { return true }
        if let since = r.drainSince, now().timeIntervalSince(since) >= Self.stoppedFindArtistLimit { return true }   // bounded
        guard let setup = await keepSetup() else { return true }
        switch await proveLetGo(r, artistId: artistId, albumId: albumId, setup: setup, artistPath: nil) {
        case .unknown: return false
        case .no: return true
        case .yes(let proof):
            guard !proof.albumFiles.isEmpty else { return true }
            do {
                try await persist()
                _ = try await gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: proof.albumFiles.map(\.id)))
                Log.logger("requests").info("an album imported after the stop was removed")
                try? await library.startScan()
            } catch let refusal as WriteGateError where refusal != .disabled && refusal != .logUnavailable && refusal != .unconfirmed {
                Log.logger("requests").error("late import not removed: the gate refused")
                return true
            } catch {
                Log.logger("requests").error("late import not removed: \(Log.category(of: error), privacy: .public)")
            }
            return false   // read again on the next pass
        }
    }

    // MARK: - A find no request is on (round 18)

    /// Round 18 (owner, 2026-11-05: finds couldn't be removed once downloaded): a song in the Finds folder that no request
    /// is on any more (its ready request was removed from Activity, which forgot it) gets its request back, so Not for me
    /// can go through it with every check of `proveLetGo` still ahead. Matched strictly, from the ledger and fresh reads:
    /// exactly one artist Magpie created, tagged a find inside the Finds root, of the song's artist MBID (else its name); exactly one of
    /// its albums of the song's album title with Magpie's ledger entry (same release group, not monitored before Magpie).
    /// A ready find already on that album is returned instead. Writes nothing to Lidarr; nil when there is no one match.
    public func recoverFind(songId: String, title: String, artist artistName: String, artistMBID songArtist: MBID? = nil,
                            album albumTitle: String) async -> RequestID? {
        guard !stopped, await load(), let setup = await keepSetup() else { return nil }
        if let r = list.last(where: { $0.songId == songId && $0.state == .ready && $0.isFind }) { return r.id }
        let entries: [LedgerEntry], artists: [LidarrArtist], roots: [String]
        do {
            entries = try await ledger.entries
            artists = try await lidarr.artists()
            roots = try await lidarr.rootFolders().map(\.path)
        } catch {
            return nil
        }
        lastLidarrContact = now()
        let finds = Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots)
        let named = artists.filter { a in
            (songArtist.map { a.foreignArtistId == $0 } ?? (Self.looseKey(a.artistName) == Self.looseKey(artistName)))
                && a.tags.contains(setup.findTagId)
                && a.path.map(finds.isInside) == true && entries.contains { $0.created(a) }
                && !entries.contains { $0.lidarrArtistId == a.id && $0.isKeptOrKeeping }
        }
        guard named.count == 1, let artist = named.first, let artistMBID = artist.foreignArtistId else { return nil }
        guard let albums = try? await lidarr.albums(artistId: artist.id) else { return nil }
        let matches = albums.filter { a in
            Self.looseKey(a.title) == Self.looseKey(albumTitle)
                && entries.contains { $0.albumId == a.id && $0.rgMbid == a.foreignAlbumId && !$0.wasMonitoredBefore }
        }
        guard matches.count == 1, let album = matches.first, let rg = album.foreignAlbumId else { return nil }
        if let r = list.last(where: { $0.albumId == album.id && $0.lidarrArtistId == artist.id && $0.state == .ready && $0.isFind }) {
            return r.id
        }
        // Anything else on this album or artist under way: not now (Not for me would refuse it anyway).
        guard !list.contains(where: { $0.lidarrArtistId == artist.id && ($0.isActive || $0.keep != nil || $0.notForMe != nil) })
        else { return nil }
        guard let tracks = try? await lidarr.tracks(albumId: album.id) else { return nil }
        let key = SongIdentity.titleKey(title)
        // Only names the request: Not for me proves the album's files itself.
        let byTitle = tracks.filter { $0.title.map(SongIdentity.titleKey) == key }
        guard let recording = (byTitle.first(where: \.hasFile) ?? byTitle.first ?? tracks.first(where: \.hasFile) ?? tracks.first)?
            .foreignRecordingId.flatMap(MBID.init) else { return nil }
        let entry = entries.first { $0.albumId == album.id && $0.rgMbid == rg }
        let id = entry?.requestId.flatMap(UUID.init(uuidString:)).map(RequestID.init)
            .flatMap { id in list.contains { $0.id == id } ? nil : id } ?? RequestID()
        var r = MagpieRequest(id: id, recording: ExternalRecording(recordingMBID: recording, artistMBID: artistMBID,
                                                                   title: title, artist: artistName,
                                                                   releaseTitle: album.title, source: .lidarr),
                              tier: .standard, createdAt: now())
        r.state = .ready
        r.plan = Plan(recordingMBID: recording, releaseGroupMBID: rg, artistMBID: artistMBID, lidarrArtistId: artist.id,
                      mode: .finds)
        r.lidarrArtistId = artist.id
        r.albumId = album.id
        r.albumTitle = album.title
        r.songId = songId
        r.trimDone = true   // what is there stays until Not for me
        return await adopt(r) ? id : nil
    }

    /// Names compared loosely: case, diacritics, width, and runs of spaces.
    static func looseKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Stop looking (round 16)

    /// How long a stopped find's clean-up keeps trying to remove its artist (a refresh still running, Lidarr away).
    static let stoppedFindArtistLimit: TimeInterval = 3600

    /// Round 16 (owner, 2026-11-05): Stop looking for (or the failure of) the last find of an artist Magpie added into
    /// the Finds folder removes the artist from Lidarr, as Not for me does once nothing is left of it, on the same
    /// proof (`mayRemoveArtist`): Magpie created it (ledger), nothing of it is kept or wanted by another request, a
    /// fresh GET shows it tagged `magpie-find` strictly inside the Finds root (so never an artist of the main library),
    /// Lidarr records no track file and no other monitored album for it, its folder holds no file on disk, and no
    /// refresh is running. Files are never deleted (`deleteFiles=false`). An artist the owner already had is never a
    /// candidate (not a find, G6). True: settled (removed, or it stays); false: not yet, a later pass looks again.
    func removeStoppedFindArtist(_ id: RequestID) async -> Bool {
        guard let r = request(id), r.isFind, r.notForMe == nil, let artistId = r.lidarrArtistId else { return true }
        switch r.state {
        case .cancelled, .failed: break
        default: return true
        }
        guard let setup = await keepSetup() else { return true }   // Finds isn't set up: nothing to prove it against
        let started = r.artistRemovalSince ?? now()
        if r.artistRemovalSince == nil { await mutate(id) { $0.artistRemovalSince = started } }
        guard now().timeIntervalSince(started) < Self.stoppedFindArtistLimit else {
            Log.logger("requests").error("Stop looking: the artist stays (it couldn't be proven empty in time)")
            return true
        }
        guard !artistBusy(artistId) else { return false }
        hold(artistId)
        defer { release(artistId) }
        let artist: LidarrArtist
        do { artist = try await lidarr.artist(id: artistId) } catch LidarrError.http(status: 404) {
            return true   // gone already
        } catch {
            return false
        }
        lastLidarrContact = now()
        guard let path = artist.path else { return true }
        let p = NotForMeProgress(phase: .removingArtist, startedAt: started, artistId: artistId, albumId: r.albumId ?? -1,
                                 artistPath: path, findsRoot: setup.findsRoot, mainRoot: setup.mainRoot,
                                 findTagId: setup.findTagId, permanentConfirmed: false, writeBudget: 1)
        switch await mayRemoveArtist(r, p) {
        case .unknown: return false
        case .no: return true
        case .yes: break
        }
        do { try await persist() } catch { return false }
        // R23 (D191–D194; fix round 1 M3): only once nothing before the artist's DELETE can stop it.
        await cleanSlateBeforeRemoving(artistId: artistId, for: id)
        do {
            _ = try await gate.send("DELETE", "artist/\(artistId)?deleteFiles=false&addImportListExclusion=false",
                                    body: nil)
            return true
        } catch let error as WriteGateError {
            switch error {
            case .disabled, .logUnavailable, .unconfirmed: return false   // changes off or unchecked: later, bounded
            case .forbidden, .invalidRequest:
                Log.logger("requests").error("Stop looking: the artist stays (removing it was refused)")
                return true
            }
        } catch where Self.isDefinitiveRejection(error) {
            Log.logger("requests").error("Stop looking: the artist stays (removing it was refused)")
            return true
        } catch {
            return false   // no answer: a fresh GET says whether it went (404: gone)
        }
    }

    private func mayRemoveArtist(_ r: MagpieRequest, _ p: NotForMeProgress) async -> Proven<Void> {
        let entries: [LedgerEntry]
        do {
            entries = try await ledger.entries.filter { $0.lidarrArtistId == p.artistId }
            guard entries.contains(where: \.createdArtist), !entries.contains(where: \.isKeptOrKeeping) else { return .no }
        } catch {
            return .unknown
        }
        let others = list.contains {
            $0.id != r.id && $0.lidarrArtistId == p.artistId && !($0.albumId == p.albumId && $0.state == .ready)
                && ($0.isActive || $0.state == .ready || $0.state == .kept || $0.keep != nil || $0.notForMe != nil
                    || $0.keepNeedsAttention || $0.notForMeNeedsAttention || $0.cleanupPending)
        }
        guard !others else { return .no }
        let setup = Self.setup(p)
        do {
            let artist = try await lidarr.artist(id: p.artistId)
            let roots = try await lidarr.rootFolders().map(\.path)
            lastLidarrContact = now()
            guard entries.contains(where: { $0.created(artist) }),   // the same artist, not a reused id
                  Self.mayKeep(artist, request: r, setup: setup, roots: roots), let path = artist.path,
                  Self.sameBytes(path, p.artistPath) else { return .no }
            guard try await lidarr.trackFiles(artistId: p.artistId).isEmpty,
                  !(try await lidarr.albums(artistId: p.artistId)).contains(where: { $0.id != p.albumId && $0.monitored })
            else { return .no }
            let empty = try await folderIsEmpty(path, guard: Self.artistGuard(path, setup: setup, roots: roots))
            guard empty else { return .no }
            // A refresh still running for the artist (the add's own RefreshArtist can outlast a quick download when
            // the metadata server is slow) re-creates it after the DELETE ("Adding missing parent artist"): a find
            // Magpie no longer tracks would be left in Lidarr. Wait for it to finish.
            // Round 20: nor while a search for one of its albums runs, or Lidarr's queue holds a download of it (a grab
            // after a stop would land in an artist that is gone).
            let albumIds = Set(try await lidarr.albums(artistId: p.artistId).map(\.id))
            if try await lidarr.commands().contains(where: { c in
                !Self.isFinished(c) && (Self.refreshes(c, artistId: p.artistId)
                    || (c.name.lowercased() == "albumsearch" && (c.albumIds.isEmpty || !albumIds.isDisjoint(with: c.albumIds))))
            }) {
                return .unknown
            }
            if try await lidarr.queueDetails(albumIds: Array(albumIds)).contains(where: { $0.artistId == p.artistId || $0.albumId.map(albumIds.contains) == true }) {
                return .unknown
            }
            return .yes(())
        } catch LidarrError.http(status: 404) {
            return .no
        } catch {
            return .unknown
        }
    }

    /// A Lidarr refresh that may touch the artist: `RefreshArtist` of it (or of every artist: no ids), or any
    /// `RefreshAlbum` (its body names an album, not the artist).
    static func refreshes(_ c: CommandStatus, artistId: Int) -> Bool {
        switch c.name.lowercased() {
        case "refreshartist": c.artistIds.isEmpty || c.artistIds.contains(artistId)
        case "refreshalbum": true
        default: false
        }
    }

    /// No file anywhere under the artist folder on Lidarr's filesystem (a missing folder is empty). Anything listed
    /// outside the folder (Lidarr lists the closest existing folder for a missing one), or more than
    /// `artistFolderWalkLimit` folders, counts as not empty.
    private func folderIsEmpty(_ path: String, guard folder: PathGuard) async throws -> Bool {
        guard try await lidarr.filesystemExists(path: path) else { return true }
        var pending = [path], seen = 0
        while let dir = pending.popLast() {
            seen += 1
            guard seen <= Self.artistFolderWalkLimit else { return false }
            let (dirs, files) = try await lidarr.contents(in: dir)
            guard files.isEmpty, dirs.allSatisfy(folder.isInside) else { return false }
            pending += dirs
        }
        return true
    }

    /// Strictly inside the artist's folder, and inside no other root folder or the main root; case-sensitive.
    static func artistGuard(_ artistPath: String, setup: KeepSetup, roots: [String]) -> PathGuard {
        PathGuard(findsRoot: artistPath, otherRoots: roots.filter { !sameBytes($0, setup.findsRoot) } + [setup.mainRoot],
                  caseInsensitive: false)
    }
}
