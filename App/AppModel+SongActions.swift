import AurralKit
import Foundation
import ListenBrainzKit
import MagpieCore
import NavidromeKit
import Observation
import Requests
import Search

/// Round 14 A3's words (design language §5, the round-11 glossary): about the music, never a service's name.
enum SongActionsCopy {
    static let listen = "Listen to the full song"
    static let listenSubtitle = "Goes into your Finds"
    static let listenSubtitleLibrary = "Goes into your library"
    static let addArtist = "Add artist"
    static let saveToPlaylist = "Save to playlist"
    static let justThisSong = "Just this song"
    static let wholeArtist = "Whole artist"
    static let choiceTitle = "Save to playlist"
    static let choiceMessage = "It joins the playlist when it\u{2019}s in your library."
    /// Decision 4: Just this song needs the fast single-song fetch (Tubifarry), which this server doesn't have.
    static let noJustThisSong = "Only the whole artist can be brought in from here. Saving one song needs a faster downloader set up on your server."
    static let unmatchedTitle = "Couldn\u{2019}t match this song"
    static let unmatchedMessage = "Magpie couldn\u{2019}t tell which recording this is, so nothing was asked for. Search for it instead."
    static let searchInstead = "Search instead"
    static let unmatchedArtist = "Couldn\u{2019}t match this artist"
    static let coming = "Coming"
    static let noPreview = "No preview available"
    static let couldntSave = "Couldn\u{2019}t save it this time. Try again in a moment."
    static func alreadyComing(_ playlist: String) -> String { "Already coming to \(playlist)" }
    static func alreadyIn(_ playlist: String) -> String { "Already in \(playlist)" }

    static func savedComing(_ playlist: String) -> String { "Coming \u{00B7} joins \(playlist) when it\u{2019}s here" }

    /// A "Coming" row's line.
    static func status(_ step: PendingAddStep, playlistGone: Bool) -> String {
        switch step {
        case .failed: playlistGone ? "That playlist can\u{2019}t take it any more" : "Couldn\u{2019}t bring it in"
        case .requestGone: "Couldn\u{2019}t bring it in"
        case .waiting(let state?): RequestCopy.status(state)
        case .waiting(nil), .lookUp: "Coming with the artist"
        case .keep: "Adding to your library\u{2026}"
        case .add: "Adding to the playlist\u{2026}"
        }
    }

    /// Owner answer 6: Settings may name the services; the row's note only when it fell back.
    static func topSongsNote(_ provider: TopSongsProvider) -> String {
        switch provider {
        case .aurral: "Popular now"
        case .listenBrainz: "from ListenBrainz"
        case .library: "from your library"
        }
    }

    static func sourceTitle(_ source: ArtistTopSongsSource) -> String {
        switch source {
        case .automatic: "Automatic"
        case .aurral: "Aurral"
        case .listenBrainz: "ListenBrainz"
        case .library: "Your library"
        }
    }

    static func sourceNote(_ source: ArtistTopSongsSource, aurral: Bool) -> String {
        switch source {
        case .automatic: aurral ? "Aurral first, then ListenBrainz, then your library." : "ListenBrainz first, then your library."
        case .aurral: "Popular songs now, all with previews."
        case .listenBrainz: "The most-listened songs worldwide."
        case .library: "Only songs you have. They play in full."
        }
    }
}

/// How a song from outside gets onto a playlist (Decision 4).
enum SaveChoice: Equatable, Sendable { case justThisSong, wholeArtist }

/// The Save to playlist picker, waiting for the owner's playlist.
struct SavePick: Identifiable {
    let id = UUID()
    let song: OutsideSong
    let choice: SaveChoice
}

