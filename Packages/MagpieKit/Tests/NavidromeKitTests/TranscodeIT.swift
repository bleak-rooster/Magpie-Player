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

    @Test(arguments: [("aac", 256, "aac"), ("aac", 160, "aac"), ("aac", 96, "aac"), ("mp3", 320, "mp3"), ("mp3", 192, "mp3")])
    func presetFormatsPlay(_ format: String, _ rate: Int, _ ext: String) async throws {
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: rate, format: format)))
        #expect(response.statusCode == 200 && data.count > 1024)
        let (ok, seconds) = try await playable(data, ext: ext)
        #expect(ok, "\(format) \(rate) kbps is playable")
        #expect(seconds > 1)
    }

    @Test func originalIsPlayable() async throws {   // the fallback target
        let client = try client(); _ = try await client.connect()
        let album = try await client.album(id: try await client.albumList(.newest, size: 1, offset: 0)[0].id)
        let song = try #require(album.songs?.first)
        let (data, response) = try await URLSessionTransport().send(URLRequest(url: client.streamURL(songId: song.id, maxBitRate: nil, format: "raw")))
        #expect(response.statusCode == 200)
        #expect(try await playable(data, ext: song.suffix ?? "mp3").0)
    }
}
