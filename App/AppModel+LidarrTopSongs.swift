import AurralKit
import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex
import NavidromeKit
import Requests
import Search

/// One top song as a source gave it (D258): Aurral's and ListenBrainz's are resolved to a library song; Navidrome's are
/// library songs already.
enum LidarrTopSongCandidate: Sendable {
    case aurral(AurralSong)
    case listenBrainz(ExternalRecording)
    case library(Song)
}

/// Round 26 K2 (owner, 2026-11-10: "When a user opens the artist and if that artist is in Lidarr, then Magpie should
/// check Aurral, then Listenbrainz, then Navidrome for top songs … This list should be saved … When the artist is
/// opened up again, in the background it should refresh the top songs and present the updated list when it is
/// complete."; D263–D268): the artist pages' Top songs for an artist Lidarr has. The reads (each bounded), K1's merge and
/// resolvers (`LidarrTopSongs`), the saved list and the session's refresh gap. Reads only: no write, no new route, no
/// MusicBrainz.
extension AppModel {
    /// The longest each source (and Lidarr's answer for the artist) is waited for (D262).
    nonisolated static let lidarrTopSongsWait: Duration = .seconds(10)
    /// The longest a search for a song too new for the match index is waited for.
    nonisolated static let lidarrTopSongsSearchWait: Duration = .seconds(5)
    /// At most one refresh per artist this often in a session, unless pulled (D264).
    nonisolated static let lidarrTopSongsRefreshGap: TimeInterval = 120
    /// At most this many `getSong` reads and this many searches per refresh.
    nonisolated static let lidarrTopSongsFetches = 5
    nonisolated static let lidarrTopSongsSearches = 5

    /// The page model for an artist page's Top songs, with the saved list as it may show now; nil without Lidarr set up
    /// (no saved list is ever shown then, D263) or without a key. Online, songs the match index no longer holds are
    /// left out (only when the index is built and non-empty); offline (D268), only the songs on the phone.
    func lidarrTopSongs(name: String, mbid: MBID?, artistId: String?) async -> LidarrTopSongsModel? {
        guard lidarr != nil, let key = LidarrTopSongsCache.key(mbid: mbid, artistId: artistId) else { return nil }
        let cache = navidromeScope.map { LidarrTopSongsCache(root: dataDirectory, scope: $0) }
        var saved: [Song]
        if isOffline {
            let rows = mbid == nil ? artistId.flatMap { cache?.load(offlineArtistId: $0) } : cache?.load(key)
            let onPhone = Set(await offlineCatalog.songs().map(\.id))
            saved = (rows ?? []).map(\.song).filter { onPhone.contains($0.id) }
        } else {
            saved = (cache?.load(key) ?? []).map(\.song)
            if let index = await matchIndex?.index, index.count > 0 {
                saved = saved.filter { index.contains(songId: $0.id) }
            }
        }
        return LidarrTopSongsModel(app: self, key: key, name: name, mbid: mbid, offline: isOffline, cache: cache,
                                   saved: saved)
    }

