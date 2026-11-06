import Foundation
import LidarrKit
import MagpieCore

/// Round 17 (owner, 2026-11-05): a song is brought in through Lidarr, one release at a time. When the release asked
/// for can't be found (Lidarr never lists it, or its search finished with nothing grabbed), the next release holding
/// the song is tried: the other releases MusicBrainz says hold the recording (single, then EP, then album), then the
/// artist's releases in Lidarr whose tracklist has a song of the same title. A find is first searched again with other
/// formats than MP3 allowed (`nothingFound`). Only when none is left does the request fail, whatever its speed; its
/// clean-up takes the album off and removes a find's artist that has nothing else in Finds (`removeStoppedFindArtist`).
extension RequestRunner {
    /// The most of the artist's other releases whose tracklists are read in one look for the song's title.
    static let titleMatchLimit = 12

    /// Moves the request on to the next release holding the song, or applies `otherwise` when there is none (or it
    /// isn't searching or waiting, or the owner asked for one album). Letting go of the release just tried can't be
    /// done right now (Lidarr or the ledger unreadable): nothing changes, and a later pass asks again.
    func nextRelease(_ id: RequestID, otherwise: RequestEvent) async {
        guard let r = request(id) else { return }
        switch r.state {
        case .searching, .waiting: break
        default: return await apply(id, otherwise)
        }
        guard r.albumTarget == nil, let plan = r.plan, let next = await nextCandidate(r) else {
            return await apply(id, otherwise)
        }
        do {
            try await letGoOfTried(r)
        } catch {
            Log.logger("requests").error("next release postponed: \(Log.category(of: error), privacy: .public)")
            return
        }
        guard let current = request(id), current.state == r.state, current.plan == plan else { return }   // moved on
        var newPlan = plan
        newPlan.releaseGroupMBID = next.releaseGroup
        if let recording = next.recording { newPlan.recordingMBID = recording }
        newPlan.lidarrArtistId = r.lidarrArtistId ?? plan.lidarrArtistId
        await mutate(id) {
            $0.releasesTried = ($0.releasesTried ?? []) + [plan.releaseGroupMBID]
            $0.releaseAlternates = ($0.releaseAlternates ?? []).filter { $0 != next.releaseGroup }
            $0.plan = newPlan
            // The artist is in Lidarr now: the next release is monitored on it, never added again.
            $0.addSent = false
            $0.joinedTo = nil
            $0.albumId = nil
            $0.albumSeen = nil
            $0.skipNextSearch = false
            $0.searchStartedAt = nil
            $0.searchStartedAtServer = nil
            $0.searchCommandId = nil
            $0.grabbed = false
            $0.failureSeenAt = nil
            $0.note = nil
            if let title = next.title, !title.isEmpty { $0.albumTitle = title }
        }
        await apply(id, .nextRelease(newPlan))
    }

    struct NextRelease: Equatable {
        var releaseGroup: MBID
        /// The track's recording when it was matched by title (another recording of the song).
        var recording: MBID?
        var title: String?
    }

    /// The next release to try: the first untried alternate (only ones Lidarr lists, once its listing of the artist
    /// is final), else a release in Lidarr whose tracklist has the song's title.
    func nextCandidate(_ r: MagpieRequest) async -> NextRelease? {
        let tried = Set((r.releasesTried ?? []) + [r.plan?.releaseGroupMBID].compactMap { $0 })
        var albums: [LidarrAlbum]?
        if let artistId = r.lidarrArtistId {
            albums = try? await lidarr.albums(artistId: artistId)
            if albums != nil { lastLidarrContact = now() }
        }
        // Right after Magpie's add the listing may still grow (Lidarr's refresh): an unlisted alternate isn't ruled out.
        let listingFinal = albums != nil && (!r.addSent || r.addRefreshDone == true)
        let alternates = (r.releaseAlternates ?? []).filter { !tried.contains($0) }
        if let rg = alternates.first(where: { rg in !listingFinal || albums?.contains { $0.foreignAlbumId == rg } == true }) {
            return NextRelease(releaseGroup: rg, title: albums?.first { $0.foreignAlbumId == rg }?.title)
        }
        guard let albums else { return nil }
        let key = SongIdentity.titleKey(r.recording.title)
        guard !key.isEmpty else { return nil }
        for album in Self.titleMatchOrder(albums, excluding: tried).prefix(Self.titleMatchLimit) {
            guard let rg = album.foreignAlbumId, let tracks = try? await lidarr.tracks(albumId: album.id) else { continue }
            if let track = tracks.first(where: { $0.title.map(SongIdentity.titleKey) == key }) {
                return NextRelease(releaseGroup: rg, recording: track.foreignRecordingId.flatMap(MBID.init), title: album.title)
            }
        }
        return nil
    }

