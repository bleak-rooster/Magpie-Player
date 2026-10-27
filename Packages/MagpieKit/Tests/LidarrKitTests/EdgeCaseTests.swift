import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

// Task 8.1: Lidarr behind a proxy that answers HTML, and a key that stopped working.

private let proxyPage = Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)

@Suite struct LidarrEdgeCaseTests {
    /// A 200 HTML page instead of JSON: a typed `decoding` error from every read, never a crash.
    @Test func htmlPageIsDecodingError() async throws {
        let t = MockTransport()
        for suffix in ["/system/status", "/rootfolder", "/artist", "/album", "/queue/details", "/history/since", "/search"] {
            t.stub(pathSuffix: suffix, body: proxyPage, headers: ["Content-Type": "text/html"])
        }
        let (client, _) = makeClient(t)
        await #expect(throws: LidarrError.decoding) { try await client.status() }
        await #expect(throws: LidarrError.decoding) { try await client.rootFolders() }
        await #expect(throws: LidarrError.decoding) { try await client.artists() }
        await #expect(throws: LidarrError.decoding) { try await client.albums(artistId: 1) }
        await #expect(throws: LidarrError.decoding) { try await client.queueDetails(albumIds: [1]) }
        await #expect(throws: LidarrError.decoding) { try await client.historySince(Date()) }
        await #expect(throws: LidarrError.decoding) { try await client.search(term: "x") }
    }

    /// The audit over a proxy page: not reachable, not a wrong key, every section empty.
    @Test func auditOverHTMLIsNotReachable() async {
        let t = MockTransport()
        t.stub(pathSuffix: "", body: proxyPage)
        let (client, _) = makeClient(t)
        let audit = await LidarrAudit.run(client)
        #expect(!audit.reachable && !audit.keyRejected)
        #expect(audit.roots.isEmpty && audit.healthIssues.isEmpty && !audit.tubifarry && !audit.hasMagpieProfiles)
    }

    /// The key was regenerated in Lidarr: the audit says so (Settings tells the owner), rather than
    /// "not answering".
    @Test(arguments: [401, 403])
    func auditWithRejectedKey(status: Int) async {
        let t = MockTransport()
        t.stub(pathSuffix: "", status: status, body: Data(#"{"error":"Unauthorized"}"#.utf8))
        let (client, _) = makeClient(t)
        let audit = await LidarrAudit.run(client)
        #expect(!audit.reachable)
        #expect(audit.keyRejected)
    }

    /// Unicode artist names and terms survive the query string.
    @Test func unicodeSearchTerm() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/search", body: Data("[]".utf8))
        let (client, _) = makeClient(t)
        _ = try await client.search(term: "Sigur Rós & 東京事変 #1")
        let req = try #require(t.requests.last)
        #expect(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "term" }?.value == "Sigur Rós & 東京事変 #1")
        #expect(req.url?.path == "/lidarr/api/v1/search")
    }
}
