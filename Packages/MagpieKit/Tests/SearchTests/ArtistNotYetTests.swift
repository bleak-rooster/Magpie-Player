import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Search

private func data(_ text: String) -> Data { Data(text.utf8) }
private let base = URL(string: "http://127.0.0.1:8686")!
private let corin = MBID("75ab6ba6-9197-4f83-8a23-a1925a7ec5a2")!
private let glasshouseRG = MBID("1f6c3c7e-2b0a-4c41-9a51-6e2d7f9b0a10")!

private let lookupInLidarr = data("""
[{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","id":7}]
""")
private let lookupNotInLidarr = data("""
[{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}]
""")
/// Lidarr's discography for artist 7: Glasshouse (in the library by release group), Saltwater Hymns (in the library by
/// title only, with a bracketed aside), Low Tide EP and Northern Rooms (not in the library).
private let albums = data("""
[{"id":1,"title":"Glasshouse","foreignAlbumId":"1f6c3c7e-2b0a-4c41-9a51-6e2d7f9b0a10","albumType":"Album","releaseDate":"2019-03-01T00:00:00Z"},
 {"id":2,"title":"Saltwater Hymns","foreignAlbumId":"2a7d4d8f-3c1b-4d52-8b62-7f3e8a0c1b21","albumType":"Album","releaseDate":"2016-05-01T00:00:00Z"},
 {"id":3,"title":"Low Tide","foreignAlbumId":"3b8e5e90-4d2c-4e63-9c73-804f9b1d2c32","albumType":"EP","releaseDate":"2021-01-01T00:00:00Z"},
 {"id":4,"title":"Northern Rooms","foreignAlbumId":"4c9f6fa1-5e3d-4f74-8d84-915a0c2e3d43","albumType":"Album","releaseDate":"2023-09-01T00:00:00Z"},
 {"id":5,"title":"","foreignAlbumId":"5da07fb2-6f4e-4085-9e95-a26b1d3f4e54"}]
""")
private let search = data("""
[{"foreignId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","artist":{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}},
 {"foreignId":"4c9f6fa1-5e3d-4f74-8d84-915a0c2e3d43","album":{"title":"Northern Rooms","albumType":"Album","releaseDate":"2023-09-01T00:00:00Z",
   "artist":{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}}},
 {"foreignId":"1f6c3c7e-2b0a-4c41-9a51-6e2d7f9b0a10","album":{"title":"Glasshouse","albumType":"Album",
   "artist":{"artistName":"Corin Hale","foreignArtistId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"}}},
 {"foreignId":"6eb18fc3-7a5f-4196-8fa6-b37c2e4a5f65","album":{"title":"Someone Else's Record","albumType":"Album",
   "artist":{"artistName":"Corin Hale Tribute Band","foreignArtistId":"8f0d2a1e-9b3c-4d5e-8f6a-7b8c9d0e1f23"}}}]
""")

private let library = [
    Album(id: "al-1", name: "Glasshouse (Deluxe)", artist: "Corin Hale", songCount: 10, duration: 2400,
          releaseGroupMBID: glasshouseRG),
    Album(id: "al-2", name: "Saltwater Hymns [Remastered]", artist: "Corin Hale", songCount: 9, duration: 2100),
]