/// Round 14 A3 (D100–D104): what the outside songs' ⋯ menus present, the pending playlist adds, and the previews known
/// this session. One per app (`AppModel.songActions`).
@MainActor @Observable final class SongActions {
    /// Listen to the full song: the existing Try sheet.
    var trying: TryTarget?
    /// Add artist: the existing Add (R18's sheet, or one confirmation with your defaults).
    let adder = DiscoverArtistAdder()
    /// Save to playlist, Whole artist: the Add, then the pending add.
    var wholeArtistAdd: AddFlowRequest?
    /// Fix round 1: Whole artist's Add, held until the playlist picker has finished closing (its `onDismiss`), so the
    /// Add is never presented during the picker's dismissal (SwiftUI drops it then).
    @ObservationIgnored var queuedAdd: AddFlowRequest?
    /// The Just this song / Whole artist question.
    var choosing: OutsideSong?
    var picking: SavePick?
    /// "Couldn't match this song", with Search instead.
    var unmatched: OutsideSong?
    /// Search instead: the query the Search tab takes (it clears it).
    var searchQuery: String?
    /// Songs being matched right now (their menus wait).
    private(set) var working: Set<String> = []

    /// The playlist adds waiting for their songs (D101), this Lidarr's.
    var pending: [PendingPlaylistAdd] = []
    @ObservationIgnored var store: PlaylistAddStore?
    @ObservationIgnored var loadedScope: String?
    @ObservationIgnored var evaluating = false
    /// Fix round 1 (M4): a check asked for while one runs; it runs next.
    @ObservationIgnored var evaluateAgain = false
    @ObservationIgnored var forceAgain = false
    /// Fix round 1 (I1): the current runner has published its requests at least once. Until then a request missing from
    /// the list means "not read yet", never "stopped"; nothing is checked.
    var requestsLoaded = false
    /// Fix round 1 (M3): how often Whole artist adds are checked even when nothing else happens, and how long one
    /// waits between two library lookups.
    @ObservationIgnored var checkEvery: Duration = .seconds(300)
    @ObservationIgnored var lookUpEvery: TimeInterval = 600
    @ObservationIgnored var timer: Task<Void, Never>?
    /// Finds this session already asked to keep (the runner proves each Keep again; never asked twice from here).
    @ObservationIgnored var keepAsked: Set<RequestID> = []
    /// Every Keep asked from here, in order (tests).
    @ObservationIgnored var keepAttempts: [RequestID] = []
    @ObservationIgnored var lookedUpAt: [UUID: Date] = [:]
    @ObservationIgnored var now: () -> Date = Date.init

    /// Each artist's previews read this session (by MBID), and the Discover playlist songs loaded (owner answer 7).
    var artistPreviews: [MBID: [AurralSong]] = [:]
    @ObservationIgnored var playlistSongs: [AurralSong] = []
    @ObservationIgnored var previewReads: [MBID: Task<[AurralSong], Never>] = [:]

    func begin(_ key: String) -> Bool {
        guard !working.contains(key) else { return false }
        working.insert(key)
        return true
    }

    func end(_ key: String) { working.remove(key) }
    func isWorking(_ song: OutsideSong) -> Bool { working.contains(Self.key(song)) }

    nonisolated static func key(_ song: OutsideSong) -> String {
        "\(SongIdentity.artistKey(song.artist))|\(SongIdentity.titleKey(song.title))|\(Int(song.duration ?? 0))"
    }

    /// Remembers a loaded Discover playlist's songs (their previews may match a ListenBrainz song).
    func remember(_ songs: [AurralSong]) {
        let fresh = songs.filter { $0.preview != nil }
        playlistSongs = Array((fresh + playlistSongs).prefix(2_000))
    }

    /// The picker has closed: Whole artist's Add, if one waits, now.
    func presentQueuedAdd() {
        guard let add = queuedAdd else { return }
        queuedAdd = nil
        wholeArtistAdd = add
    }

    func forget() {
        timer?.cancel(); timer = nil; queuedAdd = nil; requestsLoaded = false; evaluateAgain = false
        pending = []; store = nil; loadedScope = nil; keepAsked = []; lookedUpAt = [:]
        artistPreviews = [:]; playlistSongs = []; previewReads.values.forEach { $0.cancel() }; previewReads = [:]
        trying = nil; wholeArtistAdd = nil; choosing = nil; picking = nil; unmatched = nil
    }
}

extension AppModel {
    // MARK: - Availability (owner answer 9)

