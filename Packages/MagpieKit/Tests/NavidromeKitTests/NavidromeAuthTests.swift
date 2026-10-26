import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
import os
@testable import NavidromeKit

@Suite struct NavidromeAuthTests {
    @Test func loginParsesAdmin() async throws {
        let (client, transport) = makeClient()
        let result = try await client.connect()
        #expect(result.isAdmin)
        #expect(result.userId == "0BTOCyRT5FKL0nlJp7uUh7")
        #expect(result.username == "admin")
        #expect(result.subsonicSalt == "fakesalt")
        #expect(result.jwt.hasPrefix("eyJfake"))
        let login = try #require(transport.requests.first { $0.url?.path.hasSuffix("/auth/login") == true })
        #expect(login.httpMethod == "POST")
        #expect(login.url?.path == "/navidrome/auth/login")
        let body = try #require(login.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["username": "admin", "password": "hunter2-not-real"])
    }

    @Test func connectPicksFirstReachableBase() async throws {
        let dead = URL(string: "https://lan.example/navidrome")!
        let transport = MockTransport()
        transport.stub(pathSuffix: "/rest/ping") { req in
            let ok = req.url?.host == "music.example"
            return .init(status: ok ? 200 : 502, body: Data(), headers: [:])
        }
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: Fixtures.data("login"))
        let (client, _) = makeClient(bases: [dead, testBase], transport: transport)
        _ = try await client.connect()
        #expect(client.streamURL(songId: "x", maxBitRate: nil, format: nil).host == "music.example")
        let login = try #require(transport.requests.first { $0.url?.path.hasSuffix("/auth/login") == true })
        #expect(login.url?.host == "music.example")
    }

    @Test func connectThrowsWhenNothingReachable() async {
        let transport = MockTransport()
        transport.stub(pathSuffix: "/rest/ping", status: 502)
        let (client, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.self) { try await client.connect() }
    }

    @Test func badCredentialsSurface() async {
        let transport = MockTransport()
        transport.stub(method: "POST", pathSuffix: "/auth/login", status: 401,
                       body: Data(#"{"error":"Invalid username or password"}"#.utf8))
        let (client, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.badCredentials) { try await client.connect() }
    }

    @Test func subsonicQueryHasNoPassword() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: Fixtures.data("getAlbumList2"))
        _ = try await client.connect()
        _ = try await client.albumList(.newest, size: 5, offset: 0)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("getAlbumList2") == true })
        let names = Set(queryItems(req).map(\.name))
        #expect(!names.contains("p"))
        #expect(queryValue(req, "u") == "admin")
        #expect(queryValue(req, "t") == "00000000000000000000000000000000")
        #expect(queryValue(req, "s") == "fakesalt")
        #expect(queryValue(req, "v") == "1.16.1")
        #expect(queryValue(req, "c") == "Magpie")
        #expect(queryValue(req, "f") == "json")
        #expect(req.url?.absoluteString.contains("hunter2") == false)
        #expect(queryValue(req, "type") == "newest")
        #expect(req.url?.path == "/navidrome/rest/getAlbumList2")
    }

    @Test func md5FallbackWhenLoginHasNoSubsonicToken() async throws {
        let transport = MockTransport()
        let loginBody = Data(#"{"id":"1","isAdmin":false,"name":"Admin","token":"jwt","username":"admin"}"#.utf8)
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: loginBody)
        let (client, _) = makeClient(transport: transport)
        transport.stub(pathSuffix: "/rest/getAlbumList2", body: Fixtures.data("getAlbumList2"))
        _ = try await client.connect()
        _ = try await client.albumList(.recent, size: 1, offset: 0)
        let req = try #require(transport.requests.last { $0.url?.path.hasSuffix("getAlbumList2") == true })
        let salt = try #require(queryValue(req, "s"))
        let token = try #require(queryValue(req, "t"))
        #expect(salt.count == 12)
        #expect(token == SubsonicAuth.md5Hex("hunter2-not-real" + salt))
        #expect(queryValue(req, "p") == nil)
    }

    @Test func concurrent401sLoginOnce() async throws {
        let transport = MockTransport()
        let expired = OSAllocatedUnfairLock(initialState: true)
        transport.stub(method: "POST", pathSuffix: "/auth/login") { _ in
            expired.withLock { $0 = false }
            return .init(status: 200, body: Fixtures.data("login"), headers: [:])
        }
        transport.stub(pathSuffix: "/rest/getAlbumList2") { _ in
            expired.withLock { $0 }
                ? .init(status: 401, body: Data(), headers: [:])
                : .init(status: 200, body: Fixtures.data("getAlbumList2"), headers: [:])
        }
        let (client, _) = makeClient(transport: transport)
        _ = try await client.connect()
        let loginsBefore = transport.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count
        #expect(loginsBefore == 1)
        expired.withLock { $0 = true }
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await client.albumList(.newest, size: 50, offset: 0).count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 7, count: 5))
        let loginsAfter = transport.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count
        #expect(loginsAfter - loginsBefore == 1)
    }

    @Test func subsonicError40TriggersReloginThenRetry() async throws {
        let (client, transport) = makeClient()
        let failed = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#.utf8)
        let first = OSAllocatedUnfairLock(initialState: true)
        transport.stub(pathSuffix: "/rest/getArtists") { _ in
            let wasFirst = first.withLock { v -> Bool in defer { v = false }; return v }
            return .init(status: 200, body: wasFirst ? failed : Fixtures.data("getArtists"), headers: [:])
        }
        let artists = try await client.artists()
        #expect(artists.count == 6)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count == 2)
    }

    @Test func secondFailureAfterReloginIsThrown() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getArtists", status: 401)
        await #expect(throws: NavidromeError.self) { try await client.artists() }
        // one initial connect + exactly one re-login, no loop
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count == 2)
    }

    @Test func jwtRefreshedFromHeader() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/api/song", body: Fixtures.data("apiSongPage"),
                       headers: ["X-Nd-Authorization": "refreshed.jwt.value", "X-Total-Count": "42"])
        _ = try await client.connect()
        _ = try await client.songsPage(start: 0, end: 8)
        _ = try await client.songsPage(start: 8, end: 16)
        let songRequests = transport.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }
        #expect(songRequests[0].value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer eyJfake.eyJfake.fake-signature")
        #expect(songRequests[1].value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer refreshed.jwt.value")
    }
}
