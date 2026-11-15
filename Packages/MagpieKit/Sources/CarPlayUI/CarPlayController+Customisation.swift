#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import Observation
import Playback
import UIKit

/// What the car reads for the owner's layout (Task 22) and the screens added with it (Task 23). The reads marked
/// observable are followed with `Observations`.
@MainActor
public protocol CarPlayCustomisationLibrary: AnyObject {
    /// Home's sections, in the owner's order (Made for you with a ListenBrainz token; offline, Downloaded). Observable.
    var homeSections: [HomeSection] { get }
    /// The Library's rows, in the owner's order, without Songs and Requests (offline: Downloads, and Genres if shown).
    /// Observable.
    var libraryRows: [LibraryRow] { get }
    /// The shelves for `sections` that have something in them, in that order, each at most `size` tiles.
    func homeShelves(_ sections: [HomeSection], size: Int) async throws -> [CPHomeShelf]

    /// Only what's on the phone plays and shows; nothing is asked of the server. Observable.
    var isOffline: Bool { get }
    /// Whether the song is a favourite on the phone (this session's change, else what the server or the queue said).
    /// Observable. Y2: Now Playing's star.
    func isFavourite(songId: String) -> Bool
    /// Favourites or unfavourites the song through the phone's favourites (X3's `setFavourite`: at once, rolled back to
    /// the real state if the server says no). Offline nothing is sent.
    func setFavourite(songId: String, _ on: Bool) async -> CPFavouriteResult

    /// Albums A–Z (Navidrome's order, articles dropped) from `offset`, at most `size`; a short page is the end. Offline,
    /// the phone's. Y2: the car's Albums reads page after page.
    func albumsAZ(offset: Int, size: Int) async throws -> [Album]

    /// The phone's genre groups (hidden and empty ones left out).
    func genreGroups() async throws -> [(id: String, name: String, albumCount: Int)]
    /// The group's genres in the order the server lists them; empty for a group with none.
    func genreSubgenres(_ groupId: String) async throws -> [Genre]
    /// The songs a `.genre` or `.genreGroup` request plays, unshuffled (a genre's in server order, a group's taken from
    /// each genre in turn, capped); the controller's `start` shuffles. Empty for other requests.
    func songs(for request: CPPlayRequest) async throws -> [Song]

    /// What's on the phone (Downloads): never asks the server.
    func downloadedAlbums() async -> [Album]
    func downloadedArtists() async -> [Artist]
    func downloadedPlaylists() async -> [Playlist]
    /// The album with its songs on the phone; nil when none is.
    func downloadedAlbum(id: String) async -> Album?
    /// The artist and their albums on the phone; nil when none is.
    func downloadedArtist(id: String) async -> (Artist, [Album])?
    /// The playlist as downloaded, with only its songs on the phone; nil when it isn't on the phone.
    func downloadedPlaylist(id: String) async -> (Playlist, [Song])?

    /// Every starred song and album.
    func favourites() async throws -> Starred
    /// The songs of a Made for you playlist; nil when it can't be read (no token, offline, or ListenBrainz didn't answer).
    func madeForYouTracks(id: String) async -> [CPMadeForYouTrack]?
    /// Round 12 Y6: Library › Discover's playlists (Aurral's flows); none by default (CarPlayDiscover.swift).
    func discoverPlaylists() async throws -> [Playlist]

