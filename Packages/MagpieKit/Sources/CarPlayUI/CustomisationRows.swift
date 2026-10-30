import Foundation
import MagpieCore

// Home and Library from the owner's layout (spec §3, Task 22): the phone's order and switches, within the car's list
// limits (D12). Task 23: the screens of the new Library rows (Genres, Favourites, Downloads), Made for you, and the
// layout watch's decision.

/// One Home shelf as the car shows it: a section and its tiles (at most `CarPlayRows.homeShelfMaxSize`).
public struct CPHomeShelf: Sendable, Hashable {
    public enum Item: Sendable, Hashable {
        case album(Album)
        case playlist(Playlist)
        case genreGroup(id: String, name: String, albumCount: Int)
        /// A ListenBrainz playlist (`id`: its MBID).
        case madeForYou(id: String, title: String)
    }

    public var section: HomeSection
    public var items: [Item]

    public init(section: HomeSection, items: [Item]) {
        self.section = section
        self.items = items
    }
}

/// One song of a Made for you playlist in the car: a library song (plays) or one not in the library (Try).
public enum CPMadeForYouTrack: Sendable, Hashable {
    case song(Song)
    case notYet(ExternalRecording)
}

/// What the car follows of the owner's layout: Home's sections, the Library's rows, and whether it is offline.
public struct CPLayout: Sendable, Hashable {
    public var home: [HomeSection]
    public var library: [LibraryRow]
    public var offline: Bool

    public init(home: [HomeSection], library: [LibraryRow], offline: Bool) {
        self.home = home; self.library = library; self.offline = offline
    }
}

/// What a layout change does to the tabs: Home reloads when its sections change or the car goes offline or back
/// online (the same sections then read elsewhere); the Library tab is redrawn when its rows change.
public struct CPLayoutChange: Sendable, Hashable {
    public var reloadsHome: Bool
    public var redrawsLibrary: Bool

    public init(reloadsHome: Bool, redrawsLibrary: Bool) {
        self.reloadsHome = reloadsHome; self.redrawsLibrary = redrawsLibrary
    }

    public init(from old: CPLayout, to new: CPLayout) {
        self.init(reloadsHome: old.home != new.home || old.offline != new.offline, redrawsLibrary: old.library != new.library)
    }
}

extension CarPlayRows {
    /// Most tiles on one Home shelf.
    public static let homeShelfMaxSize = 4

    /// The one place Home's shelves are sized (T23): shelves with `counts` tiles share `maxItems` rows, a tile at a time
    /// in the owner's order, each up to `homeShelfMaxSize` and its own count. Earlier shelves get the spare rows; a
    /// shelf past the budget gets none.
    public static func homeShelfSizes(_ counts: [Int], maxItems: Int) -> [Int] {
        var sizes = Array(repeating: 0, count: counts.count)
        var budget = max(0, maxItems)
        var grew = true
        while budget > 0, grew {
            grew = false
            for i in counts.indices where budget > 0 && sizes[i] < min(homeShelfMaxSize, counts[i]) {
                sizes[i] += 1
                budget -= 1
                grew = true
            }
        }
        return sizes
    }

    /// Home: one section per shelf with tiles, in the order given (the owner's), headed with the section's name, at most
    /// `maxSections` of them and `maxItems` tiles in all (the car's list limits, D12), sized by `homeShelfSizes`.
    /// Albums and playlists open their tracks; a genre group opens its page; Made for you opens its playlist.
    /// Downloaded albums open from the phone.
    public static func home(_ shelves: [CPHomeShelf], maxItems: Int = 12, maxSections: Int = 12) -> [CPSectionModel] {
        let built = shelves.map { shelf in
            CPSectionModel(header: shelf.section.title, rows: unique(shelf.items.map { homeRow($0, shelf.section) }, \.id))
        }.filter { !$0.rows.isEmpty }.prefix(max(0, maxSections))
        let sizes = homeShelfSizes(built.map(\.rows.count), maxItems: maxItems)
        let sections = zip(built, sizes).compactMap { section, size in
            size > 0 ? CPSectionModel(header: section.header, rows: Array(section.rows.prefix(size))) : nil
        }
        return sections.isEmpty ? state(.empty) : sections
    }

