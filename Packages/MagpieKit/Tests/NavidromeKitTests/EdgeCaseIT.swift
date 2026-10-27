import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

/// Task 8.1 against the real dev-stack Navidrome (G0: local host and dev marker only, read-only calls): the error
/// shapes and empty answers the unit tests assume are what a real server sends.
@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct EdgeCaseIT {
    /// One client, one login: Navidrome rate-limits `/auth/login` (5 per 20 s by default; it answers 429), so
    /// the IT run as a whole must not log in per check.
    @Test func errorShapesOnTheRealServer() async throws {
        let cfg = try DevStack.load()
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [cfg.url]),
                                     credentials: NavidromeCredentials(username: cfg.user, password: cfg.password),
                                     transport: SharedLoginTransport())

        // An unknown id is Subsonic `failed` code 70 in an HTTP 200, surfaced as `.api(70, _)`.
        do {
            _ = try await client.album(id: "magpie-does-not-exist")
            Issue.record("expected an API error")
        } catch NavidromeError.api(let code, _) {
            #expect(code == 70)
        }

        // Unicode and URL-significant characters in a query: the server answers (empty is fine).
        for q in ["Sigur Rós", "東京事変", "AC/DC & + #1", "🐝"] {
            _ = try await client.search(q)
        }

        // A page past the end of the library: empty, with the real total.
        let first = try await client.songsPage(start: 0, end: 1)
        let past = try await client.songsPage(start: first.total + 1000, end: first.total + 2000)
        #expect(past.songs.isEmpty)
        #expect(past.total == first.total)
    }
}
