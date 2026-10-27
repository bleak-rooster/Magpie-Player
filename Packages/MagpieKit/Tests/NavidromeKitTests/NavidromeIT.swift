import Foundation
import Testing
import MagpieCore
@testable import NavidromeKit

/// Integration tests against the local dev stack. Run via `scripts/it.sh` (sets MAGPIE_IT=1).
/// Guard G0: reads `dev/.env.local`, and refuses to run unless the host is local and the file carries the dev marker.
enum DevStack {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAGPIE_IT"] == "1" }

    struct Config {
        var url: URL
        var user: String
        var password: String
    }

    enum Failure: Error { case missingEnv, notLocal(String), notDevStack }

    static func load() throws -> Config {
        // Tests/NavidromeKitTests/NavidromeIT.swift → repo root is five levels up.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent("dev/.env.local"), encoding: .utf8) else {
            throw Failure.missingEnv
        }
        guard text.contains("Magpie dev stack") else { throw Failure.notDevStack }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0]] = parts[1] }
        }
        guard let urlText = env["NAVIDROME_URL"], let url = URL(string: urlText),
              let user = env["NAVIDROME_ADMIN_USER"], let password = env["NAVIDROME_ADMIN_PASSWORD"] else {
            throw Failure.missingEnv
        }
        guard let host = url.host, ["127.0.0.1", "localhost"].contains(host) else {
            throw Failure.notLocal(url.host ?? "?")
        }
        return Config(url: url, user: user, password: password)
    }
}

@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct NavidromeIT {
    private func client() throws -> NavidromeClient {
        let cfg = try DevStack.load()
        return NavidromeClient(endpoint: ServerEndpoint(bases: [cfg.url]),
                               credentials: NavidromeCredentials(username: cfg.user, password: cfg.password),
                               transport: URLSessionTransport())
    }

    /// B6: the dev stack's libraries as Navidrome sees them (same paths as Lidarr's roots there).
    @Test func librariesOnTheDevStack() async throws {
        let client = try client()
        _ = try await client.connect()
        let paths = try await client.libraries().map(\.path)
        #expect(paths.contains("/music/library"))
        #expect(paths.contains("/music/samples"))
    }

    @Test func connectBrowsePlayableStream() async throws {
        let client = try client()
        let login = try await client.connect()
        #expect(login.isAdmin)

        let albums = try await client.albumList(.newest, size: 10, offset: 0)
        #expect(albums.count >= 1)
        let album = try await client.album(id: albums[0].id)
        let songs = try #require(album.songs)
        #expect(!songs.isEmpty)

        var request = URLRequest(url: client.streamURL(songId: songs[0].id, maxBitRate: nil, format: nil))
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSessionTransport().send(request)
        #expect(response.statusCode == 200)
    }

    @Test func nativeSongPageAndScanStatus() async throws {
        let client = try client()
        _ = try await client.connect()
        let page = try await client.songsPage(start: 0, end: 5)
        #expect(page.total >= page.songs.count)
        #expect(!page.songs.isEmpty)
        _ = try await client.scanStatus()
        #expect(try await client.extensions().contains("songLyrics"))
    }
}
