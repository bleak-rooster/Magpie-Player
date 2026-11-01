import Foundation
import LidarrKit
import MagpieCore

/// Bring in more (Task 7.1b, D5): after a Keep that moved a find into the library, more of the artist's releases.
///
/// Only for a kept, moved find (not kept in place, no Keep still settling) whose artist Magpie created (G5: no
/// write to an artist Magpie didn't create), with `magpie-find` gone and its folder strictly inside the main root
/// (fresh GET). Every check is made again from fresh Lidarr state on `bringIn`; the offer is only what the sheet
/// shows.
///
/// Additive only (G6 spirit): albums that aren't monitored yet are monitored and searched (`PUT /album/monitor`,
/// `AlbumSearch`). Nothing is unmonitored, no profile or tag changes, no metadata profile switch (A1). Albums
/// another request still has open in the ledger are left to it. Follow new releases sets the artist's
/// `monitorNewItems` to `new` through the artist editor with exactly `{artistIds, monitorNewItems}` (the gate
/// allows only that shape, and never `none`); an artist that already follows (`all` or `new`) is left alone.
///
/// G7: each release it brings in counts toward the limit of 5 like a request on its way (security FL4), until Lidarr
/// has files for it, it is no longer monitored, or a day has passed (`followBringIns`). So one Bring in more brings
/// in at most the room left (and never more than `bringInLimit`), newest first (the offer says how many there were),
/// never more than the sheet offered, and releases are refused when there is no room. Following new releases
/// downloads nothing now, so it never needs room. M6: the albums are in the ledger (kept, closed,
/// "may have landed") before the monitor write; afterwards they say whether it applied.
extension RequestRunner {
    public enum BringInChoice: String, Sendable, CaseIterable {
        case albumsAndEPs
        case thisAlbum
        case everything
    }

    /// What one choice would bring in.
    public struct BringInOption: Sendable, Equatable {
        /// Releases to monitor and search: not monitored yet, newest first, at most `bringInLimit`.
        public var albumIds: [Int]
        /// How many releases of this choice aren't in yet (before the limit).
        public var available: Int
        /// Seconds of music in `albumIds`; nil when Lidarr doesn't know every one's length (A5: no guess), or
        /// when there is nothing to bring in.
        public var duration: TimeInterval?
        /// This album only: the album's title (also when it's in already).
        public var title: String?

        public var isCapped: Bool { available > albumIds.count }

        public init(albumIds: [Int], available: Int, duration: TimeInterval?, title: String? = nil) {
            self.albumIds = albumIds; self.available = available; self.duration = duration; self.title = title
        }
    }

    public struct BringInOffer: Sendable, Equatable {
        public var artistId: Int
        public var artistName: String
        /// `thisAlbum` is missing when the song's album can't be told (MusicBrainz unreachable, or Lidarr doesn't
        /// list it for the artist).
        public var options: [BringInChoice: BringInOption]
        /// The artist already follows new releases (`monitorNewItems` all or new).
        public var followsNewReleases: Bool
    }

    public struct BringInResult: Sendable, Equatable {
        /// Releases monitored now.
        public var albums: Int
        /// Their search was started (false: none, or Lidarr didn't take the search; they're monitored anyway).
        public var searching: Bool
        /// The artist follows new releases now (sent now, or already).
        public var following: Bool
        /// Releases the sheet offered that didn't come in now because the limit of 5 has less room than when the
        /// sheet was shown (FL4): the sheet's number is never exceeded, and a shortfall is said.
        public var heldBack: Int

        public init(albums: Int, searching: Bool, following: Bool, heldBack: Int = 0) {
            self.albums = albums; self.searching = searching; self.following = following; self.heldBack = heldBack
        }
    }

    public enum BringInError: Error, Equatable {
        /// "Allow Magpie to change Lidarr" is off (G1).
        case changesOff
        /// Finds or Keep aren't set up.
        case notSetUp
        /// Not a find that was kept and moved into the library (or Magpie didn't create its artist).
        case notKept
        /// Five requests are on their way (G7).
        case tooMany
        /// Lidarr, MusicBrainz or the ledger can't be read right now, or a Keep / Not for me is busy with the
        /// artist. Nothing was written.
        case unavailable
        /// Lidarr refused the albums (or the answer was lost and a fresh read shows none of them monitored).
        case failed
        /// The answer was lost and Lidarr couldn't be read to tell whether the albums were monitored.
        case unconfirmed
        /// R18: Lidarr has a metadata profile with the name Magpie would give these release types, with other
        /// settings. It isn't Magpie's to change, so nothing was written.
        case profileConflict(String)
    }