    private static func homeRow(_ item: CPHomeShelf.Item, _ section: HomeSection) -> CPRowModel {
        let key = "home.\(section.rawValue)."
        switch item {
        case .album(let album) where section == .downloaded:
            let name = display(album.name, untitledAlbum)
            return CPRowModel(id: key + album.id, title: name, detail: album.artist, artworkKey: album.coverArtId,
                              action: .open(.downloadedAlbum(id: album.id, title: name)))
        case .album(let album):
            return albumRow(album, id: key + album.id)
        case .playlist(let playlist):
            let name = display(playlist.name, untitledPlaylist)
            return CPRowModel(id: key + playlist.id, title: name, detail: songCount(playlist.songCount),
                              artworkKey: playlist.coverArtId, action: .open(.playlist(id: playlist.id, title: name)))
        case .genreGroup(let id, let name, let count):
            let title = display(name, untitledGenre)
            return CPRowModel(id: key + id, title: title, detail: albumCount(count),
                              action: .open(.genreGroup(id: id, name: title)))
        case .madeForYou(let id, let title):
            let name = display(title, untitledPlaylist)
            return CPRowModel(id: key + id, title: name, action: .open(.madeForYou(id: id, title: name)))
        }
    }

    /// The Library tab: the owner's rows in the owner's order. Never Songs or Requests (spec §3: too long for driving,
    /// and the car's Search covers songs); Finds only when the car has no Finds tab.
    public static func libraryRoot(_ rows: [LibraryRow], hasFindsTab: Bool) -> [CPSectionModel] {
        let models = rows.compactMap { row -> CPRowModel? in
            let destination: CPDestination? = switch row {
            case .playlists: .playlists
            case .artists: .artists
            case .albums: .albums
            case .genres: .genres
            case .favourites: .favourites
            case .downloads: .downloads
            case .finds: hasFindsTab ? nil : .finds
            case .songs, .requests: nil
            }
            return destination.map { CPRowModel(id: "library.\(row.rawValue)", title: row.title, action: .open($0)) }
        }
        return nonEmpty(unique(models, \.id))
    }
}

// MARK: - Task 23: the new Library rows' screens

extension CarPlayRows {
    static let untitledPlaylist = "Untitled playlist"
    static let untitledGenre = "Untitled genre"

    static func albumCount(_ n: Int) -> String { n == 1 ? "1 album" : "\(n) albums" }

    /// Library › Genres (depth 2): the phone's genre groups; each opens its page.
    public static func genres(_ groups: [(id: String, name: String, albumCount: Int)]) -> [CPSectionModel] {
        nonEmpty(unique(groups.map { group in
            let title = display(group.name, untitledGenre)
            return CPRowModel(id: "genres.\(group.id)", title: title, detail: albumCount(group.albumCount),
                              action: .open(.genreGroup(id: group.id, name: title)))
        }, \.id))
    }

    /// A genre group's page (D41, a leaf: it may sit at depth 3). The group offers only Shuffle; each of its genres is
    /// a row that plays the genre's songs in server order. A genre's Shuffle is Now Playing's shuffle button.
    public static func genreGroup(id: String, subgenres: [Genre]) -> [CPSectionModel] {
        guard !subgenres.isEmpty else { return state(.empty) }
        let shuffle = CPRowModel(id: "genre.shuffle", title: "Shuffle", action: .play(.genreGroup(id: id, shuffled: true)))
        let genres = unique(subgenres.map { genre in
            CPRowModel(id: "genre.\(genre.name)", title: display(genre.name, untitledGenre),
                       detail: genre.countsKnown ? songCount(genre.songCount) : nil,
                       action: .play(.genre(name: genre.name, shuffled: false)))
        }, \.id)
        return [CPSectionModel(header: nil, rows: [shuffle]), CPSectionModel(header: "Genres", rows: genres)]
    }

