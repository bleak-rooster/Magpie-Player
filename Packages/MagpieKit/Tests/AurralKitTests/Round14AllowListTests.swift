import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1 (D81): the exact set of Aurral calls Magpie may send. Each new 2.13 route is its own case; everything
/// else (Aurral's admin, settings, add, delete and download routes) is refused in code before a request is built.
@Suite struct Round14AllowListTests {
    static let mbid = "0383dadf-2a4e-4d10-a46a-e9e041da8eb3"

    static let allowed: [(String, String, AurralRoute)] = [
        ("GET", "api/health", .health),
        ("GET", "api/playlists/status", .playlistsStatus),
        ("GET", "api/playlists/jobs", .playlistsJobs),
        ("GET", "api/library/lookup/\(mbid)", .libraryLookup),
        ("POST", "api/playlists/start/flow-1", .startFlow),
        ("POST", "api/auth/login", .login),
        ("POST", "api/auth/logout", .logout),
        ("GET", "api/health/bootstrap", .bootstrap),
        ("GET", "api/auth/me", .authMe),
        ("GET", "api/discover", .recommendations),
        ("GET", "api/discover/trending", .trending),
        ("GET", "api/discover/trending/genres/132", .trendingGenre),
        ("GET", "api/discover/editorial", .editorialShelf),
        ("GET", "api/discover/editorial/links", .editorialLinks),
        ("GET", "api/discover/editorial/1313616925", .editorialPlaylist),
        ("POST", "api/discover/editorial/1313616925/library", .editorialAdd),
        ("POST", "api/discover/feedback", .discoverFeedback),
        ("GET", "api/artists/\(mbid)/preview", .artistPreview),
        ("GET", "api/artists/release-group/\(mbid)/tracks", .releaseGroupTracks),
        ("GET", "api/search", .search),
        ("GET", "api/search/unified", .searchUnified),
        ("GET", "api/playlists/jobs/flow-1", .playlistJobsById),
        ("POST", "api/playlists/flows/flow-1/download", .flowDownload),
        ("POST", "api/playlists/shared-playlists/pl-1/tracks/job-1/research", .trackResearch),
        ("GET", "api/deezer/preview/3135556.mp3", .deezerPreview),
        // Round 14 A7 (D111): Aurral's image proxy.
        ("POST", "api/image-proxy", .imageProxy),
        ("GET", "api/image-proxy/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg", .imageProxyFile),
    ]

    @Test func theExactAllowedCalls() {
        for (method, path, route) in Self.allowed {
            #expect(AurralRoute.route(method: method, path: path) == route, "\(method) \(path)")
        }
        #expect(AurralRoute.allCases.count == Self.allowed.count)
        #expect(Set(Self.allowed.map(\.2)) == Set(AurralRoute.allCases), "each route its own case")
    }

    /// Who carries the session token: never the preview or the image proxy's pictures (open on Aurral), the version
    /// check or the login.
    @Test func onlyThePublicCallsGoWithoutTheToken() {
        let open = AurralRoute.allCases.filter { !$0.isAuthorised }
        #expect(Set(open) == [.health, .login, .deezerPreview, .imageProxyFile])
    }

