import Foundation

/// Subsonic JSON envelope. Every payload member is optional: Navidrome returns `{}` for empty results.
struct SubsonicEnvelope: Decodable {
    let response: SubsonicBody
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicBody: Decodable {
    struct APIError: Decodable { let code: Int; let message: String? }
    struct AlbumList: Decodable { let album: [SubsonicAlbum]? }
    struct ArtistsIndex: Decodable {
        struct Index: Decodable { let artist: [SubsonicArtist]? }
        let index: [Index]?
    }
    struct Playlists: Decodable { let playlist: [SubsonicPlaylist]? }
    struct SearchResult: Decodable {
        let artist: [SubsonicArtist]?
        let album: [SubsonicAlbum]?
        let song: [SubsonicSong]?
    }
    struct TopSongs: Decodable { let song: [SubsonicSong]? }
    struct Genres: Decodable { let genre: [SubsonicGenre]? }
    struct Extension: Decodable { let name: String }
    struct LyricsList: Decodable { let structuredLyrics: [StructuredLyrics]? }
    struct StructuredLyrics: Decodable {
        struct Line: Decodable { let start: Double?; let value: String? }
        let synced: Bool?
        let line: [Line]?
    }
    struct ScanStatus: Decodable { let scanning: Bool? }

    let status: String
    let error: APIError?
    let albumList2: AlbumList?
    let album: SubsonicAlbum?
    let song: SubsonicSong?
    let artists: ArtistsIndex?
    let artist: SubsonicArtist?
    let playlists: Playlists?
    let playlist: SubsonicPlaylist?
    let searchResult3: SearchResult?
    let topSongs: TopSongs?
    let genres: Genres?
    let songsByGenre: TopSongs?
    let starred2: SearchResult?
    let openSubsonicExtensions: [Extension]?
    let lyricsList: LyricsList?
    let scanStatus: ScanStatus?
}

struct SubsonicSong: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let artistId: String?
    let album: String?
    let albumId: String?
    let track: Int?
    let discNumber: Int?
    let duration: Double?
    let suffix: String?
    let bitRate: Int?
    let coverArt: String?
    let musicBrainzId: String?   // recording MBID; kept as String, validated in mapping
    let isrc: [String]?
    let starred: String?
    let genre: String?
    let replayGain: SubsonicReplayGain?
}

struct SubsonicReplayGain: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
}

struct SubsonicGenre: Decodable {
    let value: String?
    let songCount: Int?
    let albumCount: Int?
}

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String?
    let artist: String?
    let artistId: String?
    let year: Int?
    let songCount: Int?
    let duration: Double?
    let coverArt: String?
    let isCompilation: Bool?
    let song: [SubsonicSong]?
    let starred: String?
}

struct SubsonicArtist: Decodable {
    let id: String
    let name: String?
    let albumCount: Int?
    let coverArt: String?
    let musicBrainzId: String?
    let album: [SubsonicAlbum]?
    let starred: String?
}

struct SubsonicPlaylist: Decodable {
    let id: String
    let name: String?
    let songCount: Int?
    let duration: Double?
    let coverArt: String?
    let entry: [SubsonicSong]?
    let owner: String?
    let readonly: Bool?
}
