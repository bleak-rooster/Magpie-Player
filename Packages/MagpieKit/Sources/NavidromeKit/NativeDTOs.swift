import Foundation

struct LoginDTO: Decodable {
    let id: String
    let isAdmin: Bool?
    let name: String?
    let username: String?
    let token: String
    let subsonicToken: String?
    let subsonicSalt: String?
}

/// `/api/song` row. Field names verified against Navidrome 0.64.2.
struct NativeSong: Decodable {
    struct Tags: Decodable { let isrc: [String]? }
    let id: String
    let title: String?
    let artist: String?
    let artistId: String?
    let album: String?
    let albumId: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double?
    let suffix: String?
    let bitRate: Int?
    let hasCoverArt: Bool?
    struct Participant: Decodable { let mbzArtistId: String? }
    struct Participants: Decodable { let artist: [Participant]? }
    let mbzRecordingID: String?   // validated in mapping, never decoded as MBID
    let mbzArtistId: String?
    let participants: Participants?
    let tags: Tags?
    let libraryId: Int?
    /// Relative to the library's folder.
    let path: String?
    let missing: Bool?
    let starred: Bool?
    let createdAt: String?   // parsed in mapping (nine fraction digits on 0.64.2)
    let genre: String?
    let rgTrackGain: Double?
    let rgAlbumGain: Double?
    let rgTrackPeak: Double?
    let rgAlbumPeak: Double?
    let sampleRate: Int?
    let bitDepth: Int?
}

/// `/api/library` row (Navidrome 0.58+; verified against 0.64.2).
struct NativeLibrary: Decodable {
    let id: Int
    let name: String?
    let path: String
}

/// A Navidrome library folder: its id (the `<libraryId>:` of a targeted scan) and its path on the server.
public struct NavidromeLibrary: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var path: String

    public init(id: Int, name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }
}

/// A library as the Subsonic API lists it (`getMusicFolders`): readable by every account, without its path.
public struct MusicFolder: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) { self.id = id; self.name = name }
}

/// One row of `/api/artist` (every role: album artists and track-only artists).
struct NativeArtist: Decodable {
    let id: String
    let name: String?
    let albumCount: Int?
    let mbzArtistId: String?
    let imageAbsent: Bool?
    let missing: Bool?
    let starred: Bool?
}
