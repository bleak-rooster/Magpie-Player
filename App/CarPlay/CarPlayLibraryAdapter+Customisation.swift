import Foundation
#if canImport(CarPlay)
import CarPlayUI
import MagpieCore

/// Home and Library as the car shows them (spec §3, Task 22): the phone's layout and the phone's shelves, minus what
/// the car can't show, so the two never disagree.
extension CarPlayLibraryAdapter {
    /// The phone's Home sections without Made for you (the car has no screen for it). Offline: Downloaded.
    var homeSections: [HomeSection] { model.homeSections(carPlay: true) }

    /// The phone's Library rows without Songs and Requests. Offline: Downloads, and Genres when shown.
    var libraryRows: [LibraryRow] { model.libraryRows(carPlay: true) }

    /// The phone's shelves (offline, nothing is asked of the server), each cut to `size`. A downloaded album is an
    /// album here; the car's Downloaded shelf opens it from the phone.
    func homeShelves(_ sections: [HomeSection], size: Int) async throws -> [CPHomeShelf] {
        try await model.homeShelves(for: sections).map { shelf in
            CPHomeShelf(section: shelf.section, items: shelf.items.prefix(max(0, size)).map { item in
                switch item {
                case .album(let album), .downloadedAlbum(let album): .album(album)
                case .playlist(let playlist): .playlist(playlist)
                case .genreGroup(let group): .genreGroup(id: group.group.id, name: group.group.name, albumCount: group.albumCount)
                }
            })
        }
    }
}
#endif
