import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A4 (D91): the public Top Australia fallback; never a host but the two pinned ones, https only.
@Suite struct PublicChartsTests {
    @Test func topAustraliaFromDeezerWithPreviewsThroughAurral() async throws {
        let stub = StubPublicCharts()
        let songs = try await PublicChartsClient(transport: stub).topAustralia()
        #expect(songs.map(\.trackName) == ["Bluebottle", "Red Dirt"], "junk ids and songs without an artist are dropped")
        #expect(songs.map(\.position) == [1, 2])
        let first = try #require(songs.first)
        #expect(first.key == "4100001" && first.artistName == "Southern Cross Band" && first.durationMs == 201_000)
        // Deezer's signed preview is never kept: the preview is Aurral's path for the same Deezer id.
        #expect(first.preview?.path == "api/deezer/preview/4100001.mp3")
        #expect(first.artwork?.raw == "https://cdn-images.dzcdn.net/images/cover/a/250x250.jpg")
        #expect(songs[1].artwork == nil, "a picture off Deezer's image host is dropped")
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.deezer.com/playlist/1313616925/tracks?limit=100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies)
        #expect(request.httpMethod == "GET")
    }

    @Test func australianAlbumsFromApple() async throws {
        let stub = StubPublicCharts()
        let albums = try await PublicChartsClient(transport: stub).australianAlbums()
        #expect(albums.map(\.name) == ["Coastline", "Dust"])
        #expect(albums[0].artwork?.raw == "https://is1-ssl.mzstatic.com/image/thumb/a/500x500bb.jpg")
        #expect(albums[1].artwork == nil, "plain http art is dropped")
        #expect(albums[0].genre == "Alternative" && albums.map(\.position) == [1, 2])
        #expect(stub.requests.first?.url?.absoluteString
                == "https://rss.marketingtools.apple.com/api/v2/au/music/most-played/100/albums.json")
    }

    @Test(arguments: ["https://evil.example.com/playlist/1313616925/tracks", "http://api.deezer.com/playlist/1313616925/tracks",
                      "https://api.deezer.com.evil.example/playlist", "https://user@api.deezer.com/playlist/1313616925/tracks"])
    func anAnswerOffThePinIsRefused(_ from: String) async throws {
        let stub = StubPublicCharts()
        stub.setAnsweredFrom(from)
        await #expect(throws: PublicChartsClient.Failure.refused) { try await PublicChartsClient(transport: stub).topAustralia() }
    }

    @Test func failuresAndOversizedAnswersThrow() async throws {
        let stub = StubPublicCharts()
        stub.setStatus(503)
        await #expect(throws: PublicChartsClient.Failure.http(503)) { try await PublicChartsClient(transport: stub).australianAlbums() }
        stub.setStatus(200)
        stub.setOversized(true)
        await #expect(throws: PublicChartsClient.Failure.tooLarge) { try await PublicChartsClient(transport: stub).topAustralia() }
    }

    @Test func junkNeverCrashes() async throws {
        let fuzz = MockTransport()
        fuzz.stub(pathSuffix: "/tracks", body: Data(#"{"data":[1,"x",null,{"id":{"a":1}},{"id":1e400}]}"#.utf8))
        fuzz.stub(pathSuffix: "/albums.json", body: Data(#"[1,2,3]"#.utf8))
        // MockTransport answers with the asked URL: the pinned host.
        #expect((try? await PublicChartsClient(transport: fuzz).topAustralia())?.isEmpty ?? true)
        await #expect(throws: PublicChartsClient.Failure.decoding) { try await PublicChartsClient(transport: fuzz).australianAlbums() }
    }
}

/// Round 14 A4 (D92): the Recommended page's rails, as Aurral's own web page groups them (recommendedRails.ts).
@Suite struct RecommendedRailsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func artist(_ name: String, depth: Int = 1, seeds: [String] = [], daysAgo: Double = 30, tags: [String] = ["indie"])
        -> AurralRecommendedArtist {
        AurralRecommendedArtist(mbid: nil, name: name, tags: tags, sourceArtists: seeds, supportingSeeds: seeds,
                                discoveryDepth: depth, firstDiscoveredAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    var sample: AurralRecommendations {
        var artists = [artist("Top", seeds: ["Seed A"])]
        artists += (1...4).map { artist("A\($0)", seeds: ["Seed A"]) }
        artists += (1...3).map { artist("B\($0)", seeds: ["Seed B"]) }   // only 3 picks: no rail
        artists += [artist("New One", daysAgo: 2), artist("Far", depth: 2, seeds: ["Seed B"]), artist("Plain")]
        return AurralRecommendations(artists: artists, globalTop: [], basedOn: [.init(name: "Seed B"), .init(name: "Seed A")],
                                     topTags: [], topGenres: [], lastUpdated: nil, isEnriching: false, configured: true)
    }

    @Test func railsGroupLikeAurralsPage() {
        let rails = RecommendedRails(sample, now: now)
        #expect(rails.topPick?.name == "Top")
        #expect(rails.newThisWeek.map(\.name) == ["New One"])
        #expect(rails.becauseYouLike.map(\.seed) == ["Seed A"], "a seed needs at least four picks")
        #expect(rails.becauseYouLike.first?.artists.map(\.name) == ["A1", "A2", "A3", "A4"])
        #expect(rails.furtherOut.map(\.name) == ["Far"])
        #expect(rails.closeToHome.map(\.name) == ["B1", "B2", "B3", "Plain"], "what no rail above showed, depth 1")
        #expect(rails.all.count == 11)
    }

    @Test func atMostThreeSeedRows() {
        var artists = [artist("Top")]
        for seed in ["S1", "S2", "S3", "S4"] { artists += (1...4).map { artist("\(seed)-\($0)", seeds: [seed]) } }
        let recs = AurralRecommendations(artists: artists, globalTop: [], basedOn: [], topTags: [], topGenres: [],
                                         lastUpdated: nil, isEnriching: false, configured: true)
        #expect(RecommendedRails(recs, now: now).becauseYouLike.map(\.seed) == ["S1", "S2", "S3"])
        #expect(RecommendedRails(recs, now: now, seedRows: 1).becauseYouLike.count == 1)
    }

    @Test func hiddenArtistsLeaveEveryRail() {
        let rails = RecommendedRails(sample, now: now, hidden: ["name:top", "name:far"])
        #expect(rails.topPick?.name == "A1")
        #expect(rails.furtherOut.isEmpty && !rails.all.contains { $0.name == "Top" })
    }

    @Test func sortingAll() {
        let rails = RecommendedRails(sample, now: now)
        #expect(rails.sorted(.rank).first?.name == "Top")
        #expect(rails.sorted(.name).prefix(2).map(\.name) == ["A1", "A2"])
        #expect(rails.sorted(.firstSeen).first?.name == "New One")
    }

    @Test func subtitles() {
        #expect(RecommendedRails.subtitle(artist("x", seeds: ["Seed A", "Seed B", "Seed C"])) == "Like Seed A, Seed B")
        #expect(RecommendedRails.subtitle(artist("x", depth: 3, seeds: ["Seed A"])) == "Via Seed A")
        #expect(RecommendedRails.subtitle(artist("x", tags: ["dream pop"])) == "Dream pop")
        #expect(RecommendedRails.subtitle(artist("x", tags: [])) == nil)
        #expect(RecommendedRails.key(artist("Mixed Case")) == "name:mixed case")
    }
}