    /// The outside songs' ⋯ menu: only with Lidarr (Finds and Add need it). Navidrome only, or with Aurral alone: hidden.
    var outsideSongMenuAvailable: Bool { lidarr != nil && session != nil }

    /// Decision 4: "Just this song" only when the fast single-song fetch (Tubifarry) was detected.
    var justThisSongAvailable: Bool { lidarrStatus?.tubifarry == true }

    /// Listen to the full song's subtitle: Finds when they're set up (the request goes there), else the library.
    var listenSubtitle: String { triesGoIntoFinds ? SongActionsCopy.listenSubtitle : SongActionsCopy.listenSubtitleLibrary }

    // MARK: - Matching (D100)

    /// The server's editorial links, as the matcher takes them (nil without a server that has them).
    private var editorialLinks: OutsideSongMatch.Links? {
        guard let client = aurralClient, !isOffline, aurralCapabilities.editorialLinks else { return nil }
        return { artist, album, deezerAlbum in
            let links = try await client.editorialLinks(artist: artist, album: album, deezerAlbumId: deezerAlbum)
            return (links.artistMBID, links.albumMBID)
        }
    }

    /// The song's recording: its own MBID, else the editorial links and the album's tracklist (MusicBrainz).
    func resolveOutsideSong(_ song: OutsideSong) async throws -> ExternalRecording {
        let catalog = outsideCatalog
        let links = editorialLinks ?? { _, _, _ in throw OutsideSongMatch.Failure.unmatched }
        return try await OutsideSongMatch.resolve(song, links: links, release: { try await catalog.release(releaseGroup: $0) })
    }

    // MARK: - The menu's actions (owner answer 8, Decisions 1 and 4)

    /// Listen to the full song: the existing Find (Try) for the matched recording; unmatched: "Couldn't match this song".
    func listenToFullSong(_ song: OutsideSong) async {
        let key = SongActions.key(song)
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        do {
            let recording = try await resolveOutsideSong(song)
            songActions.trying = TryTarget(recording: recording)
        } catch {
            songActions.unmatched = song
        }
    }

    /// Add artist: the existing Add for the song's artist (its MBID from the song, else the editorial links, else
    /// Lidarr's search by exact name), never the server's own add.
    func addArtist(of song: OutsideSong) async {
        let key = SongActions.key(song) + "|artist"
        guard songActions.begin(key) else { return }
        defer { songActions.end(key) }
        let mbid = try? await OutsideSongMatch.artist(song, links: editorialLinks ?? { _, _, _ in (nil, nil) })
        songActions.adder.add(DiscoverArtist(name: song.artist, mbid: mbid), model: self)
    }

    /// Save to playlist: asks Just this song / Whole artist first.
    func askToSave(_ song: OutsideSong) {
        if isOffline { return libraryEdits.notify(Self.offlineCopy, symbol: "wifi.slash") }
        songActions.choosing = song
    }

    /// The choice is made: the playlist picker.
    func choose(_ choice: SaveChoice, for song: OutsideSong) {
        songActions.choosing = nil
        guard choice == .wholeArtist || justThisSongAvailable else { return }
        songActions.picking = SavePick(song: song, choice: choice)
    }

