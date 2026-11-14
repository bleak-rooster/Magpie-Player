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
    /// with a token, Discover with Aurral, as on the phone). Offline: Downloaded.
    var homeSections: [HomeSection] {
        model.preferences.carPlay.visibleHomeSections(phone: model.preferences.layout, offline: model.isOffline,
                                                      hasListenBrainzToken: model.hasListenBrainzToken,
                                                      discoverSetUp: model.aurralSetUp)
    }

    /// The phone's Library rows without Requests. Offline: Downloads, and Genres when shown. Round 27 H (D300): with
    /// Flows with your playlists on, no Discover row (its playlists are in Playlists).
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

    func downloadedAlbum(id: String) async -> Album? { await model.offlineCatalog.album(id: id) }

    func downloadedArtist(id: String) async -> (Artist, [Album])? {
        let catalog = await model.offlineCatalog
        guard let artist = catalog.artists().first(where: { $0.id == id }) else { return nil }
        return (artist, catalog.albums(byArtist: id))
    }

    func downloadedPlaylist(id: String) async -> (Playlist, [Song])? {
        let catalog = await model.offlineCatalog
        guard let playlist = catalog.playlists().first(where: { $0.id == id }) else { return nil }
        return (playlist, catalog.songs(inPlaylist: id))
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
