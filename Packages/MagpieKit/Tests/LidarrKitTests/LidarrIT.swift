import Foundation
import Testing
import MagpieCore
@testable import LidarrKit

/// Integration tests against the local dev stack. Run via `scripts/it.sh` (sets MAGPIE_IT=1). GET only.
/// Guard G0: reads `dev/.env.local`, and refuses to run unless the host is local and the file carries the dev marker.
enum LidarrDevStack {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAGPIE_IT"] == "1" }

    enum Failure: Error { case missingEnv, notLocal(String), notDevStack }

    static func load() throws -> (url: URL, apiKey: String) {
        // Tests/LidarrKitTests/LidarrIT.swift → repo root is five levels up.
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
        guard let urlText = env["LIDARR_URL"], let url = URL(string: urlText), let key = env["LIDARR_API_KEY"] else {
            throw Failure.missingEnv
        }
        guard let host = url.host, ["127.0.0.1", "localhost"].contains(host) else {
            throw Failure.notLocal(url.host ?? "?")
        }
        return (url, key)
    }
}

@Suite(.enabled(if: LidarrDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct LidarrIT {
    /// G2/G9 on the dev stack: the Samples root validates against the others, and files Lidarr reports under
    /// the library root are outside it.
    @Test func devRootsValidateForFinds() async throws {
        let cfg = try LidarrDevStack.load()
        let client = LidarrClient(base: cfg.url, apiKey: cfg.apiKey, transport: URLSessionTransport())
        let roots = try await client.rootFolders().map(\.path)
        let samples = try #require(roots.first { $0 == "/music/samples" })
        let others = roots.filter { $0 != samples }
        #expect(PathGuard.validateRoot(samples, others: others) == .ok)
        #expect(PathGuard.validateRoot("/music/library", others: roots) == .equalsOther)
        let g = PathGuard(findsRoot: samples, otherRoots: others, caseInsensitive: false)
        for artist in try await client.artists() {
            guard let path = artist.path, path.hasPrefix("/music/library/") else { continue }
            #expect(!g.isInside(path))
        }
    }

    @Test func auditDevStack() async throws {
        let cfg = try LidarrDevStack.load()
        let client = LidarrClient(base: cfg.url, apiKey: cfg.apiKey, transport: URLSessionTransport())
        let audit = await LidarrAudit.run(client)
        #expect(audit.reachable)
        #expect(audit.version.hasPrefix("3."))
        #expect(audit.roots.contains { $0.path == "/music/library" })
        _ = try await client.tags()
        _ = try await client.artists()
        _ = try await client.commands()
        _ = try await client.queueDetails(albumIds: [])
        _ = try await client.historySince(Date(timeIntervalSinceNow: -86_400))
        #expect(try await client.filesystemExists(path: "/music/library"))
        #expect(try await client.filesystemExists(path: "/music/definitely-not-here") == false)
    }
}
