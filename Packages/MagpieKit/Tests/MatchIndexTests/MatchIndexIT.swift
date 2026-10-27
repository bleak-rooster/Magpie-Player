import Foundation
import MagpieCore
import NavidromeKit
import Testing
@testable import MatchIndex

/// Builds the match index from the dev stack's Navidrome. Run via `scripts/it.sh` (MAGPIE_IT=1).
/// Guard G0: reads `dev/.env.local`; refuses unless the dev marker is present and the host is local.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAGPIE_IT"] == "1", "set MAGPIE_IT=1 (scripts/it.sh)"))
struct MatchIndexIT {
    struct NotDevStack: Error {}

    static func client() throws -> NavidromeClient {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("dev/.env.local"), encoding: .utf8)
        guard text.contains("Magpie dev stack") else { throw NotDevStack() }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0]] = parts[1] }
        }
        guard let url = env["NAVIDROME_URL"].flatMap(URL.init(string:)), let host = url.host,
              ["127.0.0.1", "localhost"].contains(host),
              let user = env["NAVIDROME_ADMIN_USER"], let password = env["NAVIDROME_ADMIN_PASSWORD"] else {
            throw NotDevStack()
        }
        return NavidromeClient(endpoint: ServerEndpoint(bases: [url]),
                               credentials: NavidromeCredentials(username: user, password: password),
                               transport: URLSessionTransport())
    }

    @Test func buildsFromDevLibraryAndMatchesItsOwnSongs() async throws {
        let client = try Self.client()
        let url = FileManager.default.temporaryDirectory.appending(path: "MatchIndexIT-\(UUID().uuidString).json")
        let store = MatchIndexStore(fileURL: url)
        try await store.refresh(using: client)
        let index = await store.index
        let page = try await client.songsPage(start: 0, end: 50)
        #expect(index.count >= page.songs.count && index.count > 0)

        for song in page.songs {
            if let mbid = song.recordingMBID {
                let byMBID = ExternalRecording(recordingMBID: mbid, title: "x", artist: "y", source: .listenBrainz)
                #expect(index.match(byMBID)?.confidence == 1.0)
            }
            let byName = ExternalRecording(title: song.title.uppercased(), artist: song.artist,
                                           duration: song.duration + 1, source: .listenBrainz)
            #expect((index.match(byName)?.confidence ?? 0) >= MatchIndex.acceptThreshold, "\(song.title)")
        }
        let reloaded = MatchIndexStore(fileURL: url)
        #expect(await reloaded.loadSnapshot())
        #expect(await reloaded.index.count == index.count)
        await reloaded.erase()
    }
}