    /// Round 13: the third tab to show (Settings › CarPlay; Playlists when the choice isn't available). Observable.
    var carPlayTab: CarPlayTab { get }
    /// Round 13: where Songs' letter groups lie in the server's title order (offline, the phone's songs in that order).
    func songIndex() async throws -> CPSongIndex
    /// Round 13: songs in that title order from `offset`, at most `size`.
    func songsByTitle(offset: Int, size: Int) async throws -> [Song]
    /// Round 24 (D223's rule, D179): the signed-in user while everyone's playlists show (All), so the car's Playlists
    /// say whose the others' are; nil for Yours (and when signed out).
    var playlistCaptionUser: String? { get }
    /// Round 27 H (owner, 2026-11-14): a play started from the playlist's page in the car; the app keeps it when the
    /// playlist is a flow, for the car's Home order (D297). Nothing by default.
    func notePlaylistPlayed(id: String)
    /// Round 27 H (D299): whose a Discover playlist is ("sam"), for another user's only while everyone's show; nil
    /// otherwise (and by default).
    func discoverOwnerCaption(playlistId: String) -> String?
    /// Round 27 H (D300): whether Flows with your playlists applies now (false by default). Observable.
    var flowsWithPlaylists: Bool { get }
    /// Round 28 O4 fix round 1 (design H2): offline because the owner turned Offline mode on (not by itself). Observable.
    var isOfflineByChoice: Bool { get }
    /// Round 28 O4 fix round 1 (design H5): the artist's songs on the phone on other artists' albums ("Songs on this
    /// iPhone"); none by default.
    func artistSongsOnPhone(id: String) async -> [Song]
}

extension CarPlayCustomisationLibrary {
    public var flowsWithPlaylists: Bool { false }
    public var isOfflineByChoice: Bool { false }
    public func artistSongsOnPhone(id: String) async -> [Song] { [] }
    public func notePlaylistPlayed(id: String) {}
    public func discoverOwnerCaption(playlistId: String) -> String? { nil }
}

/// Home and Library from the owner's layout (spec §3, Task 22), the new rows' screens, genre play, the offline watch
/// (Task 23) and Now Playing's star (round 12 item 2b). A change on the phone, or going offline, reloads Home and redraws
/// the Library tab; a list being browsed keeps its shape until it is off screen (`apply`).
extension CarPlayController {
    /// Home: the shelves of the sections shown, sized together by `CarPlayRows.home` to fit the car's list.
    func loadCustomHome() {
        guard let home else { return }
        let library = library
        let sections = library.homeSections
        let (maxItems, maxSections) = listLimits()   // R24F: the same limits the pages use
        let offline = library.isOffline
        load(home) {
            let shelves = try await library.homeShelves(sections, size: CarPlayRows.homeShelfMaxSize)
            // Round 28 O4 fix round 1 (design M2): offline Home opens with "Offline · music on this iPhone", one row
            // and section of the car's limits.
            guard offline else { return { _ in CarPlayRows.home(shelves, maxItems: maxItems, maxSections: maxSections) } }
            return { _ in
                CarPlayRows.offlineHome(CarPlayRows.home(shelves, maxItems: max(0, maxItems - 1),
                                                         maxSections: max(0, maxSections - 1)))
            }
        }
    }

    /// Follows the layout (`CPLayout`: Home's sections, the Library's rows, offline). Started with the tabs; a newer
    /// start replaces the older one, in `watches` too. What the tabs show now is read before the watch starts, so a
    /// change made meanwhile isn't missed.
    func watchLayout() {
        if let old = layoutWatch {
            old.cancel()
            watches.removeAll { $0 == old }
        }
        let library = library
        let shown = Self.watched(library)
        let task = Task { [weak self] in
            let states = Observations { @MainActor in Self.watched(library) }
            var last = shown
            for await now in states where now != last {
                guard let self, !Task.isCancelled else { return }
                let layout = now.layout
                let change = CPLayoutChange(from: last.layout, to: layout)
                let wentOffline = !last.layout.offline && layout.offline, cameOnline = last.layout.offline && !layout.offline
                let becameManual = layout.offline && now.manual && !last.manual
                last = now
                if change.rebuildsTabs {   // round 13: a new third tab; the tabs are built again (and this watch with them)
                    guard self.tabBar != nil else { return }   // Z3 review I1: only while the tabs are showing
                    self.resetBindings()
                    self.showTabs()
                    return
                }
                // Round 28 O4 (D347): back online the car stays where it is (a pop still waiting is called off); the
                // third tab reads the library again the next time it is chosen (its list was the phone's).
                if cameOnline {
                    self.offlinePopTask?.cancel()
                    self.offlinePopTask = nil
                    self.thirdRoot?.isPlaceholder = true
                }
                if change.reloadsHome { self.loadCustomHome() }
                if change.redrawsLibrary, let libraryRoot = self.libraryRoot {
                    let rows = CarPlayRows.libraryRoot(layout.library)
                    self.apply(rows, to: libraryRoot, placeholder: CarPlayRows.isPlaceholder(rows))
                }
                // Fix round 1 (design H4, M1): Up Next's rows and empty lines follow, in place.
                if wentOffline || cameOnline { self.refreshListsInPlace() }
                // Fix round 1 (design H2): Offline mode pops at once; offline by itself only once it has lasted 15 s.
                if (wentOffline && now.manual) || becameManual {
                    self.popServerLists()
                } else if wentOffline {
                    self.popServerListsAfterTheWait()
                }
            }
        }
        layoutWatch = task
        watches.append(task)
    }

