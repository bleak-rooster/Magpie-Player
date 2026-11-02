import Foundation
import MagpieCore
import Testing
@testable import Playback

private func entry(_ id: String, album: String, albumId: String?, reasons: Set<DownloadReason>, at seconds: TimeInterval,
                   kind: AudioKind = .download) -> AudioEntry {
    let song = Song(id: id, title: id, artist: "A", artistId: "ar1", album: album, albumId: albumId, duration: 60)
    return AudioEntry(songId: id, quality: .original, fileName: "\(id).flac", size: 1, kind: kind,
                      reasons: kind == .download ? reasons : [], downloadedAt: Date(timeIntervalSince1970: seconds),
                      lastPlayed: nil, metadata: AudioMetadata(song))
}

/// Round 12 Y3 (plan item 5): Home's "Recently downloaded" is newest first by when the songs landed, and a downloaded
/// playlist is listed as itself, not split into the partial albums its songs come from.
@Suite struct RecentDownloadsTests {
    @Test func newestFirstByDownloadDate() {
        let c = OfflineCatalog(entries: [
            entry("a1", album: "Aardvark", albumId: "A", reasons: [.album("A")], at: 100),
            entry("z1", album: "Zebra", albumId: "Z", reasons: [.album("Z")], at: 300),
            entry("m1", album: "Moth", albumId: "M", reasons: [.album("M")], at: 200),
            entry("m2", album: "Moth", albumId: "M", reasons: [.album("M")], at: 50),
        ], playlists: [])
        #expect(c.recentlyDownloaded().map(\.id) == ["album-Z", "album-M", "album-A"], "not A–Z: newest first")
    }

    @Test func playlistsAreThemselvesNotPartialAlbums() {
        let mix = DownloadedPlaylist(id: "p1", name: "Road Mix", coverArtId: "pl-1", songIds: ["x1", "y1"], savedAt: .distantPast)
        let c = OfflineCatalog(entries: [
            entry("x1", album: "Xylo", albumId: "X", reasons: [.playlist("p1")], at: 500),
            entry("y1", album: "Yarrow", albumId: "Y", reasons: [.playlist("p1")], at: 510),
            entry("a1", album: "Aardvark", albumId: "A", reasons: [.album("A")], at: 400),
            entry("b1", album: "Both", albumId: "B", reasons: [.album("B"), .playlist("p1")], at: 300),
            entry("c1", album: "Cached", albumId: "C", reasons: [], at: 900, kind: .cache),
        ], playlists: [mix])
        let items = c.recentlyDownloaded()
        #expect(items.map(\.id) == ["playlist-p1", "album-A", "album-B"],
                "the playlist's own songs make no album tiles; a song also downloaded with its album keeps that album")
        guard case .playlist(let playlist) = items.first else { Issue.record("playlist first"); return }
        #expect(playlist.name == "Road Mix" && playlist.coverArtId == "pl-1")
    }

    @Test func ties() {
        let c = OfflineCatalog(entries: [
            entry("b1", album: "Bee", albumId: "B", reasons: [.song], at: 10),
            entry("a1", album: "Ant", albumId: "A", reasons: [.song], at: 10),
        ], playlists: [])
        #expect(c.recentlyDownloaded().map(\.id) == ["album-A", "album-B"], "the same moment: by name")
    }
}
