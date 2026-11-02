import Foundation
import LidarrKit
import MagpieCore

/// Y5 (plan item 8, owner answer 3): after Add to your library, the find goes lossless.
///
/// - **Search:** a `RefreshArtist` (Lidarr 3.2 leaves the moved files' records stale) and an `AlbumSearch` for the
///   find's albums right after the commit, then a search at most once a day for 30 days (the spike showed Lidarr's own
///   cutoff search skips an MP3 outside the Magpie Lossless profile, so these searches matter).
/// - **Watch:** the albums' track files, every `losslessCheckInterval` (daily after the MP3 is gone). When every
///   track of the find is lossless (Lidarr's upgrade replaced the MP3), the song is looked up again (relink, with one
///   coalesced, targeted scan of the artist folder) and the watch ends. It also ends 30 days after it started (I5).
/// - **MP3 rule:** only for a Keep the owner tapped under Y5 (`autoDelete`, C2): at `deadline` (commit + 7 days, Lidarr's
///   time) the recorded MP3 files that are still there are removed; "Remove the MP3 now" does the same at any time,
///   only where a file record exists (fix I8). Removal re-maps first (C3): a targeted `RefreshArtist` (fix I5: the tick
///   sends it and checks it on a later pass; only the owner's tap waits for it, renewing its lease), then each recorded
///   file is found again at `<artist folder>/<relativePath>` with its track and size; anything else is "needs
///   attention". The gate's keptLossyDelete rule checks it all again. `removedAt` is set only after a read shows the
///   files gone. A monitored album Lidarr unmonitored after the delete is monitored again (I6).
extension RequestRunner {
    public static let mp3Grace: TimeInterval = 7 * 24 * 3600
    public static let losslessSearchInterval: TimeInterval = 24 * 3600
    public static let losslessWatchLimit: TimeInterval = 30 * 24 * 3600
    public static let losslessCheckInterval: TimeInterval = 300
    /// How long the owner's "Remove the MP3 now" waits inline for its RefreshArtist (renewing its lease meanwhile).
    public static let refreshWait: TimeInterval = 180
    /// A refresh not completed this long after it was sent is sent again.
    public static let refreshGiveUp: TimeInterval = 600

    public enum MP3Outcome: Sendable, Equatable {
        /// Gone (a read showed it).
        case removed
        /// There was no MP3 left to remove (lossless already, or gone).
        case nothingToRemove
        /// Lidarr is busy with the artist or didn't finish its refresh: tried again on a later pass.
        case later
    }

    public enum MP3Error: Error, Equatable {
        /// Not a kept find with a recorded MP3 (nothing is offered).
        case notOffered
        case changesOff
        /// Lidarr couldn't be read or written right now. Nothing was removed.
        case unavailable
        /// The MP3 couldn't be matched safely; nothing was removed ("Couldn't remove the MP3").
        case needsAttention
    }

    /// The deadline's grace (tests and the dev-stack IT shorten it).
    var grace: TimeInterval { mp3GraceOverride ?? Self.mp3Grace }

    // MARK: - Start

    /// The watch for a kept find (pure: saved by the caller in the same change that says kept, fix I3). Nil: nothing to
    /// watch. `hasRecord`: the ledger holds the find's file record, so "Remove the MP3 now" is offered (fix I8).
    func makeWatch(_ r: MagpieRequest, entries: [LedgerEntry], autoDelete: Bool) -> LosslessWatch? {
        let records = entries.flatMap { $0.findFiles ?? [] }
        var albums = Set(records.map(\.albumId))
        if let album = r.albumId { albums.insert(album) }
        guard !albums.isEmpty else { return nil }
        let start = serverNow()
        var w = LosslessWatch(albumIds: albums.sorted(), startedAt: start, autoDelete: autoDelete,
                              deadline: autoDelete ? start.addingTimeInterval(grace) : nil)
        w.hasRecord = !records.isEmpty
        return w
    }