    /// G7: the most releases one Bring in more monitors and searches.
    public static let bringInLimit = 20

    /// `monitorNewItems` values that mean the artist follows new releases already.
    static let followingValues: Set<String> = ["all", "new"]

    // MARK: - Offer

    /// What each choice would bring in, from fresh Lidarr state. Writes nothing. `types` (R18): Everything is only
    /// the releases of these types.
    public func bringInOffer(_ id: RequestID, types: ReleaseTypes? = nil) async throws -> BringInOffer {
        let target = try await bringInTarget(id)
        let songAlbums = await songAlbumGroups(target.request)
        var options: [BringInChoice: BringInOption] = [:]
        for choice in BringInChoice.allCases {
            options[choice] = Self.bringInOption(target.albums, choice: choice, songAlbums: songAlbums,
                                                 skip: target.openAlbums, limit: bringInRoom, types: types)
        }
        return BringInOffer(artistId: target.artist.id, artistName: target.artist.artistName, options: options,
                            followsNewReleases: Self.follows(target.artist))
    }

    // MARK: - Bring in

    /// Monitors and searches what `choice` brings in now (nil: no releases), and follows new releases when
    /// `follow`. Every check is made again; throws `BringInError` (nothing written) unless it returns.
    ///
    /// `offered`: the release ids the sheet showed for `choice`. Then exactly those come in (the ones still not in),
    /// never more, and at most as many as the limit of 5 has room for now; any held back for room are counted in
    /// `heldBack`. Nil: the choice's newest releases, as many as there is room for. Following new releases downloads
    /// nothing now, so it never needs room.
    ///
    /// R18: `types` (with Everything) brings in only releases of those types, and first sets the artist to Magpie's
    /// metadata profile for them (provisioned if missing), so new releases follow the same types. `qualityProfileId`
    /// sets the artist's quality profile (Lossless or Smaller files). Each is sent only when it differs, before any
    /// release is monitored; the gate allows both only for an artist Magpie added.
    public func bringIn(_ id: RequestID, choice: BringInChoice?, offered: [Int]? = nil,
                        follow: Bool, types: ReleaseTypes? = nil, qualityProfileId: Int? = nil) async throws -> BringInResult {
        let target = try await bringInTarget(id)
        let artistId = target.artist.id
        guard !keepingArtists.contains(artistId) else { throw BringInError.unavailable }
        keepingArtists.insert(artistId)
        defer { keepingArtists.remove(artistId) }

        // R18: the release types and quality first. They await Lidarr (a read, maybe writes), so they come before
        // the room is checked and taken below, which must have no await between (FL4, review I1). If the room is gone
        // by then, the artist keeps the new settings (Magpie's own artist; nothing is monitored).
        try await applyProfiles(target.artist, types: choice == .everything ? types : nil,
                                qualityProfileId: qualityProfileId)

        var albums: [LidarrAlbum] = []
        var heldBack = 0
        if let choice {
            let songAlbums = choice == .thisAlbum ? await songAlbumGroups(target.request) : nil   // before the room check
            if choice == .thisAlbum, songAlbums == nil { throw BringInError.unavailable }
            let option = Self.bringInOption(target.albums, choice: choice, songAlbums: songAlbums,
                                            skip: target.openAlbums, limit: Self.bringInLimit, types: types)
            let eligible = option?.albumIds ?? []
            let wanted = offered.map { ids in ids.filter(eligible.contains) } ?? eligible
            albums = wanted.compactMap { albumId in target.albums.first { $0.id == albumId } }
            // FL4: the room left now (checked and taken with no await between), the newest first.
            guard albums.isEmpty || bringInRoom > 0 || follow else { throw BringInError.tooMany }
            if albums.count > bringInRoom {
                if offered != nil || bringInRoom == 0 { heldBack = albums.count - bringInRoom }
                albums = Array(albums.prefix(bringInRoom))
            }
        }
        let reserved = albums.map(\.id)
        if !reserved.isEmpty {
            await mutate(id) {
                $0.bringingIn = ($0.bringingIn ?? []) + reserved
                $0.bringInAt = self.now()
            }
        }
        let needsFollow = follow && !Self.follows(target.artist)
        var result = BringInResult(albums: 0, searching: false, following: follow && !needsFollow, heldBack: heldBack)
        if !albums.isEmpty {
            do {
                albums = try await monitor(albums, artist: target.artist, root: target.mainRoot)
            } catch {
                await arrived(id, Set(reserved))   // nothing monitored: no place taken
                throw error
            }
            await arrived(id, Set(reserved).subtracting(albums.map(\.id)))
            result.albums = albums.count
            do {
                _ = try await gate.send("POST", "command", body: SearchBody(name: "AlbumSearch", albumIds: albums.map(\.id)))
                result.searching = true
            } catch {
                Log.logger("requests").error("Bring in more: search not started; the releases stay monitored")
            }
        }
        if needsFollow {
            do {
                _ = try await gate.send("PUT", "artist/editor", body: FollowBody(artistIds: [artistId], monitorNewItems: "new"))
                result.following = true
            } catch {
                Log.logger("requests").error("Bring in more: following new releases didn't go through")
                if albums.isEmpty { throw Self.bringInError(error) }
            }
        }
        return result
    }