    /// The artist's studio singles, EPs and albums in Lidarr not tried yet, smallest first, then oldest.
    static func titleMatchOrder(_ albums: [LidarrAlbum], excluding tried: Set<MBID>) -> [LidarrAlbum] {
        func rank(_ a: LidarrAlbum) -> Int {
            switch a.albumType?.lowercased() {
            case "single": 0
            case "ep": 1
            case "album": 2
            default: 3
            }
        }
        return albums
            .filter { a in a.foreignAlbumId.map { !tried.contains($0) } == true && a.secondaryTypes.isEmpty && rank(a) < 3 }
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : (a.releaseDate ?? .distantFuture) < (b.releaseDate ?? .distantFuture)
            }
    }

    /// Lets go of the release just tried, as clean-up does: Magpie's own monitor of it comes off (never the owner's, a
    /// kept one, or one another live request still relies on) and its ledger entry closes.
    private func letGoOfTried(_ r: MagpieRequest) async throws {
        guard let rg = r.plan?.releaseGroupMBID, let albumId = r.albumId, let artistId = r.lidarrArtistId else { return }
        let shared = list.contains { other in
            other.id != r.id && other.plan?.releaseGroupMBID == rg
                && (other.isActive || other.state == .ready || other.state == .kept)
        }
        if shared { return }
        guard let entry = try await ledger.entry(albumId: albumId) else { return }
        if entry.isOpen, entry.isApplied, !entry.wasMonitoredBefore, !entry.isKeptOrKeeping {
            let albums = try await lidarr.albums(artistId: artistId)
            if let album = albums.first(where: { $0.id == albumId }), album.monitored {
                try await persist()
                _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: false))
            }
        }
        if entry.isOpen {
            var closed = entry
            closed.closedAt = now()
            try await ledger.record(closed)
        }
    }

    /// A release's search finished with nothing grabbed. A find still on MP3 only is searched again with other formats
    /// allowed (`widenFormats`); otherwise the next release holding the song, and with none left the request fails.
    func nothingFound(_ id: RequestID) async {
        guard let r = request(id) else { return }
        if r.isFind, r.anyFormat == nil, let artistId = r.lidarrArtistId {
            do {
                try await widenFormats(artistId)
            } catch let e as WriteGateError where e == .disabled || e == .logUnavailable || e == .unconfirmed {
                return   // changes off or unchecked: a later pass asks again
            } catch let e as LidarrError where !Self.isDefinitiveRejection(e) {
                return   // Lidarr unreachable: the same
            } catch {
                // Refused, or a same-named profile set up differently: go on with the next release in MP3.
                Log.logger("requests").error("other formats not allowed: \(Log.category(of: error), privacy: .public)")
                await mutate(id) { $0.anyFormat = false }
                return await nextRelease(id, otherwise: .error(.notFoundYet))
            }
            guard request(id)?.state == r.state else { return }
            await mutate(id) { $0.anyFormat = true }
            return await apply(id, .searchAgain)
        }
        await nextRelease(id, otherwise: .error(.notFoundYet))
    }

    private struct QualityProfileBody: Encodable, Sendable {
        var artistIds: [Int]
        var qualityProfileId: Int
    }

    /// The find's artist (Magpie created it; the gate checks) moves to "Magpie Finds Any Format", made if missing:
    /// its MP3s stay the first choice, other formats come when there is no MP3. Its later releases keep it.
    private func widenFormats(_ artistId: Int) async throws {
        let artist = try await lidarr.artist(id: artistId)
        lastLidarrContact = now()
        let profileId = try await Provisioner().ensureAnyFormat(gate: gate, client: lidarr)
        guard artist.qualityProfileId != profileId else { return }
        try await persist()
        _ = try await gate.send("PUT", "artist/editor", body: QualityProfileBody(artistIds: [artistId], qualityProfileId: profileId))
    }
}
