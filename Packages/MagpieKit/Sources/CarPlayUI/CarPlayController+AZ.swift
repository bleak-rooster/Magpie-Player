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
    /// Songs open on their five letter groups (LetterBands.swift); Playlists keep Y2's letters screen.
    func azFetcher(for destination: CPDestination) -> (@MainActor () async throws -> Content)? {
        let library = library
        let maxItems = Int(CPListTemplate.maximumItemCount), maxSections = Int(CPListTemplate.maximumSectionCount)
        func once(_ build: @escaping @Sendable () -> [CPSectionModel]) async -> Content {
            let sections = await Task.detached(priority: .userInitiated) { build() }.value
            return { _ in sections }
        }
        switch destination {
        case .playlists:
            return {
                let p = try await library.playlists()
                return await once { CarPlayRows.playlists(p, maxItems: maxItems, maxSections: maxSections) }
            }
        case .artists:
            return {
                let a = try await library.artists()
                return await once { CarPlayRows.artistBands(a, maxItems: maxItems) }
            }
        case .albums:
            return {
                let (albums, total) = try await Self.readAlbums(library)
                return await once { CarPlayRows.albumBands(albums, maxItems: maxItems, total: total) }
            }
        case .songs:
            return {
                let index = try await library.songIndex()
                return await once { CarPlayRows.songBands(index, maxItems: maxItems) }
            }
        case .songRange(_, let ranges):
            return {
                let (songs, total) = try await Self.readSongs(library, ranges: ranges, limit: maxItems)
                return { CarPlayRows.songPage(songs, total: total, playingId: $0) }
            }
        case .letterGroup(_, let sections):
            return { { _ in sections } }
        default:
            return nil
        }
    }

    /// The A–Z lists shown, read again for the car's limits now (M3: limited lists while driving, and back).
    func reloadAZLists() {
        for binding in bindings.values {
            guard let destination = binding.destination, [.playlists, .artists, .albums, .songs].contains(destination),
                  let fetch = azFetcher(for: destination) else { continue }
            load(binding, fetch)
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

    /// A song group's songs (round 13): its offset ranges in order, a page at a time, at most the car's list limit. When
    /// the group holds more, one row is left for "Showing N of M" and `total` says how many.
    static func readSongs(_ library: any CarPlayLibrary, ranges: [Range<Int>],
                          limit: Int) async throws -> (songs: [Song], total: Int?) {
        let total = ranges.reduce(0) { $0 + $1.count }
        let wanted = total <= limit ? total : max(1, limit - 1)
        var songs: [Song] = []
        for range in ranges where songs.count < wanted {
            var offset = range.lowerBound
            while offset < range.upperBound, songs.count < wanted {
                let size = min(songPageSize, range.upperBound - offset, wanted - songs.count)
                let page = try await library.songsByTitle(offset: offset, size: size)
                songs += page.prefix(size)
                if page.count < size { break }   // the library changed since the index was read
                offset += size
            }
        }
        return (songs, total > songs.count ? total : nil)
    }

    /// All the artist's songs, album by album in the artist page's order (2c: Play is in that order).
    func artistSongs(_ id: String) async throws -> [Song] {
        let library = library
        let (_, albums) = try await library.artist(id: id)
        let byAlbum = try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            for (i, album) in albums.enumerated() { group.addTask { (i, try await library.album(id: album.id).songs ?? []) } }
            var found: [Int: [Song]] = [:]
            for try await (i, songs) in group { found[i] = songs }
            return found
        }
        return albums.indices.flatMap { byAlbum[$0] ?? [] }
    }
}
#endif
