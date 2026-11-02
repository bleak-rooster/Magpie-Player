import Foundation
import LidarrKit
import MagpieCore
import MatchIndex

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

    // MARK: - Matching without MusicBrainz tags (item 9.2)

    static let fallbackInterval: TimeInterval = 60

    /// An imported request the library doesn't list by MBID (Soulseek files often carry no tags): its song by
    /// Lidarr's track file path, else by title + artist + duration (±3 s), only in the artist's folder, only when
    /// exactly one song fits. Never by name alone.
    func matchWithoutTags(_ id: RequestID) async {
        let t = now()
        guard let r = request(id), let albumId = r.albumId, let artistId = r.lidarrArtistId else { return }
        if let last = fallbackChecks[id], (0..<Self.fallbackInterval).contains(t.timeIntervalSince(last)) { return }
        fallbackChecks[id] = t
        guard let folder = try? await lidarr.artist(id: artistId).path else { return }
        var filePath: String?
        if let recording = r.recording.recordingMBID ?? r.plan?.recordingMBID,
           let track = try? await lidarr.tracks(albumId: albumId).first(where: { $0.foreignRecordingId == recording.rawValue && $0.hasFile }),
           let file = try? await lidarr.trackFile(id: track.trackFileId ?? 0) {
            filePath = file.path
        }
        guard let candidates = await library.songsTitled(r.recording.title, folder),
              let songId = Self.fallbackMatch(r.recording, filePath: filePath, folder: folder, candidates: candidates) else { return }
        await apply(id, .visibleInLibrary(songId: songId))
    }

    /// The pure rule (tested on its own): path first, then title + artist + duration within 3 s, inside `folder`.
    public static func fallbackMatch(_ recording: ExternalRecording, filePath: String?, folder: String,
                                     candidates: [(song: Song, lidarrPath: String)]) -> String? {
        let inside = candidates.filter { WriteConfinement.relative($0.lidarrPath, under: folder) != nil }
        if let filePath {
            let byPath = inside.filter { WriteConfinement.looselySame($0.lidarrPath, filePath) }
            if byPath.count == 1 { return byPath[0].song.id }
        }
        guard let duration = recording.duration else { return nil }
        let title = Normalize.name(recording.title), artist = Normalize.name(recording.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let fits = inside.filter {
            Normalize.name($0.song.title) == title && Normalize.name($0.song.artist) == artist
                && abs($0.song.duration - duration) <= 3
        }
        return fits.count == 1 ? fits[0].song.id : nil
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
        guard tryAcquireArtist(artistId) else { return }   // fix I5
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

    // MARK: - Orphan Keep intents (fix I2)

    static let orphanInterval: TimeInterval = 60

    /// A Keep intent no request follows (the app died after the ledger said "keeping", before the request saved its
    /// Keep; or a clear that failed). The request's Keep is saved before any PUT, so with none saved no move was sent:
    /// - the artist still a tagged find inside the Finds folder: the intent (and its file record) is cleared, with a
    ///   change-log note;
    /// - anything else: never cleared; the artist's finds say "needs a look".
    func recoverOrphanIntents() async {
        let t = now()
        if let last = orphanChecks, (0..<Self.orphanInterval).contains(t.timeIntervalSince(last)) { return }
        orphanChecks = t
        guard let entries = try? await ledger.entries else { return }
        let artists = Set(entries.filter { $0.keepIntentAt != nil }.map(\.lidarrArtistId))
        guard !artists.isEmpty, let setup = await keepSetup() else { return }
        for artistId in artists.sorted() where !list.contains(where: { $0.keep?.artistId == artistId }) {
            guard tryAcquireArtist(artistId) else { continue }
            defer { keepingArtists.remove(artistId) }
            guard let artist = try? await lidarr.artist(id: artistId), let roots = try? await lidarr.rootFolders().map(\.path)
            else { continue }
            let mine = entries.filter { $0.lidarrArtistId == artistId }
            let stillFind = mine.contains(where: { $0.created(artist) }) && artist.tags.contains(setup.findTagId)
                && artist.path.map(Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots).isInside) == true
            if stillFind {
                guard await clearIntent(artistId) else { continue }
                await gate.note("Cleared an Add to your library that never reached Lidarr (artist \(artistId)).")
                Log.logger("requests").error("cleared an orphan Keep intent; the artist never moved")
            } else {
                for r in list where r.lidarrArtistId == artistId && r.isFind && !r.keepNeedsAttention {
                    await mutate(r.id) { $0.keepNeedsAttention = true }
                }
                Log.logger("requests").error("an orphan Keep intent on an artist that isn't a find any more: needs a look")
            }
        }
    }

    // MARK: - Migration (§9)

    /// Fix I6: the flag is set only once every step finished or was proven not to apply; a step that couldn't (Lidarr
    /// or the ledger unreadable, no setup yet) runs again on a later pass. Every step is idempotent.
    func migrateY5() async {
        guard persistedState.migrated["y5"] == nil else { return }
        let entries: [LedgerEntry]
        do { entries = try await ledger.entries } catch { return }   // later: never migrate half-blind
        var complete = true
        // 1. I3: a legacy lock (a Keep that crashed after saying kept, before its move): cleared only when certain.
        let lockedArtists = Set(entries.filter { $0.createdArtist && $0.keptAt != nil && $0.keepIntentAt == nil }
            .map(\.lidarrArtistId))
        if !lockedArtists.isEmpty {
            if let setup = await keepSetup() {
                for artistId in lockedArtists.sorted() where await !clearLegacyLock(artistId, setup: setup) { complete = false }
            } else {
                complete = false
            }
        }
        // 2. Legacy kept-in-place finds stay as they are (I4). 3. Older kept, moved finds: the watch, no auto delete,
        //    for an artist Lidarr still lists (read now: an unreadable Lidarr leaves the step for later).
        for r in list where r.state == .kept && !r.keptInPlace && r.movedTo != nil && r.lossless == nil {
            guard let artistId = r.lidarrArtistId else { continue }
            do {
                _ = try await lidarr.artist(id: artistId)
            } catch LidarrError.http(status: 404) {
                continue   // gone from Lidarr: nothing to watch
            } catch {
                complete = false
                continue
            }
            if await !startLosslessWatch(r.id, artistId: artistId, autoDelete: false) { complete = false }
        }
        if complete { markMigrated("y5") }
    }

    /// I3: only with a request of the artist that never finished keeping (no needs attention), the artist still
    /// tagged, and its path exactly where the request's Keep started from (or, with no Keep saved at all, the request
    /// still ready, never moved, and the artist strictly inside the Finds root). Logged to the change log. True: done or
    /// proven not to apply; false: couldn't tell now.
    private func clearLegacyLock(_ artistId: Int, setup: KeepSetup) async -> Bool {
        guard let r = list.first(where: { $0.lidarrArtistId == artistId && $0.isFind }), !r.keepNeedsAttention,
              r.state != .kept, r.movedTo == nil, !r.keptInPlace else { return true }
        let artist: LidarrArtist, roots: [String]
        do {
            artist = try await lidarr.artist(id: artistId)
            roots = try await lidarr.rootFolders().map(\.path)
        } catch LidarrError.http(status: 404) {
            return true
        } catch {
            return false
        }
        guard artist.tags.contains(setup.findTagId), let path = artist.path else { return true }
        if let from = r.keep?.fromPath {
            guard Self.sameBytes(path, from) else { return true }
        } else {
            guard r.state == .ready,
                  Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots).isInside(path) else { return true }
        }
        do {
            try await ledger.update(artistId: artistId) { $0.keptAt = nil }
            await mutate(r.id) { $0.keep = nil }
            await gate.note("Cleared a Keep lock left by a crash before this version (artist \(artistId) never moved).")
            Log.logger("requests").error("cleared a Keep lock left by a crash (the artist never moved)")
            return true
        } catch {
            Log.logger("requests").error("legacy Keep lock not cleared: ledger unavailable")
            return false
        }
    }
}
