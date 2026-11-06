import Foundation
import LidarrKit
import MagpieCore

/// Round 18 (owner, 2026-11-05): a song's Try keeps only that song. Lidarr (and Tubifarry, whose indexers are only ever
/// asked for albums: researched in 2.3.1) can only download a whole release, so the smallest release holding the song is
/// still asked for first (`ReleasePicker`, round 17); once the song is ready, the release's other songs are removed from
/// the Finds folder and (when it has other songs) the album is unmonitored, so neither Lidarr nor a missing-tracks search
/// brings them back.
///
/// Only for a request asked for after round 18 (`onlyTheSong`, never "Try this album"), of a find: an artist Magpie
/// created, tagged and inside the Finds root, nothing of it kept. Proven on fresh state right before the delete:
/// - the ledger says Magpie created the artist and monitored this release (which had no files: `!wasMonitoredBefore`);
/// - Lidarr's album is still the request's release group, and no download for it is in the queue;
/// - the song is matched to a track with a file (by recording, else by title): none matched, nothing is removed;
/// - every song another request (on its way or ready) wants from the album stays;
/// - every file to delete is inside the artist's folder in the Finds root (the gate's findDelete rule checks it again).
/// Files go to Lidarr's recycle bin when one is set. Never anything of a kept artist, a library artist or another album.
extension RequestRunner {
    /// Trims that couldn't finish before the release is left as it is.
    public static let trimTryLimit = 5

    /// `tick()`: trims each ready song Try once (a later pass carries on after a cut-off one).
    func trimToSongs() async {
        for r in list where r.onlyTheSong == true && r.trimDone != true {
            guard let artistId = r.lidarrArtistId else {
                if r.state.isTerminal { await mutate(r.id) { $0.trimDone = true } }
                continue
            }
            guard !artistBusy(artistId) else { continue }
            keepingArtists.insert(artistId)
            await trimToSong(r.id, artistId: artistId)
            keepingArtists.remove(artistId)
        }
    }

    private func trimDone(_ id: RequestID, _ why: String? = nil) async {
        if let why { Log.logger("requests").info("only the song: the release stays (\(why, privacy: .public))") }
        await mutate(id) { $0.trimDone = true }
    }

