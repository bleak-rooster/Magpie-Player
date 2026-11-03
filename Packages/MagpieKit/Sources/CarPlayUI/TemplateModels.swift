import DesignSystem
import Foundation
import MagpieCore
import Search

// Value models for CarPlay lists. Built off the main thread, then applied to `CPListTemplate`s on
// it (see `CarPlayController`). Pure, so the rules (limits, diffing, depth) are unit-tested.

/// A screen that a row pushes.
public enum CPDestination: Sendable, Hashable {
    case playlists, artists, albums
    /// Library rows from the owner's layout (Task 22); their screens are Task 23's.
    case genres, favourites, downloads, finds
    /// Round 12 Y6: Library › Discover (Aurral's flow playlists), while Aurral is set up.
    case discover
    case genreGroup(id: String, name: String)
    /// An album on the phone (Downloads, or Home's Downloaded shelf): it opens with no server.
    case downloadedAlbum(id: String, title: String)
    /// An artist's albums on the phone (Downloads).
    case downloadedArtist(id: String, name: String)
    /// A playlist as downloaded (Downloads): only its songs on the phone, online or offline.
    case downloadedPlaylist(id: String, title: String)
    /// A ListenBrainz "Made for you" playlist (Home, with a token; Task 23).
    case madeForYou(id: String, title: String)
    case album(id: String, title: String)
    case playlist(id: String, title: String)
    case artist(id: String, name: String)
    /// A recent search, re-run as a list.
    case searchResults(query: String)
    /// The system search template (keyboard).
    case search
    /// Round 12 (Y2): one group of a long list's letters screen ("A", "X–Z", "S (1 of 3)"), its rows built already.
    case letterGroup(title: String, sections: [CPSectionModel])
    /// Round 13 (item 3): every song, on its five letter groups.
    case songs
    /// Round 13: one song group (or a page of it): offsets in the server's title order, read when it opens.
    case songRange(title: String, ranges: [Range<Int>])

    public var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .genres: "Genres"
        case .favourites: "Favourites"
        case .downloads: "Downloads"
        case .finds: "Finds"
        case .discover: "Discover"
        case .album(_, let title), .playlist(_, let title), .downloadedAlbum(_, let title), .madeForYou(_, let title),
             .downloadedPlaylist(_, let title): title
        case .artist(_, let name), .genreGroup(_, let name), .downloadedArtist(_, let name): name
        case .searchResults(let query): query
        case .search: "Search"
        case .letterGroup(let title, _), .songRange(let title, _): title
        case .songs: "Songs"
        }
    }
}

/// Something to play. Album and artist requests fetch their songs first.
public enum CPPlayRequest: Sendable, Hashable {
    case songs([Song], startAt: Int)
    case album(id: String, shuffled: Bool)
    case artistShuffle(id: String)
    /// A subgenre's songs, and a genre group's (Task 23).
    case genre(name: String, shuffled: Bool)
    case genreGroup(id: String, shuffled: Bool)
    /// These songs, shuffled: the Shuffle of an album or artist on the phone (nothing is asked of the server).
    case shuffle([Song])
    /// Y2 (2c): all the artist's songs in order (album by album, as the artist page lists them), from the first.
    case artistInOrder(id: String)
}

/// What tapping a row does. `.none` rows are shown disabled.
public enum RowAction: Sendable, Hashable {
    case none
    case open(CPDestination)
    case play(CPPlayRequest)
    /// A not-yet song: offers "Try it next" in an action sheet (modal, no push; D6).
    case tryNext(ExternalRecording)
    /// A not-yet song already on its way (R20): says so ("On its way"), never a second Try.
    case onItsWay
    /// Round 13 (item 9): a song in Up Next; a tap plays the queue from there.
    case queueEntry(UUID)
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
    /// SF Symbol shown with the status text of a find or not-yet row, so state never rests on the art alone (D3).
    public var statusSymbol: String?

    public init(id: String, title: String, detail: String? = nil, artworkKey: String? = nil,
                round: Bool = false, playing: Bool = false, action: RowAction, statusSymbol: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.artworkKey = artworkKey
        self.round = round; self.playing = playing; self.action = action; self.statusSymbol = statusSymbol
    }
}

