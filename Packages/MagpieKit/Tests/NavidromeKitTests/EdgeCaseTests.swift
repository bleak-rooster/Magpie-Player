import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import NavidromeKit

// Task 8.1: what a real server (behind a real proxy) sends that the happy-path tests don't.

private func envelope(_ payload: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(payload.isEmpty ? "" : ",")\#(payload)}}"#.utf8)
}

private func failed(code: Int, message: String) -> Data {
    Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\#(code),"message":"\#(message)"}}}"#.utf8)
}

/// What an auth proxy (Authelia, Authentik, a captive portal) answers in place of the API: 200 and HTML.
let proxyLoginPage = Data("<!DOCTYPE html><html><head><title>Sign in</title></head><body><form>…</form></body></html>".utf8)

private func logins(_ t: MockTransport) -> Int {
    t.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count
}

@Suite struct NavidromeEdgeCaseTests {
    // MARK: Subsonic errors in a 200

    /// `status: "failed"` in an HTTP 200 is an API error, not a decode crash, and (unless it is an auth code)
    /// never triggers a re-login.
    @Test(arguments: [(70, "Album not found"), (50, "User not authorized"), (0, "Generic error"), (10, "Required parameter missing")])
    func subsonicFailedIsAnAPIError(code: Int, message: String) async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbum", body: failed(code: code, message: message))
        _ = try await client.connect()
        await #expect(throws: NavidromeError.api(code: code, message: message)) { try await client.album(id: "x") }
        #expect(logins(transport) == 1, "no re-login for a non-auth error")
    }

    /// Failed with no `error` object at all (seen from older forks): still an API error.
    @Test func subsonicFailedWithoutErrorObject() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getArtists", body: Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1"}}"#.utf8))
        await #expect(throws: NavidromeError.api(code: 0, message: "")) { try await client.artists() }
    }

    /// Lyrics "not found" (70) is not an error to the UI.
    @Test func lyricsNotFoundIsNil() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getLyricsBySongId", body: failed(code: 70, message: "not found"))
        #expect(try await client.lyrics(songId: "s1") == nil)
    }

    // MARK: Proxy HTML pages

    /// A proxy login page in place of JSON: a typed error, never a crash, and no login loop.
    @Test func htmlInPlaceOfSubsonicJSONIsUnexpectedResponse() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: proxyLoginPage, headers: ["Content-Type": "text/html"])
        _ = try await client.connect()
        await #expect(throws: NavidromeError.unexpectedResponse) { try await client.albumList(.newest, size: 5, offset: 0) }
        #expect(logins(transport) == 1)
    }

    @Test func htmlInPlaceOfLoginIsUnexpectedResponse() async throws {
        let transport = MockTransport()
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: proxyLoginPage)
        let (client, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.unexpectedResponse) { try await client.connect() }
    }

    @Test func htmlInPlaceOfSongPageIsUnexpectedResponse() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/api/song", body: proxyLoginPage)
        await #expect(throws: NavidromeError.unexpectedResponse) { try await client.songsPage(start: 0, end: 1000) }
    }

    // MARK: Token expiry storm

    /// Twenty requests in flight all hit an expired token (Subsonic code 44 in a 200): one shared re-login,
    /// every request retried once and answered.
    @Test func tokenExpiryStormLogsInOnce() async throws {
        let transport = MockTransport()
        let rejected = OSAllocatedUnfairLock(initialState: 0)
        let storm = 20
        transport.stub(pathSuffix: "/rest/getArtists") { _ in
            let n = rejected.withLock { v -> Int in v += 1; return v }
            return .init(status: 200, body: n <= storm ? failed(code: 44, message: "Invalid token") : Fixtures.data("getArtists"))
        }
        let gated = LoginGateTransport(inner: transport, rejected: rejected, waitFor: storm)
        _ = makeClient(transport: transport)
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [testBase]), credentials: testCredentials, transport: gated)
        _ = try await client.connect()
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<storm { group.addTask { try await client.artists().count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 6, count: storm))
        #expect(logins(transport) == 2, "initial connect + one shared re-login")
    }

    /// The password was changed on the server mid-session: the storm ends in `badCredentials` for everyone,
    /// with one shared re-login attempt (Navidrome rate-limits failed logins; a login per request would lock
    /// the owner out).
    @Test func passwordChangedMidSessionFailsCalmly() async throws {
        let transport = MockTransport()
        let rejected = OSAllocatedUnfairLock(initialState: 0)
        let storm = 10
        transport.stub(pathSuffix: "/rest/getArtists") { _ in
            rejected.withLock { $0 += 1 }
            return .init(status: 401)
        }
        transport.stub(pathSuffix: "/rest/ping", body: Fixtures.data("getOpenSubsonicExtensions"))
        let firstLogin = OSAllocatedUnfairLock(initialState: true)
        transport.stub(method: "POST", pathSuffix: "/auth/login") { _ in
            let first = firstLogin.withLock { v -> Bool in defer { v = false }; return v }
            return first ? .init(status: 200, body: Fixtures.data("login")) : .init(status: 401)
        }
        let gated = LoginGateTransport(inner: transport, rejected: rejected, waitFor: storm)
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [testBase]), credentials: testCredentials, transport: gated)
        _ = try await client.connect()
        let errors = await withTaskGroup(of: NavidromeError?.self) { group in
            for _ in 0..<storm {
                group.addTask {
                    do { _ = try await client.artists(); return nil } catch { return error as? NavidromeError }
                }
            }
            return await group.reduce(into: [NavidromeError?]()) { $0.append($1) }
        }
        #expect(errors == Array(repeating: .badCredentials, count: storm))
        #expect(logins(transport) == 2, "initial connect + one shared failed re-login, not one per request")
    }

    // MARK: Unicode

    /// Accents, CJK, emoji and URL-significant characters survive the query string both ways.
    @Test(arguments: ["Sigur Rós", "東京事変", "AC/DC & Friends + 1", "Beyoncé 🐝 #1", "100% = love; ok?", "Ünïcødé\u{301}"])
    func unicodeSearchRoundTrips(query: String) async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/search3", body: Fixtures.data("search3"))
        _ = try await client.search(query)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("/rest/search3") == true })
        #expect(queryValue(req, "query") == query)
        #expect(req.url?.path == "/navidrome/rest/search3")
    }

    @Test func unicodeIdsInStreamAndCoverURLs() async throws {
        let (client, _) = makeClient()
        _ = try await client.connect()
        let stream = client.streamURL(songId: "ñ/東?&=", maxBitRate: nil, format: nil)!
        #expect(URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value == "ñ/東?&=")
        #expect(stream.path == "/navidrome/rest/stream")
        let cover = client.coverArtURL(id: "al-ü", size: 300)!
        #expect(cover.path == "/navidrome/rest/getCoverArt")
    }

    @Test func unicodeTitlesDecode() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbum", body: envelope(#"""
        "album":{"id":"al1","name":"Ágætis byrjun","artist":"Sigur Rós","song":[
          {"id":"s1","title":"Svefn-g-englar","artist":"Sigur Rós","track":2},
          {"id":"s2","title":"東京 🌃 \u0000 null byte","artist":"東京事変","track":1}]}
        """#))
        let album = try await client.album(id: "al1")
        #expect(album.name == "Ágætis byrjun")
        #expect(album.songs?.map(\.id) == ["s2", "s1"])
        #expect(album.songs?.first?.title.hasPrefix("東京 🌃") == true)
    }

    // MARK: Empty and missing

    /// A brand-new server: Navidrome answers `{}` (or nothing) for every empty list.
    @Test func emptyLibraryFirstRun() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getArtists", body: envelope(#""artists":{"ignoredArticles":"The"}"#))
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: envelope(#""albumList2":{}"#))
        transport.stub(pathSuffix: "/rest/getPlaylists", body: envelope(#""playlists":{}"#))
        transport.stub(pathSuffix: "/rest/search3", body: envelope(#""searchResult3":{}"#))
        transport.stub(pathSuffix: "/rest/getTopSongs", body: envelope(""))
        transport.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        #expect(try await client.artists().isEmpty)
        #expect(try await client.albumList(.newest, size: 24, offset: 0).isEmpty)
        #expect(try await client.playlists().isEmpty)
        let found = try await client.search("anything")
        #expect(found.songs.isEmpty && found.albums.isEmpty && found.artists.isEmpty)
        #expect(try await client.topSongs(artistName: "Nobody").isEmpty)
        let page = try await client.songsPage(start: 0, end: 1000)
        #expect(page.songs.isEmpty && page.total == 0)
    }

    /// Names, covers and durations can all be missing: the row still maps (empty text, no art, no crash).
    @Test func missingNamesAndCoversMap() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: envelope(#"""
        "albumList2":{"album":[{"id":"al1"},{"id":"al2","name":"","artist":"","coverArt":""}]}
        """#))
        transport.stub(pathSuffix: "/rest/getArtists", body: envelope(##""artists":{"index":[{"name":"#","artist":[{"id":"ar1"},{"id":"ar2","name":""}]}]}"##))
        transport.stub(pathSuffix: "/api/song", body: Data(#"[{"id":"s1"},{"id":"s2","title":"","hasCoverArt":false}]"#.utf8),
                       headers: ["X-Total-Count": "2"])
        let albums = try await client.albumList(.newest, size: 24, offset: 0)
        #expect(albums.map(\.name) == ["", ""])
        #expect(albums[0].coverArtId == nil)
        #expect(albums.allSatisfy { $0.songCount == 0 && $0.duration == 0 })
        #expect(try await client.artists().map(\.name) == ["", ""])
        let page = try await client.songsPage(start: 0, end: 1000)
        #expect(page.songs.map(\.id) == ["s1", "s2"])
        #expect(page.songs.allSatisfy { $0.coverArtId == nil && $0.duration == 0 })
    }

    // MARK: Paging headers

    /// A proxy that drops `X-Total-Count`: a full page means "maybe more", so paging continues.
    @Test func missingTotalHeaderOnAFullPageMeansMaybeMore() async throws {
        let (client, transport) = makeClient()
        let rows = (0..<10).map { #"{"id":"s\#($0)"}"# }.joined(separator: ",")
        transport.stub(pathSuffix: "/api/song", body: Data("[\(rows)]".utf8))
        let full = try await client.songsPage(start: 0, end: 10)
        #expect(full.total > 10, "a full page without a total must not end paging")
        let short = try await client.songsPage(start: 20, end: 40)
        #expect(short.total == 30, "a short page is the end")
    }

    // MARK: Fix round 1: JSON of the wrong shape is not a proxy page

    /// Real JSON the client can't read (a field changed type in a newer Navidrome) is `unexpectedData`, not
    /// "something in front of your server".
    @Test func jsonOfTheWrongShapeIsUnexpectedData() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: envelope(#""albumList2":{"album":"not a list"}"#))
        transport.stub(pathSuffix: "/api/song", body: Data(#"  [{"title":"no id"}]"#.utf8), headers: ["X-Total-Count": "1"])
        await #expect(throws: NavidromeError.unexpectedData) { try await client.albumList(.newest, size: 5, offset: 0) }
        await #expect(throws: NavidromeError.unexpectedData) { try await client.songsPage(start: 0, end: 1000) }
    }

    @Test func nonJSONBodiesAreUnexpectedResponse() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getArtists", body: Data("\n  Bad Gateway".utf8))
        transport.stub(pathSuffix: "/rest/getPlaylists", body: Data())
        await #expect(throws: NavidromeError.unexpectedResponse) { try await client.artists() }
        await #expect(throws: NavidromeError.unexpectedResponse) { try await client.playlists() }
    }
}
