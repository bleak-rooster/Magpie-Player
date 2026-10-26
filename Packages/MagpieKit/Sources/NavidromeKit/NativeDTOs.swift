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
    let mbzRecordingID: String?   // validated in mapping, never decoded as MBID
    let tags: Tags?
    let libraryId: Int?
    let missing: Bool?
    let starred: Bool?
}
