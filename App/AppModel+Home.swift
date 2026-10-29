import Foundation
import MagpieCore
import NavidromeKit
import Search

/// One Home shelf: a section and its tiles. "Made for you" isn't one; it keeps its own shelf (`madeForYouShelf`).
struct HomeShelf: Identifiable, Equatable, Sendable {
    enum Item: Equatable, Sendable {
        case album(Album)
        case playlist(Playlist)
        case genreGroup(GenreGroupSection)
        /// An album on the phone (Downloaded): it opens offline too.
        case downloadedAlbum(Album)
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
    var homeSections: [HomeSection] {
        preferences.layout.visibleHomeSections(offline: isOffline, hasListenBrainzToken: hasListenBrainzToken, carPlay: false)
    }

    /// The shelves for `sections`, in that order, fetched at the same time. Made for you is left out (its own shelf),
    /// and so is any section with nothing in it or that couldn't be read. Throws only when every section that asks the
    /// server failed. Offline, nothing is asked of the server: only Downloaded (and Genres, from the phone) fill in.
    func homeShelves(for sections: [HomeSection]) async throws -> [HomeShelf] {
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
        return zip(wanted, results).compactMap { section, result in
            guard case .success(let items) = result, !items.isEmpty else { return nil }
            return HomeShelf(section: section, items: items)
        }
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
