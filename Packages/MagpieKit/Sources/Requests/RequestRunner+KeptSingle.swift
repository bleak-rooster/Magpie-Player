import Foundation
import LidarrKit
import MagpieCore

/// Round 22 (owner, 2026-11-06): "when the entire artist is added because you've decided to keep a find, you should be
/// given the option to keep or delete the single. When deleting the single, ensure that the artist isn't deleted."
///
/// After a Keep that moved a find whose own release is a Single, Bring in more records the owner's choice for it when it
/// brings in at least one album or EP (`KeptSingle`, D171). **Keep it** (the default) sends nothing. **Remove it once the
/// album is here** (D172) waits, within the bring-in's window (`keptSingleWindow`, a day, as Bring in more counts its
/// releases), until one of the albums or EPs this Bring in more brought in holds the song with its file (by recording,
/// else title: `wantedTracks`, as the trim matches). Then, proven on fresh reads:
/// - the ledger says Magpie added the artist and monitored the single itself (not before the owner), the artist's Keep is
///   confirmed with none under way, and the artist is in the main root;
/// - Lidarr's album is still the single's release group and a Single;
/// - the library lists the album's copy (else its folder is scanned and it waits), and the owner's own playlists that held
///   the single's song now hold the album's copy, in place (D173; not done: it waits);
/// - the removal is saved in the ledger (M6), the single is unmonitored (the album monitor rule allows a kept album only
///   with that record), then exactly all of its files are deleted (`ConfinedShape.keptSingleDelete`, which proves it all
///   again). The request's song becomes the album's copy (the queue follows through `onRelinked`), and the library scans.
/// Never `DELETE /artist`, never another album. No release holding the song in the window, the bring-in called off (its
/// releases unmonitored without files), or the releases in without the song: the single stays, and why is recorded.
extension RequestRunner {
    /// How long a removal waits for a release holding the song (as Bring in more counts its releases: a day).
    public static let keptSingleWindow: TimeInterval = RequestMachine.giveUpAfter
    /// How often a waiting removal reads Lidarr.
    public static let keptSingleCheckInterval: TimeInterval = 60
    /// Removals that couldn't finish before the single is left as it is.
    public static let keptSingleTryLimit = 5

    // MARK: - The choice

    /// Bring in more brought `brought` in for a kept single: records the choice when an album or EP is among them.
    func recordKeptSingle(_ id: RequestID, _ single: KeptSingleOffer?, brought: [LidarrAlbum], remove: Bool) async {
        guard let single else { return }
        let ids = brought.filter { ["album", "ep"].contains($0.albumType?.lowercased() ?? "") }.map(\.id)
        guard !ids.isEmpty else { return }
        let at = now()
        await mutate(id) { r in
            if var ks = r.keptSingle, ks.isOpen, ks.albumId == single.albumId {
                ks.bringIn += ids.filter { !ks.bringIn.contains($0) }
                ks.since = at
                if remove { ks.choice = .remove }
                r.keptSingle = ks
            } else {
                r.keptSingle = KeptSingle(albumId: single.albumId, title: single.title, choice: remove ? .remove : .keep,
                                          bringIn: ids, since: at)
            }
        }
    }

    /// The request page: keep or remove the single while the bring-in is under way. False: nothing to change (settled,
    /// or no single). Nothing is sent here.
    public func setKeptSingle(_ id: RequestID, remove: Bool) async -> Bool {
        guard !stopped, await load(), request(id)?.keptSingle?.isOpen == true else { return false }
        await mutate(id) { $0.keptSingle?.choice = remove ? .remove : .keep }
        keptSingleChecks[id] = nil
        return true
    }

    // MARK: - Following

    /// `tick()`: closes choices whose window ended and carries waiting removals on (at most every
    /// `keptSingleCheckInterval` each).
    func followKeptSingles() async {
        for r in list {
            guard let ks = r.keptSingle, ks.isOpen else { continue }
            if now().timeIntervalSince(ks.since) >= Self.keptSingleWindow {
                await settleKeptSingle(r.id, ks.choice == .remove ? .albumDidNotArrive : .kept)
                continue
            }
            guard ks.choice == .remove else { continue }
            // A last check "in the future" (the clock went back) is due now.
            if let last = keptSingleChecks[r.id], (0..<Self.keptSingleCheckInterval).contains(now().timeIntervalSince(last)) {
                continue
            }
            keptSingleChecks[r.id] = now()
            guard let artistId = r.lidarrArtistId, tryAcquireArtist(artistId) else { continue }
            await removeKeptSingle(r.id, artistId: artistId)
            keepingArtists.remove(artistId)
        }
    }

    private func settleKeptSingle(_ id: RequestID, _ outcome: KeptSingle.Outcome, replacedBy: Int? = nil) async {
        let at = now()
        await mutate(id) {
            $0.keptSingle?.outcome = outcome
            $0.keptSingle?.outcomeAt = at
            if let replacedBy { $0.keptSingle?.replacedBy = replacedBy }
        }
        keptSingleChecks[id] = nil
        if outcome != .removed, outcome != .kept {
            Log.logger("requests").info("kept single: it stays (\(outcome.rawValue, privacy: .public))")
        }
    }

    private func keptSingleFailed(_ id: RequestID, albumId: Int, _ why: String) async {
        Log.logger("requests").error("kept single: \(why, privacy: .public)")
        let tries = (request(id)?.keptSingle?.tries ?? 0) + 1
        await mutate(id) { $0.keptSingle?.tries = tries }
        guard tries >= Self.keptSingleTryLimit else { return }
        try? await ledger.update(albumId: albumId) { $0.keptSingleRemovalAt = nil }
        await settleKeptSingle(id, .notRemovable)
    }

