import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import NavidromeKit

/// G0: runs only against the local dev stack (`DevStack`), with the fixture genres from `dev/fixtures/make-library.sh`.
@Suite(.enabled(if: DevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct GenreIT {
    private func client() throws -> NavidromeClient {
        let cfg = try DevStack.load()
        return NavidromeClient(endpoint: ServerEndpoint(bases: [cfg.url]),
                               credentials: NavidromeCredentials(username: cfg.user, password: cfg.password),
                               transport: SharedLoginTransport())
    }

    @Test func fixtureGenresAndStarred() async throws {
        let client = try client(); _ = try await client.connect()
        let genres = try await client.genres()
        #expect(genres.first { $0.name == "Ambient" }?.albumCount == 2)
        #expect(genres.first { $0.name == "Indie Rock" }?.albumCount == 1)
        #expect(try await client.albums(genre: "Ambient", size: 50, offset: 0).count == 2)
        let ambient = try await client.songs(genre: "Ambient", count: 500, offset: 0)
        #expect(ambient.count == 12 && ambient.allSatisfy { $0.genre == "Ambient" })
        let id = ambient[0].id
        try await client.star(id: id)
        #expect(try await client.starred().songs.map(\.id).contains(id))
        try await client.unstar(id: id)
        #expect(!(try await client.starred().songs.map(\.id).contains(id)))
    }
}
