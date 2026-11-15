import Foundation
import MagpieTestSupport
import Testing
import MagpieCore
@testable import Playback

/// Round 28 O2 (owner, 2026-11-15, "ensure … there are no edge case errors"): seeded, deterministic runs of downloads,
/// removals, page records, lyrics, covers and refreshes against a real store, with odd stored data thrown in (D331–D336).
/// Invariants after every step: no record without a download, no lyrics without a download, no cover unreferenced
/// after a prune, the catalogue builds every page without trapping, and nothing it lists is a cached song.
@Suite(.serialized) final class OfflineCatalogFuzzTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "OfflineCatalogFuzzTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: tmp) }

    static let songIds = (0..<8).map { "s\($0)" }
    static let albumIds = ["al0", "al1", "al2"]
    static let artistIds = ["ar0", "ar1", "va"]

    static func song(_ id: String, _ rng: inout SeededRNG) -> Song {
        let n = Int(id.dropFirst()) ?? 0
        return Song(id: id, title: ["T\(n)", "", "Ünï \(n)"].randomElement(using: &rng)!,
                    artist: "Artist \(n % 2)", artistId: Bool.random(using: &rng) ? "ar\(n % 2)" : nil,
                    album: "Album \(n % 3)", albumId: Int.random(in: 0..<5, using: &rng) == 0 ? nil : "al\(n % 3)",
                    track: Int.random(in: -1...20, using: &rng), disc: Bool.random(using: &rng) ? nil : 1,
                    duration: [60, 0, -5].randomElement(using: &rng)!, coverArtId: "mf-\(id)")
    }

    func temp() throws -> URL {
        let dir = tmp.appending(path: "incoming")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: UUID().uuidString)
        try Data(count: 10).write(to: url)
        return url
    }

    @Test func catalog_randomDownloadsRemovalsAndRefreshesNeverOrphanOrTrap() async throws {
        for seed in UInt64(1)...500 {
            var rng = SeededRNG(seed: seed)
            let root = tmp.appending(path: "seed\(seed)")
            var store = AudioStore(root: root, scope: "fuzz")
            await store.load()
            for _ in 0..<14 {
                let id = Self.songIds.randomElement(using: &rng)!
                let song = Self.song(id, &rng)
                let reasons: [DownloadReason] = [.song, .album(song.albumId ?? "al0"), .playlist("p1"), .favourites, .artist("ar0")]
                switch Int.random(in: 0..<13, using: &rng) {
                case 0, 1:
                    let kind: AudioKind = Int.random(in: 0..<4, using: &rng) == 0 ? .cache : .download
                    _ = try? await store.add(temp(), metadata: AudioMetadata(song), quality: .original, kind: kind,
                                             reason: kind == .download ? reasons.randomElement(using: &rng)! : nil,
                                             fileExtension: "mp3", downloadsLimit: nil)
                case 2:
                    let songs = (0..<Int.random(in: 0...4, using: &rng)).map { _ in Self.song(Self.songIds.randomElement(using: &rng)!, &rng) }
                    let album = Album(id: Self.albumIds.randomElement(using: &rng)!, name: "A", artist: "Various",
                                      artistId: Self.artistIds.randomElement(using: &rng)!,
                                      songCount: Int.random(in: -3...9, using: &rng), duration: .nan, coverArtId: "al-x")
                    _ = try? await store.recordAlbum(.init(album: album, songs: songs, savedAt: .now))
                case 3:
                    let artist = Artist(id: Self.artistIds.randomElement(using: &rng)!, name: "N", albumCount: 1,
                                        coverArtId: "ar-\(Int.random(in: 0..<3, using: &rng))")
                    let albums = Self.albumIds.shuffled(using: &rng).prefix(2).map {
                        Album(id: $0, name: "A", artist: "N", songCount: 1, duration: 1)
                    }
                    _ = try? await store.recordArtist(.init(artist: artist, albums: albums, savedAt: .now))
                case 4:
                    let songs = Self.songIds.shuffled(using: &rng).prefix(3).map { Self.song($0, &rng) }
                    let playlist = Playlist(id: ["p1", "p2"].randomElement(using: &rng)!, name: "P", songCount: 3, duration: 1,
                                            coverArtId: "pl-1", owner: Bool.random(using: &rng) ? "sam" : nil)
                    _ = try? await store.recordPlaylist(OfflineRecords.playlistRecord(
                        playlist, songs: songs, kind: [.playlist, .flow, .sharedPlaylist].randomElement(using: &rng)!, savedAt: .now))
                case 5:
                    let lyrics = Bool.random(using: &rng) ? nil : Lyrics(synced: Bool.random(using: &rng), lines: [LyricLine(text: "la")])
                    _ = try? await store.saveLyrics(OfflineLyrics(songId: id, source: .library, lyrics: lyrics, savedAt: .now))
                case 6:
                    _ = try? await store.saveCover(Data([1]), coverArtId: ["mf-\(id)", "al-x", "ar-1", "pl-1", "stray"].randomElement(using: &rng)!)
                case 7:
                    _ = try? await store.refreshMetadata(song, albumArtist: Bool.random(using: &rng) ? "Various" : nil,
                                                         albumArtistId: Bool.random(using: &rng) ? "va" : nil)
                case 8, 9:
                    let reason = reasons.randomElement(using: &rng)!
                    _ = try? await store.removeReason(reason, songIds: Bool.random(using: &rng) ? nil : [id])
                    await store.pruneCovers(keeping: [])
                    try await checkPruned(store, seed: seed, pruneCovers: true)
                case 10:
                    if Int.random(in: 0..<4, using: &rng) == 0 {
                        _ = try? await store.removeAll(kind: .download)
                        try await checkPruned(store, seed: seed, pruneCovers: true)
                    }
                case 11:
                    // Odd stored data: the records or a lyrics file mangled, then a relaunch.
                    let dir = store.directory
                    let target = Bool.random(using: &rng) ? dir.appending(path: "records.json")
                        : dir.appending(path: "lyrics/\(AudioStore.sha256(id)).json")
                    if FileManager.default.fileExists(atPath: target.path) {
                        let junk: [Data] = [Data(), Data("{".utf8), Data("[1,2]".utf8),
                                            Data(#"{"version":1,"albums":{"x":{"id":"y"}},"artists":{},"playlists":{}}"#.utf8),
                                            Data(#"{"version":1,"songId":"\#(id)","source":"other","savedAt":0}"#.utf8),
                                            Data((0..<40).map { _ in UInt8.random(in: 0...255, using: &rng) })]
                        try junk.randomElement(using: &rng)!.write(to: target)
                    }
                    store = AudioStore(root: root, scope: "fuzz")
                    await store.load()
                default:
                    _ = try? await store.markPlayed(songId: id)
                }
                try await checkCatalogue(store, seed: seed)
            }
        }
    }

    /// No record or lyrics file without a download; after a prune, no cover nothing names.
    func checkPruned(_ store: AudioStore, seed: UInt64, pruneCovers: Bool) async throws {
        let downloads = await store.entries().filter { $0.kind == .download }
        let records = await store.records()
        #expect(records == records.pruned(downloads: downloads.map(\.metadata)), "seed \(seed): a record outlived its downloads")
        let ids = Set(downloads.map(\.songId))
        let lyricsDir = store.directory.appending(path: "lyrics")
        let lyricsNames = Set((try? FileManager.default.contentsOfDirectory(atPath: lyricsDir.path)) ?? [])
        let allowed = Set(ids.map { AudioStore.sha256($0) + ".json" })
        #expect(lyricsNames.isSubset(of: allowed), "seed \(seed): lyrics outlived their song")
        if pruneCovers {
            let covers = Set((try? FileManager.default.contentsOfDirectory(atPath: store.directory.appending(path: "covers").path)) ?? [])
            let named = downloads.flatMap { [$0.metadata.coverArtId, $0.metadata.albumCoverArtId] }.compactMap { $0 }
                + Array(records.coverIds) + (await store.playlists()).compactMap(\.coverArtId)
            let referenced = Set(named.map { AudioStore.sha256($0) + ".jpg" })
            #expect(covers.isSubset(of: referenced), "seed \(seed): a cover nothing names")
        }
    }

    /// Every page builds, and nothing listed is a cached song.
    func checkCatalogue(_ store: AudioStore, seed: UInt64) async throws {
        let entries = await store.entries()
        let cached = Set(entries.filter { $0.kind == .cache }.map(\.songId))
        let c = OfflineCatalog(entries: entries, playlists: await store.playlists(), records: await store.records())
        var listed: [Song] = c.songs()
        for album in c.albums() {
            let page = try #require(c.albumPage(id: album.id), "seed \(seed): an album listed with no page")
            listed += page.album.songs ?? []
            #expect(page.onPhone == (page.album.songs?.count ?? 0))
        }
        for artist in c.artists() {
            let page = try #require(c.artistPage(id: artist.id), "seed \(seed): an artist listed with no page")
            listed += page.songs + page.albums.flatMap { $0.songs ?? [] }
        }
        for playlist in c.playlists(includingRecorded: true) {
            let page = try #require(c.playlistPage(id: playlist.id), "seed \(seed): a playlist listed with no page")
            listed += page.songs
        }
        #expect(listed.allSatisfy { !cached.contains($0.id) }, "seed \(seed): a cached song was listed")
    }
}