    /// One look; returns when removed, settled, or waiting for a later pass.
    func removeKeptSingle(_ id: RequestID, artistId: Int) async {
        guard let r = request(id), let ks = r.keptSingle, ks.isOpen, ks.choice == .remove else { return }
        guard r.state == .kept, !r.keptInPlace else { return await settleKeptSingle(id, .notRemovable) }
        guard r.keep == nil, !r.keepNeedsAttention, await gate.enabled, let setup = await keepSetup() else { return }

        let entries: [LedgerEntry]
        do { entries = try await ledger.entries.filter { $0.lidarrArtistId == artistId } } catch { return }
        if entries.contains(where: { $0.keepIntentAt != nil }) { return }   // a Keep under way: later
        guard let entry = entries.first(where: { $0.albumId == ks.albumId }), entry.createdArtist, !entry.wasMonitoredBefore,
              entry.isConfirmedKept, WriteConfinement.confirmedKept(artistId, in: entries) else {
            return await settleKeptSingle(id, .notRemovable)
        }
        let artist: LidarrArtist, albums: [LidarrAlbum], roots: [String]
        do {
            artist = try await lidarr.artist(id: artistId)
            albums = try await lidarr.albums(artistId: artistId)
            roots = try await lidarr.rootFolders().map(\.path)
        } catch LidarrError.http(status: 404) {
            return await settleKeptSingle(id, .notRemovable)
        } catch {
            return
        }
        lastLidarrContact = now()
        let main = PathGuard(findsRoot: setup.mainRoot, otherRoots: roots.filter { !Self.sameBytes($0, setup.mainRoot) },
                             caseInsensitive: false)
        guard entries.contains(where: { $0.created(artist) }), let path = artist.path, main.isInside(path),
              roots.contains(where: { Self.sameBytes($0, setup.mainRoot) }) else {
            return await settleKeptSingle(id, .notRemovable)
        }
        guard let single = albums.first(where: { $0.id == ks.albumId }), single.foreignAlbumId == entry.rgMbid,
              single.albumType?.lowercased() == "single" else {
            return await settleKeptSingle(id, .notRemovable)
        }

        // A release this Bring in more brought in that holds the song with its file.
        let candidates = ks.bringIn.compactMap { albumId in albums.first { $0.id == albumId } }
            .filter { ["album", "ep"].contains($0.albumType?.lowercased() ?? "") && $0.id != single.id }
        var found: (album: LidarrAlbum, track: LidarrTrack, file: TrackFile)?
        do {
            for album in candidates where (album.trackFileCount ?? 0) > 0 {
                let tracks = try await lidarr.tracks(albumId: album.id)
                guard let track = Self.wantedTracks(tracks, for: [r]).first, let fileId = track.trackFileId else { continue }
                if let file = try await lidarr.trackFiles(albumId: album.id).first(where: { $0.id == fileId }) {
                    found = (album, track, file)
                    break
                }
            }
        } catch {
            return
        }
        guard let found else {
            let arrived = { (a: LidarrAlbum) in (a.trackFileCount ?? 0) > 0 && (a.trackCount.map { (a.trackFileCount ?? 0) >= $0 } ?? true) }
            if candidates.allSatisfy({ !$0.monitored && (($0.trackFileCount ?? 0) == 0) }) {
                return await settleKeptSingle(id, .albumDidNotArrive)   // called off (or gone)
            }
            if candidates.allSatisfy({ arrived($0) || !$0.monitored }), candidates.contains(where: arrived) {
                return await settleKeptSingle(id, .noCopy)
            }
            return   // still coming
        }

        // The album's copy, as the library lists it: it plays in the single's place.
        guard let listed = await library.songsTitled(found.track.title ?? r.recording.title, path) else { return }
        guard let albumSong = listed.first(where: { WriteConfinement.looselySame($0.lidarrPath, found.file.path) })?.song else {
            _ = await library.scanFolder(path)
            return
        }
        let before = r.songId
        if let before, before != albumSong.id {
            guard await library.repointSong(before, albumSong) else { return }   // D173: playlists first
        }

        // M6: the removal is on disk before anything is sent; the gate needs it.
        let at = now()
        do {
            try await ledger.update(albumId: single.id) {
                $0.keptSingleRemovalAt = at
                $0.keptSingleReplacedBy = found.album.id
            }
        } catch {
            return
        }
        do { try await persist() } catch { return }
        if single.monitored {
            do {
                _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [single.id], monitored: false))
            } catch let error as WriteGateError where error == .disabled || error == .logUnavailable || error == .unconfirmed {
                return
            } catch {
                return await keptSingleFailed(id, albumId: single.id, "unmonitoring the single")
            }
        }
        let files: [TrackFile]
        do { files = try await lidarr.trackFiles(albumId: single.id) } catch { return }
        if !files.isEmpty {
            let ids = files.map(\.id)
            do {
                _ = try await gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: ids), confinedAs: .keptSingleDelete)
            } catch let error as WriteGateError where error == .disabled || error == .logUnavailable || error == .unconfirmed {
                return
            } catch {
                return await keptSingleFailed(id, albumId: single.id, "the single's files weren't removed")
            }
        }
        await mutate(id) {
            $0.songId = albumSong.id
            $0.songSuffix = albumSong.suffix
            if var watch = $0.lossless, watch.isActive, watch.albumIds.contains(single.id) {
                watch.doneAt = at   // no lossless search or MP3 rule for a release that's gone
                $0.lossless = watch
            }
        }
        await settleKeptSingle(id, .removed, replacedBy: found.album.id)
        if let updated = request(id) { onRelinked(updated, before, albumSong) }
        do { try await library.startScan() } catch {
            Log.logger("requests").error("kept single: scan failed: \(Log.category(of: error), privacy: .public)")
        }
    }
}
