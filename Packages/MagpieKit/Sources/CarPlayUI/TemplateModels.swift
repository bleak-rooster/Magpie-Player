import Foundation
import MagpieCore

// Value models for CarPlay lists. Built off the main thread, then applied to `CPListTemplate`s on
// it (see `CarPlayController`). Pure, so the rules (limits, diffing, depth) are unit-tested.

/// A screen that a row pushes.
public enum CPDestination: Sendable, Hashable {
    case playlists, artists, albums
    case album(id: String, title: String)
    case playlist(id: String, title: String)
    case artist(id: String, name: String)
    /// A recent search, re-run as a list.
    case searchResults(query: String)
    /// The system search template (keyboard).
    case search

    public var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .album(_, let title), .playlist(_, let title): title
        case .artist(_, let name): name
        case .searchResults(let query): query
        case .search: "Search"
        }
    }
}

/// Something to play. Album and artist requests fetch their songs first.
public enum CPPlayRequest: Sendable, Hashable {
    case songs([Song], startAt: Int)
    case album(id: String, shuffled: Bool)
    case artistShuffle(id: String)
}

/// What tapping a row does. `.none` rows are shown disabled.
public enum RowAction: Sendable, Hashable {
    case none
    case open(CPDestination)
    case play(CPPlayRequest)
}

public struct CPRowModel: Sendable, Hashable, Identifiable {
    /// Stable across reloads; the diff matches rows by it.
    public var id: String
    public var title: String
    public var detail: String?
    /// Cover art id, loaded off the main thread and sized for the car screen.
    public var artworkKey: String?
    /// Drawn as a record (`RoundArt`): for not-yet rows.
    public var round: Bool
    public var playing: Bool
    public var action: RowAction

    public init(id: String, title: String, detail: String? = nil, artworkKey: String? = nil,
                round: Bool = false, playing: Bool = false, action: RowAction) {
        self.id = id; self.title = title; self.detail = detail; self.artworkKey = artworkKey
        self.round = round; self.playing = playing; self.action = action
    }
}

public struct CPSectionModel: Sendable, Hashable {
    public var header: String?
    public var rows: [CPRowModel]

    public init(header: String?, rows: [CPRowModel]) {
        self.header = header; self.rows = rows
    }
}

/// The depth budget (critique H1): a tab root plus at most two pushes, so Now Playing (4) and
/// Up Next (5) fit from any browse screen, including when the system pushes Now Playing itself.
public struct CPNavigator: Sendable {
    /// Counting the tab root as 1.
    public static let maxBrowseDepth = 3

    public private(set) var stack: [CPDestination] = []

    public init() {}

    public var depth: Int { 1 + stack.count }

    /// Whether a browse screen may be pushed on top of a stack `depth` templates deep.
    public static func allowsPush(atDepth depth: Int) -> Bool { depth < maxBrowseDepth }

    /// Pushes `destination` unless that would go past the budget.
    @discardableResult
    public mutating func push(_ destination: CPDestination) -> Bool {
        guard Self.allowsPush(atDepth: depth) else { return false }
        stack.append(destination)
        return true
    }

    public mutating func pop() {
        _ = stack.popLast()
    }
}

/// Why a list has nothing to show. Copy describes the state; it never asks the driver to do
/// anything (critique H2).
public enum CarPlayState: Sendable, Hashable {
    case locked, notSetUp, outOfReach, failed, empty
}

/// Builds the row models for each CarPlay screen. All functions are pure.
public enum CarPlayRows {
    /// Albums per Home shelf: three shelves fit the 12-item limit some cars impose.
    public static let homeShelfSize = 4

    public static func state(_ state: CarPlayState) -> [CPSectionModel] {
        let (id, title): (String, String) = switch state {
        case .locked: ("state.locked", "Locked until this iPhone is unlocked")
        case .notSetUp: ("state.notSetUp", "Not set up on this iPhone yet")
        case .outOfReach: ("state.outOfReach", "Your library is out of reach")
        case .failed: ("state.failed", "Your library didn't send this")
        case .empty: ("state.empty", "Nothing here yet")
        }
        return [CPSectionModel(header: nil, rows: [CPRowModel(id: id, title: title, action: .none)])]
    }

    // MARK: Tab roots (depth 1)