public struct CPSectionModel: Sendable, Hashable {
    public var header: String?
    public var rows: [CPRowModel]
    /// The section's letter in CarPlay's letter scrubber (Y2: A–Z lists); nil for other lists.
    public var indexTitle: String?

    public init(header: String?, rows: [CPRowModel], indexTitle: String? = nil) {
        self.header = header; self.rows = rows; self.indexTitle = indexTitle
    }
}

/// The depth budget (critique H1, D12 as revised by the owner in round 12): a tab root plus at most three pushes
/// (tab → letters → group → page), so Now Playing (5) fits from any browse screen within CarPlay's template depth limit
/// for audio apps. Round 13: Up Next is on; it goes above Now Playing only while that fits (`upNextFits`).
public struct CPNavigator: Sendable {
    /// Counting the tab root as 1.
    public static let maxBrowseDepth = 4
    /// CarPlay's template depth limit for audio apps, Now Playing included.
    public static let carPlayTemplateDepthLimit = 5

    public private(set) var stack: [CPDestination] = []

    public init() {}

    public var depth: Int { 1 + stack.count }

    /// Whether a browse screen may be pushed on top of a stack `depth` templates deep.
    public static func allowsPush(atDepth depth: Int) -> Bool { depth < maxBrowseDepth }

    /// Whether Up Next may be pushed on a stack `stackDepth` templates deep (the tab bar and Now Playing counted); when
    /// it can't, the car goes back to the tab and opens Now Playing then Up Next.
    public static func upNextFits(stackDepth: Int) -> Bool { stackDepth < carPlayTemplateDepthLimit }

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
    /// No Finds library is chosen on the phone.
    case findsOff
    /// T3: the library is out of reach and iOS's Local Network setting is off for Magpie.
    case localNetworkDenied
    /// T3: out of reach, and the Local Network prompt hasn't been answered (it can only be answered on the phone).
    /// The one instructive state line (D33, spec §8).
    case localNetworkPending
    /// T23: offline mode is on (or the server is unreachable): only what's on the phone shows.
    case offline

    /// D3: the symbol shown with the state's text, for the states that have one.
    public var statusSymbol: String? {
        switch self {
        case .localNetworkDenied: "network.slash"
        case .localNetworkPending: "iphone"
        case .offline: "wifi.slash"
        default: nil
        }
    }

    /// What a failed read shows: offline when the app is (T23: never "out of reach" or Local Network then), out of
    /// reach (with the Local Network reason when there is one), or didn't send.
    public static func unavailable(outOfReach: Bool, localNetwork: CPLocalNetwork, offline: Bool = false) -> CarPlayState {
        if offline { return .offline }
        guard outOfReach else { return .failed }
        return switch localNetwork {
        case .fine: .outOfReach
        case .denied: .localNetworkDenied
        case .pending: .localNetworkPending
        }
    }
}

/// T3: iOS's Local Network permission as the car needs to know it.
public enum CPLocalNetwork: Sendable, Hashable { case fine, pending, denied }

/// Builds the row models for each CarPlay screen. All functions are pure.
public enum CarPlayRows {
    public static func state(_ state: CarPlayState) -> [CPSectionModel] {
        let (id, title): (String, String) = switch state {
        case .locked: ("state.locked", "Locked until this iPhone is unlocked")
        case .notSetUp: ("state.notSetUp", "Not set up on this iPhone yet")
        case .outOfReach: ("state.outOfReach", "Your library is out of reach")
        case .failed: ("state.failed", "Your library didn't send this")
        case .empty: ("state.empty", "Nothing here yet")
        case .findsOff: ("state.findsOff", "Finds aren't set up on this iPhone")
        case .localNetworkDenied: ("state.localNetworkDenied", "Local network access is off for Magpie")
        case .localNetworkPending: ("state.localNetworkPending", "Open Magpie on your iPhone once to allow local network access")
        case .offline: ("state.offline", "You're offline")
        }
        return [CPSectionModel(header: nil, rows: [CPRowModel(id: id, title: title, action: .none,
                                                              statusSymbol: state.statusSymbol)])]
    }

    /// Only state rows: a placeholder, which real rows may replace even while the list is on screen.
    public static func isPlaceholder(_ sections: [CPSectionModel]) -> Bool {
        let rows = sections.flatMap(\.rows)
        return !rows.isEmpty && rows.allSatisfy { $0.id.hasPrefix("state.") }
    }

