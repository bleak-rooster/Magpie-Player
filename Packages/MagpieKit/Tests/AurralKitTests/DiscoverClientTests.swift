import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1: the 2.13 reads over the wire, against StubAurral (never the owner's Aurral).
@Suite struct DiscoverClientTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    static let mbid = MBID("a74b1b7f-71a5-4011-9441-d0b5e4122711")!

    @Test func readsEveryDiscoverRoute() async throws {
        let recs = try await client.recommendations(limit: 2, offset: 1)
        #expect(recs.artists.map(\.name) == ["Low Tide Club", "Mallee Fowl"])
        let trending = try await client.trending()
        #expect(trending.region == "AU" && trending.songs?.items.count == 5 && trending.genres.count == 3)
        #expect(try await client.trendingGenre(132)?.name == "Pop")
        let shelf = try await client.editorialShelf()
        #expect(shelf.forYou.count == 2 && shelf.genres.count == 2)
        let playlist = try await client.editorialPlaylist("908622995")
        #expect(playlist.tracks.count == 4)
        let links = try await client.editorialLinks(artist: "Stub Arrows", album: "Wide Open", deezerAlbumId: "302127")
        #expect(links.artistMBID == Self.mbid && links.albumMBID != nil)
        let preview = try await client.artistPreview(Self.mbid, artistName: "Stub Arrows")
        #expect(preview.count == 3 && preview.allSatisfy { $0.artistName == "Stub Arrows" && $0.preview != nil })
        let unified = try await client.searchUnified("arrows", limit: 10)
        #expect(unified.artists.count == 2 && unified.albums.count == 1)
        let tracks = try await client.releaseGroupTracks(MBID(StubAurralDiscover.releaseGroup)!, artistMBID: Self.mbid,
                                                         artistName: "Stub Arrows", albumTitle: "Wide Open")
        #expect(tracks.count == 4 && tracks.filter { $0.preview != nil }.count == 3)
        #expect(stub.asked == [
            "GET /api/discover", "GET /api/discover/trending", "GET /api/discover/trending/genres/132",
            "GET /api/discover/editorial", "GET /api/discover/editorial/908622995", "GET /api/discover/editorial/links",
            "GET /api/artists/a74b1b7f-71a5-4011-9441-d0b5e4122711/preview", "GET /api/search/unified",
            "GET /api/artists/release-group/\(StubAurralDiscover.releaseGroup)/tracks",
        ])
        let queries = stub.requests.map { $0.url?.query ?? "" }
        #expect(queries[0] == "limit=2&offset=1")
        #expect(queries[5] == "artist=Stub%20Arrows&album=Wide%20Open&albumId=302127")
        #expect(queries[6] == "artistName=Stub%20Arrows")
        #expect(queries[7] == "q=arrows&mode=full&limit=10")
        #expect(queries[8] == "artistMbid=a74b1b7f-71a5-4011-9441-d0b5e4122711&artistName=Stub%20Arrows&albumTitle=Wide%20Open")
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
    }

    @Test func searchPagesForLoadMore() async throws {
        let first = try await client.searchAlbums("wide", limit: 24, offset: 0)
        #expect(first.items.count == 24 && first.hasMore && first.count == 30)
        let next = try await client.searchAlbums("wide", limit: 24, offset: 24)
        #expect(next.items.count == 6 && !next.hasMore)
        let artists = try await client.searchArtists("wide", limit: 20, offset: 20)
        #expect(artists.items.count == 10 && !artists.hasMore)
        #expect(stub.requests.map { $0.url?.query ?? "" } == ["q=wide&scope=album&limit=24&offset=0",
                                                              "q=wide&scope=album&limit=24&offset=24",
                                                              "q=wide&scope=artist&limit=20&offset=20"])
    }

    /// Limits are clamped before they're sent (Aurral: discover 1–200, unified search ≤ 30).
    @Test func limitsAreClamped() async throws {
        _ = try await client.recommendations(limit: 5_000, offset: -3)
        _ = try await client.searchUnified("x", limit: 500)
        _ = try await client.searchAlbums("x", limit: 0, offset: -1)
        #expect(stub.requests.map { $0.url?.query ?? "" } == ["limit=200&offset=0", "q=x&mode=full&limit=30",
                                                              "q=x&scope=album&limit=1&offset=0"])
    }

    /// Empty search text and odd ids are refused before anything is sent.
    @Test func oddInputsAreRefusedUnsent() async throws {
        await #expect(throws: AurralError.self) { _ = try await client.searchUnified("   ") }
        await #expect(throws: AurralError.self) { _ = try await client.searchAlbums("") }
        await #expect(throws: AurralError.self) { _ = try await client.editorialPlaylist("../settings") }
        await #expect(throws: AurralError.self) { _ = try await client.editorialPlaylist("abc") }
        await #expect(throws: AurralError.self) { _ = try await client.trendingGenre(-1) }
        await #expect(throws: AurralError.self) { _ = try await client.trendingGenre(1_234_567) }
        await #expect(throws: AurralError.self) { _ = try await client.playlistJobs("a/b") }
        await #expect(throws: AurralError.self) { _ = try await client.editorialLinks(artist: " ", album: nil, deezerAlbumId: nil) }
        #expect(stub.requests.isEmpty)
    }

    /// A genre chart that isn't ready yet (404) reads as nil; Trending's sections can each be missing.
    @Test func genreNotReadyAndMissingSections() async throws {
        stub.setGenreChartReady(116, false)
        #expect(try await client.trendingGenre(116) == nil)
        stub.setTrendingMissing([.songs, .artists, .genres])
        stub.setTrendingRegion("US")
        let t = try await client.trending()
        #expect(t.songs == nil && t.artists == nil && t.genres.isEmpty && t.albums != nil && t.region == "US")
    }

    /// A slow or failing Aurral surfaces as an error the caller can fall back on; an Aurral without the routes (2.10)
    /// answers notFound.
    @Test func failuresSurface() async throws {
        stub.setDiscoverFailure(502)
        await #expect(throws: AurralError.http(status: 502)) { _ = try await client.trending() }
        stub.setDiscoverFailure(nil)
        stub.setDiscoverDelay(.milliseconds(50))
        let started = ContinuousClock.now
        _ = try await client.trending()
        #expect(ContinuousClock.now - started >= .milliseconds(50))
        let old = StubAurral()
        let oldClient = AurralClient(base: old.base, session: old.signedInSession(), transport: old)
        await #expect(throws: AurralError.notFound) { _ = try await oldClient.trending() }
    }

    @Test func playlistJobsById() async throws {
        stub.setFlows([.init(id: "flow-1", name: "Indie Pop Picks")])
        stub.setJobs([.init(flowId: "flow-1", artistName: "A", trackName: "B", status: "failed"),
                      .init(flowId: "flow-2", artistName: "C", trackName: "D")])
        let jobs = try #require(try await client.playlistJobs("flow-1"))
        #expect(jobs.map(\.trackName) == ["B"] && jobs.first?.status == "failed")
        #expect(stub.asked == ["GET /api/playlists/jobs/flow-1"])
    }
}
