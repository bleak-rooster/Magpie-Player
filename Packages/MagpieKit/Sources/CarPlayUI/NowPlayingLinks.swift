import Foundation
import MagpieCore

/// Round 12 item 2d: where Now Playing's album/artist button goes for the song playing. Either may be missing; with
/// none the button is off.
public struct CPNowPlayingLinks: Sendable, Hashable {
    public var album: CPDestination?
    public var artist: CPDestination?

    public init(album: CPDestination? = nil, artist: CPDestination? = nil) {
        self.album = album; self.artist = artist
    }

    public var isEmpty: Bool { album == nil && artist == nil }
}

/// The choice offered when both are known.
public enum CPNowPlayingLinkCopy {
    public static let album = "Go to album"
    public static let artist = "Go to artist"
    public static let cancel = "Cancel"
}

extension CarPlayRows {
    /// Online: the album and artist pages, when the song names them. Offline (as R10 on the phone): only the downloaded
    /// pages, when they are on the phone.
    public static func nowPlayingLinks(_ song: Song?, offline: Bool, albumOnPhone: Bool, artistOnPhone: Bool) -> CPNowPlayingLinks {
        guard let song else { return CPNowPlayingLinks() }
        let albumTitle = display(song.album, untitledAlbum), artistName = display(song.artist, unknownArtist)
        let albumId = song.albumId.flatMap { $0.isEmpty ? nil : $0 }
        let artistId = song.artistId.flatMap { $0.isEmpty ? nil : $0 }
        if offline {
            return CPNowPlayingLinks(
                album: albumOnPhone ? albumId.map { .downloadedAlbum(id: $0, title: albumTitle) } : nil,
                artist: artistOnPhone ? artistId.map { .downloadedArtist(id: $0, name: artistName) } : nil)
        }
        return CPNowPlayingLinks(album: albumId.map { .album(id: $0, title: albumTitle) },
                                 artist: artistId.map { .artist(id: $0, name: artistName) })
    }
}
