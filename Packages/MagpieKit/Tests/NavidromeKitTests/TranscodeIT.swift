import AVFoundation
import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

/// G0: runs only against the local dev stack. Every streaming preset must be something AVFoundation opens.
@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct TranscodeIT {
    private func client() throws -> NavidromeClient {
        let cfg = try DevStack.load()
        return NavidromeClient(endpoint: ServerEndpoint(bases: [cfg.url]),
                               credentials: NavidromeCredentials(username: cfg.user, password: cfg.password),
                               transport: SharedLoginTransport())
    }

    func playable(_ data: Data, ext: String) async throws -> (Bool, Double) {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let (ok, duration) = try await asset.load(.isPlayable, .duration)
        return (ok, duration.seconds)
    }

    @Test(arguments: [("aac", 256, "aac"), ("aac", 160, "aac"), ("aac", 96, "aac"), ("opus", 192, "ogg"), ("opus", 128, "ogg"),
                          ("opus", 96, "ogg"), ("opus", 64, "ogg"), ("mp3", 320, "mp3"), ("mp3", 192, "mp3")])
    func presetFormatsPlay(_ format: String, _ rate: Int, _ ext: String) async throws {
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: rate, format: format)!))
        #expect(response.statusCode == 200 && data.count > 1024)
        let (ok, seconds) = try await playable(data, ext: ext)
        #expect(ok, "\(format) \(rate) kbps is playable")
        #expect(seconds > 1)
    }

    /// D45: with `estimateContentLength=true` an uncached Opus transcode at 64 to 192 kbps is cut off (-1005, "wrote
    /// more than the declared Content-Length", found when the four presets were first added here), so the client
    /// leaves it off. Random low rates miss the server's transcode cache, so a fresh chunked transcode runs.
    @Test func uncachedOpusStreamsChunkedAndCompletes() async throws {
        let rate = Int.random(in: 41...63)
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let url = client.streamURL(songId: song.id, maxBitRate: rate, format: "opus")!
        #expect(!url.absoluteString.contains("estimateContentLength"))
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: url))
        #expect(response.statusCode == 200 && data.count > 1024)
        #expect(data.prefix(4) == Data("OggS".utf8))
    }

    /// Round 27 P (owner item 11, 2026-11-14): cause 3 of plan §2.7. With `estimateContentLength` (MP3 kept it, D42),
    /// MP3 192 and 128 of the VBR V0 fixture were cut short on the dev image (-1005, the server's "wrote more than the
    /// declared Content-Length"), so the song ended early; MP3 now goes out chunked too (D282). Each rate ends within
    /// 1 s of the API's length and never runs past a declared length.
    @Test(arguments: [320, 192, 128])
    func mp3OfAVBRFileEndsAtItsLength(_ rate: Int) async throws {
        let client = try client(); _ = try await client.connect()
        let found = try await client.search("Late Night Finds", songCount: 0, albumCount: 5, artistCount: 0)
        let albumId = try #require(found.albums.first { $0.name.hasPrefix("Late Night Finds") }?.id, "the VBR V0 fixture")
        let songs = try await client.album(id: albumId).songs ?? []
        let song = try #require(songs.max { $0.duration < $1.duration })
        let url = try #require(client.streamURL(songId: song.id, maxBitRate: rate, format: "mp3"))
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: url))
        #expect(response.statusCode == 200)
        if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) {
            #expect(data.count <= declared, "\(rate) kbps: no more than the declared length")
        }
        let (ok, seconds) = try await playable(data, ext: "mp3")
        #expect(ok)
        #expect(abs(seconds - song.duration) <= 1, "\(rate) kbps: \(seconds) s of a \(song.duration) s song")
    }

    /// Round 27 P (D278, D281): `timeOffset` starts a conversion part-way where the server advertises `transcodeOffset`.
    /// A server that doesn't advertise it: this says so and checks nothing more. The dev fixtures are 9 to 18 s long, so
    /// the plan's 30 s offset becomes half the longest song (a whole number of seconds, at least 5).
    @Test func convertedStreamStartsAtTimeOffset() async throws {
        let client = try client(); _ = try await client.connect()
        guard try await client.extensions().contains("transcodeOffset") else {
            print("TranscodeIT: skipped convertedStreamStartsAtTimeOffset: this Navidrome doesn't advertise transcodeOffset")
            return
        }
        var songs: [Song] = []
        for album in try await client.albumList(.newest, size: 20, offset: 0) {
            songs += try await client.album(id: album.id).songs ?? []
        }
        let song = try #require(songs.max { $0.duration < $1.duration })
        let offset = Int(song.duration / 2)
        try #require(offset >= 5, "a song of at least 10 s")
        let url = try #require(client.streamURL(songId: song.id, maxBitRate: 192, format: "mp3", timeOffset: offset))
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: url))
        #expect(response.statusCode == 200)
        let (ok, seconds) = try await playable(data, ext: "mp3")
        #expect(ok)
        let expected = song.duration - Double(offset)
        #expect(abs(seconds - expected) <= 1.5, "starts \(offset) s in: \(seconds) s of a \(song.duration) s song")
        let (whole, _) = try await URLSessionTransport().send(URLRequest(url: try #require(
            client.streamURL(songId: song.id, maxBitRate: 192, format: "mp3"))))
        let full = try await playable(whole, ext: "mp3").1
        #expect(seconds < full - Double(offset) / 2, "shorter than the whole song: \(seconds) s vs \(full) s")
    }

    @Test func originalIsPlayable() async throws {   // the fallback target
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: nil, format: "raw")!))
        #expect(response.statusCode == 200)
        #expect(try await playable(data, ext: song.suffix ?? "mp3").0)
    }
}