    // MARK: - Round 28 O4: going offline (owner, 2026-11-15; D347, D348; fix round 1, design H2, H4, M1)

    /// What the watch follows: the layout, and whether offline is the owner's choice.
    struct Watched: Equatable {
        var layout: CPLayout
        var manual: Bool
    }

    private static func watched(_ library: any CarPlayLibrary) -> Watched {
        Watched(layout: layout(of: library), manual: library.isOfflineByChoice)
    }

    /// Whether a list is the phone's own (Downloads and what it opens): it plays offline, so it stays.
    static func isFromThePhone(_ destination: CPDestination) -> Bool {
        switch destination {
        case .downloads, .downloadedAlbum, .downloadedArtist, .downloadedPlaylist: true
        case .page(let ref): ref.base.map(isFromThePhone) ?? false
        default: false
        }
    }

    /// A pushed list read from the server (Up Next, Now Playing and Search have no server list behind them).
    private func isServerList(_ template: CPTemplate) -> Bool {
        guard let destination = bindings[ObjectIdentifier(template)]?.destination else { return false }
        return !Self.isFromThePhone(destination)
    }

    /// Design H2: offline by itself, the pop waits `offlinePopWait` (15 s), called off if the library answers sooner.
    func popServerListsAfterTheWait() {
        offlinePopTask?.cancel()
        let wait = offlinePopWait
        offlinePopTask = Task { [weak self] in
            await wait()
            guard !Task.isCancelled, let self, self.library.isOffline, self.tabBar != nil else { return }
            self.popServerLists()
        }
    }

    /// The car went offline (D347): every list read from the server goes, from the first one pushed (rows that can't
    /// play); the phone's own lists below it stay (fix round 1, design H2), and so does the chosen tab. Now Playing, if
    /// it was above, is put back on top. The tabs' first lists are read again now from what's on the phone. Only on the
    /// way to offline: coming back online leaves the car where it is.
    func popServerLists() {
        offlinePopTask?.cancel()
        offlinePopTask = nil
        guard tabBar != nil else { return }
        let templates = interface.templates
        let nowPlaying = CPNowPlayingTemplate.shared
        if let cut = templates.indices.dropFirst().first(where: { isServerList(templates[$0]) }) {
            let keep = templates[cut - 1]
            let popped = templates[cut...]
            let putBack = popped.contains { $0 === nowPlaying }
            for template in popped {
                let id = ObjectIdentifier(template)
                bindings[id]?.cancel()
                bindings[id] = nil
            }
            interface.pop(to: keep, animated: false) { [weak self] done, _ in
                MainActor.assumeIsolated {
                    guard done, putBack, let self, self.interface.topTemplate === keep else { return }
                    self.interface.pushTemplate(nowPlaying, animated: false, completion: nil)
                }
            }
        }
        // Each tab's first list now, even the one on screen (its server rows wouldn't play).
        home?.isPlaceholder = true
        loadCustomHome()
        if let libraryRoot {
            libraryRoot.isPlaceholder = true
            let rows = CarPlayRows.libraryRoot(library.libraryRows)
            apply(rows, to: libraryRoot, placeholder: CarPlayRows.isPlaceholder(rows))
        }
        if let thirdRoot {
            thirdRoot.isPlaceholder = true
            loadThirdTab()
        }
    }

    /// Every list with rows builds them again; one of the same shape changes in place (`apply`).
    private func refreshListsInPlace() {
        for binding in bindings.values where binding.content != nil {
            Task { [weak self] in await self?.refresh(binding) }
        }
    }

