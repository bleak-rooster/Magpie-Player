import Foundation
#if canImport(CarPlay)
import CarPlayUI
import MagpieCore
import Playback

/// Home and Library as the car shows them (spec §3, Task 22): the phone's layout and the phone's shelves, so the two
/// never disagree. Task 23: Genres, Favourites, Downloads and Made for you, offline, and (Y2) the favourite star, each
/// the phone's own. Offline, every read here is the phone's and nothing is asked of the server.
extension CarPlayLibraryAdapter {
    /// The car's Home sections (round 13: Settings › CarPlay › Home, the phone's Home until changed there; Made for you
    /// with a token, Discover with Aurral, as on the phone). Offline (round 28 O4, D347): Downloaded, Discover's flows on
    /// the phone and Playlists, in the car's order.
    var homeSections: [HomeSection] {
        model.preferences.carPlay.visibleHomeSections(phone: model.preferences.layout, offline: model.isOffline,
                                                      hasListenBrainzToken: model.hasListenBrainzToken,
                                                      discoverSetUp: model.aurralSetUp)
    }

    /// The phone's Library rows without Requests; offline, the phone's offline rows (round 28 O4, D347: each opens from
    /// what's on the phone). Round 27 H (D300): with Flows with your playlists on, no Discover row (its playlists are in
    /// Playlists).
    var libraryRows: [LibraryRow] {
        let rows = model.libraryRows(carPlay: true)
        return model.carFlowsWithPlaylists ? rows.filter { $0 != .discover } : rows
    }

    /// Round 24 (D223's rule, D179): while Playlists show All, the signed-in user, so the car's rows say whose the
    /// others' playlists are; nil for Yours. Round 27 H (D299, D300): with Flows with your playlists on, in Yours too,
    /// so another user's flow there says whose (Yours' own playlists name nobody either way).
    var playlistCaptionUser: String? {
        guard model.playlistShow == .all || model.carFlowsWithPlaylists, let user = model.session?.username, !user.isEmpty
        else { return nil }
        return user
    }

    // MARK: - Round 27 H: flows by last played, and whose (D297, D299)

    /// D300: Flows with your playlists as it applies now (with Aurral set up); a change rebuilds the car's tabs.
    var flowsWithPlaylists: Bool { model.carFlowsWithPlaylists }

    /// A play started from a playlist's page in the car: kept when it is a flow (`noteFlowPlayed`).
    func notePlaylistPlayed(id: String) { model.noteFlowPlayed(playlistId: id) }

    /// Another user's flow's Aurral username while everyone's show (D205's caption); nil otherwise.
    func discoverOwnerCaption(playlistId: String) -> String? { model.homeFlowCaption(playlistId: playlistId) }

    /// The phone's shelves (offline, nothing is asked of the server), each cut to `size`, with Made for you's from its
    /// own shelf (read first when it is empty, as the phone's Home does). A downloaded album is an album here; the
    /// car's Downloaded shelf opens it from the phone.
    func homeShelves(_ sections: [HomeSection], size: Int) async throws -> [CPHomeShelf] {
        let model = model
        // Read once per token: an empty answer isn't asked for again on every reload (a new token asks again).
        // Round 28 O4 (D347): offline the phone's own shelves, built here from what's on it.
        if model.isOffline { return await offlineHomeShelves(sections, size: size) }
        let generation = model.listenBrainzTokenGeneration
        let readsMadeForYou = sections.contains(.madeForYou) && model.hasListenBrainzToken && !model.isOffline
            && model.madeForYouShelf.isEmpty && madeForYouReadGeneration != generation
        if readsMadeForYou { madeForYouReadGeneration = generation }
        async let refreshed: Void = refreshMadeForYou(if: readsMadeForYou)
        // Round 27 H (D297): Discover's shelf is the car's own, by last played, whatever the phone's Home order. Fix
        // round 1 (I1): read alongside the other shelves, so a slow Aurral never holds them up. Each answer is awaited
        // into its own constant (B1/D120's shape: never a `.success(try await …)` built inline).
        async let discoverRead = carDiscoverShelf(if: sections.contains(.discover))
        let others: Result<[HomeShelf], any Error>
        do {
            let read = try await model.homeShelves(for: sections.filter { $0 != .discover })
            others = .success(read)
        } catch {
            others = .failure(error)
        }
        let flows = await discoverRead
        let shelves: [HomeShelf]
        switch others {
        case .success(let read):
            shelves = read
        case .failure(let error):
            // Every other section failed: still a Home while Discover's shelf read, as when it was one of them.
            // A read cut short stays cut short (P5): never an empty Home in its place.
            guard case .success? = flows, !AppModel.isCancellation(error) else { await refreshed; throw error }
            shelves = []
        }
        // Discover was the only section asking the server, and it failed: the read failed (as before round 27).
        if case .failure(let error)? = flows,
           !sections.contains(where: { $0 != .discover && $0 != .downloaded && $0.readsShelf }) {
            await refreshed
            throw error
        }
        await refreshed
        let count = max(0, size)
        let madeForYou = model.isOffline ? [] : model.madeForYouShelf.prefix(count).map {
            CPHomeShelf.Item.madeForYou(id: $0.id.rawValue, title: $0.title)
        }
        return sections.compactMap { section -> CPHomeShelf? in
            if section == .madeForYou {
                return madeForYou.isEmpty ? nil : CPHomeShelf(section: section, items: madeForYou)
            }
            if section == .discover {   // round 27 H (D297, D299)
                guard case .success(let read)? = flows else { return nil }
                let shown = Array(read.prefix(count))
                guard !shown.isEmpty else { return nil }
                let captions = Dictionary(shown.compactMap { p in model.homeFlowCaption(playlistId: p.id).map { (p.id, $0) } },
                                          uniquingKeysWith: { first, _ in first })
                return CPHomeShelf(section: section, items: shown.map(CPHomeShelf.Item.playlist), captions: captions)
            }
            guard let shelf = shelves.first(where: { $0.section == section }) else { return nil }
            return CPHomeShelf(section: section, items: shelf.items.prefix(count).compactMap { item -> CPHomeShelf.Item? in
                switch item {
                case .album(let album), .downloadedAlbum(let album): .album(album)
                case .playlist(let playlist): .playlist(playlist)
                case .genreGroup(let group): .genreGroup(id: group.group.id, name: group.group.name, albumCount: group.albumCount)
                case .outside: nil   // round 14: the car has no provided shelves (not a car section)
                }
            })
        }
    }

