import Foundation
import MagpieCore

// Round 12 Y6 (plan item 7): Discover in the car. Home's Discover shelf is the phone's (its playlists open as any
// playlist does, with the library's copies in place: the adapter's `playlist(id:)`); Library › Discover lists them.

#if os(iOS) && canImport(CarPlay)
extension CarPlayCustomisationLibrary {
    /// No Discover unless the library says so.
    public func discoverPlaylists() async throws -> [Playlist] { [] }
}
#endif

extension CarPlayRows {
    /// Library › Discover (depth 2): Aurral's flow playlists, in the order given; each opens its songs (a leaf).
    public static func discover(_ playlists: [Playlist]) -> [CPSectionModel] {
        nonEmpty(unique(playlists.map { playlist in
            let name = display(playlist.name, untitledPlaylist)
            return CPRowModel(id: "discover.\(playlist.id)", title: name, detail: songCount(playlist.songCount),
                              artworkKey: playlist.coverArtId, action: .open(.playlist(id: playlist.id, title: name)))
        }, \.id))
    }
}
