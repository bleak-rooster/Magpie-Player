import Foundation
import MagpieCore
import Search
import Testing
@testable import Magpie

private let mbid = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!

private func row(_ id: String, _ source: TopSongsProvider = .library) -> LidarrTopSongs.Row {
    LidarrTopSongs.Row(song: Song(id: id, title: "Song \(id)", artist: "Aurora Field", artistId: "ar1", album: "First Light",
                                  albumId: "al1", duration: 201, suffix: "flac", bitRate: 900, coverArtId: "al-al1",
                                  recordingMBID: MBID("20a2961b-d8e8-481c-bd5b-abb38a2850ad"), artistMBID: mbid,
                                  isrcs: ["GBAAA0000001"], libraryId: 1),
                       source: source)
}

/// Round 26 K2 (owner, 2026-11-10, item 6: "This list should be saved for when the artist is next opened up"; D263): the
/// saved Top songs of artists Lidarr has, per account and artist, modelled on Popular's file (R3).
@MainActor @Suite(.serialized) struct LidarrTopSongsCacheTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LidarrTopSongsCacheTests-\(UUID().uuidString)")

    var cache: LidarrTopSongsCache { LidarrTopSongsCache(root: tmp, scope: "abc123") }

    @Test func cache_fileAndKeys() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(cache.url.path.hasSuffix("Magpie/TopSongs/abc123.json"))
        #expect(LidarrTopSongsCache.key(mbid: mbid, artistId: "ar1") == "mbid:\(mbid.rawValue)", "the MBID first")
        #expect(LidarrTopSongsCache.key(mbid: nil, artistId: "ar1") == "id:ar1", "else the library's artist id")
        #expect(LidarrTopSongsCache.key(mbid: nil, artistId: nil) == nil)
        #expect(LidarrTopSongsCache.key(mbid: nil, artistId: "") == nil)

        let key = try #require(LidarrTopSongsCache.key(mbid: mbid, artistId: nil))
        #expect(cache.load(key) == nil, "nothing saved")
        cache.save([row("a", .aurral), row("b", .listenBrainz)], key: key)
        let saved = try #require(cache.load(key))
        #expect(saved.map(\.id) == ["a", "b"] && saved.map(\.source) == ["aurral", "listenBrainz"])
        #expect(saved.first?.song.title == "Song a" && saved.first?.song.coverArtId == "al-al1" && saved.first?.song.duration == 201)
        #expect(LidarrTopSongsCache(root: tmp, scope: "other").load(key) == nil, "per account")
        #expect(cache.load("id:ar2") == nil, "per artist")

        cache.remove(key)
        #expect(cache.load(key) == nil)
        cache.save([row("a")], key: key)
        cache.save([], key: key)
        #expect(cache.load(key) == nil, "an empty list removes the artist")
    }

    @Test func cache_keepsAtMostFiveRows() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        cache.save((1...8).map { row("s\($0)") }, key: "id:ar1")
        #expect(cache.load("id:ar1")?.map(\.id) == ["s1", "s2", "s3", "s4", "s5"])
    }

    @Test func cache_keeps300Artists() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<302 { cache.save([row("s\(i)")], key: "id:ar\(i)", now: start.addingTimeInterval(TimeInterval(i))) }
        #expect(cache.load("id:ar0") == nil && cache.load("id:ar1") == nil, "the two saved longest ago go")
        #expect(cache.load("id:ar2") != nil && cache.load("id:ar301") != nil)
        #expect(cache.count == 300)
    }

    @Test func cache_oversizedReadsAsNone() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        cache.save([row("a")], key: "id:ar1")
        #expect(cache.load("id:ar1") != nil)
        let big = try Data(contentsOf: cache.url) + Data(repeating: 0x20, count: LidarrTopSongsCache.maxBytes)
        try big.write(to: cache.url)
        #expect(cache.load("id:ar1") == nil, "a file over 1 MB reads as none")
        try Data("{\"version\":2,\"artists\":{}}".utf8).write(to: cache.url)
        #expect(cache.load("id:ar1") == nil, "another version reads as none")
        try Data("not json".utf8).write(to: cache.url)
        #expect(cache.load("id:ar1") == nil)
        cache.save([row("b")], key: "id:ar1")
        #expect(cache.load("id:ar1")?.map(\.id) == ["b"], "an unreadable file is replaced by the next save")
    }

    /// Only ids and what a row shows: no URL, preview path, Deezer id, recording or artist MBID, ISRC or library id.
    @Test func cache_storesNoURLs() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        cache.save([row("a", .aurral)], key: "mbid:\(mbid.rawValue)")
        let text = try String(decoding: Data(contentsOf: cache.url), as: UTF8.self)
        for banned in ["http", "://", "preview", "deezer", "20a2961b", "GBAAA0000001", "libraryId", "recording", "isrc"] {
            #expect(!text.lowercased().contains(banned.lowercased()), "\(banned)")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cache.url)) as? [String: Any])
        let artists = try #require(object["artists"] as? [String: Any])
        let entry = try #require(artists["mbid:\(mbid.rawValue)"] as? [String: Any])
        let rows = try #require(entry["rows"] as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["id", "title", "artist", "artistId", "album", "albumId", "duration", "coverArtId",
                                      "suffix", "bitRate", "source"])
    }

    @Test func cache_excludedFromBackup() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        cache.save([row("a")], key: "id:ar1")
        #expect(try cache.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try cache.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup == true)
        LidarrTopSongsCache.removeAll(root: tmp)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
    }
}
