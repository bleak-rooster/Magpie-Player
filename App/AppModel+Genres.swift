import Foundation
import MagpieCore
import NavidromeKit
import Search

/// Genres (spec §4, Task 19): the server's genres grouped by `GenreGroups`, a group's albums merged from its genres, a
/// group's Shuffle (round-robin across its genres, capped at `groupSongCap`), a genre's songs in server order, and the
/// owner's overrides (move a genre, new groups, names, hidden groups) kept in Preferences.
///
/// Offline (spec §6) every answer comes from the downloads' snapshots instead, and nothing is sent: the genres are those
/// of the songs on the phone, and Play and Shuffle use only those songs.
extension AppModel {
    /// A group's Shuffle, and a genre's Play and Shuffle, take at most this many songs.
    static let groupSongCap = 500
    /// A genre page, and each genre of a group page, shows at most this many albums (one `getAlbumList2` page).
    static let genreAlbumCap = 500
    /// A group's genres are asked this many at a time.
    static let fetchWidth = 4

    // MARK: - Lists

    /// The visible groups, each with its genres (hidden and empty groups are left out).
    func genreSections() async throws -> [GenreGroupSection] {
        GenreGroups.grouped(try await rawGenres(), preferences: preferences.genres)
    }

    /// Every group with genres, the hidden ones too (Edit lists them so they can be shown again).
    func genreSectionsIncludingHidden() async throws -> [GenreGroupSection] {
        var prefs = preferences.genres
        prefs.hidden = []
        return GenreGroups.grouped(try await rawGenres(), preferences: prefs)
    }

    /// The flat "All genres" list, A–Z. Hiding a group doesn't hide its genres here.
    func allGenres() async throws -> [Genre] {
        GenreGroups.allGenres(try await rawGenres())
    }

    /// Where "Move to group…" can send a genre: every group not hidden, built in first, then the owner's.
    var genreGroupChoices: [GenreGroup] {
        let prefs = preferences.genres
        let custom = prefs.customGroups.map { GenreGroup(id: $0, name: prefs.groupNames[$0] ?? "Custom") }
        return (GenreGroups.builtIn.map { GenreGroup(id: $0.id, name: prefs.groupNames[$0.id] ?? $0.name) } + custom)
            .filter { !prefs.hidden.contains($0.id) }
    }

    /// Whether another group fits (Preferences keeps at most `GenrePreferences.maxCustomGroups`).
    var canCreateGroup: Bool { preferences.genres.customGroups.count < GenrePreferences.maxCustomGroups }

    // MARK: - Groups

    /// A group's page: its section, and its genres in the order the server lists them (from one `getGenres`).
    struct GenreGroupPage: Sendable {
        let section: GenreGroupSection
        let genres: [Genre]
    }

    /// One group, hidden or not, with its genres in server order; nil when it has no genres. Asks for the genres once.
    func genreGroup(_ groupId: String) async throws -> GenreGroupPage? {
        let raw = try await rawGenres()
        var prefs = preferences.genres
        prefs.hidden = []
        guard let section = GenreGroups.grouped(raw, preferences: prefs).first(where: { $0.group.id == groupId }) else {
            return nil
        }
        let names = Set(section.genres.map(\.name))
        return GenreGroupPage(section: section, genres: raw.filter { names.contains($0.name) })
    }

    /// The albums of every genre in the group, merged and de-duplicated by id, in first-seen order (genres in server
    /// order).
    func groupAlbums(_ groupId: String) async throws -> [Album] {
        try await groupAlbums(in: try await genreGroup(groupId)?.genres ?? [])
    }

    /// `groupAlbums` for a group's genres already in hand: at most `genreAlbumCap` albums from each genre, asked
    /// `fetchWidth` genres at a time and merged in the genres' order, so the result doesn't depend on which answers first.
    func groupAlbums(in genres: [Genre]) async throws -> [Album] {
        if isOffline { return await offlineAlbums(Set(genres.map(\.name))) }
        let pages = try await inOrder(genres.map(\.name)) { [weak self] name in try await self?.serverAlbums(name) ?? [] }
        var seen = Set<String>()
        return pages.joined().filter { seen.insert($0.id).inserted }
    }

