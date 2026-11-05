import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 15 C4 (D141): the server's native album list for a genre page: genre names become Navidrome's ids, and each
/// page is read through the session's client.
struct ServerGenreAlbums: GenreAlbumSource {
    let ids: [String: String]
    let read: @Sendable (GenreAlbumQuery, [String], Int, Int) async throws -> GenreAlbumPage

    /// Whether every genre in `names` has a native id (else the page sorts on the phone, D144).
    func knows(_ names: [String]) -> Bool { names.allSatisfy { ids[$0] != nil } }

    func page(_ query: GenreAlbumQuery, start: Int, end: Int) async throws -> GenreAlbumPage {
        try await read(query, query.genres.compactMap { ids[$0] }, start, end)
    }
}

/// Round 15 C4 (owner, build 15: "there has to be a way to filter and sort the albums when you open up Genres"): a
/// group's or a genre's albums, sorted and filtered (D141–D145).
///
/// - **Server** (normal): Navidrome sorts and filters (`/api/album`), and the page holds only the pages scrolled to.
/// - **Phone**: offline and Downloaded only use the albums on the phone; a server without the native list (or a genre
///   it can't name) uses the Subsonic list as before (at most 500 albums a genre); either is sorted and filtered here.
@MainActor @Observable final class GenreAlbumBrowser {
    enum Kind { case group, genre }

    /// Where the list on screen comes from.
    enum Origin: Equatable { case server, phone, subsonic }

    let kind: Kind
    /// The page's genres (a group's sub-genres with their counts; a genre page's one).
    private(set) var genres: [Genre] = []
    private(set) var sort: GenreAlbumSort = .name
    private(set) var filter = GenreAlbumFilter.none
    private(set) var albums: Loadable<[Album]> = .loading
    /// How many albums the list has (nil: not known yet).
    private(set) var total: Int?
    private(set) var decades: [Int] = []
    private(set) var origin: Origin = .server
    /// A decade too big to sort on the phone is shown in year order.
    private(set) var inYearOrder = false
    private(set) var loadingMore = false
    /// Changes on every reload, so a view can scroll back to the top.
    private(set) var generation = 0

    private weak var model: AppModel?
    private var pager: GenreAlbumPager?
    private var server: ServerGenreAlbums?
    private var seed = Int.random(in: 1...Int(Int32.max))

    init(kind: Kind) { self.kind = kind }

    /// The page's sort, picked last time on this kind of page (D143).
    private func keptSort(_ model: AppModel) -> GenreAlbumSort {
        kind == .group ? model.preferences.genres.groupSort : model.preferences.genres.genreSort
    }

    /// Called when the page has its genres (and again when they or the offline state change).
    func start(model: AppModel, genres: [Genre]) async {
        self.model = model
        let names = Set(genres.map(\.name))
        filter.genres = filter.genres.intersection(names)
        self.genres = genres
        sort = keptSort(model)
        server = nil
        decades = decadeKey.flatMap { Self.decadeCache[$0] } ?? []
        await reload()
    }

    // MARK: - The owner's choices

    func pick(_ sort: GenreAlbumSort) async {
        if sort == .random { seed = Int.random(in: 1...Int(Int32.max)) }   // a fresh shuffle each time it is picked
        guard sort != self.sort || sort == .random else { return }
        self.sort = sort
        model?.updatePreferences { [kind] in
            if kind == .group { $0.genres.groupSort = sort } else { $0.genres.genreSort = sort }
        }
        await reload()
    }

    func toggle(genre name: String) async {
        if filter.genres.contains(name) { filter.genres.remove(name) } else { filter.genres.insert(name) }
        await reload()
    }

    func pick(decade: Int?) async {
        guard decade != filter.decade else { return }
        filter.decade = decade
        await reload()
    }

    func setFavouritesOnly(_ on: Bool) async {
        filter.favouritesOnly = on
        await reload()
    }

    func setDownloadedOnly(_ on: Bool) async {
        filter.downloadedOnly = on
        await reload()
    }

    /// Typed text: read after a short pause, so each letter doesn't ask the server.
    func setText(_ text: String) async {
        guard text != filter.text else { return }
        filter.text = text
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, filter.text == text else { return }
        await reload()
    }

