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
            return .init(status: ok ? 200 : 502, body: ok ? pingOK : Data(), headers: [:])
        }
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: Fixtures.data("login"))
        let (client, _) = makeClient(bases: [dead, testBase], transport: transport)
        _ = try await client.connect()
        #expect(client.streamURL(songId: "x", maxBitRate: nil, format: nil)?.host == "music.example")
        let login = try #require(transport.requests.first { $0.url?.path.hasSuffix("/auth/login") == true })
        #expect(login.url?.host == "music.example")
    }

    /// QC (crash report #4): a base no URL can be built on gives no stream or cover URL (callers skip them) and a
    /// connect that fails, never a trap.
    @Test func unbuildableBaseGivesNoURLsAndNoTrap() async throws {
        let odd = try #require(URL(dataRepresentation: Data("://x:a".utf8), relativeTo: nil))
        let (client, transport) = makeClient(bases: [odd])
        #expect(client.streamURL(songId: "x", maxBitRate: nil, format: nil) == nil)
        #expect(client.coverArtURL(id: "al-1", size: 300) == nil)
        await #expect(throws: NavidromeError.self) { try await client.connect() }
        #expect(transport.requests.isEmpty)
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
        let rejected = OSAllocatedUnfairLock(initialState: 0)
        // The first five browse requests get 401, independent of login state.
        transport.stub(pathSuffix: "/rest/getAlbumList2") { _ in
            let n = rejected.withLock { v -> Int in v += 1; return v }
            return n <= 5
                ? .init(status: 401, body: Data(), headers: [:])
                : .init(status: 200, body: Fixtures.data("getAlbumList2"), headers: [:])
        }
        // Login is held back until all five 401s are recorded, so every request is in flight together.
        let gated = LoginGateTransport(inner: transport, rejected: rejected, waitFor: 5)
        _ = makeClient(transport: transport)   // stubs ping + login on the shared mock
        let gatedClient = NavidromeClient(endpoint: ServerEndpoint(bases: [testBase]),
                                          credentials: testCredentials, transport: gated)
        _ = try await gatedClient.connect()
        func logins() -> Int { transport.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count }
        #expect(logins() == 1)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await gatedClient.albumList(.newest, size: 50, offset: 0).count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 7, count: 5))
        #expect(rejected.withLock { $0 } >= 5)
        #expect(logins() == 2)   // initial connect + exactly one shared re-login
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

    // MARK: - Security H2: only a Subsonic ping answer gets the password

    @Test(arguments: [
        #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#,
        // Navidrome 0.64 answers a ping without `u` like this (dev stack, 2026-10-27).
        #"{"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2","openSubsonic":true,"error":{"code":10,"message":"missing parameter: 'u'"}}}"#,
        #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}"#,
    ])
    func subsonicPingAnswersAreServers(_ body: String) {
        #expect(SubsonicPing.isServerAnswer(Data(body.utf8)))
    }

    @Test(arguments: [
        "",
        "<html><body>Router login</body></html>",
        "OK",
        "{}",
        #"{"status":"ok"}"#,
        #"{"subsonic-response":{"status":"weird"}}"#,
        #"{"subsonic-response":{"status":"failed","error":{"code":10}}}"#,
        #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#,
        #"{"subsonic-response":{"status":"failed","version":"1.16.1"}}"#,
    ])
    func otherAnswersAreNotServers(_ body: String) {
        #expect(!SubsonicPing.isServerAnswer(Data(body.utf8)))
    }

    /// A captive portal or router answers 200 to every path: no login is sent to it.
    @Test func portalAnswering200NeverGetsThePassword() async {
        let transport = MockTransport()
        transport.stub(pathSuffix: "/rest/ping", body: Data("<html>Welcome to the hotel Wi-Fi</html>".utf8))
        transport.stub(method: "POST", pathSuffix: "/auth/login", body: Fixtures.data("login"))
        let (client, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.noReachableServer) { try await client.connect() }
        #expect(!transport.requests.contains { $0.httpMethod == "POST" }, "no password sent")
    }
}

private let pingOK = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