    private func refreshMadeForYou(if needed: Bool) async {
        if needed { await model.refreshMadeForYou() }
    }

    /// Round 27 H (D297): the car's Discover home shelf, played newest first then A to Z; nil when not shown. Offline
    /// nothing is asked (Discover isn't a Home section offline).
    private func carDiscoverShelf(if wanted: Bool) async -> Result<[Playlist], any Error>? {
        guard wanted, !model.isOffline else { return nil }
        do {
            let flows = try await model.carDiscoverFlows()   // B1 (D120): into a constant first
            return .success(flows)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Offline and Now Playing's star

    var isOffline: Bool { model.isOffline }

    /// Y2 (2b): the phone's favourite state for the song (the queue's copy until a page or a change says otherwise).
    func isFavourite(songId: String) -> Bool { model.isFavourite(.song(songId)) }

    /// Through the phone's favourites (X3), which change at once and roll back to the real state on a refusal. Offline
    /// nothing is sent. Whether it went through is read back from the phone's state afterwards.
    func setFavourite(songId: String, _ on: Bool) async -> CPFavouriteResult {
        if model.isOffline { return .offline }
        await model.setFavourite(.song(songId), on)
        return model.isFavourite(.song(songId)) == on ? .done : .failed(adding: on)
    }

    // MARK: - Albums A–Z (Y2)

    func albumsAZ(offset: Int, size: Int) async throws -> [Album] {
        // Offline the phone's albums all come at once (M6: one catalog read; the car sorts them).
        if model.isOffline { return offset == 0 ? await model.offlineCatalog.albums() : [] }
        return try await model.request { try await $0.albumList(.alphabeticalByName, size: size, offset: offset) }
    }

    // MARK: - Genres (D41)

    func genreGroups() async throws -> [(id: String, name: String, albumCount: Int)] {
        try await model.genreSections().map { (id: $0.group.id, name: $0.group.name, albumCount: $0.albumCount) }
    }

    func genreSubgenres(_ groupId: String) async throws -> [Genre] {
        try await model.genreGroup(groupId)?.genres ?? []
    }

    /// A genre's songs in server order; a group's taken from each of its genres in turn, capped. Unshuffled: the
    /// controller's `start` owns shuffling.
    func songs(for request: CPPlayRequest) async throws -> [Song] {
        switch request {
        case .genre(let name, _):
            return try await model.genreSongs(name)
        case .genreGroup(let id, _):
            return try await model.groupSongsInFetchOrder(model.genreGroup(id)?.genres ?? [])
        default:
            return []
        }
    }

    // MARK: - Downloads (what's on the phone)

    func downloadedAlbums() async -> [Album] { await model.offlineCatalog.albums() }

    func downloadedArtists() async -> [Artist] { await model.offlineCatalog.artists() }

    func downloadedPlaylists() async -> [Playlist] { await model.offlineCatalog.playlists() }

    /// Round 28 O4 (D347): the album page on the phone (O2): its songs on the phone, in the server's order where it
    /// was read online, with `songCount` the album's own when known.
    func downloadedAlbum(id: String) async -> Album? {
        let catalog = await model.offlineCatalog
        guard let page = catalog.albumPage(id: id) else { return catalog.album(id: id) }
        var album = page.album
        album.songCount = page.total ?? page.onPhone
        return album
    }

    /// Round 28 O4 (D347): an album artist or a track artist (O2's page): the albums they made with a song on the
    /// phone. Fix round 1 (design H5): their songs on other artists' albums are `artistSongsOnPhone`, never those albums.
    func downloadedArtist(id: String) async -> (Artist, [Album])? {
        guard let page = await model.offlineCatalog.artistPage(id: id) else { return nil }
        return (page.artist, page.albums)
    }

    /// Fix round 1 (design H5): the artist's songs on the phone on other artists' albums ("Songs on this iPhone").
    func artistSongsOnPhone(id: String) async -> [Song] {
        await model.offlineCatalog.artistPage(id: id)?.songs ?? []
    }

    /// Fix round 1 (design H2): Offline mode is on (the car pops at once; offline by itself it waits 15 s).
    var isOfflineByChoice: Bool { model.isOffline && model.isForcedOffline }

    /// A playlist downloaded as a whole (Downloads), with only its songs on the phone; `songCount` is the playlist's.
    func downloadedPlaylist(id: String) async -> (Playlist, [Song])? {
        let catalog = await model.offlineCatalog
        guard catalog.playlists().contains(where: { $0.id == id }), let page = catalog.playlistPage(id: id) else { return nil }
        return Self.withTotal(page)
    }

    // MARK: - Round 28 O4: offline lists (owner, 2026-11-15; D347)

    /// Offline Playlists: the playlists holding a download, downloaded or read online since (Q3), as Playlists lists
    /// them (D185, D188: Discover's stay out); with Flows with your playlists (D300), the flows on the phone joined.
    func offlinePlaylists(combined: Bool) async -> [Playlist] {
        let listed = await model.offlineCatalog.playlists(includingRecorded: true).filter { !model.leavesOutOfPlaylists($0) }
        guard combined else { return listed }
        return model.carPlaylistsWithFlows(listed, flows: await model.offlineFlows())
    }

    /// Offline, a playlist's page from the phone (downloaded, or read online holding a download), else a flow's.
    func offlinePlaylistPage(id: String) async -> (Playlist, [Song])? {
        if let page = await model.offlineCatalog.playlistPage(id: id) { return Self.withTotal(page) }
        return await model.offlineFlowPage(id: id).map(Self.withTotal)
    }

    /// The page's playlist with `songCount` how many songs it has, and its songs on the phone.
    static func withTotal(_ page: OfflinePlaylistPage) -> (Playlist, [Song]) {
        var playlist = page.playlist
        playlist.songCount = page.total ?? page.onPhone
        return (playlist, page.songs)
    }

    /// Car Home offline (`CarPlayPreferences.visibleHomeSections`): Downloaded (the phone's shelf), Discover (the flows
    /// on the phone, by the car's last-played order, D297) and Playlists (those holding a download), each cut to
    /// `size`; empty shelves left out. Nothing is asked of the server.
    private func offlineHomeShelves(_ sections: [HomeSection], size: Int) async -> [CPHomeShelf] {
        let count = max(0, size)
        let downloaded = sections.contains(.downloaded) ? ((try? await model.homeShelves(for: [.downloaded])) ?? []) : []
        var flows: [Playlist] = []
        if sections.contains(.discover) {
            flows = HomeFlowsOrder.lastPlayed.sorted(await model.offlineFlows(), lastPlayed: model.flowPlays)
        }
        let playlists = sections.contains(.playlists) ? await offlinePlaylists(combined: false) : []
        return sections.compactMap { section -> CPHomeShelf? in
            let items: [CPHomeShelf.Item]
            var captions: [String: String] = [:]
            switch section {
            case .downloaded:
                items = (downloaded.first { $0.section == .downloaded }?.items ?? []).prefix(count).compactMap { item in
                    switch item {
                    case .album(let album), .downloadedAlbum(let album): .album(album)
                    case .playlist(let playlist): .playlist(playlist)
                    case .genreGroup, .outside: nil
                    }
                }
            case .discover:
                let shown = Array(flows.prefix(count))
                items = shown.map(CPHomeShelf.Item.playlist)
                captions = Dictionary(shown.compactMap { p in model.homeFlowCaption(playlistId: p.id).map { (p.id, $0) } },
                                      uniquingKeysWith: { first, _ in first })
            case .playlists:
                items = playlists.prefix(count).map(CPHomeShelf.Item.playlist)
            default:
                items = []
            }
            return items.isEmpty ? nil : CPHomeShelf(section: section, items: items, captions: captions)
        }
    }

    // MARK: - Favourites and Made for you

    /// Offline the phone doesn't know what's starred, and nothing is asked: the list says the library is out of reach.
    func favourites() async throws -> Starred {
        if model.isOffline { throw AppModel.forcedOfflineError }
        return try await model.favourites()
    }

    func madeForYouTracks(id: String) async -> [CPMadeForYouTrack]? {
        guard let mbid = MBID(id), let rows = await model.madeForYouTracks(mbid) else { return nil }
        return rows.map { row in
            switch row {
            case .library(let song): .song(song)
            case .notYet(let recording): .notYet(recording)
            }
        }
    }
}
#endif
