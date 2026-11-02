import Foundation
import LidarrKit
import MagpieCore

/// Y5 (plan item 8, owner answer 3): after Add to your library, the find goes lossless.
///
/// - **Search:** an `AlbumSearch` for the find's albums at the commit, then at most once a day for 30 days (the spike
///   showed Lidarr's own cutoff search skips an MP3 outside the Magpie Lossless profile, so these searches matter).
/// - **Watch:** the albums' track files, every `losslessCheckInterval` (daily after the MP3 is gone). When every
///   track of the find is lossless (Lidarr's upgrade replaced the MP3), the song is looked up again (relink) and the
///   watch ends. It also ends 30 days after it started (I5).
/// - **MP3 rule:** only for a Keep the owner tapped under Y5 (`autoDelete`, C2): at `deadline` (commit + 7 days, Lidarr's
///   time) the recorded MP3 files that are still there are removed; "Remove the MP3 now" does the same at any time.
///   Removal re-maps first (C3): a targeted `RefreshArtist`, waited for, then each recorded file is found again at
///   `<artist folder>/<relativePath>` with its track and size; anything else is "needs attention". The gate's
///   keptLossyDelete rule checks it all again. `removedAt` is set only after a read shows the files gone. A monitored
///   album Lidarr unmonitored after the delete is monitored again (I6).
extension RequestRunner {
    public static let mp3Grace: TimeInterval = 7 * 24 * 3600
    public static let losslessSearchInterval: TimeInterval = 24 * 3600
    public static let losslessWatchLimit: TimeInterval = 30 * 24 * 3600
    public static let losslessCheckInterval: TimeInterval = 300
    /// How long a removal waits inline for its RefreshArtist.
    public static let refreshWait: TimeInterval = 120

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

    /// At a Keep's commit (or an adopted / older kept find, `autoDelete: false`): the watch, and the first search.
    func startLosslessWatch(_ id: RequestID, artistId: Int, autoDelete: Bool) async {
        guard let r = request(id), r.lossless == nil else { return }
        let entries = (try? await ledger.entries.filter { $0.lidarrArtistId == artistId }) ?? []
        var albums = Set(entries.flatMap { $0.findFiles ?? [] }.map(\.albumId))
        if let album = r.albumId { albums.insert(album) }
        guard !albums.isEmpty else { return }
        let start = serverNow()
        await mutate(id) {
            $0.lossless = LosslessWatch(albumIds: albums.sorted(), startedAt: start, autoDelete: autoDelete,
                                        deadline: autoDelete ? start.addingTimeInterval(self.grace) : nil)
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

    /// `tick()`: every active watch, at most every `losslessCheckInterval` (daily once the MP3 is gone).
    func followLossless() async {
        for r in list {
            guard let w = r.lossless, w.isActive, let artistId = r.lidarrArtistId, !artistBusy(artistId) else { continue }
            let t = serverNow()
            let every = w.removedAt == nil ? Self.losslessCheckInterval : Self.losslessSearchInterval
            if let last = w.lastCheckAt, (0..<every).contains(t.timeIntervalSince(last)) { continue }
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
                _ = try? await removeMP3(r.id, artistId: artistId)
            }
        }
    }

    /// Every track of the find's albums that has a file has a lossless one. Nil: can't tell now.
    private func findIsLossless(_ id: RequestID, artistId: Int) async -> Bool? {
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
            $0.mp3NeedsAttention = false
            if let path {
                $0.relinkPending = true
                $0.movedTo = path
                $0.movedAt = self.now()
            }
        }
        if let path { try? await library.rescanMoved(path, path) }
        await relink(id)
    }

    // MARK: - Remove the MP3

    /// Whether "Remove the MP3 now" is offered for this request: a kept find whose MP3 Magpie recorded, not yet gone.
    public func mp3Removable(_ id: RequestID) async -> Bool {
        guard let r = request(id), r.state == .kept, let w = r.lossless, w.isActive, w.removedAt == nil,
              w.losslessAt == nil, !r.mp3NeedsAttention, let artistId = r.lidarrArtistId,
              let entries = try? await ledger.entries.filter({ $0.lidarrArtistId == artistId }) else { return false }
        return WriteConfinement.confirmedKept(artistId, in: entries) && entries.contains { !($0.findFiles ?? []).isEmpty }
    }

    /// I7: removing it can't be undone (Lidarr's recycle bin is unset). Nil: can't tell.
    public func mp3RemovalIsPermanent() async -> Bool? {
        do { return try await lidarr.recycleBin() == nil } catch { return nil }
    }

    /// "Remove the MP3 now" (confirmed by the owner).
    public func removeMP3Now(_ id: RequestID) async throws -> MP3Outcome {
        guard !stopped, await load(), let artistId = request(id)?.lidarrArtistId else { throw MP3Error.notOffered }
        guard await mp3Removable(id) else { throw MP3Error.notOffered }
        guard await gate.enabled else { throw MP3Error.changesOff }
        return try await removeMP3(id, artistId: artistId)
    }

    /// One removal at a time per artist (the artist lease), so the deadline and a tap never delete twice.
    func removeMP3(_ id: RequestID, artistId: Int) async throws -> MP3Outcome {
        guard !artistBusy(artistId) else { return .later }
        keepingArtists.insert(artistId)
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
        // C3: Lidarr's records go stale after the move; a targeted refresh, waited for, re-reads them.
        guard await refreshArtist(artistId) else { return .later }
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
            await mutate(id) { $0.lossless?.removedAt = self.serverNow() }
            return .nothingToRemove
        }
        do {
            try await persist()
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
        // Never claimed without a read.
        guard let after = try? await lidarr.trackFiles(artistId: artistId) else { return .later }
        guard !after.contains(where: { doomed.contains($0.id) }) else { return .later }
        let before = request(id)?.songId
        await mutate(id) {
            $0.lossless?.removedAt = self.serverNow()
            $0.songId = nil
        }
        await remonitor(id, artistId: artistId)
        try? await library.rescanMoved(folder, folder)
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

    /// Sends a targeted RefreshArtist and waits (up to `refreshWait`) for it to complete. False: not done (later).
    func refreshArtist(_ artistId: Int) async -> Bool {
        let commandId: Int
        do {
            let data = try await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: artistId))
            guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else { return false }
            commandId = id
        } catch {
            return false
        }
        let until = now().addingTimeInterval(Self.refreshWait)
        while now() < until, !stopped {
            if let c = try? await lidarr.command(id: commandId) {
                let status = c.status.lowercased()
                if status == "completed" { return true }
                if Self.finishedCommandStates.contains(status) { return false }
            }
            await sleep(Self.keepPollInterval)
        }
        return false
    }
}
