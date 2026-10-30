#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import Observation
import UIKit

/// What the car reads for the owner's layout (Task 22) and the screens added with it (Task 23). The reads marked
/// observable are followed with `Observations`.
@MainActor
public protocol CarPlayLayoutLibrary: AnyObject {
    /// Home's sections, in the owner's order (Made for you with a ListenBrainz token; offline, Downloaded). Observable.
    var homeSections: [HomeSection] { get }
    /// The Library's rows, in the owner's order, without Songs and Requests (offline: Downloads, and Genres if shown).
    /// Observable.
    var libraryRows: [LibraryRow] { get }
    /// The shelves for `sections` that have something in them, in that order, each at most `size` tiles.
    func homeShelves(_ sections: [HomeSection], size: Int) async throws -> [CPHomeShelf]

    /// Only what's on the phone plays and shows; nothing is asked of the server. Observable.
    var isOffline: Bool { get }
    /// The sleep timer is set (minutes or the end of the song). Observable.
    var sleepTimerActive: Bool { get }
    /// Off: starts the owner's default sleep timer. On: turns it off.
    func toggleSleepTimer()

    /// The phone's genre groups (hidden and empty ones left out).
    func genreGroups() async throws -> [(id: String, name: String, albumCount: Int)]
    /// The group's genres in the order the server lists them; empty for a group with none.
    func genreSubgenres(_ groupId: String) async throws -> [Genre]
    /// The songs a `.genre` or `.genreGroup` request plays (a group's come shuffled); empty for other requests.
    func songs(for request: CPPlayRequest) async throws -> [Song]

    /// What's on the phone (Downloads): never asks the server.
    func downloadedAlbums() async -> [Album]
    func downloadedArtists() async -> [Artist]
    func downloadedPlaylists() async -> [Playlist]
    /// The album with its songs on the phone; nil when none is.
    func downloadedAlbum(id: String) async -> Album?
    /// The artist and their albums on the phone; nil when none is.
    func downloadedArtist(id: String) async -> (Artist, [Album])?

    /// Every starred song and album.
    func favourites() async throws -> Starred
    /// The songs of a Made for you playlist; nil when it can't be read (no token, offline, or ListenBrainz didn't answer).
    func madeForYouTracks(id: String) async -> [CPMadeForYouTrack]?
}

/// A read that came back empty-handed without an error of its own (Made for you, a download no longer on the phone).
struct CPNothingRead: Error {}

/// Home and Library from the owner's layout (spec §3, Task 22), the new rows' screens, genre play, the offline watch and
/// the sleep button (Task 23). A change on the phone, or going offline, reloads Home and redraws the Library tab; a list
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
        case .madeForYou(let id, _):
            return {
                guard let tracks = await library.madeForYouTracks(id: id) else { throw CPNothingRead() }
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

    /// Genre requests fetch their songs first; a group's come shuffled (D41). Songs from the phone play as they are.
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

    // MARK: - Sleep timer (spec §5: CPNowPlayingImageButton lets the template carry it)

    /// The moon in Now Playing: selected while the timer is set. A tap sets the owner's default or turns it off, and
    /// says which.
    func sleepButton() -> CPNowPlayingButton {
        let button = CPNowPlayingImageButton(image: UIImage(systemName: "moon.zzz") ?? UIImage()) { [weak self] _ in
            self?.toggleSleepTimer()
        }
        button.isSelected = library.sleepTimerActive
        return button
    }

    private func toggleSleepTimer() {
        library.toggleSleepTimer()
        updateNowPlayingButtons()
        showMessage(CarPlayRows.sleepTimerMessage(active: library.sleepTimerActive))
    }

    /// The timer set or ended on the phone, or run out: the button follows.
    func watchSleepTimer() {
        let library = library
        let shown = library.sleepTimerActive
        watches.append(Task { [weak self] in
            var last = shown
            for await active in Observations({ @MainActor in library.sleepTimerActive }) where active != last {
                last = active
                self?.updateNowPlayingButtons()
            }
        })
    }
}
#endif