    /// An adopted or older kept find (`autoDelete: false`): the watch is saved first, then its first commands go.
    /// True: done (or nothing to watch); false: the ledger couldn't be read (tried again later).
    @discardableResult
    func startLosslessWatch(_ id: RequestID, artistId: Int, autoDelete: Bool) async -> Bool {
        guard let r = request(id) else { return true }
        guard r.lossless == nil else { return true }
        guard let entries = try? await ledger.entries.filter({ $0.lidarrArtistId == artistId }) else { return false }
        guard let watch = makeWatch(r, entries: entries, autoDelete: autoDelete) else { return true }
        await mutate(id) { $0.lossless = watch }
        await kickLosslessWatch(id, artistId: artistId)
        return true
    }

    /// The watch's first commands (after it is saved, M6): a rescan, then the first search. Sent again by a later pass
    /// if a crash came first (no search yet).
    func kickLosslessWatch(_ id: RequestID, artistId: Int) async {
        guard let w = request(id)?.lossless, w.isActive, w.searches == 0 else { return }
        if (try? await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: artistId))) != nil {
            lastLidarrContact = now()
        }
        await searchLossless(id)
    }

    private func searchLossless(_ id: RequestID) async {
        guard let w = request(id)?.lossless, w.isActive, w.losslessAt == nil else { return }
        do {
            try await persist()
            _ = try await gate.send("POST", "command", body: LosslessSearchBody(name: "AlbumSearch", albumIds: w.albumIds))
            await mutate(id) {
                $0.lossless?.searches += 1
                $0.lossless?.lastSearchAt = self.serverNow()
            }
        } catch {
            Log.logger("requests").error("lossless search postponed: \(Log.category(of: error), privacy: .public)")
        }
    }

    struct LosslessSearchBody: Encodable, Sendable {
        var name: String
        var albumIds: [Int]
    }

    struct RefreshBody: Encodable, Sendable {
        var name: String
        var artistId: Int
    }

    struct MonitorAlbumsBody: Encodable, Sendable {
        var albumIds: [Int]
        var monitored: Bool
    }

    // MARK: - Follow (tick)

    /// Tests and the dev-stack IT: the next pass checks this watch now (it is throttled otherwise).
    func forceLosslessCheck(_ id: RequestID) async { await mutate(id) { $0.lossless?.lastCheckAt = nil } }

    /// `tick()`: every active watch, at most every `losslessCheckInterval` (daily once the MP3 is gone).
    func followLossless() async {
        for r in list {
            guard let w = r.lossless, w.isActive, let artistId = r.lidarrArtistId, !artistBusy(artistId) else { continue }
            if w.searches == 0 { await kickLosslessWatch(r.id, artistId: artistId) }   // fix I3: a crash came first
            let t = serverNow()
            let pendingRefresh = w.refreshCommandId != nil
            let every = w.removedAt == nil ? Self.losslessCheckInterval : Self.losslessSearchInterval
            if !pendingRefresh, let last = w.lastCheckAt, (0..<every).contains(t.timeIntervalSince(last)) { continue }
            await mutate(r.id) { $0.lossless?.lastCheckAt = t }
            if t.timeIntervalSince(w.startedAt) >= Self.losslessWatchLimit {
                await mutate(r.id) { $0.lossless?.doneAt = t }
                continue
            }
            switch await findIsLossless(r.id, artistId: artistId) {
            case true?:
                await landedLossless(r.id, artistId: artistId)
                continue
            case nil:
                continue   // Lidarr can't be read now
            case false?:
                break
            }
            if w.lastSearchAt.map({ t.timeIntervalSince($0) >= Self.losslessSearchInterval }) ?? true {
                await searchLossless(r.id)
            }
            if w.autoDelete, w.removedAt == nil, let deadline = w.deadline, t >= deadline, !r.mp3NeedsAttention {
                _ = try? await removeMP3(r.id, artistId: artistId, inline: false)
            }
        }
    }

    /// Every track of the find's albums that has a file has a lossless one. Nil: can't tell now.
    func findIsLossless(_ id: RequestID, artistId: Int) async -> Bool? {
        guard let w = request(id)?.lossless else { return nil }
        let recorded = Set(((try? await ledger.entries) ?? []).filter { $0.lidarrArtistId == artistId }
            .flatMap { $0.findFiles ?? [] }.compactMap(\.foreignTrackId))
        do {
            var any = false
            for album in w.albumIds {
                let files = Dictionary(uniqueKeysWithValues: try await lidarr.trackFiles(albumId: album).map { ($0.id, $0) })
                let tracks = try await lidarr.tracks(albumId: album).filter {
                    recorded.isEmpty || $0.foreignTrackId.map(recorded.contains) == true
                }
                for track in tracks {
                    guard track.hasFile, let file = files[track.trackFileId ?? 0] else {
                        if !recorded.isEmpty { return false }   // a recorded track without a file: not there yet
                        continue
                    }
                    any = true
                    guard Self.isLossless(file.quality) else { return false }
                }
            }
            lastLidarrContact = now()
            return any
        } catch {
            return nil
        }
    }

    static func isLossless(_ quality: String?) -> Bool {
        guard let q = quality?.uppercased() else { return false }
        return q.hasPrefix("FLAC") || q.hasPrefix("ALAC") || q == "WAV" || q == "APE" || q == "WAVPACK"
    }

    private func landedLossless(_ id: RequestID, artistId: Int) async {
        let t = serverNow()
        let path = try? await lidarr.artist(id: artistId).path
        await mutate(id) {
            $0.lossless?.losslessAt = t
            $0.lossless?.doneAt = t
            $0.lossless?.refreshCommandId = nil
            $0.mp3NeedsAttention = false
            if let path {
                $0.relinkPending = true
                $0.movedTo = path
                $0.movedAt = self.now()
            }
        }
        if let path { requestFolderScan(path) }   // fix I7: one coalesced, targeted scan
        await relink(id)
    }

    // MARK: - Remove the MP3

    /// Whether "Remove the MP3 now" is offered for this request: a kept find whose MP3 Magpie recorded (fix I8: only
    /// where a file record exists), not yet gone.
    public func mp3Removable(_ id: RequestID) async -> Bool {
        guard let r = request(id), r.state == .kept, let w = r.lossless, w.isActive, w.removedAt == nil,
              w.losslessAt == nil, w.hasRecord == true, !r.mp3NeedsAttention, let artistId = r.lidarrArtistId,
              let entries = try? await ledger.entries.filter({ $0.lidarrArtistId == artistId }) else { return false }
        return WriteConfinement.confirmedKept(artistId, in: entries) && entries.contains { !($0.findFiles ?? []).isEmpty }
    }

    /// I7: removing it can't be undone (Lidarr's recycle bin is unset). Nil: can't tell.
    public func mp3RemovalIsPermanent() async -> Bool? {
        do { return try await lidarr.recycleBin() == nil } catch { return nil }
    }

    /// "Remove the MP3 now" (confirmed by the owner): waits for Lidarr's refresh, renewing its lease.
    public func removeMP3Now(_ id: RequestID) async throws -> MP3Outcome {
        guard !stopped, await load(), let artistId = request(id)?.lidarrArtistId else { throw MP3Error.notOffered }
        guard await mp3Removable(id) else { throw MP3Error.notOffered }
        guard await gate.enabled else { throw MP3Error.changesOff }
        return try await removeMP3(id, artistId: artistId, inline: true)
    }

    /// One removal at a time per artist (the artist lease, taken atomically), so the deadline and a tap never delete
    /// twice. `inline` (the owner's tap) waits for the refresh; the tick sends it and comes back on a later pass.
    func removeMP3(_ id: RequestID, artistId: Int, inline: Bool) async throws -> MP3Outcome {
        guard tryAcquireArtist(artistId) else { return .later }
        defer { keepingArtists.remove(artistId) }
        guard let w = request(id)?.lossless, w.removedAt == nil else { return .nothingToRemove }
        let entries: [LedgerEntry]
        do { entries = try await ledger.entries.filter { $0.lidarrArtistId == artistId } } catch { throw MP3Error.unavailable }
        var finds: [FindFile] = []
        for f in entries.flatMap({ $0.findFiles ?? [] }) where !finds.contains(where: {
            $0.albumId == f.albumId && WriteConfinement.looselySame($0.relativePath, f.relativePath)
        }) { finds.append(f) }
        guard WriteConfinement.confirmedKept(artistId, in: entries), !finds.isEmpty else {
            await mp3Attention(id, "no record of the find's files")
            throw MP3Error.needsAttention
        }
        // C3: Lidarr's records go stale after the move; a targeted refresh, completed, re-reads them.
        guard await refreshDone(id, artistId: artistId, inline: inline) else { return .later }
        let artist: LidarrArtist, files: [TrackFile], tracks: [LidarrTrack]
        do {
            artist = try await lidarr.artist(id: artistId)
            files = try await lidarr.trackFiles(artistId: artistId)
            var all: [LidarrTrack] = []
            for album in Set(finds.map(\.albumId)) { all += try await lidarr.tracks(albumId: album) }
            tracks = all
        } catch {
            throw MP3Error.unavailable
        }
        lastLidarrContact = now()
        guard let folder = artist.path else { throw MP3Error.unavailable }
        var doomed: [Int] = []
        for find in finds {
            let here = files.filter {
                $0.albumId == find.albumId
                    && WriteConfinement.relative($0.path, under: folder).map { WriteConfinement.looselySame($0, find.relativePath) } == true
            }
            guard here.count <= 1 else { await mp3Attention(id, "two files at one path"); throw MP3Error.needsAttention }
            guard let file = here.first else {
                // Not at its path: gone, or upgraded under another name, only if its track has no lossy file anywhere.
                let elsewhere = tracks.first { $0.foreignTrackId != nil && $0.foreignTrackId == find.foreignTrackId && $0.hasFile }
                    .flatMap { t in files.first { $0.id == t.trackFileId } }
                if let other = elsewhere, !Self.isLossless(other.quality) {
                    await mp3Attention(id, "the MP3 isn't where it was recorded")
                    throw MP3Error.needsAttention
                }
                continue
            }
            if Self.isLossless(file.quality) { continue }
            let track = tracks.first { $0.trackFileId == file.id }
            guard WriteConfinement.isLossy(file.quality), let foreign = find.foreignTrackId, track?.foreignTrackId == foreign,
                  file.size == find.size else {
                await mp3Attention(id, "the MP3 changed or can't be matched")
                throw MP3Error.needsAttention
            }
            doomed.append(file.id)
        }
        guard !doomed.isEmpty else {
            await mutate(id) {
                $0.lossless?.removedAt = self.serverNow()
                $0.lossless?.refreshCommandId = nil
            }
            return .nothingToRemove
        }
        do {
            try await persist()
            if crashed(.beforeDelete) { return .later }
            do {
                _ = try await gate.send("DELETE", "trackfile/bulk", body: BulkFiles(trackFileIds: doomed))
            } catch LidarrError.http(let status) where status == 404 || status == 405 {
                for file in doomed { _ = try await gate.send("DELETE", "trackfile/\(file)", body: nil) }
            }
        } catch WriteGateError.disabled {
            throw MP3Error.changesOff
        } catch let error as WriteGateError {
            if case .forbidden = error {
                await mp3Attention(id, "the gate refused the MP3 delete")
                throw MP3Error.needsAttention
            }
            throw MP3Error.unavailable
        } catch {
            // No answer: a later read tells (never claimed without one).
        }
        if crashed(.afterDelete) { return .later }
        // Never claimed without a read.
        guard let after = try? await lidarr.trackFiles(artistId: artistId) else { return .later }
        guard !after.contains(where: { doomed.contains($0.id) }) else { return .later }
        let before = request(id)?.songId
        await mutate(id) {
            $0.lossless?.removedAt = self.serverNow()
            $0.lossless?.refreshCommandId = nil
            $0.songId = nil
        }
        await remonitor(id, artistId: artistId)
        requestFolderScan(folder)   // fix I7
        if let r = request(id) { onMP3Removed(r, before) }
        return .removed
    }

    struct BulkFiles: Encodable, Sendable { var trackFileIds: [Int] }

    private func mp3Attention(_ id: RequestID, _ why: String) async {
        Log.logger("requests").error("MP3 not removed: \(why, privacy: .public)")
        await mutate(id) { $0.mp3NeedsAttention = true }
    }

    /// I6: a find album Lidarr unmonitored after the delete is monitored again (the album keeps being searched).
    private func remonitor(_ id: RequestID, artistId: Int) async {
        guard let w = request(id)?.lossless, let albums = try? await lidarr.albums(artistId: artistId) else { return }
        let off = albums.filter { w.albumIds.contains($0.id) && !$0.monitored }.map(\.id)
        guard !off.isEmpty else { return }
        do {
            try await persist()
            _ = try await gate.send("PUT", "album/monitor", body: MonitorAlbumsBody(albumIds: off, monitored: true))
        } catch {
            Log.logger("requests").error("album not monitored again: \(Log.category(of: error), privacy: .public)")
        }
    }

    /// Fix I5: the removal's targeted RefreshArtist. Its id is saved on the watch (before the next step), so a pass
    /// only checks it, and a relaunch picks it up. `inline` (the owner's tap) waits up to `refreshWait` for it,
    /// renewing its lease at every poll; the tick never waits. True: it completed (the records are fresh).
    private func refreshDone(_ id: RequestID, artistId: Int, inline: Bool) async -> Bool {
        if let sent = request(id)?.lossless?.refreshSentAt, now().timeIntervalSince(sent) >= Self.refreshGiveUp {
            await mutate(id) { $0.lossless?.refreshCommandId = nil; $0.lossless?.refreshSentAt = nil }
        }
        if request(id)?.lossless?.refreshCommandId == nil {
            guard let data = try? await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: artistId)),
                  let commandId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else { return false }
            await mutate(id) {
                $0.lossless?.refreshCommandId = commandId
                $0.lossless?.refreshSentAt = self.now()
            }
            if crashed(.refreshSent) { return false }
        }
        let until = now().addingTimeInterval(inline ? Self.refreshWait : 0)
        while !stopped {
            guard let commandId = request(id)?.lossless?.refreshCommandId else { return false }
            switch try? await lidarr.command(id: commandId) {
            case let c? where c.status.lowercased() == "completed":
                return true
            case let c? where Self.finishedCommandStates.contains(c.status.lowercased()):
                await mutate(id) { $0.lossless?.refreshCommandId = nil }   // failed: sent again next time
                return false
            case nil:
                await mutate(id) { $0.lossless?.refreshCommandId = nil }   // pruned or unreadable: sent again
                return false
            default:
                break
            }
            guard now() < until else { return false }
            await sleep(Self.keepPollInterval)
            renewLeases()   // fix I5: the heartbeat inside the wait
        }
        return false
    }

    // MARK: - Coalesced, targeted scans (fix I7)

    /// The artist folder needs Navidrome's scan (a lossless copy landed, an MP3 left). Coalesced across requests.
    func requestFolderScan(_ folder: String) {
        if pendingScans[folder] == nil { pendingScans[folder] = now() }
    }

    /// Once per pass: at most one scan per folder, never while Navidrome scans, backing off (1, 2, 4, 8 min) while a
    /// folder stays pending, for at most `relinkLimit` (30 min) per folder; a folder that can't be placed in a library
    /// is given up (never a whole-library or full scan).
    func flushFolderScans() async {
        let t = now()
        pendingScans = pendingScans.filter { t.timeIntervalSince($0.value) < Self.relinkLimit }
        guard !pendingScans.isEmpty else { scanBackoff = 60; return }
        if let last = lastFolderScan, t.timeIntervalSince(last) < scanBackoff { return }
        guard (try? await library.isScanning()) == false else { return }
        lastFolderScan = t
        for folder in pendingScans.keys.sorted() {
            if await !library.scanFolder(folder) { pendingScans[folder] = nil }
        }
        scanBackoff = min(scanBackoff * 2, 480)
    }

    /// The relink found the song: its folder's scan is no longer needed.
    func folderScanned(_ folder: String) {
        pendingScans[folder] = nil
        if pendingScans.isEmpty { scanBackoff = 60 }
    }
}