    /// The playlist is picked (an existing one, or a new one just made). Returns what to say when it didn't work.
    /// - Just this song: the Find for the matched recording, kept on arrival; the add waits for it (D101).
    /// - Whole artist: the Add with your defaults; the add waits for the song to arrive with the artist.
    @discardableResult
    func save(_ song: OutsideSong, choice: SaveChoice, to playlist: Playlist) async -> String? {
        guard canEdit(playlist) else { return PlaylistEditError.notYours.message }
        // Fix round 1 (M5): the same song for the same playlist is already coming, or already there.
        let asked = ExternalRecording(recordingMBID: song.recordingMBID, artistMBID: song.artistMBID, title: song.title,
                                      artist: song.artist, releaseTitle: song.album, duration: song.duration, source: .lidarr)
        if songActions.pending.contains(where: { $0.playlistId == playlist.id && Self.sameSong($0.recording, asked) }) {
            return SongActionsCopy.alreadyComing(playlist.name)
        }
        // A song the library has already goes straight on (no Find, no Add).
        if let copy = await libraryCopy(of: asked) {
            if let ids = try? await songIds(in: playlist), ids.contains(copy.id) { return SongActionsCopy.alreadyIn(playlist.name) }
            do { try await add([copy.id], to: playlist); return nil } catch { return PlaylistEditError.message(for: error) }
        }
        switch choice {
        case .justThisSong:
            guard justThisSongAvailable else { return SongActionsCopy.noJustThisSong }
            let recording: ExternalRecording
            do { recording = try await resolveOutsideSong(song) } catch {
                songActions.unmatched = song
                return SongActionsCopy.unmatchedTitle
            }
            do {
                let id = try await tryRecording(recording)
                await addPending(PendingPlaylistAdd(playlistId: playlist.id, playlistName: playlist.name,
                                                    recording: recording, requestId: id, createdAt: songActions.now()))
                return nil
            } catch {
                return TryCopy.message(for: error)
            }
        case .wholeArtist:
            // Only the artist's MBID is needed (the server's links); the song is then looked for by artist, title and
            // length when it lands. No MusicBrainz read for it.
            guard let mbid = try? await OutsideSongMatch.artist(song, links: editorialLinks ?? { _, _, _ in (nil, nil) }) else {
                return SongActionsCopy.unmatchedArtist
            }
            let pending = PendingPlaylistAdd(playlistId: playlist.id, playlistName: playlist.name, recording: asked,
                                             requestId: nil, createdAt: songActions.now())
            songActions.queuedAdd = addRequest(artist: song.artist,
                                               candidates: [ArtistLidarr.Candidate(mbid: mbid, name: song.artist)]) { [weak self] mbid, choices in
                guard let self else { throw ArtistLidarrError.failed }
                do {
                    _ = try await self.addArtist(mbid: mbid, choices: choices)
                } catch ArtistLidarrError.alreadyInLidarr {
                    // Already coming (or in): the add just waits for the song.
                }
                await self.addPending(pending)
            }
            return nil
        }
    }

    /// The same song for M5: the same recording MBID when both have one, else artist, title and length (3 s).
    nonisolated static func sameSong(_ a: ExternalRecording, _ b: ExternalRecording) -> Bool {
        if let x = a.recordingMBID, let y = b.recordingMBID { return x == y }
        return SongIdentity.same(title: a.title, artist: a.artist, duration: a.duration,
                                 as: b.title, artist: b.artist, duration: b.duration)
    }

    // MARK: - Pending playlist adds (Decision 5, D101)

