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
        /// An album on the phone (Recently downloaded): it opens offline too. A downloaded playlist there is a
        /// `.playlist` (its page reads the phone's copy offline).
        case downloadedAlbum(Album)
        /// Round 14 A6: a tile of a provided section (`HomeAurralShelves`).
        case outside(HomeOutsideItem)

        /// What the tile is (Task 21): stable across reads, unlike its position.
        var id: String {
            switch self {
            case .album(let album), .downloadedAlbum(let album): "album-\(album.id)"
            case .playlist(let playlist): "playlist-\(playlist.id)"
            case .genreGroup(let section): "group-\(section.group.id)"
            case .outside(let item): "outside-\(item.id)"
            }
        }
    }

    var section: HomeSection
    var items: [Item]
    var id: HomeSection { section }

    /// Round 12 Y3: whether `item` is a kind of tile `section` shows. A saved shelf with any other kind is stale (an
    /// older build, another section's tiles) and is thrown away on load.
    static func fits(_ item: Item, in section: HomeSection) -> Bool {
        switch (section, item) {
        case (.jumpBackIn, .album), (.recentlyAdded, .album), (.mostPlayed, .album), (.favourites, .album),
             (.randomAlbums, .album): true
        // Round 13 Z2: Discover's shelf is playlists too. Left out, a saved Discover shelf was thrown away at every
        // launch, so Home opened without Discover (the next shelf in its place) until Aurral answered.
        case (.playlists, .playlist), (.discover, .playlist): true
        case (.genres, .genreGroup): true
        case (.downloaded, .downloadedAlbum), (.downloaded, .playlist): true
        case (.quickAccess, .album): true   // round 14 A6: the server's recently played albums
        // Round 14 A4: Your flows ends with the For you playlists (Discover playlists not added yet).
        case (.discover, .outside(let item)): item.kind == .playlist
        case (let section, .outside): section.isProvided
        default: false
        }
    }
}

/// One section's answer in Home's read (B1): where it goes, what it was read for, and what came back.
struct HomeSectionAnswer: Sendable {
    let index: Int
    let section: HomeSection
    let result: Result<[HomeShelf.Item], any Error>
}

extension HomeSection {
    /// Round 14 A6: a section Home's feed reads a shelf for. Made for you keeps its own; the greeting and the chips are
    /// part of the page.
    var readsShelf: Bool { self != .madeForYou && !isChrome }
}

/// Home layout (spec §3, Task 20): the sections the owner shows, in the owner's order, each fetched only when shown.
extension AppModel {
    /// Tiles read per shelf: the most a shelf can show (round 14 A6: each shows its own count, `HomeSectionStyle`).
    nonisolated static let homeShelfSize = HomeSectionStyle.countRange.upperBound

    /// The sections Home shows now, on the phone: the owner's order and switches; Made for you only with a token;
    /// Discover and the provided sections only with Aurral (round 14 A6: and a provider, `homeOutsideSections`);
    /// offline, Downloaded.
    var homeSections: [HomeSection] {
        preferences.layout.visibleHomeSections(offline: isOffline, hasListenBrainzToken: hasListenBrainzToken,
                                               discoverSetUp: aurralSetUp, outside: homeOutsideSections)   // Y6
    }

    /// A read of Home's sections: the shelves with something in them, in the order asked, and the sections that
    /// couldn't be read (Home says so under their titles, Task 21).
    struct HomeRead: Sendable {
        var shelves: [HomeShelf]
        var failed: Set<HomeSection>
        /// Sections whose read was cut short (cancelled, or never reported): not read, and never a failure (P5).
        var cancelled: Set<HomeSection> = []
    }

    /// The shelves for `sections`, in that order, fetched at the same time. Made for you is left out (its own shelf),
    /// and so is any section with nothing in it or that couldn't be read. Throws only when every section that asks the
    /// server failed. Offline, nothing is asked of the server: only Downloaded (and Genres, from the phone) fill in.
    func homeShelves(for sections: [HomeSection]) async throws -> [HomeShelf] {
        try await homeRead(for: sections).shelves
    }

