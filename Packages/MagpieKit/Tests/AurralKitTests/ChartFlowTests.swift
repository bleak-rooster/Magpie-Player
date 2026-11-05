import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 15 C2 (owner items 5 and 5b, D130–D134): a flow of a chart's top N songs. Aurral 2.13's editorial add
/// (`POST /api/discover/editorial/:id/library`) takes no song count and re-syncs the whole chart, keeping removed songs,
/// so a chart flow is one of the user's own Aurral playlists ("shared playlists") holding exactly the top N:
/// `POST /api/playlists/shared-playlists {name, sourceName, tracks}` makes it, `PUT .../:id {tracks}` replaces its
/// songs (Refresh now, Songs: N) and `DELETE .../:id` removes it. Aurral downloads, matches and publishes it to
/// Navidrome as it does for Add flow.
@Suite struct ChartFlowTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        stub.setSyncedCreationDelay(reads: 0)
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    static func songs(_ n: Int) -> [ChartFlowTrack] {
        (1...n).map { ChartFlowTrack(artistName: "Artist \($0)", trackName: "Song \($0)", albumName: "Album \($0)",
                                     durationMs: 180_000 + $0 * 1_000) }
    }

    // MARK: - The routes (pinned in AurralRoute and check-writes)

    @Test func theThreeRoutesAndNothingNear() {
        #expect(AurralRoute.route(method: "POST", path: "api/playlists/shared-playlists") == .chartFlowCreate)
        #expect(AurralRoute.route(method: "PUT", path: "api/playlists/shared-playlists/a4000000-0000-4000-8000-000000000001") == .chartFlowUpdate)
        #expect(AurralRoute.route(method: "DELETE", path: "api/playlists/shared-playlists/pl_1") == .chartFlowDelete)
        for (method, path) in [("GET", "api/playlists/shared-playlists"), ("PUT", "api/playlists/shared-playlists"),
                               ("DELETE", "api/playlists/shared-playlists"), ("POST", "api/playlists/shared-playlists/pl-1"),
                               ("GET", "api/playlists/shared-playlists/pl-1"), ("PATCH", "api/playlists/shared-playlists/pl-1"),
                               ("PUT", "api/playlists/shared-playlists/../settings"), ("DELETE", "api/playlists/shared-playlists/a b"),
                               ("POST", "api/playlists/shared-playlists/pl-1/sync"), ("POST", "api/playlists/shared-playlists/pl-1/tracks"),
                               ("DELETE", "api/playlists/shared-playlists/pl-1/tracks/job-1"),
                               ("POST", "api/playlists/shared-playlists/pl-1/track-removals"),
                               ("PUT", "api/playlists/shared-playlists/pl-1/track-availability"),
                               ("PUT", "api/playlists/flows/flow-1"), ("DELETE", "api/playlists/flows/flow-1")] {
            #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
        }
        #expect(AurralRoute.chartFlowCreate.isAuthorised && AurralRoute.chartFlowUpdate.isAuthorised
                && AurralRoute.chartFlowDelete.isAuthorised)
        #expect(AurralRoute.chartFlowCreate.queryNames.isEmpty && AurralRoute.chartFlowUpdate.queryNames.isEmpty
                && AurralRoute.chartFlowDelete.queryNames.isEmpty)
    }

    // MARK: - Create, resize/refresh, remove

    @Test func createSendsExactlyTheTopSongsAndTheStatusListsIt() async throws {
        let made = try await client.createChartFlow(name: "Top Worldwide", tracks: Self.songs(10))
        #expect(!made.playlistId.isEmpty)
        #expect(stub.asked == ["POST /api/playlists/shared-playlists"])
        let body = try #require(stub.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["name", "sourceName", "tracks"])
        #expect(body["name"] as? String == "Top Worldwide" && body["sourceName"] as? String == "Charts")
        let tracks = try #require(body["tracks"] as? [[String: Any]])
        #expect(tracks.count == 10)
        #expect(Set(tracks[0].keys) == ["artistName", "trackName", "albumName", "durationMs"])
        #expect(tracks[0]["trackName"] as? String == "Song 1" && tracks[9]["artistName"] as? String == "Artist 10")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.count == 10)
        let status = try await client.status()
        #expect(status.sharedPlaylists.contains { $0.id == made.playlistId && $0.name == "Top Worldwide" })
    }

    @Test func resizingReplacesTheSongsKeepingTheOnesStillIn() async throws {
        let made = try await client.createChartFlow(name: "Top Australia", tracks: Self.songs(10))
        _ = try await client.updateChartFlow(playlistId: made.playlistId, tracks: Array(Self.songs(10).prefix(5)))
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.map(\.title) == ["Song 1", "Song 2", "Song 3", "Song 4", "Song 5"])
        _ = try await client.updateChartFlow(playlistId: made.playlistId, tracks: Self.songs(20))
        #expect(stub.sharedPlaylistSongs(made.playlistId)?.count == 20)
        let put = try #require(stub.requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.path == "/api/playlists/shared-playlists/\(made.playlistId)")
        let body = try #require(put.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["tracks"], "only the songs: the name and source stay as they are")
    }

    @Test func removeDeletesItAndAGoneOneIsAlreadyRemoved() async throws {
        let made = try await client.createChartFlow(name: "Pop", tracks: Self.songs(3))
        try await client.deleteChartFlow(playlistId: made.playlistId)
        #expect(stub.sharedPlaylistSongs(made.playlistId) == nil)
        #expect(stub.requests.last?.httpBody == nil, "no body")
        try await client.deleteChartFlow(playlistId: made.playlistId)   // 404: already gone, nothing to do
        await #expect(throws: AurralError.notFound) {
            _ = try await client.updateChartFlow(playlistId: made.playlistId, tracks: Self.songs(2))
        }
    }

    @Test func aNameAlreadyTakenIsTold() async throws {
        stub.addSharedPlaylist(id: "own-1", name: "Top Worldwide", provider: nil, songs: [])
        await #expect(throws: AurralError.nameTaken) {
            _ = try await client.createChartFlow(name: "Top Worldwide", tracks: Self.songs(2))
        }
    }

    @Test func withoutAccessFlowItIsRefused() async throws {
        stub.addUser(id: 2, username: "kid", password: "pw", role: "user")
        let kid = AurralClient(base: stub.base, session: AurralSession(username: "kid", password: "pw", login: nil), transport: stub)
        await #expect(throws: AurralError.notPermitted) { _ = try await kid.createChartFlow(name: "x", tracks: Self.songs(1)) }
    }

    @Test func oddIdsAndEmptyListsAreRefusedUnsent() async throws {
        for id in ["", "../settings", "a b", "a/b", String(repeating: "a", count: 101)] {
            await #expect(throws: AurralError.self, "\(id)") { _ = try await client.updateChartFlow(playlistId: id, tracks: Self.songs(1)) }
            await #expect(throws: AurralError.self, "\(id)") { try await client.deleteChartFlow(playlistId: id) }
        }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "x", tracks: []) }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "  ", tracks: Self.songs(1)) }
        await #expect(throws: AurralError.self) { _ = try await client.createChartFlow(name: "x", tracks: Self.songs(101)) }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - The plan: which songs

    @Test func theTopNSkippingRepeatsAndBlanks() {
        var songs = Self.songs(6)
        songs.insert(ChartFlowTrack(artistName: "ARTIST 1", trackName: "song 1 ", albumName: nil, durationMs: nil), at: 1)
        songs.insert(ChartFlowTrack(artistName: " ", trackName: "Nameless", albumName: nil, durationMs: nil), at: 2)
        let plan = ChartFlowPlan.tracks(from: songs, count: 3)
        #expect(plan.map(\.trackName) == ["Song 1", "Song 2", "Song 3"])
        #expect(ChartFlowPlan.tracks(from: songs, count: 0).count == 1, "at least one")
        #expect(ChartFlowPlan.tracks(from: songs, count: 500).count == 6, "at most what the chart has")
        #expect(ChartFlowPlan.tracks(from: Self.songs(150), count: 150).count == ChartFlowPlan.maxSongs)
    }

    @Test func theCountsOffered() {
        #expect(ChartFlowPlan.presets(chartLength: 100) == [10, 20, 25, 50, 100])
        #expect(ChartFlowPlan.presets(chartLength: 50) == [10, 20, 25, 50])
        #expect(ChartFlowPlan.presets(chartLength: 30) == [10, 20, 25, 30])
        #expect(ChartFlowPlan.presets(chartLength: 4) == [4])
        #expect(ChartFlowPlan.presets(chartLength: 0) == [])
        #expect(ChartFlowPlan.defaultCount(chartLength: 100) == 25 && ChartFlowPlan.defaultCount(chartLength: 12) == 12)
    }

    // MARK: - Each chart its own flow (D133)

    @Test func eachChartHasItsOwnFlowAndCount() throws {
        var book = ChartFlowBook()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        book.set(ChartFlow(chartKey: "worldwide", playlistId: "pl-w", name: "Top Worldwide", count: 10, createdAt: now, refreshedAt: now))
        book.set(ChartFlow(chartKey: "country:AU", playlistId: "pl-au", name: "Top Australia", count: 50, createdAt: now, refreshedAt: now))
        book.set(ChartFlow(chartKey: "genre:132", playlistId: "pl-pop", name: "Pop", count: 20, createdAt: now, refreshedAt: now))
        #expect(book.flow(for: "worldwide")?.count == 10 && book.flow(for: "country:AU")?.count == 50)
        book.resize("worldwide", to: 5, at: now.addingTimeInterval(60))
        #expect(book.flow(for: "worldwide")?.count == 5 && book.flow(for: "country:AU")?.count == 50, "only that chart")
        #expect(book.flow(for: "worldwide")?.refreshedAt == now.addingTimeInterval(60))
        #expect(book.playlistIds == ["pl-w", "pl-au", "pl-pop"])
        book.remove("country:AU")
        #expect(book.flow(for: "country:AU") == nil && book.playlistIds == ["pl-w", "pl-pop"])
        let decoded = try JSONDecoder().decode(ChartFlowBook.self, from: try JSONEncoder().encode(book))
        #expect(decoded == book)
        #expect(book.chartKey(forPlaylist: "pl-pop") == "genre:132")
    }
}
