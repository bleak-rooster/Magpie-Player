import Foundation
import MagpieCore
import NavidromeKit
import Search

/// Genres (spec §4, Task 19): the server's genres grouped by `GenreGroups`, a group's albums merged from its genres, a
/// group's Shuffle (capped at `groupSongCap`), a genre's songs in server order, and the owner's overrides (move a genre,
/// new groups, names, hidden groups) kept in Preferences.
///
/// Offline (spec §6) every answer comes from the downloads' snapshots instead, and nothing is sent: the genres are those
/// of the songs on the phone, and Play and Shuffle use only those songs.
extension AppModel {
    /// A group's Shuffle, and a genre's Play and Shuffle, take at most this many songs.
    static let groupSongCap = 500
    /// Albums are asked for this many at a time (the most `getAlbumList2` gives).
    private static let albumPage = 500

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

    /// One group, hidden or not; nil when it has no genres.
    func genreSection(_ groupId: String) async throws -> GenreGroupSection? {
        try await genreSectionsIncludingHidden().first { $0.group.id == groupId }
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

    // MARK: - Albums and songs

    /// The albums of every genre in the group (in the server's genre order), merged and de-duplicated by id, in
    /// first-seen order.
    func groupAlbums(_ groupId: String) async throws -> [Album] {
        let genres = try await groupGenres(groupId)
        if isOffline { return await offlineAlbums(Set(genres.map(\.name))) }
        var albums: [Album] = []
        var seen = Set<String>()
        for genre in genres {
            for album in try await serverAlbums(genre.name) where seen.insert(album.id).inserted { albums.append(album) }
        }
        return albums
    }

    /// A genre's albums.
    func genreAlbums(_ name: String) async throws -> [Album] {
        if isOffline { return await offlineAlbums([name]) }
        return try await serverAlbums(name)
    }

    /// The group's songs for Shuffle: each genre asked a page of `groupSongCap` at a time until there are that many or
    /// the genres run out, then shuffled. A group offers Shuffle only.
    func groupSongs(_ groupId: String) async throws -> [Song] {
        let genres = try await groupGenres(groupId)
        let cap = Self.groupSongCap
        if isOffline { return Array(await offlineSongs(Set(genres.map(\.name))).prefix(cap)).shuffled() }
        var songs: [Song] = []
        var seen = Set<String>()
        outer: for genre in genres {
            var offset = 0
            while true {
                let page = try await request { [name = genre.name, offset] in try await $0.songs(genre: name, count: cap, offset: offset) }
                var added = 0
                for song in page where seen.insert(song.id).inserted {
                    songs.append(song)
                    added += 1
                    if songs.count == cap { break outer }
                }
                // A short page is the last; a page with nothing new (a server ignoring the offset) ends it too.
                guard page.count == cap, added > 0 else { break }
                offset += cap
            }
        }
        return songs.shuffled()
    }

    /// A genre's first `groupSongCap` songs in server order (Play); Shuffle shuffles them.
    func genreSongs(_ name: String) async throws -> [Song] {
        if isOffline { return Array(await offlineSongs([name]).prefix(Self.groupSongCap)) }
        return try await request { [cap = Self.groupSongCap] in try await $0.songs(genre: name, count: cap, offset: 0) }
    }

    // MARK: - The owner's overrides

    /// Puts the genre in `groupId`. Moving it to the group its rules already give clears the override, and a custom
    /// group left with no genre is let go (with its name), so the capped lists stay small.
    func moveGenre(_ name: String, toGroup groupId: String) {
        let key = GenreGroups.key(name)
        let ruleGroups = Set(GenreGroups.split(name).map(GenreGroups.groupId(for:)))
        updatePreferences { prefs in
            var g = prefs.genres
            if ruleGroups == [groupId] { g.assignments[key] = nil } else { g.assignments[key] = groupId }
            let used = Set(g.assignments.values).union([groupId])
            let unused = g.customGroups.filter { !used.contains($0) }
            g.customGroups.removeAll { unused.contains($0) }
            for id in unused { g.groupNames[id] = nil; g.hidden.remove(id) }
            prefs.genres = g
        }
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

    /// Trimmed and cut to what Preferences keeps; nil when blank.
    private static func groupTitle(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(GenrePreferences.maxTextLength))
    }

    /// The group's genres (hidden or not) in the order the server lists them; empty for a group with none.
    private func groupGenres(_ groupId: String) async throws -> [Genre] {
        let raw = try await rawGenres()
        var prefs = preferences.genres
        prefs.hidden = []
        guard let section = GenreGroups.grouped(raw, preferences: prefs).first(where: { $0.group.id == groupId }) else { return [] }
        let names = Set(section.genres.map(\.name))
        return raw.filter { names.contains($0.name) }
    }

    /// The server's genres, or offline the downloads' genres.
    private func rawGenres() async throws -> [Genre] {
        if isOffline { return await offlineCatalog.genres() }
        return try await request { try await $0.genres() }
    }

    /// Every album of a genre, a page at a time.
    private func serverAlbums(_ name: String) async throws -> [Album] {
        var albums: [Album] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            let page = try await request { [size = Self.albumPage, offset] in try await $0.albums(genre: name, size: size, offset: offset) }
            let fresh = page.filter { seen.insert($0.id).inserted }
            albums += fresh
            guard page.count == Self.albumPage, !fresh.isEmpty else { return albums }
            offset += Self.albumPage
        }
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