@Suite struct ArtistNotYetTests {
    @Test func knownArtistInLidarrListsItsAlbumsMinusTheLibrarys() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/v1/artist/lookup", body: lookupInLidarr)
        t.stub(pathSuffix: "/api/v1/album", body: albums)
        let found = await ArtistNotYet.albums(artist: "Corin Hale", mbid: corin, library: library,
                                              lidarr: LidarrClient(base: base, apiKey: "k", transport: t))
        #expect(found.map(\.title) == ["Northern Rooms", "Low Tide"])   // newest first
        #expect(found.map(\.kind) == ["Album", "EP"])
        #expect(found.map(\.year) == [2023, 2021])
        #expect(found.allSatisfy { $0.artist == "Corin Hale" && $0.artistMBID == corin })
        let lookup = try #require(t.requests.first)
        #expect(URLComponents(url: lookup.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(URLQueryItem(name: "term", value: "lidarr:" + corin.rawValue)) == true)   // A10
        let albumsRequest = try #require(t.requests.first { $0.url?.path.hasSuffix("/api/v1/album") == true })
        #expect(albumsRequest.url?.query?.contains("artistId=7") == true)
        #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })   // read-only
        #expect(!t.requests.contains { $0.url?.path.hasSuffix("/api/v1/search") == true })
    }

    @Test func knownArtistNotInLidarrFallsBackToSearchRowsByThatArtist() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/v1/artist/lookup", body: lookupNotInLidarr)
        t.stub(pathSuffix: "/api/v1/search", body: search)
        let found = await ArtistNotYet.albums(artist: "Corin Hale", mbid: corin, library: library,
                                              lidarr: LidarrClient(base: base, apiKey: "k", transport: t))
        #expect(found.map(\.title) == ["Northern Rooms"])   // not Glasshouse (library), not the tribute band
        #expect(t.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func noMBIDMatchesSearchRowsByNormalisedName() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/v1/search", body: search)
        let found = await ArtistNotYet.albums(artist: "córin  HALE", mbid: nil, library: library,
                                              lidarr: LidarrClient(base: base, apiKey: "k", transport: t))
        #expect(found.map(\.title) == ["Northern Rooms"])
        #expect(!t.requests.contains { $0.url?.path.hasSuffix("/artist/lookup") == true })
    }

    @Test func failuresAndTimeoutsShowNothing() async throws {
        let t = MockTransport()
        t.stub(pathSuffix: "/api/v1/artist/lookup", status: 500)
        #expect(await ArtistNotYet.albums(artist: "Corin Hale", mbid: corin, library: library,
                                          lidarr: LidarrClient(base: base, apiKey: "k", transport: t)).isEmpty)
        let clock = TestClock()
        let started = ContinuousClock.now
        async let found = ArtistNotYet.albums(artist: "Corin Hale", mbid: nil, library: [],
                                              lidarr: LidarrClient(base: base, apiKey: "k", transport: HangingTransport()),
                                              sleep: { try await clock.sleep($0) })
        await clock.until(waiting: 1)
        clock.advance(by: ArtistNotYet.timeout)
        #expect(await found.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func dashSuffixEditionsAreTheSameAlbumButVersionsStayDistinct() {
        func album(_ title: String) -> NotYetAlbum { NotYetAlbum(title: title, artist: "Corin Hale") }
        let owned = [Album(id: "a", name: "Glasshouse", artist: "Corin Hale", songCount: 1, duration: 60),
                     Album(id: "b", name: "Saltwater Hymns - Deluxe Edition", artist: "Corin Hale", songCount: 1, duration: 60)]
        let candidates = ["Glasshouse - Deluxe Edition", "Glasshouse \u{2013} Remastered 2011", "Glasshouse - 10th Anniversary Edition",
                          "Glasshouse \u{2014} Expanded", "Glasshouse - Special Edition", "Saltwater Hymns",
                          "Glasshouse - Live", "Glasshouse - Acoustic Sessions", "Glasshouse - Demo Edition",
                          "Glasshouse (Remix)", "Glasshouse - Remixes"].map(album)
        let kept = ArtistNotYet.excluding(candidates, library: owned).map(\.title)
        #expect(kept == ["Glasshouse - Live", "Glasshouse - Acoustic Sessions", "Glasshouse - Demo Edition",
                         "Glasshouse (Remix)", "Glasshouse - Remixes"])
    }

    @Test func excludingDedupesAndCaps() {
        let rows = (0..<40).map { (i: Int) in NotYetAlbum(title: "Record \(i)", artist: "A", year: i) }
            + [NotYetAlbum(title: "Record 3", artist: "A", year: 3)]
        let kept = ArtistNotYet.excluding(rows, library: [Album(id: "x", name: "record 39", artist: "A", songCount: 1, duration: 60)])
        #expect(kept.count == ArtistNotYet.limit)
        #expect(kept.first?.title == "Record 38")
        #expect(Set(kept.map(\.title)).count == kept.count)
    }
}

/// Never answers (cancellation-aware).
struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
    }
}