    public static func home(recent: [Album], newest: [Album], frequent: [Album]) -> [CPSectionModel] {
        func shelf(_ key: String, _ header: String, _ albums: [Album]) -> CPSectionModel {
            CPSectionModel(header: header, rows: unique(albums, \.id).prefix(homeShelfSize).map {
                albumRow($0, id: "home.\(key).\($0.id)")
            })
        }
        let sections = [
            shelf("recent", "Jump back in", recent),
            shelf("newest", "Recently added", newest),
            shelf("frequent", "Most played", frequent),
        ].filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    public static func libraryRoot() -> [CPSectionModel] {
        [CPSectionModel(header: nil, rows: [
            CPRowModel(id: "library.playlists", title: "Playlists", action: .open(.playlists)),
            CPRowModel(id: "library.artists", title: "Artists", action: .open(.artists)),
            CPRowModel(id: "library.albums", title: "Albums", action: .open(.albums)),
        ])]
    }

    /// "Type a search" pushes the keyboard search; while driving the car may withhold the
    /// keyboard, and the row says so (same id either way, so the change is made in place).
    public static func searchRoot(recents: [String], keyboardLimited: Bool) -> [CPSectionModel] {
        let type = CPRowModel(id: "search.type", title: "Type a search",
                              detail: keyboardLimited ? "Unavailable while driving" : nil,
                              action: keyboardLimited ? .none : .open(.search))
        var sections = [CPSectionModel(header: nil, rows: [type])]
        if !recents.isEmpty {
            sections.append(CPSectionModel(header: "Recent searches", rows: recents.map {
                CPRowModel(id: "recent.\($0)", title: $0, action: .open(.searchResults(query: $0)))
            }))
        }
        return sections
    }

    // MARK: Lists (depth 2)

    public static func playlists(_ playlists: [Playlist]) -> [CPSectionModel] {
        nonEmpty(unique(playlists, \.id).map {
            let name = display($0.name, "Untitled playlist")
            return CPRowModel(id: "playlist.\($0.id)", title: name, detail: songCount($0.songCount),
                              artworkKey: $0.coverArtId, action: .open(.playlist(id: $0.id, title: name)))
        })
    }

    public static func artists(_ artists: [Artist]) -> [CPSectionModel] {
        nonEmpty(unique(artists, \.id).map {
            let name = display($0.name, unknownArtist)
            return CPRowModel(id: "artist.\($0.id)", title: name,
                              detail: $0.albumCount == 1 ? "1 album" : "\($0.albumCount) albums",
                              artworkKey: $0.coverArtId, action: .open(.artist(id: $0.id, name: name)))
        })
    }

    public static func albums(_ albums: [Album]) -> [CPSectionModel] {
        nonEmpty(unique(albums, \.id).map { albumRow($0, id: "album.\($0.id)") })
    }

    /// A recent search re-run: library songs, then albums.
    public static func searchResults(_ result: LibrarySearchResult, playingId: String?) -> [CPSectionModel] {
        let songs = CPSectionModel(header: "Songs", rows: result.songs.enumerated().map { i, song in
            CPRowModel(id: "song.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                       artworkKey: song.coverArtId, playing: song.id == playingId,
                       action: .play(.songs(result.songs, startAt: i)))
        })
        let albums = CPSectionModel(header: "Albums", rows: unique(result.albums, \.id).map { albumRow($0, id: "album.\($0.id)") })
        let sections = [songs, albums].filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    /// Results for the system search template, which shows a flat list: the kind goes in the
    /// detail line.
    public static func searchItems(_ result: LibrarySearchResult) -> [CPRowModel] {
        let songs = result.songs.enumerated().map { i, song in
            CPRowModel(id: "song.\(i).\(song.id)", title: display(song.title, untitled), detail: "Song · \(song.artist)",
                       artworkKey: song.coverArtId, action: .play(.songs(result.songs, startAt: i)))
        }
        let albums = unique(result.albums, \.id).map {
            let name = display($0.name, untitledAlbum)
            return CPRowModel(id: "album.\($0.id)", title: name, detail: "Album · \($0.artist)",
                              artworkKey: $0.coverArtId, action: .open(.album(id: $0.id, title: name)))
        }
        return songs + albums
    }

    // MARK: Leaves (depth 3): rows play, never push

    public static func album(_ album: Album, playingId: String?) -> [CPSectionModel] {
        let songs = album.songs ?? []
        guard !songs.isEmpty else { return state(.empty) }
        let shuffle = CPRowModel(id: "album.shuffle", title: "Shuffle", detail: songCount(songs.count),
                                 action: .play(.album(id: album.id, shuffled: true)))
        let tracks = songs.enumerated().map { i, song in
            CPRowModel(id: "track.\(i).\(song.id)", title: display(song.title, untitled), detail: duration(song.duration),
                       playing: song.id == playingId, action: .play(.songs(songs, startAt: i)))
        }
        return [CPSectionModel(header: nil, rows: [shuffle]), CPSectionModel(header: album.artist, rows: tracks)]
    }

    public static func playlist(_ playlist: Playlist, songs: [Song], playingId: String?) -> [CPSectionModel] {
        guard !songs.isEmpty else { return state(.empty) }
        return [CPSectionModel(header: nil, rows: songs.enumerated().map { i, song in
            CPRowModel(id: "track.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                       artworkKey: song.coverArtId, playing: song.id == playingId,
                       action: .play(.songs(songs, startAt: i)))
        })]
    }

    /// Albums play when tapped (no tracklist push here: this screen is already at depth 3).
    public static func artist(_ artist: Artist, albums: [Album]) -> [CPSectionModel] {
        guard !albums.isEmpty else { return state(.empty) }
        let shuffle = CPRowModel(id: "artist.shuffle", title: "Shuffle", detail: artist.name,
                                 action: .play(.artistShuffle(id: artist.id)))
        let rows = unique(albums, \.id).map {
            CPRowModel(id: "album.\($0.id)", title: display($0.name, untitledAlbum), detail: $0.year.map(String.init),
                       artworkKey: $0.coverArtId, action: .play(.album(id: $0.id, shuffled: false)))
        }
        return [CPSectionModel(header: nil, rows: [shuffle]), CPSectionModel(header: "Albums", rows: rows)]
    }

    // MARK: Helpers

    private static func albumRow(_ album: Album, id: String) -> CPRowModel {
        let name = display(album.name, untitledAlbum)
        return CPRowModel(id: id, title: name, detail: album.artist, artworkKey: album.coverArtId,
                          action: .open(.album(id: album.id, title: name)))
    }

    static let untitled = "Untitled"
    static let untitledAlbum = "Untitled album"
    static let unknownArtist = "Unknown artist"

    /// Tags can leave a name empty; a car screen never shows a blank row or title.
    private static func display(_ name: String, _ fallback: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : name
    }

    /// Rows are matched by id (in-place updates, artwork): an id a server page repeats is shown once.
    private static func unique<T>(_ items: some Sequence<T>, _ id: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private static func nonEmpty(_ rows: [CPRowModel]) -> [CPSectionModel] {
        rows.isEmpty ? state(.empty) : [CPSectionModel(header: nil, rows: rows)]
    }

    private static func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