    /// The group's songs for Shuffle (a group offers Shuffle only).
    func groupSongs(_ groupId: String) async throws -> [Song] {
        try await groupSongs(in: try await genreGroup(groupId)?.genres ?? [])
    }

    /// `groupSongs` for a group's genres already in hand: the songs of `groupSongsInFetchOrder`, shuffled.
    func groupSongs(in genres: [Genre]) async throws -> [Song] {
        try await groupSongsInFetchOrder(genres).shuffled()
    }

    /// Up to `groupSongCap` songs taken from each genre in turn (round-robin, so one big genre can't crowd out the
    /// rest), before the shuffle. Each round asks every genre that may have more for an equal share of what is still
    /// wanted; a genre that gives a short page, or nothing new (a server ignoring the offset), is done.
    func groupSongsInFetchOrder(_ genres: [Genre]) async throws -> [Song] {
        let cap = Self.groupSongCap
        if isOffline {
            var lists: [[Song]] = []
            for genre in genres { lists.append(await offlineSongs([genre.name])) }
            return Self.roundRobin(lists, cap: cap)
        }
        var lists = Array(repeating: [Song](), count: genres.count)
        var offsets = Array(repeating: 0, count: genres.count)
        var active = Array(genres.indices)
        var seen = Set<String>()
        var total = 0
        while total < cap, !active.isEmpty {
            let quota = (cap - total + active.count - 1) / active.count
            let asks = active.map { SongAsk(genre: genres[$0].name, offset: offsets[$0]) }
            let pages = try await inOrder(asks) { [weak self] ask in
                try await self?.request { try await $0.songs(genre: ask.genre, count: quota, offset: ask.offset) } ?? []
            }
            var still: [Int] = []
            for (index, page) in zip(active, pages) {
                let fresh = page.filter { seen.insert($0.id).inserted }
                lists[index] += fresh
                offsets[index] += page.count
                total += fresh.count
                if page.count == quota, !fresh.isEmpty { still.append(index) }
            }
            active = still
        }
        return Self.roundRobin(lists, cap: cap)
    }

    // MARK: - Genres

    /// A genre's albums, at most `genreAlbumCap`.
    func genreAlbums(_ name: String) async throws -> [Album] {
        if isOffline { return await offlineAlbums([name]) }
        return try await serverAlbums(name)
    }

    /// A genre's first `groupSongCap` songs in server order (Play); Shuffle shuffles them.
    func genreSongs(_ name: String) async throws -> [Song] {
        if isOffline { return Array(await offlineSongs([name]).prefix(Self.groupSongCap)) }
        return try await request { [cap = Self.groupSongCap] in try await $0.songs(genre: name, count: cap, offset: 0) }
    }

    // MARK: - The owner's overrides

    /// Why a move can't be kept (§5 voice); shown instead of dropping it.
    enum GenreMoveRefusal: Error, Equatable {
        case tooManyMoves, nameTooLong

        var message: String {
            switch self {
            case .tooManyMoves: "You've moved as many genres as Magpie can keep. Move some back first."
            case .nameTooLong: "This genre's name is too long to move."
            }
        }
    }

    /// Whether moving `name` to `groupId` can't be kept: Preferences holds at most `GenrePreferences.maxAssignments`
    /// moves, each named in at most `maxTextLength` characters. A move back to the rules' group always can be.
    func moveRefusal(_ name: String, toGroup groupId: String) -> GenreMoveRefusal? {
        guard !Self.isRuleGroup(name, groupId) else { return nil }
        let key = GenreGroups.key(name)
        if key.count > GenrePreferences.maxTextLength { return .nameTooLong }
        let assignments = preferences.genres.assignments
        if assignments[key] == nil, assignments.count >= GenrePreferences.maxAssignments { return .tooManyMoves }
        return nil
    }

    /// Puts the genre in `groupId`, or says why it can't (nothing changes then). Moving it to the group its rules
    /// already give clears the override, and a custom group left with no genre is let go (with its name), so the capped
    /// lists stay small.
    @discardableResult func moveGenre(_ name: String, toGroup groupId: String) -> GenreMoveRefusal? {
        if let refusal = moveRefusal(name, toGroup: groupId) { return refusal }
        let key = GenreGroups.key(name)
        let back = Self.isRuleGroup(name, groupId)
        updatePreferences { prefs in
            var g = prefs.genres
            g.assignments[key] = back ? nil : groupId
            let used = Set(g.assignments.values).union([groupId])
            let unused = g.customGroups.filter { !used.contains($0) }
            g.customGroups.removeAll { unused.contains($0) }
            for id in unused { g.groupNames[id] = nil; g.hidden.remove(id) }
            prefs.genres = g
        }
        return nil
    }