    // MARK: - Counting toward G7 (FL4)

    /// Places left in the limit of 5, at most `bringInLimit`.
    var bringInRoom: Int { max(0, min(Self.bringInLimit, Self.maxActive - activeCount)) }

    /// The releases no longer take a place.
    private func arrived(_ id: RequestID, _ albumIds: Set<Int>) async {
        guard !albumIds.isEmpty else { return }
        await mutate(id) {
            let left = ($0.bringingIn ?? []).filter { !albumIds.contains($0) }
            $0.bringingIn = left.isEmpty ? nil : left
            if left.isEmpty { $0.bringInAt = nil }
        }
    }

    /// `tick()`: releases Bring in more is bringing in leave the count once Lidarr has files for them or doesn't
    /// monitor them (or is gone), or `RequestMachine.giveUpAfter` after the Bring in more. Checked at most every
    /// `bringInCheckInterval` per find; a read that fails keeps them counted.
    func followBringIns() async {
        for r in list {
            guard let ids = r.bringingIn, !ids.isEmpty else { continue }
            let since = now().timeIntervalSince(r.bringInAt ?? r.updatedAt)
            guard since < RequestMachine.giveUpAfter, let artistId = r.lidarrArtistId else {
                await arrived(r.id, Set(ids))
                continue
            }
            // A last check "in the future" (the clock went back) is due now.
            if let last = bringInChecks[r.id], (0..<Self.bringInCheckInterval).contains(now().timeIntervalSince(last)) {
                continue
            }
            bringInChecks[r.id] = now()
            guard let albums = try? await lidarr.albums(artistId: artistId) else { continue }
            lastLidarrContact = now()
            let done = ids.filter { id in
                guard let album = albums.first(where: { $0.id == id }) else { return true }
                return !album.monitored || (album.trackFileCount ?? 0) > 0
            }
            await arrived(r.id, Set(done))
        }
    }

    static let bringInCheckInterval: TimeInterval = 60

    // MARK: - Internals

    private struct MonitorBody: Encodable, Sendable {
        var albumIds: [Int]
        var monitored: Bool
    }

    private struct SearchBody: Encodable, Sendable {
        var name: String
        var albumIds: [Int]
    }

    /// Exactly the two fields the gate allows for following (A4: only what changes).
    private struct FollowBody: Encodable, Sendable {
        var artistIds: [Int]
        var monitorNewItems: String
    }

    private struct Target {
        var request: MagpieRequest
        var artist: LidarrArtist
        var albums: [LidarrAlbum]
        /// Albums an open ledger entry belongs to (a request still on its way): never touched here.
        var openAlbums: Set<Int>
        var mainRoot: String
    }