    /// Lidarr's answer for the page's artist, waited for at most `lidarrTopSongsWait`. The read itself goes on (the page's
    /// Lidarr line shows when it comes); only the Top songs stop waiting. A cancelled page cancels it.
    func waitForLidarrTopSongsAnswer(_ read: @escaping @MainActor () async -> LidarrTopSongsModel.LidarrAnswer) async
        -> LidarrTopSongsModel.LidarrAnswer {
        let task = Task { @MainActor in await read() }
        let sleep = lidarrTopSongsSession.sleep(for: .lidarrAnswer)
        return await withTaskCancellationHandler {
            switch await Deadline.run(Self.lidarrTopSongsWait, sleep: sleep, { await task.value }) {
            case .success(let answer): answer
            case .failure: .unread
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Whether the artist's list may be refreshed now (two minutes since the last refresh this session).
    func lidarrTopSongsMayRefresh(_ key: String) -> Bool {
        guard let at = lidarrTopSongsSession.refreshedAt[key] else { return true }
        return lidarrTopSongsSession.now().timeIntervalSince(at) >= Self.lidarrTopSongsRefreshGap
    }

    func noteLidarrTopSongsRefreshed(_ key: String) {
        lidarrTopSongsSession.refreshedAt[key] = lidarrTopSongsSession.now()
    }

    /// Sign-out (D263): every account's saved Top songs, and this session's reads.
    func forgetLidarrTopSongs() {
        LidarrTopSongsCache.removeAll(root: dataDirectory)
        lidarrTopSongsSession.forget()
    }

    // MARK: - The sources this setup has (Settings' footer, D266)

    /// Aurral is one of the sources (set up, with its artist-preview capability, and reachable without asking consent).
    /// Fix round 1 (M4, design M5): the one predicate for Settings' footer and the refresh, so they never disagree.
    var lidarrTopSongsUsesAurral: Bool { aurralSetUp && aurralCapabilities.artistPreview && aurralClient != nil }

    /// The set-up sources in the fixed order, as Settings names them.
    var lidarrTopSongsSourceNames: [String] {
        (lidarrTopSongsUsesAurral ? ["Aurral"] : []) + (hasListenBrainzToken ? ["ListenBrainz"] : []) + ["your library"]
    }

    // MARK: - The refresh (D262, D264)

    /// Reads Aurral, ListenBrainz and Navidrome in parallel (and Lidarr's albums and tracks when Aurral or ListenBrainz
    /// can answer), each under `lidarrTopSongsWait`, then K1's merge with its resolvers: the match index's ladder, else
    /// the album step through Lidarr; a linked song is fetched (`getSong`, at most `lidarrTopSongsFetches`) and must pass
    /// `LidarrTopSongs.confirms` before it shows; a track the index can't link is searched for (at most
    /// `lidarrTopSongsSearches`, `lidarrTopSongsSearchWait` each) and must pass the same rule. `fresh` (pull to refresh)
    /// asks Aurral again; otherwise its answer this session is used (a failure is never kept).
    func readLidarrTopSongs(name: String, mbid: MBID?, lidarrArtistId: Int, fresh: Bool) async -> LidarrTopSongs.Result {
        let aurralOn = mbid != nil && !isOffline && lidarrTopSongsUsesAurral
        let listenBrainzOn = mbid != nil && hasListenBrainzToken
        async let aurral = readAurralTopSongs(mbid: aurralOn ? mbid : nil, name: name, fresh: fresh)
        async let listenBrainz = readListenBrainzTopSongs(mbid: listenBrainzOn ? mbid : nil)
        async let library = readLibraryTopSongs(name: name)
        async let reads = readLidarrTracks(artistId: aurralOn || listenBrainzOn ? lidarrArtistId : nil)
        let sources = LidarrTopSongs.Sources(aurral: await aurral, listenBrainz: await listenBrainz, library: await library)
        let lidarr = await reads
        guard !Task.isCancelled else { return LidarrTopSongs.Result(rows: [], complete: false) }

        let index = await matchIndex?.index ?? .empty
        let discover = knownAurralSongIds
        var resolver = TopSongResolver(app: self, name: name, mbid: mbid, index: index, lidarr: lidarr,
                                       avoiding: { discover.contains($0) })
        if case .answered(let candidates) = sources.library {
            for case .library(let song) in candidates { resolver.held[song.id] = song }
        }
        return await LidarrTopSongs.merge(sources: sources, discoverLibraries: discoverLibraryIds) { _, candidate in
            switch candidate {
            case .library(let song): return .song(song)   // Navidrome's top songs are library songs already (D259)
            case .aurral(let song):
                return await resolver.resolve(LidarrTopSongs.recording(aurral: song, artistName: name, artistMBID: mbid))
            case .listenBrainz(let recording): return await resolver.resolve(recording)
            }
        }
    }

    private func readAurralTopSongs(mbid: MBID?, name: String, fresh: Bool) async
        -> LidarrTopSongs.Answer<LidarrTopSongCandidate> {
        guard let mbid, let client = aurralClient else { return .unavailable }
        let scope = navidromeScope
        if !fresh, let known = lidarrTopSongsSession.aurral[mbid] {
            return .answered(known.map(LidarrTopSongCandidate.aurral))
        }
        switch await Deadline.run(Self.lidarrTopSongsWait, sleep: lidarrTopSongsSession.sleep(for: .aurral), {
            try await client.artistPreview(mbid, artistName: name)
        }) {
        case .success(let songs):
            // Only an answer is kept for the session, and only for the account that asked (fix round 1, I2).
            if navidromeScope == scope, lidarr != nil { lidarrTopSongsSession.aurral[mbid] = songs }
            return .answered(songs.map(LidarrTopSongCandidate.aurral))
        case .failure:
            return .failed
        }
    }

    private func readListenBrainzTopSongs(mbid: MBID?) async -> LidarrTopSongs.Answer<LidarrTopSongCandidate> {
        guard let mbid else { return .unavailable }
        let client = ListenBrainzClient(transport: transport, token: tokenStore.load(), limiter: listenBrainzLimiter)
        let depth = LidarrTopSongs.readDepth(.listenBrainz)
        switch await Deadline.run(Self.lidarrTopSongsWait, sleep: lidarrTopSongsSession.sleep(for: .listenBrainz), {
            try await client.topRecordingsForArtist(mbid, limit: depth)
        }) {
        case .success(let recordings): return .answered(recordings.map(LidarrTopSongCandidate.listenBrainz))
        case .failure: return .failed
        }
    }

    private func readLibraryTopSongs(name: String) async -> LidarrTopSongs.Answer<LidarrTopSongCandidate> {
        switch await Deadline.run(Self.lidarrTopSongsWait, sleep: lidarrTopSongsSession.sleep(for: .library), { @MainActor in
            try await self.request { try await $0.topSongs(artistName: name) }
        }) {
        case .success(let songs): return .answered(songs.map(LidarrTopSongCandidate.library))
        case .failure: return .failed
        }
    }

    /// Lidarr's albums and tracks of the artist, both read or `.failed`. Not read (nil id) when neither Aurral nor
    /// ListenBrainz can answer: then nothing needs the album step.
    private func readLidarrTracks(artistId: Int?) async -> LidarrTopSongs.LidarrReads {
        guard let artistId, let client = lidarrClient else { return .failed }
        let sleep = lidarrTopSongsSession.sleep(for: .lidarrReads)
        let wait = Self.lidarrTopSongsWait
        async let albums = Deadline.run(wait, sleep: sleep) { try await client.albums(artistId: artistId) }
        async let tracks = Deadline.run(wait, sleep: sleep) { try await client.tracks(artistId: artistId) }
        guard case .success(let a) = await albums, case .success(let t) = await tracks else { return .failed }
        return .read(albums: a, tracks: t)
    }
}

/// Resolves an Aurral or ListenBrainz top song to a library song for one refresh (D259, D260), with its read budgets.
@MainActor private struct TopSongResolver {
    let app: AppModel
    let name: String
    let mbid: MBID?
    let index: MatchIndex
    let lidarr: LidarrTopSongs.LidarrReads
    let avoiding: (String) -> Bool
    /// Full songs already held (Navidrome's top songs): no `getSong` for them.
    var held: [String: Song] = [:]
    /// Ids already looked at: a second source naming the same song never costs another read (the merge places it once).
    var seen = Set<String>()
    var fetches = 0
    var searches = 0

    init(app: AppModel, name: String, mbid: MBID?, index: MatchIndex, lidarr: LidarrTopSongs.LidarrReads,
         avoiding: @escaping (String) -> Bool) {
        self.app = app; self.name = name; self.mbid = mbid; self.index = index; self.lidarr = lidarr
        self.avoiding = avoiding
    }

    mutating func resolve(_ recording: ExternalRecording) async -> LidarrTopSongs.Resolution {
        let link = LidarrTopSongs.link(recording, artistName: name, artistMBID: mbid, index: index, lidarr: lidarr,
                                       avoiding: avoiding)
        switch link {
        case .none: return .notInLibrary
        case .lidarrUnread: return .lidarrUnread
        case .song(let id), .albumSong(let id, _, _):
            guard seen.insert(id).inserted else { return .notInLibrary }
            let song: Song
            if let known = held[id] {
                song = known
            } else {
                guard fetches < AppModel.lidarrTopSongsFetches else { return .notInLibrary }
                fetches += 1
                let app = app
                let sleep = app.lidarrTopSongsSession.sleep(for: .song)
                switch await Deadline.run(AppModel.lidarrTopSongsWait, sleep: sleep, { @MainActor in
                    try await app.request { try await $0.song(id: id) }
                }) {
                case .success(let fetched): song = fetched
                case .failure(let error):
                    // Gone since the index was built: skipped. The server didn't answer: skipped, and the list is
                    // incomplete (the merge's one "couldn't read" case), so a blip never replaces a saved list.
                    if case .api(code: 70, _)? = error as? NavidromeError { return .notInLibrary }
                    return .lidarrUnread
                }
            }
            // Fix round 1 (I1, ruling C1): a direct-ladder match must also have the top song's strict title (the ladder's
            // `Normalize` folds "(Reprise)" and the like). For top songs only: the ladder itself is unchanged.
            if case .song = link {
                let key = TopSongIdentity.titleKey(recording.title)
                guard !key.isEmpty, TopSongIdentity.titleKey(song.title) == key else { return .notInLibrary }
            }
            // K1 I2 (controller ruling): the shown song must pass the strict rule on its full title.
            return LidarrTopSongs.confirms(song, link, artistName: name, artistMBID: mbid) ? .song(song) : .notInLibrary
        case .track(let track, _):
            let title = track.title ?? ""
            guard !title.isEmpty, searches < AppModel.lidarrTopSongsSearches else { return .notInLibrary }
            searches += 1
            let (app, query) = (app, "\(name) \(title)")
            let sleep = app.lidarrTopSongsSession.sleep(for: .search)
            let found = await Deadline.run(AppModel.lidarrTopSongsSearchWait, sleep: sleep, { @MainActor in
                try await app.request { try await $0.search(query, songCount: 20, albumCount: 0, artistCount: 0) }
            })
            // A song too new for the index that the search doesn't find (or a slow search) is skipped; the next refresh
            // finds it through the index.
            guard case .success(let result) = found else { return .notInLibrary }
            let hits = result.songs.filter {
                !avoiding($0.id) && LidarrTopSongs.confirms($0, link, artistName: name, artistMBID: mbid)
            }
            guard hits.count == 1, let hit = hits.first, seen.insert(hit.id).inserted else { return .notInLibrary }
            return .song(hit)
        }
    }
}