    /// A new, empty group named `name` (trimmed); it shows once a genre is moved into it.
    @discardableResult func createGroup(named name: String) -> String {
        let id = "custom.\(UUID().uuidString)"
        let title = Self.groupTitle(name) ?? "Custom"
        updatePreferences {
            $0.genres.customGroups.append(id)
            $0.genres.groupNames[id] = title
        }
        return id
    }

    /// Renames a group. A blank name gives a built-in group its own name back and leaves a custom one as it was.
    func renameGroup(_ id: String, to name: String) {
        let title = Self.groupTitle(name)
        let builtIn = GenreGroups.builtIn.first { $0.id == id }
        if title == nil, builtIn == nil { return }
        updatePreferences { $0.genres.groupNames[id] = title == builtIn?.name ? nil : title }
    }

    func setGroupHidden(_ id: String, _ hidden: Bool) {
        updatePreferences {
            if hidden { $0.genres.hidden.insert(id) } else { $0.genres.hidden.remove(id) }
        }
    }

    // MARK: - Private

    private struct SongAsk: Sendable {
        let genre: String
        let offset: Int
    }

    /// Trimmed and cut to what Preferences keeps; nil when blank.
    private static func groupTitle(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(GenrePreferences.maxTextLength))
    }

    /// Whether `groupId` is the one group the genre's rules already give it.
    private static func isRuleGroup(_ name: String, _ groupId: String) -> Bool {
        Set(GenreGroups.split(name).map(GenreGroups.groupId(for:))) == [groupId]
    }

    /// The server's genres, or offline the downloads' genres.
    private func rawGenres() async throws -> [Genre] {
        if isOffline { return await offlineCatalog.genres() }
        return try await request { try await $0.genres() }
    }

    /// A genre's first `genreAlbumCap` albums (one page).
    private func serverAlbums(_ name: String) async throws -> [Album] {
        try await request { [cap = Self.genreAlbumCap] in try await $0.albums(genre: name, size: cap, offset: 0) }
    }

    /// `op` over `items`, at most `fetchWidth` at a time, with the results in the items' order.
    private func inOrder<Item: Sendable, T: Sendable>(
        _ items: [Item], _ op: @escaping @Sendable @MainActor (Item) async throws -> T
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: items.count)
            for (index, item) in items.enumerated() {
                if index >= Self.fetchWidth, let (done, value) = try await group.next() { results[done] = value }
                group.addTask { (index, try await op(item)) }
            }
            for try await (done, value) in group { results[done] = value }
            // Positions must line up with `items` (callers zip them): a gap means the read was cut short, so stop
            // rather than shift later results onto the wrong genre (same failure as the build 8 Home crash).
            guard results.allSatisfy({ $0 != nil }) else { throw CancellationError() }
            return results.map { $0! }
        }
    }

    /// One song from each list in turn until `cap` or the lists run out.
    private static func roundRobin(_ lists: [[Song]], cap: Int) -> [Song] {
        var out: [Song] = []
        var row = 0
        while out.count < cap, lists.contains(where: { row < $0.count }) {
            for list in lists where row < list.count && out.count < cap { out.append(list[row]) }
            row += 1
        }
        return out
    }

    /// The downloaded albums with a song in one of `genres`, A–Z.
    private func offlineAlbums(_ genres: Set<String>) async -> [Album] {
        await offlineCatalog.albums().filter { album in album.songs?.contains { Self.inGenres($0, genres) } == true }
    }

    /// The downloaded songs in `genres`, album by album in track order.
    private func offlineSongs(_ genres: Set<String>) async -> [Song] {
        await offlineCatalog.albums().flatMap { $0.songs ?? [] }.filter { Self.inGenres($0, genres) }
    }

    /// As `OfflineCatalog.genres()` names them (trimmed).
    private static func inGenres(_ song: Song, _ genres: Set<String>) -> Bool {
        guard let genre = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return genres.contains(genre)
    }
}
