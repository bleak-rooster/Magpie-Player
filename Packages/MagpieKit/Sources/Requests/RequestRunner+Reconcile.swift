import Foundation
import LidarrKit
import MagpieCore

/// Y5 (plan item 9): the pass derives what it can from the servers instead of trusting saved steps.
///
/// - **Fact folding** (§3): before a request's step, Lidarr's facts become machine events. A track file for the
///   request's *recording* (I8: per recording, so one imported song of a partial album doesn't count for another)
///   → `.imported`. The album gone after it was listed once and after the add's RefreshArtist completed (I12/6), or the
///   artist gone → `.error(.stoppedInLidarr)`. Navidrome's listing stays the Ready truth (`checkLibrary`).
/// - **Adopted finds** (C2): a find someone moved into the main root by hand (untagged there, no Keep, nothing kept)
///   is verified like a Keep and committed, with the lossless watch but never the automatic MP3 delete.
/// - **Migration** (§9, flag `y5`, set last so a crash re-runs it; every step idempotent): legacy locks (I3) and a
///   watch for older kept finds (no automatic delete, C2).
extension RequestRunner {
    static let factInterval: TimeInterval = 60
    static let adoptedInterval: TimeInterval = 300

    // MARK: - Fact folding

    func foldFacts() async {
        let t = now()
        for r in list where r.isActive && !requestBusy(r.id) {
            guard let albumId = r.albumId, let artistId = r.lidarrArtistId else { continue }
            switch r.state {
            case .searching, .downloading, .waiting: break
            default: continue
            }
            if let last = factChecks[r.id], (0..<Self.factInterval).contains(t.timeIntervalSince(last)) { continue }
            factChecks[r.id] = t
            if let recording = r.recording.recordingMBID ?? r.plan?.recordingMBID,
               let tracks = try? await lidarr.tracks(albumId: albumId),
               tracks.contains(where: { $0.foreignRecordingId == recording.rawValue && $0.hasFile }) {
                lastLidarrContact = now()
                await apply(r.id, .imported)
                continue
            }
            // I12/6: only once the album was listed and (for an add) Lidarr's refresh of the artist completed.
            guard r.albumSeen == true, !r.addSent || r.addRefreshDone == true else { continue }
            do {
                let albums = try await lidarr.albums(artistId: artistId)
                lastLidarrContact = now()
                if !albums.contains(where: { $0.id == albumId }) { await apply(r.id, .error(.stoppedInLidarr)) }
            } catch LidarrError.http(status: 404) {
                await apply(r.id, .error(.stoppedInLidarr))
            } catch {
                continue
            }
        }
    }

    // MARK: - Adopted finds (C2)

    func followAdopted() async {
        guard let setup = await keepSetup() else { return }
        let t = now()
        for r in list where r.state == .ready && r.isFind && r.keep == nil && !r.keepNeedsAttention {
            guard let artistId = r.lidarrArtistId, !artistBusy(artistId) else { continue }
            if let last = adoptedChecks[r.id], (0..<Self.adoptedInterval).contains(t.timeIntervalSince(last)) { continue }
            adoptedChecks[r.id] = t
            await adopt(r.id, artistId: artistId, setup: setup)
        }
    }

    /// Verify, then commit (never straight to commit, C2): Magpie's own artist, untagged, strictly inside the main
    /// root, nothing kept or keeping, and every track file on disk inside its folder.
    private func adopt(_ id: RequestID, artistId: Int, setup: KeepSetup) async {
        guard let entries = try? await ledger.entries.filter({ $0.lidarrArtistId == artistId }),
              !entries.contains(where: \.isKeptOrKeeping),
              let artist = try? await lidarr.artist(id: artistId), entries.contains(where: { $0.created(artist) }),
              !artist.tags.contains(setup.findTagId), let path = artist.path,
              let roots = try? await lidarr.rootFolders().map(\.path) else { return }
        let main = PathGuard(findsRoot: setup.mainRoot, otherRoots: roots.filter { !Self.sameBytes($0, setup.mainRoot) },
                             caseInsensitive: false)
        guard main.isInside(path), let files = try? await lidarr.trackFiles(artistId: artistId), !files.isEmpty,
              files.allSatisfy({ main.isInside($0.path) && WriteConfinement.relative($0.path, under: path) != nil }) else { return }
        for (folder, wanted) in Dictionary(grouping: files.map(\.path), by: { ($0 as NSString).deletingLastPathComponent }) {
            guard let present = try? await lidarr.files(in: folder), wanted.allSatisfy(Set(present).contains) else { return }
        }
        lastLidarrContact = now()
        Log.logger("requests").error("a find was moved into the library outside Magpie; adopted as kept")
        keepingArtists.insert(artistId)
        defer { keepingArtists.remove(artistId) }
        guard await commitKept(artistId) else { return }
        for other in list where other.lidarrArtistId == artistId && other.state == .ready && other.keep == nil {
            await apply(other.id, .keep)
            await mutate(other.id) {
                $0.relinkPending = true
                $0.movedAt = self.now()
                $0.movedTo = path
            }
            await relink(other.id)
        }
        await startLosslessWatch(id, artistId: artistId, autoDelete: false)
    }

    // MARK: - Migration (§9)

    func migrateY5() async {
        guard persistedState.migrated["y5"] == nil else { return }
        let entries: [LedgerEntry]
        do { entries = try await ledger.entries } catch { return }   // later: never migrate half-blind
        // 1. I3: a legacy lock (a Keep that crashed after saying kept, before its move): cleared only when certain.
        let lockedArtists = Set(entries.filter { $0.createdArtist && $0.keptAt != nil && $0.keepIntentAt == nil }
            .map(\.lidarrArtistId))
        if let setup = await keepSetup() {
            for artistId in lockedArtists { await clearLegacyLock(artistId, setup: setup) }
        }
        // 2. Legacy kept-in-place finds stay as they are (I4). 3. Older kept, moved finds: the watch, no auto delete.
        for r in list where r.state == .kept && !r.keptInPlace && r.movedTo != nil && r.lossless == nil {
            guard let artistId = r.lidarrArtistId else { continue }
            await startLosslessWatch(r.id, artistId: artistId, autoDelete: false)
        }
        markMigrated("y5")
    }

    /// I3: only with a request of the artist that never finished keeping (no needs attention), the artist still
    /// tagged, and its path exactly where the request's Keep started from (or, with no Keep saved at all, the request
    /// still ready, never moved, and the artist strictly inside the Finds root). Logged to the device log.
    private func clearLegacyLock(_ artistId: Int, setup: KeepSetup) async {
        guard let r = list.first(where: { $0.lidarrArtistId == artistId && $0.isFind }), !r.keepNeedsAttention,
              r.state != .kept, r.movedTo == nil, !r.keptInPlace,
              let artist = try? await lidarr.artist(id: artistId), artist.tags.contains(setup.findTagId),
              let path = artist.path, let roots = try? await lidarr.rootFolders().map(\.path) else { return }
        if let from = r.keep?.fromPath {
            guard Self.sameBytes(path, from) else { return }
        } else {
            guard r.state == .ready,
                  Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots).isInside(path) else { return }
        }
        do {
            try await ledger.update(artistId: artistId) { $0.keptAt = nil }
            await mutate(r.id) { $0.keep = nil }
            Log.logger("requests").error("cleared a Keep lock left by a crash (the artist never moved)")
        } catch {
            Log.logger("requests").error("legacy Keep lock not cleared: ledger unavailable")
        }
    }
}