    // MARK: Tab roots (depth 1)

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

    /// The Finds tab (D12): New finds, then the finds with days left, as the phone's Finds shelf has them. Records
    /// with a text status and a symbol (D3). A tap plays the finds from there; Keep is in Now Playing.
    public static func finds(_ shelf: CPFindsShelf?, playingId: String?) -> [CPSectionModel] {
        guard let shelf else { return state(.findsOff) }
        let all = shelf.newFinds + shelf.finds
        let songs = all.map(\.song)
        var index = 0
        func section(_ header: String, _ finds: [CPFind]) -> CPSectionModel {
            CPSectionModel(header: header, rows: finds.map { find in
                defer { index += 1 }
                let state = find.state
                return CPRowModel(id: "find.\(find.song.id)", title: display(find.song.title, untitled),
                                  detail: "\(state.statusText) · \(display(find.song.artist, unknownArtist))",
                                  artworkKey: find.song.coverArtId, round: true, playing: find.song.id == playingId,
                                  action: .play(.songs(songs, startAt: index)), statusSymbol: state.statusSymbol)
            })
        }
        let sections = [section("New finds", shelf.newFinds), section("Finds", shelf.finds)].filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    // MARK: Lists (depth 2)

    /// Y2: Playlists, Artists and Albums are A–Z (`lettered`): letter sections within the car's limits, otherwise a
    /// letters screen. Without limits (the defaults) always letter sections. Playlists keep leading articles, as the
    /// phone's Playlists; artists and albums drop Navidrome's, as the phone's A–Z does.
    public static func playlists(_ playlists: [Playlist], maxItems: Int = .max, maxSections: Int = .max) -> [CPSectionModel] {
        lettered(unique(playlists, \.id).map {
            let name = display($0.name, "Untitled playlist")
            let row = CPRowModel(id: "playlist.\($0.id)", title: name, detail: songCount($0.songCount),
                                 artworkKey: $0.coverArtId, action: .open(.playlist(id: $0.id, title: name)))
            return letterEntry(name: $0.name, articles: [], row: row)
        }, kind: .playlists, maxItems: maxItems, maxSections: maxSections)
    }

    public static func artists(_ artists: [Artist], maxItems: Int = .max, maxSections: Int = .max) -> [CPSectionModel] {
        lettered(unique(artists, \.id).map {
            let name = display($0.name, unknownArtist)
            let albums = $0.albumCount == 1 ? "1 album" : "\($0.albumCount) albums"
            let row = CPRowModel(id: "artist.\($0.id)", title: name, detail: albums,
                                 artworkKey: $0.coverArtId, action: .open(.artist(id: $0.id, name: name)))
            return letterEntry(name: $0.name, articles: LetterIndex.navidromeArticles, row: row)
        }, kind: .artists, maxItems: maxItems, maxSections: maxSections)
    }

    /// - Parameter total: how many albums the library has when only some were read (fix round 1: "Showing 5000 of N").
    public static func albums(_ albums: [Album], maxItems: Int = .max, maxSections: Int = .max,
                              total: Int? = nil) -> [CPSectionModel] {
        let shown = unique(albums, \.id)
        let note = total.flatMap { $0 > shown.count ? "Showing \(shown.count) of \($0)" : nil }
        return lettered(shown.map {
            letterEntry(name: $0.name, articles: LetterIndex.navidromeArticles, row: albumRow($0, id: "album.\($0.id)"))
        }, kind: .albums, maxItems: maxItems, maxSections: maxSections, note: note)
    }

    /// A recent search re-run: library songs, then albums, then songs not in the library (D4: library first).
    public static func searchResults(_ result: LibrarySearchResult, notYet: [ExternalRecording] = [],
                                     offer: CPTryOffer = .unavailable, onTheirWay: [Int: String] = [:],
                                     playingId: String?) -> [CPSectionModel] {
        let songs = CPSectionModel(header: "Songs", rows: result.songs.enumerated().map { i, song in
            CPRowModel(id: "song.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                       artworkKey: song.coverArtId, playing: song.id == playingId,
                       action: .play(.songs(result.songs, startAt: i)))
        })
        let artists = CPSectionModel(header: "Artists", rows: searchArtistRows(result.artists))   // R19
        let albums = CPSectionModel(header: "Albums", rows: unique(result.albums, \.id).map { albumRow($0, id: "album.\($0.id)") })
        let outside = CPSectionModel(header: RowState.notYet.statusText,
                                     rows: notYetRows(notYet, offer: offer, onTheirWay: onTheirWay))
        let sections = [songs, artists, albums, outside].filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    /// Results for the system search template, which shows a flat list: the kind goes in the
    /// detail line. Songs not in the library come last.
    public static func searchItems(_ result: LibrarySearchResult, notYet: [ExternalRecording] = [],
                                   offer: CPTryOffer = .unavailable, onTheirWay: [Int: String] = [:]) -> [CPRowModel] {
        let songs = result.songs.enumerated().map { i, song in
            CPRowModel(id: "song.\(i).\(song.id)", title: display(song.title, untitled), detail: "Song · \(song.artist)",
                       artworkKey: song.coverArtId, action: .play(.songs(result.songs, startAt: i)))
        }
        let albums = unique(result.albums, \.id).map {
            let name = display($0.name, untitledAlbum)
            return CPRowModel(id: "album.\($0.id)", title: name, detail: "Album · \($0.artist)",
                              artworkKey: $0.coverArtId, action: .open(.album(id: $0.id, title: name)))
        }
        return songs + searchArtistRows(result.artists) + albums + notYetRows(notYet, offer: offer, onTheirWay: onTheirWay)
    }

    /// R19: an artist found by search opens the artist page (its albums play there, within D12's depth budget).
    static func searchArtistRows(_ artists: [Artist]) -> [CPRowModel] {
        unique(artists, \.id).map {
            let name = display($0.name, unknownArtist)
            return CPRowModel(id: "artist.\($0.id)", title: name,
                              detail: $0.albumCount == 1 ? "Artist \u{00B7} 1 album" : "Artist \u{00B7} \($0.albumCount) albums",
                              artworkKey: $0.coverArtId, round: true, action: .open(.artist(id: $0.id, name: name)))
        }
    }

    /// Fits the search template's flat list into `maxItems`: library rows first (D4), but when the list is too long,
    /// up to a third of it is kept for songs not in the library, so they are never cut off entirely.
    public static func fitSearchItems(_ rows: [CPRowModel], maxItems: Int) -> [CPRowModel] {
        guard maxItems > 0 else { return [] }
        guard rows.count > maxItems else { return rows }
        let outside = rows.filter { $0.id.hasPrefix(notYetPrefix) }
        let inside = rows.filter { !$0.id.hasPrefix(notYetPrefix) }
        let outsideShown = min(outside.count, max(maxItems / 3, maxItems - inside.count))
        return Array(inside.prefix(maxItems - outsideShown)) + outside.prefix(outsideShown)
    }

    static let notYetPrefix = "notyet."

    /// A song from outside the library: a record with "Not in your library" and its symbol (D3), and "· Try" when
    /// Try is possible here; then a tap offers "Try it next". Otherwise the row does nothing.
    /// R17 / R20: a song in `onTheirWay` (by index) shows its request's status and a tap says it's on its way; never a
    /// second Try.
    static func notYetRows(_ recordings: [ExternalRecording], offer: CPTryOffer,
                           onTheirWay: [Int: String] = [:]) -> [CPRowModel] {
        let state = RowState.notYet
        let status = offer == .unavailable ? state.statusText : "\(state.statusText) · Try"
        return recordings.enumerated().map { i, recording in
            let id = "\(notYetPrefix)\(i).\(recording.recordingMBID?.rawValue ?? recording.title)"
            let artist = display(recording.artist, unknownArtist)
            // R15: its release's cover from outside, in memory only (`OutsideArtKey`); a plain record without.
            let art = OutsideArtKey.cover(releaseGroup: nil, release: recording.releaseMBID)?.token
            if let live = onTheirWay[i] {
                return CPRowModel(id: id, title: display(recording.title, untitled), detail: "\(live) · \(artist)",
                                  artworkKey: art, round: true, action: .onItsWay, statusSymbol: "arrow.down.circle")
            }
            return CPRowModel(id: id, title: display(recording.title, untitled), detail: "\(status) · \(artist)",
                              artworkKey: art, round: true,
                              action: offer == .unavailable ? .none : .tryNext(recording), statusSymbol: state.statusSymbol)
        }
    }

    // MARK: Leaves (depth 3): rows play, never push

    public static func album(_ album: Album, playingId: String?) -> [CPSectionModel] {
        let songs = album.songs ?? []
        guard !songs.isEmpty else { return state(.empty) }
        let tracks = songs.enumerated().map { i, song in
            CPRowModel(id: "track.\(i).\(song.id)", title: display(song.title, untitled), detail: duration(song.duration),
                       playing: song.id == playingId, action: .play(.songs(songs, startAt: i)))
        }
        return [playShuffle(id: "album", detail: songCount(songs.count), play: .songs(songs, startAt: 0),
                            shuffle: .album(id: album.id, shuffled: true)),
                CPSectionModel(header: album.artist, rows: tracks)]
    }

    /// Y2 (2c): the two rows every album, artist and playlist page starts with. Both replace the queue (the car never
    /// asks first, R12): Play in order from the first song, Shuffle shuffled.
    static func playShuffle(id: String, detail: String?, play: CPPlayRequest, shuffle: CPPlayRequest) -> CPSectionModel {
        CPSectionModel(header: nil, rows: [
            CPRowModel(id: "\(id).play", title: "Play", detail: detail, action: .play(play)),
            CPRowModel(id: "\(id).shuffle", title: "Shuffle", action: .play(shuffle)),
        ])
    }

    public static func playlist(_ playlist: Playlist, songs: [Song], playingId: String?) -> [CPSectionModel] {
        guard !songs.isEmpty else { return state(.empty) }
        return [playShuffle(id: "playlist", detail: songCount(songs.count), play: .songs(songs, startAt: 0),
                            shuffle: .shuffle(songs)),
                CPSectionModel(header: nil, rows: songs.enumerated().map { i, song in
            CPRowModel(id: "track.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                       artworkKey: song.coverArtId, playing: song.id == playingId,
                       action: .play(.songs(songs, startAt: i)))
        })]
    }

    /// Fix round 1 (I2): albums open their page when one more push fits the depth budget (`albumsOpen`, decided by the
    /// controller for where this page sits); otherwise they play when tapped.
    public static func artist(_ artist: Artist, albums: [Album], albumsOpen: Bool = false) -> [CPSectionModel] {
        guard !albums.isEmpty else { return state(.empty) }
        let rows = unique(albums, \.id).map {
            let name = display($0.name, untitledAlbum)
            return CPRowModel(id: "album.\($0.id)", title: name, detail: $0.year.map(String.init), artworkKey: $0.coverArtId,
                              action: albumsOpen ? .open(.album(id: $0.id, title: name)) : .play(.album(id: $0.id, shuffled: false)))
        }
        return [playShuffle(id: "artist", detail: display(artist.name, unknownArtist), play: .artistInOrder(id: artist.id),
                            shuffle: .artistShuffle(id: artist.id)),
                CPSectionModel(header: "Albums", rows: rows)]
    }

    // MARK: Helpers

    static func albumRow(_ album: Album, id: String) -> CPRowModel {
        let name = display(album.name, untitledAlbum)
        return CPRowModel(id: id, title: name, detail: album.artist, artworkKey: album.coverArtId,
                          action: .open(.album(id: album.id, title: name)))
    }

    static let untitled = "Untitled"
    static let untitledAlbum = "Untitled album"
    static let unknownArtist = "Unknown artist"

    /// Tags can leave a name empty; a car screen never shows a blank row or title.
    static func display(_ name: String, _ fallback: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : name
    }

    /// Rows are matched by id (in-place updates, artwork): an id a server page repeats is shown once.
    static func unique<T>(_ items: some Sequence<T>, _ id: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0[keyPath: id]).inserted }
    }

    static func nonEmpty(_ rows: [CPRowModel]) -> [CPSectionModel] {
        rows.isEmpty ? state(.empty) : [CPSectionModel(header: nil, rows: rows)]
    }

    static func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0, seconds < 1e9 else { return nil }   // Int(_:) traps on NaN and infinity
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