    /// The kept, moved find's artist and albums, after every precondition (see the type comment).
    private func bringInTarget(_ id: RequestID) async throws -> Target {
        guard !stopped, await load() else { throw BringInError.unavailable }
        guard let r = request(id), r.state == .kept, !r.keptInPlace, r.keep == nil, !r.keepNeedsAttention,
              let artistId = r.lidarrArtistId else { throw BringInError.notKept }
        guard await gate.enabled else { throw BringInError.changesOff }
        guard let setup = await keepSetup() else { throw BringInError.notSetUp }

        let entries: [LedgerEntry]
        do { entries = try await ledger.entries } catch { throw BringInError.unavailable }
        let artistEntries = entries.filter { $0.lidarrArtistId == artistId }
        guard artistEntries.contains(where: \.createdArtist), artistEntries.contains(where: { $0.keptAt != nil }) else {
            throw BringInError.notKept
        }
        let artist: LidarrArtist, albums: [LidarrAlbum]
        do {
            artist = try await lidarr.artist(id: artistId)
            albums = try await lidarr.albums(artistId: artistId)
        } catch LidarrError.http(status: 404) {
            throw BringInError.notKept
        } catch {
            throw BringInError.unavailable
        }
        lastLidarrContact = now()
        guard let expected = r.plan?.artistMBID, artist.foreignArtistId == expected,
              artistEntries.contains(where: { $0.created(artist) }),
              // Kept, said of this very artist (not of an earlier one under a reused id).
              artistEntries.contains(where: { $0.keptAt != nil && $0.created(artist) }) else { throw BringInError.notKept }
        let main = PathGuard(findsRoot: setup.mainRoot, otherRoots: [setup.findsRoot], caseInsensitive: false)
        guard !artist.tags.contains(setup.findTagId), let path = artist.path, main.isInside(path) else {
            throw BringInError.notKept
        }
        let open = Set(entries.filter { $0.isOpen && $0.lidarrArtistId == artistId }.compactMap(\.albumId))
        return Target(request: r, artist: artist, albums: albums.filter { $0.artistId == nil || $0.artistId == artistId },
                      openAlbums: open, mainRoot: setup.mainRoot)
    }

    /// Release groups of type Album (no secondary types: no live albums or compilations) the song is on, from
    /// MusicBrainz (A8; asked only on the owner's tap). Nil when it can't be told.
    private func songAlbumGroups(_ r: MagpieRequest) async -> Set<MBID>? {
        guard let recording = r.plan?.recordingMBID ?? r.recording.recordingMBID,
              let found = try? await mb.recording(recording) else { return nil }
        return Set(found.releases.map(\.releaseGroup).filter {
            $0.primaryType?.lowercased() == "album" && $0.secondaryTypes.isEmpty
        }.map(\.id))
    }