    /// Follows the connected Lidarr's file (called when the runner is rebuilt), and checks Whole artist adds every
    /// `checkEvery` while there is one (fix round 1, M3: their songs land with no request moving).
    func followPendingAdds(instance: String?, restart: Bool = false) {
        guard songActions.loadedScope != instance || restart else { return }
        songActions.timer?.cancel()
        songActions.timer = nil
        songActions.pending = []
        songActions.keepAsked = []
        songActions.loadedScope = instance
        guard let instance else { songActions.store = nil; return }
        let store = PlaylistAddStore(fileURL: PlaylistAddStore.defaultURL(in: dataDirectory, instance: instance))
        songActions.store = store
        Task { [weak self] in
            let saved = (try? await store.load()) ?? []
            guard let self, self.songActions.store === store else { return }
            self.songActions.pending = saved + self.songActions.pending.filter { p in !saved.contains { $0.id == p.id } }
            await self.evaluatePendingAdds()
        }
        let every = songActions.checkEvery
        songActions.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, let self else { return }
                if self.songActions.pending.contains(where: { $0.requestId == nil && !$0.isFailed }) {
                    await self.evaluatePendingAdds()
                }
            }
        }
    }

    func addPending(_ add: PendingPlaylistAdd) async {
        songActions.pending.append(add)
        await savePending()
        libraryEdits.notify(SongActionsCopy.savedComing(add.playlistName), symbol: "clock")
        playlistsChanged(nil)
        await evaluatePendingAdds()
    }

    private func savePending() async {
        try? await songActions.store?.save(songActions.pending)
    }

    /// The pending adds for one playlist (its "Coming" rows), with what each is doing.
    func pendingAdds(for playlistId: String) -> [(add: PendingPlaylistAdd, step: PendingAddStep)] {
        songActions.pending.filter { $0.playlistId == playlistId }.map { add in (add, pendingStep(add)) }
    }

    /// The add's step; a missing request reads as waiting until the runner's list is in (fix round 1, I1).
    func pendingStep(_ add: PendingPlaylistAdd) -> PendingAddStep {
        let step = PendingPlaylistAdds.step(add, request: add.requestId.flatMap(magpieRequest), now: songActions.now())
        return step == .requestGone && !songActions.requestsLoaded ? .waiting(nil) : step
    }

    /// One pass over the pending adds: keep arrived finds, add arrived songs, look Whole artist songs up (every 10 min),
    /// mark the stopped ones. After each requests update, and when a playlist page opens.
    func evaluatePendingAdds(force: Bool = false) async {
        guard session != nil, !isOffline, !songActions.pending.isEmpty else { return }
        // Fix round 1 (M4): asked for while a pass runs: it runs next (one more pass, however many asks).
        guard !songActions.evaluating else {
            songActions.evaluateAgain = true
            songActions.forceAgain = songActions.forceAgain || force
            return
        }
        songActions.evaluating = true
        defer { songActions.evaluating = false }
        var force = force
        repeat {
            songActions.evaluateAgain = false
            await evaluatePass(force: force)
            force = songActions.forceAgain
            songActions.forceAgain = false
        } while songActions.evaluateAgain
    }

    private func evaluatePass(force: Bool) async {
        var dirty = false
        for add in songActions.pending {
            let now = songActions.now()
            switch PendingPlaylistAdds.step(add, request: add.requestId.flatMap(magpieRequest), now: now) {
            case .waiting, .requestGone:
                continue   // I1: a missing request is never saved as failed
            case .failed:
                if add.failedAt == nil { update(add.id) { $0.failedAt = now }; dirty = true }
            case .keep(let id):
                // I1: only on the current runner's list.
                guard songActions.requestsLoaded, !songActions.keepAsked.contains(id) else { continue }
                songActions.keepAsked.insert(id)
                songActions.keepAttempts.append(id)
                // The runner proves the Keep on fresh state. Not possible right now: asked again on a later pass; refused
                // (switched off, not set up): the row says so, with Retry.
                do { _ = try await keepFind(id) } catch RequestRunner.KeepError.unavailable {
                    songActions.keepAsked.remove(id)
                } catch {
                    if !(magpieRequest(id)?.collision ?? false) { update(add.id) { $0.failedAt = now }; dirty = true }
                }
            case .add(let songId):
                guard songActions.requestsLoaded else { continue }
                if await apply(add, songId: songId) { dirty = true }
            case .lookUp:
                if !force, let at = songActions.lookedUpAt[add.id], now.timeIntervalSince(at) < songActions.lookUpEvery { continue }
                songActions.lookedUpAt[add.id] = now
                if let song = await libraryCopy(of: add.recording), await apply(add, songId: song.id) { dirty = true }
            }
        }
        if dirty { await savePending() }
    }

    /// The library's song for a recording that came in by itself (Whole artist): MBID first, else artist, title and
    /// length within 3 s; never by name alone.
    func libraryCopy(of recording: ExternalRecording) async -> Song? {
        let byId = await librarySong(for: recording).map { [$0] } ?? []
        let hits = (try? await request { try await $0.search(recording.title, songCount: 20, albumCount: 0, artistCount: 0) })?.songs ?? []
        return PendingPlaylistAdds.librarySong(for: recording, mbidMatches: byId, textMatches: hits)
    }

    /// Adds the arrived song through the playlist write every other add uses (`add(_:to:)`: the owner's own playlist,
    /// read fresh, sent once). True when the list changed.
    private func apply(_ add: PendingPlaylistAdd, songId: String) async -> Bool {
        guard let playlist = try? await request({ try await $0.playlists() }).first(where: { $0.id == add.playlistId }) else {
            // Can't read the playlists now: next pass. Read, and it's gone: Remove only.
            if (try? await request({ try await $0.playlists() })) != nil {
                update(add.id) { $0.failedAt = songActions.now(); $0.playlistGone = true }
                return true
            }
            return false
        }
        // Sent before (a relaunch, a dropped answer): read first, never add twice. Fix round 1 (M1): a read that fails
        // sends nothing; the next pass reads again.
        if add.sendingSongId == songId {
            guard let ids = try? await songIds(in: playlist) else { return false }
            if ids.contains(songId) {
                songActions.pending.removeAll { $0.id == add.id }
                return true
            }
        }
        update(add.id) { $0.sendingSongId = songId }
        await savePending()
        do {
            try await self.add([songId], to: playlist)
            songActions.pending.removeAll { $0.id == add.id }
            return true
        } catch PlaylistEditError.notYours {
            update(add.id) { $0.failedAt = songActions.now(); $0.playlistGone = true }
            return true
        } catch {
            return false   // tried again on the next pass (read first)
        }
    }

    private func update(_ id: UUID, _ change: (inout PendingPlaylistAdd) -> Void) {
        guard let i = songActions.pending.firstIndex(where: { $0.id == id }) else { return }
        change(&songActions.pending[i])
    }

    /// Retry on a failed "Coming" row: the Find again (or the Keep again), or Whole artist's wait again.
    func retryPending(_ id: UUID) async {
        guard let add = songActions.pending.first(where: { $0.id == id }), add.playlistGone != true else { return }
        if let requestId = add.requestId, let r = magpieRequest(requestId), r.state == .ready, r.isFind {
            songActions.keepAsked.remove(requestId)
            update(id) { $0.failedAt = nil }
        } else if add.requestId != nil {
            guard let newId = try? await tryRecording(add.recording) else {
                return libraryEdits.notify(SongActionsCopy.couldntSave, symbol: "exclamationmark.circle")
            }
            update(id) { $0.requestId = newId; $0.failedAt = nil; $0.createdAt = songActions.now() }
        } else {
            update(id) { $0.failedAt = nil; $0.createdAt = songActions.now() }
            songActions.lookedUpAt[id] = nil
        }
        await savePending()
        await evaluatePendingAdds(force: true)
    }

    /// Remove on a "Coming" row: the add is dropped (a Find already on its way still comes, into your Finds).
    func removePending(_ id: UUID) async {
        songActions.pending.removeAll { $0.id == id }
        await savePending()
    }

    // MARK: - Previews for songs the server didn't list (owner answer 7, D103)

    /// The artist's previews, read once per session (nil MBID or no preview route: none).
    func artistPreviewSongs(_ mbid: MBID?, artistName: String) async -> [AurralSong] {
        guard let mbid, previewsAvailable, aurralCapabilities.artistPreview, let client = aurralClient else { return [] }
        if let known = songActions.artistPreviews[mbid] { return known }
        let task = songActions.previewReads[mbid] ?? Task { (try? await client.artistPreview(mbid, artistName: artistName)) ?? [] }
        songActions.previewReads[mbid] = task
        let songs = await task.value
        songActions.previewReads[mbid] = nil
        songActions.artistPreviews[mbid] = songs
        return songs
    }

    /// The preview for an outside song: itself when the server listed it; else the same song among the artist's top
    /// songs, the loaded charts and the loaded Discover playlists. Nil: "No preview available" (nothing guessed).
    func previewSong(for recording: ExternalRecording) async -> AurralSong? {
        guard previewsAvailable else { return nil }
        let artistSongs = await artistPreviewSongs(recording.artistMBID, artistName: recording.artist)
        var others = songActions.playlistSongs
        if let trending = aurralFeeds.trending { others += (trending.songs ?? []).map(\.song) }
        for chart in aurralFeeds.genreCharts.values { others += chart.map(\.song) }
        return PreviewMatch.find(title: recording.title, artist: recording.artist, duration: recording.duration,
                                 artistSongs: artistSongs, otherSongs: others)
    }
}
