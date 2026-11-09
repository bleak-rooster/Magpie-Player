#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore

// Y2 (round 12 item 2): the reads behind the car's A–Z lists, and the artist's songs for Play and Shuffle (2c). Fix
// round 1 (I1): kept out of CarPlayController.swift, which only calls `azFetcher` and `artistSongs`.
extension CarPlayController {
    /// Navidrome's largest album-list page.
    static let albumListSize = 500
    /// Most albums the car's Albums reads: ten pages. Past it the list says "Showing 5000 of N".
    static let albumsMax = 5000
    /// Single-row reads allowed to count the albums past `albumsMax`.
    static let albumCountProbes = 40

    /// Playlists, Artists, Albums, Songs and a letter group's list; nil for anything else. Each list is laid out once
    /// per read, off the main thread (M1: its rows don't depend on the song playing; a song group's do). The car's
    /// limits are read now; `reloadAZLists` reads the lists again when they change. Round 13: Artists, Albums and
    /// Songs open on their five letter groups (LetterBands.swift); round 24 (D230): Playlists too, over the ceiling.
    /// Z3 review I2: `binding` keeps what was read, so new limits only lay it out again (`reloadAZLists`).
    func azFetcher(for destination: CPDestination, into binding: ListBinding? = nil)
        -> (@MainActor () async throws -> Content)? {
        let library = library
        let limits = listLimits()
        @MainActor func once(_ build: @escaping @Sendable (_ items: Int, _ sections: Int) -> [CPSectionModel]) async -> Content {
            let layout: (Int, Int) async -> [CPSectionModel] = { items, sections in
                await Task.detached(priority: .userInitiated) { build(items, sections) }.value
            }
            let sections = await layout(limits.items, limits.sections)
            binding?.limits = limits
            binding?.relayout = layout
            return { _ in sections }
        }
        switch destination {
        case .playlists:
            return {
                let p = try await library.playlists()
                let user = library.playlistCaptionUser   // R24F: whose, while everyone's show (D223, D179)
                return await once { CarPlayRows.playlistBands(p, maxItems: $0, maxSections: $1, signedInUser: user) }
            }
        case .artists:
            return {
                let a = try await library.artists()
                return await once { items, _ in CarPlayRows.artistBands(a, maxItems: items) }
            }
        case .albums:
            return {
                let (albums, total) = try await Self.readAlbums(library)
                return await once { items, _ in CarPlayRows.albumBands(albums, maxItems: items, total: total) }
            }
        case .songs:
            return {
                let index = try await library.songIndex()
                return await once { items, _ in CarPlayRows.songBands(index, maxItems: items) }
            }
        case .songRange(let title, let ranges):
            return songPageFetcher(ranges, title: title, base: destination, start: 0, limits: limits, into: binding)
        case .letterGroup(_, let sections):
            return { { _ in sections } }
        case .page(let ref):
            // R24F (D231): a song group's page reads its own songs; any other page is its list read again (only when
            // it couldn't be laid out from what was read).
            if case .songRange(let title, let ranges)? = ref.base {
                return songPageFetcher(ranges, title: title, base: .songRange(title: title, ranges: ranges),
                                       start: ref.start, limits: limits, into: binding)
            }
            return ref.base.flatMap { azFetcher(for: $0, into: binding) }
        default:
            return nil
        }
    }

    /// The A–Z lists shown, laid out again for the car's limits now (M3: limited lists while driving, and back). Z3
    /// review I2: only when the limits really changed, and from what each list already read; a list not read yet is
    /// read.
    /// Round 24 (D231): pages follow the new limits too. A song group's page is read again for them (its page holds
    /// only its songs); every other list is laid out again from what it shows (a list on screen keeps its shape until
    /// it is off screen, `apply`).
    func reloadAZLists() {
        let now = listLimits()
        for binding in bindings.values {
            let base: CPDestination? = if case .page(let ref) = binding.destination { ref.base } else { binding.destination }
            if case .songRange? = base {
                if let limits = binding.limits, limits == now { continue }
                if let destination = binding.destination, let fetch = azFetcher(for: destination, into: binding) {
                    load(binding, fetch)
                }
                continue
            }
            guard let destination = binding.destination, let base, [.playlists, .artists, .albums, .songs].contains(base)
            else {
                if binding.content != nil { Task { [weak self] in await self?.refresh(binding) } }
                continue
            }
            if let limits = binding.limits, limits == now { continue }
            if let relayout = binding.relayout, !binding.isPlaceholder {
                binding.loadTask?.cancel()
                binding.loadTask = Task { [weak self] in
                    let sections = await relayout(now.items, now.sections)
                    guard !Task.isCancelled, let self else { return }
                    binding.limits = now
                    binding.content = { _ in sections }
                    await self.refresh(binding)
                }
            } else if let fetch = azFetcher(for: destination, into: binding) {
                load(binding, fetch)
            }
        }
    }