    /// What `choice` brings in from `albums` (pure). Nil: This album only, and the song's album isn't known.
    /// `types` (R18) narrows Everything to those release types.
    static func bringInOption(_ albums: [LidarrAlbum], choice: BringInChoice, songAlbums: Set<MBID>?,
                              skip: Set<Int>, limit: Int, types: ReleaseTypes? = nil) -> BringInOption? {
        let known = albums.filter { $0.foreignAlbumId != nil }
        let type = { (a: LidarrAlbum) in a.albumType?.lowercased() ?? "" }
        let candidates: [LidarrAlbum]
        var title: String?
        switch choice {
        case .albumsAndEPs:
            candidates = known.filter { ["album", "ep"].contains(type($0)) }
        case .everything:
            candidates = types.map { t in known.filter { t.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes) } }
                ?? known
        case .thisAlbum:
            // The earliest such album Lidarr lists (the original, not a later edition).
            guard let groups = songAlbums,
                  let album = known.filter({ type($0) == "album" && groups.contains($0.foreignAlbumId!) })
                    .min(by: { ($0.releaseDate ?? .distantFuture, $0.id) < ($1.releaseDate ?? .distantFuture, $1.id) })
            else { return nil }
            candidates = [album]
            title = album.title
        }
        let pending = candidates.filter { !$0.monitored && !skip.contains($0.id) }
            .sorted { ($0.releaseDate ?? .distantPast, $0.id) > ($1.releaseDate ?? .distantPast, $1.id) }
        let chosen = Array(pending.prefix(limit))
        let lengths = chosen.compactMap(\.duration)
        let duration = !chosen.isEmpty && lengths.count == chosen.count ? lengths.reduce(0, +) : nil
        return BringInOption(albumIds: chosen.map(\.id), available: pending.count, duration: duration, title: title)
    }

    /// R18: the artist's release types (Magpie's metadata profile for them, created through the gate if missing) and
    /// quality profile, each sent only when it differs, as exactly `{artistIds, metadataProfileId}` and
    /// `{artistIds, qualityProfileId}`. Throws `BringInError`; nothing after a failure is sent.
    private func applyProfiles(_ artist: LidarrArtist, types: ReleaseTypes?, qualityProfileId: Int?) async throws {
        do {
            if let types {
                let profile = try await Provisioner().ensureReleaseTypes(types, gate: gate, client: lidarr)
                if artist.metadataProfileId != profile {
                    _ = try await gate.send("PUT", "artist/editor",
                                            body: MetadataProfileBody(artistIds: [artist.id], metadataProfileId: profile))
                }
            }
            if let qualityProfileId, artist.qualityProfileId != qualityProfileId {
                _ = try await gate.send("PUT", "artist/editor",
                                        body: QualityProfileBody(artistIds: [artist.id], qualityProfileId: qualityProfileId))
            }
        } catch ProvisionError.conflict(let name) {
            throw BringInError.profileConflict(name)
        } catch let error as WriteGateError {
            throw Self.bringInError(error)
        } catch let error where Self.isDefinitiveRejection(error) || error is ProvisionError {
            throw BringInError.failed
        } catch {
            throw BringInError.unavailable
        }
    }

    private struct MetadataProfileBody: Encodable, Sendable {
        var artistIds: [Int]
        var metadataProfileId: Int
    }

    private struct QualityProfileBody: Encodable, Sendable {
        var artistIds: [Int]
        var qualityProfileId: Int
    }

    static func follows(_ artist: LidarrArtist) -> Bool {
        followingValues.contains(artist.monitorNewItems?.lowercased() ?? "")
    }

    /// M6: the albums go into the ledger as Magpie's (kept: Not for me never touches them, G3.4; closed: never
    /// inherited by a Cancel) and "may have landed" before the PUT; afterwards applied, or not sent when the gate
    /// or Lidarr refused it. A lost answer is checked with a GET: the albums it shows monitored are applied and
    /// returned (they get searched); the rest stay unclear. Returns the albums monitored now.
    private func monitor(_ albums: [LidarrAlbum], artist: LidarrArtist, root: String) async throws -> [LidarrAlbum] {
        let artistId = artist.id
        let at = now()
        var entries = albums.compactMap { album in
            album.foreignAlbumId.map {
                LedgerEntry(lidarrArtistId: artistId, albumId: album.id, rgMbid: $0, createdArtist: true,
                            wasMonitoredBefore: false, root: root, mode: .fallback, keptAt: at, send: .unclear,
                            closedAt: at, artistMbid: artist.foreignArtistId)
            }
        }
        do {
            for e in entries { try await ledger.record(e) }
        } catch {
            throw BringInError.unavailable   // not on disk: nothing is sent
        }
        func settle(_ send: (LedgerEntry) -> MonitorSend) async {
            for i in entries.indices {
                entries[i].send = send(entries[i])
                try? await ledger.record(entries[i])
            }
        }
        do {
            _ = try await gate.send("PUT", "album/monitor", body: MonitorBody(albumIds: albums.map(\.id), monitored: true))
        } catch let refusal as WriteGateError {
            await settle { _ in .notSent }
            throw Self.bringInError(refusal)
        } catch let error where Self.isDefinitiveRejection(error) {
            await settle { _ in .notSent }
            throw BringInError.failed
        } catch {
            guard let fresh = try? await lidarr.albums(artistId: artistId) else { throw BringInError.unconfirmed }
            let on = Set(fresh.filter(\.monitored).map(\.id))
            await settle { on.contains($0.albumId ?? -1) ? .applied : .unclear }
            let landed = albums.filter { on.contains($0.id) }
            guard !landed.isEmpty else { throw BringInError.failed }
            Log.logger("requests").error("Bring in more: answer lost; \(landed.count, privacy: .public) of \(albums.count, privacy: .public) monitored")
            return landed
        }
        await settle { _ in .applied }
        return albums
    }

    static func bringInError(_ error: Error) -> BringInError {
        switch error as? WriteGateError {
        case .disabled?: .changesOff
        case .logUnavailable?, .unconfirmed?: .unavailable
        default: .failed
        }
    }
}
