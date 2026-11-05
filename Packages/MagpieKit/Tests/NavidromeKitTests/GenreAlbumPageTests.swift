import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import NavidromeKit

/// Round 15 C4 (D141): a genre page's albums through Navidrome's native `/api/album`, sorted and filtered by the server,
/// a page at a time. Row shapes as the dev Navidrome 0.64.2 sends them.
@Suite struct GenreAlbumPageTests {
    private static let row = #"""
    {"id":"3NSQ","name":"Continuum","albumArtistId":"ar1","albumArtist":"Aurora Field","maxYear":2019,"minYear":2019,
     "songCount":6,"duration":82.5,"playCount":7,"starred":true,"imageHash":"6721505be4359208","compilation":false,
     "mbzReleaseGroupId":"75ab6ba6-9197-4f83-8a23-a1925a7ec5a2","createdAt":"2026-10-26T15:00:08.399563353Z",
     "genres":[{"id":"g-amb","name":"Ambient"}],"missing":false}
    """#
    private static let missingRow = #"{"id":"gone","name":"Gone","albumArtist":"X","maxYear":0,"songCount":1,"missing":true}"#
    private static let compilation = #"""
    {"id":"va1","name":"Late Night Finds","albumArtist":"Various","maxYear":0,"songCount":3,"compilation":true}
    """#

    private func connected(_ stubs: (MockTransport) -> Void) async throws -> (NavidromeClient, MockTransport) {
        let (client, transport) = makeClient()
        stubs(transport)
        _ = try await client.connect()
        return (client, transport)
    }

    private func values(_ request: URLRequest, _ name: String) -> [String] {
        queryItems(request).filter { $0.name == name }.compactMap(\.value)
    }

    @Test func eachSortAsksTheServersOwnOrder() async throws {
        let (client, t) = try await connected {
            $0.stub(pathSuffix: "/api/album", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        }
        let expected: [GenreAlbumSort: (String, String?)] = [
            .name: ("name", "ASC"), .artist: ("artist", "ASC"), .newest: ("max_year", "DESC"), .oldest: ("max_year", "ASC"),
            .recentlyAdded: ("recently_added", "DESC"), .mostPlayed: ("play_count", "DESC"), .random: ("random", nil),
        ]
        for sort in GenreAlbumSort.allCases {
            let query = GenreAlbumQuery(genres: ["Ambient"], sort: sort, seed: 42)
            _ = try await client.albumsPage(query, genreIds: ["g-amb"], start: 100, end: 200)
            let r = try #require(t.requests.last)
            #expect(r.url?.path.hasSuffix("/api/album") == true)
            #expect(queryValue(r, "_sort") == expected[sort]?.0, "\(sort)")
            #expect(queryValue(r, "_order") == expected[sort]?.1, "\(sort)")
            #expect(queryValue(r, "_start") == "100" && queryValue(r, "_end") == "200")
            #expect(queryValue(r, "missing") == "false", "albums whose files are gone aren't counted")
            #expect(queryValue(r, "seed") == (sort == .random ? "42" : nil), "a seed only for Random")
            #expect(r.value(forHTTPHeaderField: "X-ND-Authorization") != nil)
        }
    }

    @Test func filtersGoToTheServer() async throws {
        let (client, t) = try await connected {
            $0.stub(pathSuffix: "/api/album", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        }
        let query = GenreAlbumQuery(genres: ["Rock", "Indie Rock"], sort: .name, text: "atlas", favouritesOnly: true)
        _ = try await client.albumsPage(query, genreIds: ["g-rock", "g-indie"], start: 0, end: 100)
        let r = try #require(t.requests.last)
        #expect(values(r, "genre_id") == ["g-rock", "g-indie"], "any of the genres")
        #expect(queryValue(r, "name") == "atlas", "album or artist (Navidrome's full-text filter)")
        #expect(queryValue(r, "starred") == "true")

        _ = try await client.albumsPage(GenreAlbumQuery(genres: ["Rock"], sort: .name), genreIds: ["g-rock"], start: 0, end: 100)
        let plain = try #require(t.requests.last)
        #expect(queryValue(plain, "name") == nil && queryValue(plain, "starred") == nil)
    }

    @Test func aPageMapsRowsAndCountsTheWholeList() async throws {
        let body = Data("[\(Self.row),\(Self.missingRow),\(Self.compilation)]".utf8)
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/album", body: body, headers: ["X-Total-Count": "6383"])
        }
        let page = try await client.albumsPage(GenreAlbumQuery(genres: ["Ambient"], sort: .name), genreIds: ["g-amb"],
                                               start: 0, end: 100)
        #expect(page.total == 6383)
        #expect(page.albums.map(\.id) == ["3NSQ", "va1"], "a missing album is left out")
        let a = try #require(page.albums.first)
        #expect(a.name == "Continuum" && a.artist == "Aurora Field" && a.artistId == "ar1" && a.year == 2019)
        #expect(a.songCount == 6 && a.duration == 82.5 && a.playCount == 7 && a.starred)
        #expect(a.coverArtId == "al-3NSQ_6721505be4359208", "the same cover id getAlbumList2 gives")
        #expect(a.releaseGroupMBID == MBID("75ab6ba6-9197-4f83-8a23-a1925a7ec5a2"))
        #expect(a.created != nil)
        let va = page.albums[1]
        #expect(va.artist == "Various Artists" && va.year == nil && va.coverArtId == "al-va1")
    }

    @Test func withoutTheCountHeaderAFullPageMeansMore() async throws {
        let rows = (0..<3).map { #"{"id":"a\#($0)","name":"A\#($0)","albumArtist":"X","songCount":1}"# }
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/album", body: Data("[\(rows.joined(separator: ","))]".utf8))
        }
        let full = try await client.albumsPage(GenreAlbumQuery(genres: ["G"], sort: .name), genreIds: ["g"], start: 0, end: 3)
        #expect(full.total == 4, "maybe more")
        let short = try await client.albumsPage(GenreAlbumQuery(genres: ["G"], sort: .name), genreIds: ["g"], start: 0, end: 10)
        #expect(short.total == 3)
    }

    @Test func genreIdsByName() async throws {
        let (client, t) = try await connected {
            $0.stub(pathSuffix: "/api/genre", body: Data(#"[{"id":"g1","name":"Rock"},{"id":"g2","name":"Indie Rock"},{"id":"g3"}]"#.utf8),
                    headers: ["X-Total-Count": "3"])
        }
        #expect(try await client.genreIds() == ["Rock": "g1", "Indie Rock": "g2"])
        let r = try #require(t.requests.last)
        #expect(queryValue(r, "_start") == "0" && queryValue(r, "_end") == "5000")
    }

    @Test func aServerWithoutTheNativeListThrows() async throws {
        let (client, _) = try await connected {
            $0.stub(pathSuffix: "/api/album", status: 404, body: Data())
        }
        await #expect(throws: NavidromeError.http(status: 404)) {
            try await client.albumsPage(GenreAlbumQuery(genres: ["G"], sort: .name), genreIds: ["g"], start: 0, end: 100)
        }
    }
}
