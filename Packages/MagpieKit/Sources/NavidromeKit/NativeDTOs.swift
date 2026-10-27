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