    /// `homeShelves(for:)`, naming the sections that couldn't be read.
    func homeRead(for sections: [HomeSection]) async throws -> HomeRead {
        let wanted = sections.filter(\.readsShelf)
        // B1 (build 14): the section's answer is awaited into its own constant before it is paired with its position.
        // Written as one `return` pairing `index` with an inline `.success(try await …)` inside do/catch, the optimised
        // (Release) build lost `index` across the await: every answer landed on the first section asked, so each shelf
        // showed another section's tiles (random albums under Recommended, Jump back in, Recently added) and the rest
        // never loaded. Debug builds were right. scripts/check-release.sh now refuses that shape (D120).
        let results = await withTaskGroup(of: HomeSectionAnswer.self) { group in
            for (index, section) in wanted.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return HomeSectionAnswer(index: index, section: section, result: .success([])) }
                    let result = await self.homeResult(section)
                    return HomeSectionAnswer(index: index, section: section, result: result)
                }
            }
            var results = [Result<[HomeShelf.Item], any Error>?](repeating: nil, count: wanted.count)
            for await answer in group {
                // Belt and braces: an answer is kept only at the position of the section it was read for.
                guard results.indices.contains(answer.index), wanted[answer.index] == answer.section else { continue }
                results[answer.index] = answer.result
            }
            return results
        }
        // A cancelled read reports nothing rather than "every section failed".
        try Task.checkCancellation()
        return try Self.assemble(wanted: wanted, results: results)
    }

    /// Joins one result per wanted section, by position. A section with no result (a read cut short) counts as
    /// not read, so Home retries it; dropping the gaps instead shifted every later index and trapped with
    /// "Index out of range" at launch (TestFlight build 8). Throws only when every section that asks the server failed.
    static func assemble(wanted: [HomeSection], results: [Result<[HomeShelf.Item], any Error>?]) throws -> HomeRead {
        let filled = wanted.indices.map { i -> Result<[HomeShelf.Item], any Error> in
            (results.indices.contains(i) ? results[i] : nil) ?? .failure(CancellationError())
        }
        let asksServer = wanted.indices.filter { Self.asksServer(wanted[$0]) }
        let failures = asksServer.compactMap { i -> (any Error)? in if case .failure(let e) = filled[i] { e } else { nil } }
        // Every server section failed: a real error when they all are; a cancellation when they all were cut short;
        // a mix is returned as it is, so the cut-short ones stay unread rather than failed (fix M4).
        if !asksServer.isEmpty, failures.count == asksServer.count, let first = failures.first {
            let real = failures.filter { !isCancellation($0) }
            if real.isEmpty { throw first }
            if real.count == failures.count { throw real[0] }
        }
        let shelves = zip(wanted, filled).compactMap { section, result -> HomeShelf? in
            guard case .success(let items) = result, !items.isEmpty else { return nil }
            return HomeShelf(section: section, items: items)
        }
        var failed = Set<HomeSection>(), cancelled = Set<HomeSection>()
        for (section, result) in zip(wanted, filled) {
            guard case .failure(let error) = result else { continue }
            if isCancellation(error) { cancelled.insert(section) } else { failed.insert(section) }
        }
        return HomeRead(shelves: shelves, failed: failed, cancelled: cancelled)
    }

    /// A read cut short rather than one that failed: Swift's `CancellationError` or URLSession's `.cancelled` (P5).
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Downloaded reads the phone only; every other section asks the server.
    private static func asksServer(_ section: HomeSection) -> Bool { section != .downloaded }

    /// The longest Home waits for a provided section (B1): past it the section counts as not read (its saved shelf
    /// stays and it is read again later), so a slow or silent provider never holds back the library's shelves.
    nonisolated static let providedWait: Duration = .seconds(8)

    /// One section's read as a value, so the task group never builds its answer around an `await` (B1).
    private func homeResult(_ section: HomeSection) async -> Result<[HomeShelf.Item], any Error> {
        let result: Result<[HomeShelf.Item], any Error>
        if section.isProvided {
            result = await HomeDeadline.run(Self.providedWait) { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.homeItems(section)
            }
        } else {
            do { result = .success(try await homeItems(section)) } catch { result = .failure(error) }
        }
        return result.map { items in items.filter { HomeShelf.fits($0, in: section) } }   // B1: never another kind
    }

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
            let all = try await request { try await $0.playlists() }
            return Self.homePlaylists(all, username: session?.username, isDiscover: isDiscoverPlaylist)
                .prefix(size).map(HomeShelf.Item.playlist)
        case .genres:
            // The groups with the most albums; ties keep the groups' own order.
            let sections = try await genreSections().enumerated()
                .sorted { ($0.element.albumCount, -$0.offset) > ($1.element.albumCount, -$1.offset) }
            return sections.prefix(size).map { .genreGroup($0.element) }
        case .downloaded:
            // Y3: newest first by download date; a downloaded playlist as itself, never as partial albums.
            return await offlineCatalog.recentlyDownloaded().prefix(size).map { item in
                switch item {
                case .album(let album): .downloadedAlbum(album)
                case .playlist(let playlist): .playlist(playlist)
                }
            }
        case .madeForYou, .greeting, .filterChips: return []
        // Round 14 A6: the quick grid's fallback, the server's recently played albums (`QuickAccess.tiles`).
        case .quickAccess: return try await albums(.recent)
        case .recommended, .newThisWeek, .becauseYouLike, .morePlaylists, .closeToHome, .furtherOut, .trending,
             .genreCharts:
            // Round 14 A6 (D109): from the provider, never from Aurral directly; nothing while it doesn't offer it.
            guard !isOffline, homeOutsideSections.contains(section) else { return [] }
            // Shown from its saved shelf, not named yet (I2): not loaded, so the saved copy stays and it is retried.
            guard homeAurralShelves.availableSections.contains(section) else { throw HomeSectionNotOffered() }
            let rows = section == .becauseYouLike ? HomeSectionStyle.becauseYouLikeRange.upperBound : 1
            return try await homeAurralShelves.items(for: section, limit: size * rows).prefix(size * rows)
                .map(HomeShelf.Item.outside)
        case .discover:   // Y6: Aurral's flow playlists (AppModel+Discover.swift)
            let flows = try await discoverPlaylists().prefix(size).map(HomeShelf.Item.playlist)
            return flows + (await forYouOnHome(limit: size - flows.count)).map(HomeShelf.Item.outside)   // round 14 A4
        }
    }

    /// Y3: the Playlists shelf's order: the signed-in user's own first, then public ones from others; within each,
    /// the most recently changed first (no date last), then by name. Discover's playlists (Aurral flows, Y6) are left
    /// out: they have their own section.
    nonisolated static func homePlaylists(_ playlists: [Playlist], username: String?,
                                          isDiscover: (Playlist) -> Bool = { _ in false }) -> [Playlist] {
        func own(_ p: Playlist) -> Bool {
            guard let owner = p.owner, let username else { return false }
            return owner.caseInsensitiveCompare(username) == .orderedSame
        }
        return playlists.filter { !isDiscover($0) }.sorted { a, b in
            if own(a) != own(b) { return own(a) }
            let at = a.changed ?? .distantPast, bt = b.changed ?? .distantPast
            if at != bt { return at > bt }
            switch a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// Y6 hook: whether a playlist belongs in Discover (an Aurral flow) rather than Playlists. None until Aurral is
    /// set up.
    func isDiscoverPlaylist(_ playlist: Playlist) -> Bool { isDiscoverPlaylist(id: playlist.id) }

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
                                              lidarrConnected: lidarr != nil, carPlay: carPlay,
                                              discoverSetUp: aurralSetUp,   // Y6
                                              trendingSetUp: aurralFeeds?.can.trending ?? false,   // round 14 A4
                                              recommendedSetUp: aurralFeeds?.can.recommendations ?? false)
    }

    /// The Recently added grid at the bottom of the Library: its own switch, and never offline.
    var showsRecentlyAddedGrid: Bool { preferences.layout.showsRecentlyAdded && !isOffline }

    /// One page of every song, A–Z by title (`page` from 0).
    func songsPage(_ page: Int) async throws -> [Song] {
        let size = Self.songsPageSize
        return try await request { try await $0.songsPage(start: page * size, end: (page + 1) * size, sort: "title") }.songs
    }

    /// Library › Favourites: every starred song, album and artist (`getStarred2`), noted as favourites (R7).
    func favourites() async throws -> Starred {
        let starred = try await request { try await $0.starred() }
        noteFavourites(starred)
        return starred
    }
}

/// B1: runs `op` for at most `limit`. Past it the answer is a `CancellationError` (Home's "not read yet") and `op` is
/// cancelled without being waited for, so an answer that never comes can't hold a read up.
enum HomeDeadline {
    static func run<T: Sendable>(_ limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                                 _ op: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
        let once = Once<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>, Never>) in
                let work = Task {
                    let result: Result<T, any Error>
                    do { result = .success(try await op()) } catch { result = .failure(error) }
                    once.finish(result)
                }
                let timer = Task {
                    do { try await sleep(limit) } catch { return }
                    once.finish(.failure(CancellationError()))
                }
                once.start(continuation, cancelling: [work, timer])
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }

    /// The first answer wins; then both tasks are cancelled.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, any Error>, Never>?
        private var early: Result<T, any Error>?
        private var tasks: [Task<Void, Never>] = []
        private var done = false

        func start(_ continuation: CheckedContinuation<Result<T, any Error>, Never>, cancelling tasks: [Task<Void, Never>]) {
            lock.lock()
            if let early {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            guard let continuation else { early = result; lock.unlock(); return }
            self.continuation = nil
            let tasks = self.tasks
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation.resume(returning: result)
        }
    }
}
