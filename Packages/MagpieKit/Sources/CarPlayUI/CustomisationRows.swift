import Foundation
import MagpieCore

// Home and Library from the owner's layout (spec §3, Task 22): the phone's order and switches, minus what the car can't
// show, within the car's list limits (D12).

/// One Home shelf as the car shows it: a section and its tiles, already cut to the car's shelf size.
public struct CPHomeShelf: Sendable, Hashable {
    public enum Item: Sendable, Hashable {
        case album(Album)
        case playlist(Playlist)
        case genreGroup(id: String, name: String, albumCount: Int)
    }

    public var section: HomeSection
    public var items: [Item]

    public init(section: HomeSection, items: [Item]) {
        self.section = section
        self.items = items
    }
}

extension CarPlayRows {
    /// Tiles per Home shelf: four, fewer as sections are added so the shelves fit the 12 items some cars allow, and
    /// never fewer than two.
    public static func homeShelfSize(sectionCount: Int) -> Int {
        max(2, min(4, 12 / max(1, sectionCount)))
    }

    /// Home: one section per shelf, in the order given (the owner's), headed with the section's name. Albums and
    /// playlists open their tracks; a genre group opens its page. Downloaded albums open from the phone.
    public static func home(_ shelves: [CPHomeShelf]) -> [CPSectionModel] {
        let size = homeShelfSize(sectionCount: shelves.count)
        let sections = shelves.map { shelf in
            let key = "home.\(shelf.section.rawValue)."
            let rows = shelf.items.map { item -> CPRowModel in
                switch item {
                case .album(let album) where shelf.section == .downloaded:
                    let name = display(album.name, untitledAlbum)
                    return CPRowModel(id: key + album.id, title: name, detail: album.artist, artworkKey: album.coverArtId,
                                      action: .open(.downloadedAlbum(id: album.id, title: name)))
                case .album(let album):
                    return albumRow(album, id: key + album.id)
                case .playlist(let playlist):
                    let name = display(playlist.name, "Untitled playlist")
                    return CPRowModel(id: key + playlist.id, title: name, detail: songCount(playlist.songCount),
                                      artworkKey: playlist.coverArtId, action: .open(.playlist(id: playlist.id, title: name)))
                case .genreGroup(let id, let name, let albumCount):
                    let title = display(name, "Untitled genre")
                    return CPRowModel(id: key + id, title: title, detail: albumCount == 1 ? "1 album" : "\(albumCount) albums",
                                      action: .open(.genreGroup(id: id, name: title)))
                }
            }
            return CPSectionModel(header: shelf.section.title, rows: Array(unique(rows, \.id).prefix(size)))
        }.filter { !$0.rows.isEmpty }
        return sections.isEmpty ? state(.empty) : sections
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