    /// The writes are exactly the eight POSTs (A7: the image proxy's cache step is the eighth).
    @Test func theWritesAreExactlyEight() {
        let writes = AurralRoute.allCases.filter { $0.method != "GET" }
        #expect(Set(writes) == [.startFlow, .login, .logout, .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch,
                                .imageProxy])
    }

    @Test func bannedAndTwistedCallsAreRefused() async throws {
        let refused: [(String, String)] = [
            // Aurral's admin and taste-changing Discover routes.
            ("POST", "api/discover/refresh"), ("POST", "api/discover/clear"), ("POST", "api/discover/clear-discovery"),
            ("GET", "api/discover/blocked-tags"), ("POST", "api/discover/blocked-tags"), ("DELETE", "api/discover/blocked-tags"),
            ("GET", "api/discover/feedback"), ("DELETE", "api/discover/feedback/1"), ("POST", "api/discover/feedback/reset"),
            ("POST", "api/discover/feedback/restore"), ("POST", "api/discover/preferences"), ("GET", "api/discover/preferences"),
            ("PUT", "api/discover/spotify-import"), ("GET", "api/discover/status"), ("GET", "api/discover/tags"),
            // Adds and downloads Magpie leaves to Lidarr (D: downloads go through Lidarr).
            ("POST", "api/library/artists"), ("POST", "api/library/albums"), ("POST", "api/library/albums/request"),
            ("POST", "api/library/downloads/track"), ("POST", "api/library/downloads/album"), ("GET", "api/library/downloads"),
            ("POST", "api/playlists/shared-playlists"), ("POST", "api/playlists/shared-playlists/pl-1/tracks"),
            ("POST", "api/playlists/shared-playlists/pl-1/sync"), ("DELETE", "api/playlists/shared-playlists/pl-1"),
            ("POST", "api/playlists/flows"), ("PUT", "api/playlists/flows/flow-1"), ("DELETE", "api/playlists/flows/flow-1"),
            ("POST", "api/playlists/flows/flow-1/tracks/job-1/research"),   // 2.13: synced playlists use shared-playlists
            ("GET", "api/playlists/flows/flow-1/lidarr-import-list"), ("POST", "api/playlists/jobs/job-1/retry"),
            ("GET", "api/playlists/jobs/job-1/files"), ("DELETE", "api/playlists/jobs/all"),
            ("GET", "api/settings"), ("GET", "api/users"), ("GET", "api/auth/api-key"), ("POST", "api/auth/reauth"),
            ("GET", "api/search/library"), ("GET", "api/search/link"), ("GET", "api/artists/\(Self.mbid)/similar"),
            // The allowed ones with the wrong verb.
            ("POST", "api/discover"), ("DELETE", "api/discover/trending"), ("POST", "api/discover/editorial/1"),
            ("GET", "api/discover/editorial/1/library"), ("GET", "api/discover/feedback"), ("POST", "api/search"),
            ("GET", "api/playlists/flows/flow-1/download"), ("GET", "api/playlists/shared-playlists/p/tracks/j/research"),
            ("POST", "api/deezer/preview/1.mp3"), ("POST", "api/auth/me"), ("POST", "api/health/bootstrap"),
            // Twisted ids.
            ("GET", "api/discover/trending/genres/1234567"), ("GET", "api/discover/trending/genres/pop"),
            ("GET", "api/discover/trending/genres/-1"), ("GET", "api/discover/trending/genres/1/x"),
            ("GET", "api/discover/editorial/abc"), ("GET", "api/discover/editorial/123456789012345678901"),
            ("POST", "api/discover/editorial/links/library"), ("POST", "api/discover/editorial/1/library/x"),
            ("POST", "api/discover/editorial/../settings/library"),
            ("GET", "api/artists/not-an-mbid/preview"), ("GET", "api/artists/\(Self.mbid)/preview/x"),
            ("GET", "api/artists/release-group/x/tracks"), ("GET", "api/artists/release-group/\(Self.mbid)"),
            ("GET", "api/search/unified/x"), ("GET", "api/search?q=x"),
            ("GET", "api/playlists/jobs/a%2Fb"), ("GET", "api/playlists/jobs/../settings"),
            ("POST", "api/playlists/flows/../download"), ("POST", "api/playlists/flows/a b/download"),
            ("POST", "api/playlists/shared-playlists/p/tracks/../research"),
            ("POST", "api/playlists/shared-playlists/p/tracks/j/research/x"),
            ("GET", "api/deezer/preview/1.mp3x"), ("GET", "api/deezer/preview/abc.mp3"), ("GET", "api/deezer/preview/.mp3"),
            ("GET", "api/deezer/preview/123456789012345678901.mp3"), ("GET", "api/deezer/preview/1.MP3"),
            ("GET", "api/deezer/preview/1"), ("GET", "api/deezer/preview/1.mp3/x"),
            ("GET", "api/image-proxy"), ("POST", "api/image-proxy/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), ("GET", "api/image-proxy/abc.jpg"),
            ("GET", "api/image-proxy/../settings"), ("DELETE", "api/image-proxy/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            ("GET", "api//discover"), ("GET", "/api/discover"), ("GET", "API/DISCOVER"), ("GET", "api/discover/"),
        ]
        let stub = StubAurral()
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        for (method, path) in refused {
            #expect(!AurralRoute.isAllowed(method: method, path: path), "\(method) \(path)")
            await #expect(throws: AurralError.forbidden("\(method) \(path)"), "\(method) \(path)") {
                _ = try await client.send(method: method, path: path)
            }
        }
        #expect(stub.requests.isEmpty, "nothing was sent")
    }

    /// Query names are allow-listed per route too: a route never carries a parameter Magpie didn't mean to send.
    @Test func queryNamesAreAllowListedPerRoute() async throws {
        #expect(AurralRoute.recommendations.queryNames == ["limit", "offset"])
        #expect(AurralRoute.search.queryNames == ["q", "scope", "limit", "offset"])
        #expect(AurralRoute.searchUnified.queryNames == ["q", "mode", "limit"])
        #expect(AurralRoute.editorialLinks.queryNames == ["artist", "album", "albumId"])
        #expect(AurralRoute.artistPreview.queryNames == ["artistName"])
        #expect(AurralRoute.releaseGroupTracks.queryNames == ["artistMbid", "artistName", "albumTitle", "deezerAlbumId"])
        #expect(AurralRoute.deezerPreview.queryNames == ["download"])   // A7 (D110)
        for route in AurralRoute.allCases where ![.recommendations, .search, .searchUnified, .editorialLinks, .artistPreview,
                                                  .releaseGroupTracks, .deezerPreview].contains(route) {
            #expect(route.queryNames.isEmpty, "\(route)")
        }
        let stub = StubAurral()
        let client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
        await #expect(throws: AurralError.self) {
            _ = try await client.send(method: "GET", path: "api/discover", query: [URLQueryItem(name: "refresh", value: "1")])
        }
        await #expect(throws: AurralError.self) {
            _ = try await client.send(method: "GET", path: "api/discover/trending", query: [URLQueryItem(name: "limit", value: "1")])
        }
        #expect(stub.requests.isEmpty)
    }
}