    /// Offline: an empty list says what isn't on the phone (D348; fix round 1, design M1), and Up Next's songs not on
    /// the phone say so and do nothing (design H4). Home has its own line (`loadCustomHome`).
    func offlineCopy(_ sections: [CPSectionModel], for binding: ListBinding) -> [CPSectionModel] {
        guard library.isOffline, binding !== home else { return sections }
        if sections.contains(where: { $0.rows.contains { $0.id.hasPrefix(CarPlayRows.upNextRowPrefix) } }) {
            let current = player.queue.current?.id
            let notOnPhone = Set(player.queue.upcoming.filter { $0.id != current && !player.isPlayable($0.song) }.map(\.id))
            return CarPlayRows.upNextOffline(sections, notOnPhone: notOnPhone)
        }
        guard let kind = binding.destination.flatMap(CarPlayRows.offlineEmptyKind) else { return sections }
        return CarPlayRows.offlineEmpty(sections, kind)
    }

    private static func layout(of library: any CarPlayLibrary) -> CPLayout {
        CPLayout(home: library.homeSections, library: library.libraryRows, offline: library.isOffline, tab: library.carPlayTab,
                 flowsWithPlaylists: library.flowsWithPlaylists)
    }

    /// The screens of the destinations added with the layout. Each reads through the library, which offline reads the
    /// phone and asks nothing of the server.
    func customFetcher(for destination: CPDestination) -> @MainActor () async throws -> Content {
        let library = library
        switch destination {
        case .genres:
            return { let groups = try await library.genreGroups(); return { _ in CarPlayRows.genres(groups) } }
        case .genreGroup(let id, _):
            return {
                let genres = try await library.genreSubgenres(id)
                return { _ in CarPlayRows.genreGroup(id: id, subgenres: genres) }
            }
        case .favourites:
            return { let starred = try await library.favourites(); return { CarPlayRows.favourites(starred, playingId: $0) } }
        case .downloads:
            return {
                async let albums = library.downloadedAlbums()
                async let artists = library.downloadedArtists()
                async let playlists = library.downloadedPlaylists()
                let (al, ar, pl) = await (albums, artists, playlists)
                return { _ in CarPlayRows.downloads(albums: al, artists: ar, playlists: pl) }
            }
        case .downloadedAlbum(let id, _):
            return {
                guard let album = await library.downloadedAlbum(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                // Round 28 O4 (D347): `songCount` is the album's, `songs` those on the phone.
                return { CarPlayRows.onPhone(CarPlayRows.downloadedAlbum(album, playingId: $0),
                                             songs: album.songs?.count ?? 0, total: album.songCount) }
            }
        case .downloadedArtist(let id, _):
            let albumsOpen = CPNavigator.allowsPush(atDepth: browseDepth)   // fix round 1 (I2)
            return {
                guard let page = await library.downloadedArtist(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                // Round 28 O4 fix round 1 (design H5): their albums, then their songs on other artists' albums.
                let songs = await library.artistSongsOnPhone(id: id)
                return { _ in
                    CarPlayRows.artistOnPhone(page.0, albums: page.1, songs: songs, albumsOpen: albumsOpen, downloadedPages: true)
                }
            }
        case .downloadedPlaylist(let id, _):
            return {
                guard let page = await library.downloadedPlaylist(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                return { CarPlayRows.playlist(page.0, songs: page.1, playingId: $0, onPhone: true) }   // D347
            }
        case .madeForYou(let id, _):
            return {
                // A playlist that can't be read (ListenBrainz didn't answer) shows as empty, not as a library failure.
                guard let tracks = await library.madeForYouTracks(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                let offer = library.tryOffer
                return { CarPlayRows.madeForYou(tracks, offer: offer, playingId: $0) }
            }
        case .discover:   // Y6 (CarPlayDiscover.swift); round 27 H (D299): another user's rows end " · sam"
            return {
                let playlists = try await library.discoverPlaylists()
                let captions = Self.discoverCaptions(playlists, library)
                return { _ in CarPlayRows.discover(playlists, captions: captions) }
            }
        case .finds:
            // Read again first, so the list isn't what the phone last saw (the Finds tab refreshes the same way).
            return {
                await library.refreshFinds()
                let shelf = library.findsShelf
                return { CarPlayRows.finds(shelf, playingId: $0) }
            }
        default:
            return { { _ in CarPlayRows.state(.empty) } }
        }
    }

    /// Round 27 H (D299): the captions of the Discover playlists another user made, by playlist id.
    static func discoverCaptions(_ playlists: [Playlist], _ library: any CarPlayLibrary) -> [String: String] {
        Dictionary(playlists.compactMap { p in library.discoverOwnerCaption(playlistId: p.id).map { (p.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Round 27 H (owner, 2026-11-14; D297): a play tapped on a playlist's page (the list on top, or a page of it) is
    /// told to the library, which keeps it when the playlist is a flow. Called by `perform` before the play starts.
    func notePlaylistPlay() {
        guard let top = interface.topTemplate, let destination = bindings[ObjectIdentifier(top)]?.destination,
              let id = Self.playlistId(of: destination) else { return }
        library.notePlaylistPlayed(id: id)
    }

    /// The playlist a list shows: a playlist's page, downloaded or not, or a page of one (D232); nil for any other.
    static func playlistId(of destination: CPDestination) -> String? {
        switch destination {
        case .playlist(let id, _), .downloadedPlaylist(let id, _): id
        case .page(let ref): ref.base.flatMap(playlistId)
        default: nil
        }
    }

    /// Genre requests fetch their songs first. Shuffling has one owner, `start(_:at:shuffled:)` (the player's shuffle):
    /// a group's Shuffle (D41) and the phone's Shuffle rows ask for it; a genre's row plays in server order.
    func playCustom(_ request: CPPlayRequest) {
        switch request {
        case .shuffle(let songs):
            start(songs, at: 0, shuffled: true)
        case .genre(_, let shuffled), .genreGroup(_, let shuffled):
            let library = library
            Task {
                do {
                    start(try await library.songs(for: request), at: 0, shuffled: shuffled)
                } catch {
                    showUnavailable(error)
                }
            }
        default:
            break
        }
    }

    // MARK: - Favourite (round 12 item 2b: CPNowPlayingImageButton, where the sleep timer was)

    /// The star in Now Playing: filled and selected while the song playing is a favourite; off while nothing plays or
    /// while a change is with the server.
    func favouriteButton() -> CPNowPlayingButton {
        let id = player.queue.current?.song.id
        let on = id.map { library.isFavourite(songId: $0) } ?? false
        let image = UIImage(systemName: on ? "star.fill" : "star") ?? UIImage()
        let button = CPNowPlayingImageButton(image: image) { [weak self] _ in self?.favouriteTapped() }
        button.isSelected = on
        button.isEnabled = id.map { !favouriting.contains($0) } ?? false
        button.accessibilityLabel = on ? "Unfavourite" : "Favourite"
        return button
    }

    /// Toggles the song playing. Says something only when it didn't go through (critique M3: in answer to the tap);
    /// the star itself follows the phone's state, which the phone rolls back on a refusal.
    func favouriteTapped() {
        guard let id = player.queue.current?.song.id, !favouriting.contains(id) else { return }
        let on = !library.isFavourite(songId: id)
        favouriting.insert(id)
        updateNowPlayingButtons()
        let library = library
        favouriteTask = Task { [weak self] in
            let result = await library.setFavourite(songId: id, on)
            guard !Task.isCancelled, let self else { return }   // disconnected: the car's buttons aren't ours any more
            self.favouriting.remove(id)
            self.updateNowPlayingButtons()
            if let message = CarPlayRows.favouriteMessage(result) { self.showMessage(message) }
        }
    }
}

// R6: the car's shuffle and repeat buttons mirror the phone's (the glyph, One included, comes from the remote
// command centre's current types, which `NowPlayingBridge.syncModes` keeps).
extension CarPlayController {
    struct ModeSelection: Equatable, Sendable {
        var shuffle: Bool
        var repeating: Bool
    }

    static func modeSelection(of player: Player) -> ModeSelection {
        ModeSelection(shuffle: player.isShuffled, repeating: player.repeatMode != .off)
    }
}
#endif