    /// Every filter off (the sort stays).
    func clearFilters() async {
        filter = .none
        await reload()
    }

    // MARK: - Reading

    /// The genres asked for now.
    var askedGenres: [String] { filter.genres(of: genres.map(\.name)) }

    func reload() async {
        guard let model else { return }
        generation += 1
        let mine = generation
        loadingMore = false
        loadMoreFailed = false
        pager = nil
        if albums.value == nil { albums = .loading }
        let asked = askedGenres
        guard !asked.isEmpty else {
            albums = .loaded([]); total = 0
            return
        }
        if model.isOffline || filter.downloadedOnly {
            let phone = await model.phoneGenreAlbums(Set(asked))
            guard mine == generation else { return }
            showOnPhone(phone, origin: .phone)
            return
        }
        do {
            if server == nil { server = try await model.serverGenreAlbums() }
            guard mine == generation else { return }
            guard let server, server.knows(asked) else { try await readSubsonic(asked, mine); return }
            let query = GenreAlbumQuery(genres: asked, sort: sort, text: filter.searchText,
                                        favouritesOnly: filter.favouritesOnly, seed: seed)
            let pager = GenreAlbumPager(source: server, query: query, decade: filter.decade)
            try await pager.loadFirst()
            guard mine == generation else { return }
            self.pager = pager
            origin = .server
            inYearOrder = pager.inYearOrder
            total = pager.total
            albums = .loaded(pager.albums)
            if decades.isEmpty { await readDecades(server, mine) }
        } catch where AppModel.nativeListUnsupported(error) {
            guard mine == generation else { return }
            // Review I2: the Subsonic list failing too says so (or, with albums on screen, the "couldn't refresh" notice).
            do {
                try await readSubsonic(asked, mine)
            } catch {
                guard mine == generation else { return }
                albums = albums.failing(error, noticeTo: model)
            }
        } catch {
            guard mine == generation else { return }
            albums = albums.failing(error, noticeTo: model)
        }
    }

    /// The next page, when the last album shows.
    func loadMore() async {
        guard let pager, pager.hasMore, !loadingMore else { return }
        let mine = generation
        loadingMore = true
        loadMoreFailed = false
        defer { if mine == generation { loadingMore = false } }
        do {
            try await pager.loadMore()
            guard mine == generation else { return }
            albums = .loaded(pager.albums)
        } catch {
            // Review M3: the albums on screen stay, and the grid's end offers Try again instead of a spinner.
            guard mine == generation, !AppModel.isCancellation(error) else { return }
            loadMoreFailed = true
        }
    }

    var hasMore: Bool { pager?.hasMore ?? false }

    /// The last "more" read failed: the grid's end says so, with Try again.
    private(set) var loadMoreFailed = false

    func retryMore() async { await loadMore() }

    /// No native list (or a genre it can't name): the Subsonic list as before, sorted and filtered on the phone.
    private func readSubsonic(_ asked: [String], _ mine: Int) async throws {
        guard let model else { return }
        let names = Set(asked)
        let listed = try await model.groupAlbums(in: genres.filter { names.contains($0.name) })
        guard mine == generation else { return }
        showOnPhone(listed, origin: .subsonic)
    }

    private func showOnPhone(_ list: [Album], origin: Origin) {
        var narrowed = filter
        narrowed.genres = []
        let shown = GenreAlbumOrder.apply(list, sort: sort, filter: narrowed, seed: seed)
        self.origin = origin
        inYearOrder = false
        total = shown.count
        albums = .loaded(shown)
        if decades.isEmpty || filter.decade == nil {
            let years = list.compactMap(\.year).filter { $0 > 0 }
            decades = Decades.spanning(oldest: years.min(), newest: years.max())
        }
    }

    /// The decades the page's albums span (all its genres), from a few single-album reads.
    /// Review M1: the decades a page spans are read once per account and set of genres and kept for the session (a
    /// handful of single-album reads), not on every open.
    private static var decadeCache: [String: [Int]] = [:]

