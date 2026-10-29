import Foundation
import MagpieCore
import NavidromeKit
import Search

/// One Home shelf: a section and its tiles. "Made for you" isn't one; it keeps its own shelf (`madeForYouShelf`).
struct HomeShelf: Identifiable, Equatable, Sendable {
    enum Item: Identifiable, Equatable, Sendable {
        case album(Album)
        case playlist(Playlist)
        case genreGroup(GenreGroupSection)
        /// An album on the phone (Downloaded): it opens offline too.
        case downloadedAlbum(Album)

        /// What the tile is (Task 21): stable across reads, unlike its position.
        var id: String {
            switch self {
            case .album(let album), .downloadedAlbum(let album): "album-\(album.id)"
            case .playlist(let playlist): "playlist-\(playlist.id)"
            case .genreGroup(let section): "group-\(section.group.id)"
            }
        }
    }

    var section: HomeSection
    var items: [Item]
    var id: HomeSection { section }
}

/// Home layout (spec §3, Task 20): the sections the owner shows, in the owner's order, each fetched only when shown.
extension AppModel {
    /// Tiles per shelf (not configurable).
    static let homeShelfSize = 12

    /// The sections Home shows now: the owner's order and switches; Made for you only with a token; offline, Downloaded.
    var homeSections: [HomeSection] { homeSections(carPlay: false) }

    /// The phone's sections, or the car's (no Made for you: the car has no screen for it).
    func homeSections(carPlay: Bool) -> [HomeSection] {
        preferences.layout.visibleHomeSections(offline: isOffline, hasListenBrainzToken: hasListenBrainzToken, carPlay: carPlay)
    }

    /// A read of Home's sections: the shelves with something in them, in the order asked, and the sections that
    /// couldn't be read (Home says so under their titles, Task 21).
    struct HomeRead: Sendable {
        var shelves: [HomeShelf]
        var failed: Set<HomeSection>
    }

    /// The shelves for `sections`, in that order, fetched at the same time. Made for you is left out (its own shelf),
    /// and so is any section with nothing in it or that couldn't be read. Throws only when every section that asks the
    /// server failed. Offline, nothing is asked of the server: only Downloaded (and Genres, from the phone) fill in.
    func homeShelves(for sections: [HomeSection]) async throws -> [HomeShelf] {
        try await homeRead(for: sections).shelves
    }

    /// `homeShelves(for:)`, naming the sections that couldn't be read.
    func homeRead(for sections: [HomeSection]) async throws -> HomeRead {
        let wanted = sections.filter { $0 != .madeForYou }
        let results = await withTaskGroup(of: (Int, Result<[HomeShelf.Item], any Error>).self) { group in
            for (index, section) in wanted.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (index, .success([])) }
                    do { return (index, .success(try await self.homeItems(section))) } catch { return (index, .failure(error)) }
                }
            }
            var results = [Result<[HomeShelf.Item], any Error>?](repeating: nil, count: wanted.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
        let asksServer = wanted.indices.filter { Self.asksServer(wanted[$0]) }
        let failures = asksServer.compactMap { i -> (any Error)? in if case .failure(let e) = results[i] { e } else { nil } }
        if !asksServer.isEmpty, failures.count == asksServer.count, let first = failures.first { throw first }
        let shelves = zip(wanted, results).compactMap { section, result -> HomeShelf? in
            guard case .success(let items) = result, !items.isEmpty else { return nil }
            return HomeShelf(section: section, items: items)
        }
        let failed = zip(wanted, results).compactMap { section, result -> HomeSection? in
            if case .failure = result { section } else { nil }
        }
        return HomeRead(shelves: shelves, failed: Set(failed))
    }

    /// Downloaded reads the phone only; every other section asks the server.
    private static func asksServer(_ section: HomeSection) -> Bool { section != .downloaded }

    /// One section's tiles, at most `homeShelfSize`.
    private func homeItems(_ section: HomeSection) async throws -> [HomeShelf.Item] {
        let size = Self.homeShelfSize
        switch section {
        case .jumpBackIn: return try await albums(.recent)
        case .recentlyAdded: return try await albums(.newest)
        case .mostPlayed: return try await albums(.frequent)
        case .favourites: return try await albums(.starred)
        case .randomAlbums: return try await albums(.random)
        case .playlists:
            guard !isOffline else { return [] }
            return try await request { try await $0.playlists() }.prefix(size).map(HomeShelf.Item.playlist)
        case .genres:
            // The groups with the most albums; ties keep the groups' own order.
            let sections = try await genreSections().enumerated()
                .sorted { ($0.element.albumCount, -$0.offset) > ($1.element.albumCount, -$1.offset) }
            return sections.prefix(size).map { .genreGroup($0.element) }
        case .downloaded: return await offlineCatalog.albums().prefix(size).map(HomeShelf.Item.downloadedAlbum)
        case .madeForYou: return []
        }
    }

    private func albums(_ type: AlbumListType) async throws -> [HomeShelf.Item] {
        guard !isOffline else { return [] }   // Task 14: nothing is asked of the server offline
        return try await request { [size = Self.homeShelfSize] in try await $0.albumList(type, size: size, offset: 0) }
            .map(HomeShelf.Item.album)
    }
}

/// Library layout (spec §3, Task 21): the rows the owner shows, in the owner's order; the Recently added grid's switch;
/// Songs a page at a time; Favourites.
extension AppModel {
    /// Songs per page of Library › Songs.
    static let songsPageSize = 100

    /// The rows the Library shows now. Online: the owner's order and switches, Finds only once set up, Requests only
    /// with Lidarr connected. Offline (Task 14): Downloads, which always shows, and Genres (read from the phone) when
    /// switched on, in the owner's order.
    var libraryRows: [LibraryRow] { libraryRows(carPlay: false) }

    /// The phone's rows, or the car's (no Songs, no Requests): one rule for both (`visibleLibraryRows`).
    func libraryRows(carPlay: Bool) -> [LibraryRow] {
        preferences.layout.visibleLibraryRows(offline: isOffline, findsSetUp: findsSetup?.library != nil,
                                              lidarrConnected: lidarr != nil, carPlay: carPlay)
    }

    /// The Recently added grid at the bottom of the Library: its own switch, and never offline.
    var showsRecentlyAddedGrid: Bool { preferences.layout.showsRecentlyAdded && !isOffline }

    /// One page of every song, A–Z by title (`page` from 0).
    func songsPage(_ page: Int) async throws -> [Song] {
        let size = Self.songsPageSize
        return try await request { try await $0.songsPage(start: page * size, end: (page + 1) * size, sort: "title") }.songs
    }

    /// Library › Favourites: every starred song and album (`getStarred2`).
    func favourites() async throws -> Starred {
        try await request { try await $0.starred() }
    }
}