    /// Albums A–Z, page after page past the server's 500, up to `albumsMax`. At the cap, the library's album count
    /// (found by single-row reads: gallop, then halve) so the list can say how many it shows.
    static func readAlbums(_ library: any CarPlayLibrary) async throws -> (albums: [Album], total: Int?) {
        var albums: [Album] = []
        while albums.count < albumsMax {
            let page = try await library.albumsAZ(offset: albums.count, size: albumListSize)
            albums += page
            if page.count < albumListSize { return (albums, nil) }
        }
        var probes = 0
        func pastEnd(_ offset: Int) async throws -> Bool {
            probes += 1
            return try await library.albumsAZ(offset: offset, size: 1).isEmpty
        }
        let start = albums.count
        if try await pastEnd(start) { return (albums, nil) }
        var low = start + 1, step = start, high = start + step
        while try await !pastEnd(high) {
            low = high + 1
            step *= 2
            high = start + step
            guard probes < albumCountProbes / 2 else { return (albums, low) }
        }
        while low < high, probes < albumCountProbes {
            let mid = low + (high - low) / 2
            if try await pastEnd(mid) { high = mid } else { low = mid + 1 }
        }
        return (albums, low)
    }

    /// Songs per read of a song group.
    static let songPageSize = 500

    /// A song group's songs (round 13): its offset ranges in order, a page at a time, at most `limit`. When the ranges
    /// hold more, one place is left (round 13's "Showing N of M") and `total` says how many; round 24's pages ask for
    /// exactly their own songs, so they always get all of them.
    static func readSongs(_ library: any CarPlayLibrary, ranges: [Range<Int>], limit: Int,
                          pageSize: Int = songPageSize) async throws -> (songs: [Song], total: Int?) {
        let total = ranges.reduce(0) { $0 + $1.count }
        let wanted = total <= limit ? total : max(1, limit - 1)
        var songs: [Song] = []
        for range in ranges where songs.count < wanted {
            var offset = range.lowerBound
            while offset < range.upperBound, songs.count < wanted {
                let size = min(pageSize, range.upperBound - offset, wanted - songs.count)
                let page = try await library.songsByTitle(offset: offset, size: size)
                songs += page.prefix(size)
                // Z3 review M3: a page short by missing files still holds its place; only an empty one ends the range
                // (the library changed since the index was read).
                if page.isEmpty { break }
                offset += size
            }
        }
        return (songs, total > songs.count ? total : nil)
    }

    /// Round 24 (owner, 2026-11-08; D231): a song group's page. The group's songs are cut into pages for the car's
    /// limits by count (`CPPager.breaks`), and the page holding `start` reads only its own songs, so every song is
    /// reachable through "More…" without reading the whole group (D65: a group was read up to the limit, then "Showing
    /// N of M"). Its letter sections give way to one plain section when they and the navigation rows wouldn't fit.
    func songPageFetcher(_ ranges: [Range<Int>], title: String, base: CPDestination, start: Int,
                         limits: (items: Int, sections: Int), into binding: ListBinding?)
        -> @MainActor () async throws -> Content {
        let library = library
        let total = ranges.reduce(0) { $0 + $1.count }
        let pages = CPPager.breaks(rowCount: total, maxItems: limits.items, maxSections: limits.sections)
        let index = pages.firstIndex { $0.contains(start) } ?? max(0, pages.count - 1)
        binding?.limits = limits
        return {
            guard pages.indices.contains(index) else { return { _ in CarPlayRows.state(.empty) } }
            let rows = pages[index]
            let songs = try await Self.readSongs(library, ranges: CarPlayRows.slice(ranges, rows), limit: rows.count).songs
            func link(_ i: Int) -> CPPageLink? {
                pages.indices.contains(i)
                    ? CPPageLink(start: pages[i].lowerBound, count: pages[i].count, index: i, pageCount: pages.count) : nil
            }
            let previous = CPPager.hasPrevious(maxItems: limits.items) ? link(index - 1) : nil
            let next = link(index + 1)
            let navigation = (previous == nil ? 0 : 1) + (next == nil ? 0 : 1)
            let action = CPPageRef.action(base: base, baseTitle: title)
            return { playing in
                var content = CarPlayRows.songPage(songs, total: nil, playingId: playing)
                if content.count + (CPPager.ownSections(maxSections: limits.sections) ? navigation : 0) > limits.sections {
                    content = [CPSectionModel(header: nil, rows: content.flatMap(\.rows))]
                }
                return CPPager.assemble(content, previous: previous, next: next, maxSections: limits.sections, link: action)
            }
        }
    }

    /// All the artist's songs, album by album in the artist page's order (2c: Play is in that order).
    func artistSongs(_ id: String) async throws -> [Song] {
        let library = library
        let (_, albums) = try await library.artist(id: id)
        // B1 fix round (D120): answers by album id, never by position.
        let byAlbum = try await KeyedGather.values(albums.map(\.id)) { id in try await library.album(id: id).songs ?? [] }
        return albums.flatMap { byAlbum[$0.id] ?? [] }
    }
}
#endif
