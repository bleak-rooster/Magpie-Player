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
}

/// Home and Library from the owner's layout (spec §3, Task 22), the new rows' screens, genre play, the offline watch
/// (Task 23) and Now Playing's star (round 12 item 2b). A change on the phone, or going offline, reloads Home and redraws the Library tab; a list
/// being browsed keeps its shape until it is off screen (`apply`).
extension CarPlayController {
    /// Home: the shelves of the sections shown, sized together by `CarPlayRows.home` to fit the car's list.
    func loadCustomHome() {
        guard let home else { return }
        let library = library
        let sections = library.homeSections
        let maxItems = Int(CPListTemplate.maximumItemCount), maxSections = Int(CPListTemplate.maximumSectionCount)
        load(home) {
            let shelves = try await library.homeShelves(sections, size: CarPlayRows.homeShelfMaxSize)
            return { _ in CarPlayRows.home(shelves, maxItems: maxItems, maxSections: maxSections) }
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
        let shown = Self.layout(of: library)
        let task = Task { [weak self] in
            let layouts = Observations { @MainActor in Self.layout(of: library) }
            var last = shown
            for await layout in layouts where layout != last {
                guard let self, !Task.isCancelled else { return }
                let change = CPLayoutChange(from: last, to: layout)
                last = layout
                if change.reloadsHome { self.loadCustomHome() }
                if change.redrawsLibrary, let libraryRoot = self.libraryRoot {
                    let rows = CarPlayRows.libraryRoot(layout.library, hasFindsTab: self.findsRoot != nil)
                    self.apply(rows, to: libraryRoot, placeholder: CarPlayRows.isPlaceholder(rows))
                }
            }
        }
        layoutWatch = task
        watches.append(task)
    }

    private static func layout(of library: any CarPlayLibrary) -> CPLayout {
        CPLayout(home: library.homeSections, library: library.libraryRows, offline: library.isOffline)
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
                return { CarPlayRows.downloadedAlbum(album, playingId: $0) }
            }
        case .downloadedArtist(let id, _):
            return {
                guard let page = await library.downloadedArtist(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                return { _ in CarPlayRows.downloadedArtist(page.0, albums: page.1) }
            }
        case .downloadedPlaylist(let id, _):
            return {
                guard let page = await library.downloadedPlaylist(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                return { CarPlayRows.playlist(page.0, songs: page.1, playingId: $0) }
            }
        case .madeForYou(let id, _):
            return {
                // A playlist that can't be read (ListenBrainz didn't answer) shows as empty, not as a library failure.
                guard let tracks = await library.madeForYouTracks(id: id) else { return { _ in CarPlayRows.state(.empty) } }
                let offer = library.tryOffer
                return { CarPlayRows.madeForYou(tracks, offer: offer, playingId: $0) }
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
        Task {
            let result = await library.setFavourite(songId: id, on)
            favouriting.remove(id)
            updateNowPlayingButtons()
            if let message = CarPlayRows.favouriteMessage(result) { showMessage(message) }
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