    private var decadeKey: String? {
        guard let scope = model?.navidromeScope else { return nil }
        return "\(scope)|" + genres.map(\.name).sorted().joined(separator: "\u{1F}")
    }

    private func readDecades(_ server: ServerGenreAlbums, _ mine: Int) async {
        let all = GenreAlbumQuery(genres: genres.map(\.name), sort: .oldest)
        guard let span = try? await GenreAlbumPager.yearSpan(server, query: all), mine == generation else { return }
        decades = Decades.spanning(oldest: span.oldest, newest: span.newest)
        if let key = decadeKey {
            if Self.decadeCache.count >= 200 { Self.decadeCache.removeAll() }
            Self.decadeCache[key] = decades
        }
    }
}

// MARK: - The controls

/// The sort and filter row under a genre page's header: the sort, the sub-genres (a group's), the decade, Favourites
/// and Downloaded as chips; Clear when anything is on; and how many albums that leaves.
struct GenreAlbumControls: View {
    let browser: GenreAlbumBrowser
    @Environment(AppModel.self) private var model
    @Environment(\.magpieTheme) private var theme
    private let themed = Themed()

    /// Sub-genres shown as chips (the biggest first); the rest are in More.
    static let chipLimit = 12

    var body: some View {
        let p = themed.palette
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    sortMenu
                    // Next to the sort, so it is always on screen while a filter is on.
                    if browser.filter.isActive {
                        Button { Task { await browser.clearFilters() } } label: {
                            ChipLabel(title: "Clear", symbol: "xmark", isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filters")
                        .accessibilityIdentifier("genre-clear")
                    }
                    if browser.decades.count > 1 || browser.filter.decade != nil { decadeMenu }
                    FilterChip("Favourites", isSelected: browser.filter.favouritesOnly) {
                        Task { await browser.setFavouritesOnly(!browser.filter.favouritesOnly) }
                    }
                    .accessibilityIdentifier("genre-favourites")
                    if !model.isOffline {
                        FilterChip("Downloaded", isSelected: browser.filter.downloadedOnly) {
                            Task { await browser.setDownloadedOnly(!browser.filter.downloadedOnly) }
                        }
                        .accessibilityIdentifier("genre-downloaded")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.margin)
            }
            if browser.kind == .group, browser.genres.count > 1 { subGenreChips }
            Text(summary).font(theme.numberFont(.footnote)).foregroundStyle(p.ink2Color)
                .padding(.horizontal, Tokens.Spacing.margin)
                .accessibilityIdentifier("genre-album-count")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort and filter")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(GenreAlbumSort.allCases, id: \.self) { sort in
                Button { Task { await browser.pick(sort) } } label: {
                    if sort == browser.sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                }
                .accessibilityIdentifier("genre-sort-\(sort.rawValue)")
            }
        } label: {
            ChipLabel(title: browser.sort.title, symbol: "arrow.up.arrow.down", isSelected: false, menu: true)
        }
        .accessibilityLabel("Sort: \(browser.sort.title)")
        .accessibilityIdentifier("genre-sort")
    }

    private var decadeMenu: some View {
        Menu {
            Button { Task { await browser.pick(decade: nil) } } label: {
                if browser.filter.decade == nil { Label("Any year", systemImage: "checkmark") } else { Text("Any year") }
            }
            ForEach(browser.decades, id: \.self) { decade in
                Button { Task { await browser.pick(decade: decade) } } label: {
                    if browser.filter.decade == decade {
                        Label(Decades.label(decade), systemImage: "checkmark")
                    } else {
                        Text(Decades.label(decade))
                    }
                }
            }
        } label: {
            ChipLabel(title: browser.filter.decade.map(Decades.label) ?? "Decade", symbol: nil,
                      isSelected: browser.filter.decade != nil, menu: true)
        }
        .accessibilityLabel(browser.filter.decade.map { "Decade: \(Decades.label($0))" } ?? "Decade")
        .accessibilityIdentifier("genre-decade")
    }

    private var subGenreChips: some View {
        let ranked = browser.genres.sorted { $0.albumCount > $1.albumCount }
        let picked = browser.filter.genres
        let chips = ranked.prefix(Self.chipLimit) + ranked.dropFirst(Self.chipLimit).filter { picked.contains($0.name) }
        let rest = ranked.dropFirst(Self.chipLimit)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(Array(chips), id: \.name) { genre in
                    FilterChip(genre.countsKnown ? "\(genre.name) · \(genre.albumCount)" : genre.name,
                               isSelected: picked.contains(genre.name)) {
                        Task { await browser.toggle(genre: genre.name) }
                    }
                    .accessibilityIdentifier("genre-chip-\(genre.name)")
                }
                if !rest.isEmpty {
                    Menu {
                        ForEach(Array(rest), id: \.name) { genre in
                            Button { Task { await browser.toggle(genre: genre.name) } } label: {
                                let title = genre.countsKnown ? "\(genre.name) (\(genre.albumCount))" : genre.name
                                if picked.contains(genre.name) { Label(title, systemImage: "checkmark") } else { Text(title) }
                            }
                        }
                    } label: {
                        ChipLabel(title: "More genres", symbol: nil, isSelected: false, menu: true)
                    }
                    .accessibilityIdentifier("genre-chip-more")
                }
            }
            .padding(.horizontal, Tokens.Spacing.margin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Genres in this group")
    }

    private var summary: String {
        var parts: [String] = []
        if let total = browser.total { parts.append(GenreAlbumCopy.count(total)) }
        if browser.inYearOrder { parts.append(GenreAlbumCopy.inYearOrder) }
        switch browser.origin {
        case .server: break
        case .phone: if !model.isOffline, browser.filter.downloadedOnly { parts.append(GenreAlbumCopy.onPhone) }
        case .subsonic: parts.append(GenreAlbumCopy.subsonic)
        }
        return parts.joined(separator: " · ")
    }
}