    /// One try; returns when done, waiting (a later pass), or out of tries.
    func trimToSong(_ id: RequestID, artistId: Int) async {
        guard let r = request(id) else { return }
        if r.state.isTerminal { return await trimDone(id) }   // kept, let go, stopped or failed: nothing to trim
        guard r.state == .ready else { return }               // still on its way
        guard r.isFind, r.albumTarget == nil, let albumId = r.albumId, let plan = r.plan else {
            return await trimDone(id)   // a library artist or Add to library: never trimmed
        }
        guard r.keep == nil, !r.keepNeedsAttention, r.notForMe == nil, !r.notForMeNeedsAttention else {
            return await trimDone(id, "a Keep or Not for me")
        }
        // Every song of this release a request still wants (this one, and any other Try on it, ready or on its way).
        let album = list.filter { $0.lidarrArtistId == artistId && $0.albumId == albumId && ($0.isActive || $0.state == .ready) }
        if album.contains(where: { $0.albumTarget != nil }) { return await trimDone(id, "the whole album was asked for") }
        if list.contains(where: { $0.lidarrArtistId == artistId && ($0.state == .kept || $0.keep != nil) }) {
            return await trimDone(id, "the artist is kept")
        }
        // Another song of this release still on its way: its file isn't in yet.
        if list.contains(where: { $0.id != id && $0.isActive && ($0.albumId == albumId || $0.plan?.releaseGroupMBID == plan.releaseGroupMBID) }) {
            return
        }
        guard let setup = await keepSetup() else { return }

        let entries: [LedgerEntry]
        do { entries = try await ledger.entries.filter { $0.lidarrArtistId == artistId } } catch { return }
        guard entries.contains(where: \.createdArtist), !entries.contains(where: \.isKeptOrKeeping),
              let entry = entries.first(where: { $0.albumId == albumId }), !entry.wasMonitoredBefore,
              entry.rgMbid == plan.releaseGroupMBID else {
            return await trimDone(id, "not a release Magpie brought in")
        }
        let roots: [String], artist: LidarrArtist, albums: [LidarrAlbum], tracks: [LidarrTrack]
        let files: [TrackFile], queue: [QueueItem], commands: [CommandStatus]
        do {
            roots = try await lidarr.rootFolders().map(\.path)
            artist = try await lidarr.artist(id: artistId)
            albums = try await lidarr.albums(artistId: artistId)
            tracks = try await lidarr.tracks(albumId: albumId)
            files = try await lidarr.trackFiles(albumId: albumId)
            queue = try await lidarr.queueDetails(albumIds: [albumId])
            commands = try await lidarr.commands()
        } catch LidarrError.http(status: 404) {
            return await trimDone(id, "gone from Lidarr")
        } catch {
            return
        }
        lastLidarrContact = now()
        guard entries.contains(where: { $0.created(artist) }), Self.mayKeep(artist, request: r, setup: setup, roots: roots),
              let path = artist.path,
              let lidarrAlbum = albums.first(where: { $0.id == albumId && $0.foreignAlbumId == entry.rgMbid }) else {
            return await trimDone(id, "no longer a find of this release")
        }
        // Still downloading or importing, or the artist being moved or refreshed: later.
        guard queue.allSatisfy({ $0.albumId != albumId }),
              !commands.contains(where: { (Self.isMove($0, of: artistId) || Self.refreshes($0, artistId: artistId)) && !Self.isFinished($0) })
        else { return }

        let wanted = Self.wantedTracks(tracks, for: album)
        guard !wanted.isEmpty else { return await trimDone(id, "the song wasn't matched to a track") }
        let keepFiles = Set(wanted.compactMap(\.trackFileId))
        let extras = files.filter { !keepFiles.contains($0.id) }
        let finds = Self.findsGuard(findsRoot: setup.findsRoot, mainRoot: setup.mainRoot, roots: roots)
        let folder = Self.artistGuard(path, setup: setup, roots: roots)
        guard extras.allSatisfy({ finds.isInside($0.path) && folder.isInside($0.path) && ($0.albumId == nil || $0.albumId == albumId) })
        else { return await trimDone(id, "a file outside the find's folder") }

        if !extras.isEmpty {
            do { try await persist() } catch { return }
            do {
                _ = try await gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: extras.map(\.id)))
            } catch let error as WriteGateError {
                switch error {
                case .disabled, .logUnavailable, .unconfirmed: return   // changes off or unchecked: later
                case .forbidden, .invalidRequest: return await trimFailed(id, "the gate refused the delete")
                }
            } catch let error where Self.isDefinitiveRejection(error) {
                if case .http(let status)? = error as? LidarrError, status == 404 || status == 405 {
                    // No bulk route: one at a time (each pass proves the rest again first).
                    do { _ = try await gate.send("DELETE", "trackfile/\(extras[0].id)", body: nil) } catch {
                        return await trimFailed(id, "a delete was refused")
                    }
                    return   // the next pass deletes the next one
                }
                return await trimFailed(id, "Lidarr refused the delete")
            } catch {
                return await trimFailed(id, "no answer to the delete")   // a fresh read next pass says what's left
            }
        }
        // Only a release with other songs is unmonitored (they would be fetched again); a single that is just the song
        // stays monitored, so a Keep's lossless upgrade still comes (FindFlowIT).
        if lidarrAlbum.monitored, tracks.count > wanted.count {
            do { try await persist() } catch { return }
            do {
                _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: false))
                await mutate(id) { $0.trimUnmonitored = true }
            } catch let error as WriteGateError where error == .disabled || error == .logUnavailable || error == .unconfirmed {
                return
            } catch {
                return await trimFailed(id, "unmonitoring the album")
            }
        }
        await mutate(id) { $0.trimDone = true }
        if !extras.isEmpty {
            do { try await library.startScan() } catch {
                Log.logger("requests").error("only the song: scan failed: \(Log.category(of: error), privacy: .public)")
            }
        }
    }

    private func trimFailed(_ id: RequestID, _ why: String) async {
        Log.logger("requests").error("only the song: \(why, privacy: .public)")
        let tries = (request(id)?.trimTries ?? 0) + 1
        await mutate(id) {
            $0.trimTries = tries
            if tries >= Self.trimTryLimit { $0.trimDone = true }
        }
    }

    /// The album's tracks with a file that some request on it wants: by recording (the plan's, or the source's), else by
    /// title (`SongIdentity.titleKey`). Pure (tests).
    static func wantedTracks(_ tracks: [LidarrTrack], for requests: [MagpieRequest]) -> [LidarrTrack] {
        let recordings = Set(requests.flatMap { [$0.plan?.recordingMBID, $0.recording.recordingMBID].compactMap { $0 } })
        let titles = Set(requests.map { SongIdentity.titleKey($0.recording.title) }.filter { !$0.isEmpty })
        return tracks.filter { t in
            guard t.hasFile else { return false }
            if let id = t.foreignRecordingId.flatMap(MBID.init), recordings.contains(id) { return true }
            return t.title.map { titles.contains(SongIdentity.titleKey($0)) } ?? false
        }
    }
}