    /// Library › Downloads (depth 2): what's on the phone. Albums and artists open from the phone; a playlist opens as
    /// a playlist (from the phone while offline).
    public static func downloads(albums: [Album], artists: [Artist] = [], playlists: [Playlist]) -> [CPSectionModel] {
        let albumRows = unique(albums, \.id).map { album in
            let name = display(album.name, untitledAlbum)
            return CPRowModel(id: "downloads.album.\(album.id)", title: name, detail: album.artist, artworkKey: album.coverArtId,
                              action: .open(.downloadedAlbum(id: album.id, title: name)))
        }
        let artistRows = unique(artists, \.id).map { artist in
            let name = display(artist.name, unknownArtist)
            return CPRowModel(id: "downloads.artist.\(artist.id)", title: name, detail: albumCount(artist.albumCount),
                              action: .open(.downloadedArtist(id: artist.id, name: name)))
        }
        let playlistRows = unique(playlists, \.id).map { playlist in
            let name = display(playlist.name, untitledPlaylist)
            return CPRowModel(id: "downloads.playlist.\(playlist.id)", title: name, detail: songCount(playlist.songCount),
                              artworkKey: playlist.coverArtId, action: .open(.playlist(id: playlist.id, title: name)))
        }
        let sections = [CPSectionModel(header: "Albums", rows: albumRows), CPSectionModel(header: "Artists", rows: artistRows),
                        CPSectionModel(header: "Playlists", rows: playlistRows)].filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    /// An album on the phone (a leaf): Shuffle and its tracks, all from the phone.
    public static func downloadedAlbum(_ album: Album, playingId: String?) -> [CPSectionModel] {
        let songs = album.songs ?? []
        guard !songs.isEmpty else { return state(.empty) }
        let shuffle = CPRowModel(id: "album.shuffle", title: "Shuffle", detail: songCount(songs.count),
                                 action: .play(.shuffle(songs)))
        let tracks = songs.enumerated().map { i, song in
            CPRowModel(id: "track.\(i).\(song.id)", title: display(song.title, untitled), detail: duration(song.duration),
                       playing: song.id == playingId, action: .play(.songs(songs, startAt: i)))
        }
        return [CPSectionModel(header: nil, rows: [shuffle]), CPSectionModel(header: album.artist, rows: tracks)]
    }

    /// An artist's albums on the phone (a leaf): Shuffle of them all, then each album, which plays from its start.
    public static func downloadedArtist(_ artist: Artist, albums: [Album]) -> [CPSectionModel] {
        let albums = unique(albums, \.id).filter { !($0.songs ?? []).isEmpty }
        guard !albums.isEmpty else { return state(.empty) }
        let all = albums.flatMap { $0.songs ?? [] }
        let shuffle = CPRowModel(id: "artist.shuffle", title: "Shuffle", detail: display(artist.name, unknownArtist),
                                 action: .play(.shuffle(all)))
        let rows = albums.map { album in
            CPRowModel(id: "album.\(album.id)", title: display(album.name, untitledAlbum), detail: album.year.map(String.init),
                       artworkKey: album.coverArtId, action: .play(.songs(album.songs ?? [], startAt: 0)))
        }
        return [CPSectionModel(header: nil, rows: [shuffle]), CPSectionModel(header: "Albums", rows: rows)]
    }

    /// Library › Favourites (depth 2): starred songs, which play from the one tapped, then starred albums, which open.
    public static func favourites(_ starred: Starred, playingId: String?) -> [CPSectionModel] {
        let songs = starred.songs
        let songRows = songs.enumerated().map { i, song in
            CPRowModel(id: "favourites.song.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                       artworkKey: song.coverArtId, playing: song.id == playingId, action: .play(.songs(songs, startAt: i)))
        }
        let albumRows = unique(starred.albums, \.id).map { albumRow($0, id: "favourites.album.\($0.id)") }
        let sections = [CPSectionModel(header: "Songs", rows: songRows), CPSectionModel(header: "Albums", rows: albumRows)]
            .filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
    }

    /// A Made for you playlist (a leaf): its songs in order. A library song plays from there among the playlist's
    /// library songs; a song not in the library offers Try, as in the car's search (D6).
    public static func madeForYou(_ tracks: [CPMadeForYouTrack], offer: CPTryOffer, playingId: String?) -> [CPSectionModel] {
        let songs = tracks.compactMap { if case .song(let song) = $0 { song } else { nil } }
        var played = 0
        let rows = tracks.enumerated().map { i, track -> CPRowModel in
            switch track {
            case .song(let song):
                defer { played += 1 }
                return CPRowModel(id: "madeForYou.\(i).\(song.id)", title: display(song.title, untitled), detail: song.artist,
                                  artworkKey: song.coverArtId, playing: song.id == playingId,
                                  action: .play(.songs(songs, startAt: played)))
            case .notYet(let recording):
                var row = notYetRows([recording], offer: offer)[0]
                row.id = "\(notYetPrefix)\(i).\(recording.recordingMBID?.rawValue ?? recording.title)"
                return row
            }
        }
        return nonEmpty(rows)
    }

    /// What the car says when the sleep button is tapped (only then: critique M3).
    public static func sleepTimerMessage(active: Bool) -> String { active ? "Sleep timer on" : "Sleep timer off" }
}