enum GenreAlbumCopy {
    static func count(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "album" : "albums")" }
    static let inYearOrder = "In year order (too many to sort)"
    static let onPhone = "On this phone"
    static let subsonic = "Up to 500 a genre"
    static let noneMatch = "No albums match."
    static let moreFailed = "Couldn't load more. Try again"
}

/// A chip that opens a menu (or a plain one inside a button): the same capsule as `FilterChip`.
struct ChipLabel: View {
    let title: String
    let symbol: String?
    let isSelected: Bool
    var menu = false
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.semibold))
            if menu { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .padding(.horizontal, Tokens.CompactCapsule.horizontalPadding)
        .frame(minHeight: Tokens.CompactCapsule.height)
        .foregroundStyle(isSelected ? p.onAccentColor : p.inkColor)
        .background(isSelected ? p.accentColor : p.surfaceColor, in: Capsule())
        .frame(minHeight: Tokens.minHitSize)
        .contentShape(Rectangle())
    }
}

/// The albums of a genre page: the grid, more as the last one shows, and what to say when none match.
struct GenreAlbumList: View {
    let browser: GenreAlbumBrowser
    let emptyText: String
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        LoadableView(state: browser.albums, retry: { await browser.reload() }) { albums in
            if albums.isEmpty {
                Text(browser.filter.isActive ? GenreAlbumCopy.noneMatch : (model.isOffline ? OfflineCopy.notOnPhone : emptyText))
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    .accessibilityIdentifier("genre-albums-empty")
            } else {
                VStack(spacing: Tokens.Spacing.l) {
                    AlbumGrid(albums: albums, subtitle: subtitle) { Task { await browser.loadMore() } }
                    if browser.loadMoreFailed {
                        Button { Task { await browser.retryMore() } } label: {
                            Label(GenreAlbumCopy.moreFailed, systemImage: "arrow.clockwise").font(.footnote)
                        }
                        .accessibilityIdentifier("genre-load-more-retry")
                    } else if browser.hasMore {
                        ProgressView().accessibilityLabel("Loading more albums")
                    }
                }
            }
        }
    }

    private func subtitle(_ album: Album) -> String { Self.subtitle(album, sort: browser.sort) }

    static func subtitle(_ album: Album, sort: GenreAlbumSort) -> String {
        switch sort {
        case .newest, .oldest: album.sortYear.map { "\(album.artist) · \($0)" } ?? album.artist
        default: album.artist
        }
    }
}
