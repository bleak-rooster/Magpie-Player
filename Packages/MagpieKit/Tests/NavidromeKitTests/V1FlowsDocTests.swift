import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Testing
@testable import NavidromeKit

/// Verify V1: docs/FLOWS.md §3a (probe, login, re-login) and §4 (what Navidrome receives), checked through
/// the client's public API against a MockTransport.
@Suite struct V1FlowsDocTests {
    private let failed = { (code: Int) in
        Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\#(code),"message":"x"}}}"#.utf8)
    }

    private func logins(_ t: MockTransport) -> Int {
        t.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count
    }

    /// §3a Probe: `GET /rest/ping?v=1.16.1&c=Magpie&f=json`, no credentials of any kind.
    @Test func pingCarriesNoCredentials() async throws {
        let (client, transport) = makeClient()
        _ = try await client.connect()
        let ping = try #require(transport.requests.first { $0.url?.path.hasSuffix("/rest/ping") == true })
        #expect((ping.httpMethod ?? "GET") == "GET")
        #expect(ping.httpBody == nil)
        #expect(ping.value(forHTTPHeaderField: "X-ND-Authorization") == nil)
        #expect(ping.value(forHTTPHeaderField: "Authorization") == nil)
        let items = queryItems(ping)
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                == ["v": "1.16.1", "c": "Magpie", "f": "json"])
        // The ping precedes the login: the password only goes out after a Subsonic answer.
        let firstPing = try #require(transport.requests.firstIndex { $0.url?.path.hasSuffix("/rest/ping") == true })
        let firstLogin = try #require(transport.requests.firstIndex { $0.url?.path.hasSuffix("/auth/login") == true })
        #expect(firstPing < firstLogin)
    }

    /// §3a Re-login: Subsonic error 44 (like 40) triggers one re-login and one retry.
    @Test func subsonicError44TriggersReloginThenRetry() async throws {
        let (client, transport) = makeClient()
        let first = OSAllocatedUnfairLock(initialState: true)
        let expired = failed(44)
        transport.stub(pathSuffix: "/rest/getArtists") { _ in
            let wasFirst = first.withLock { v -> Bool in defer { v = false }; return v }
            return .init(status: 200, body: wasFirst ? expired : Fixtures.data("getArtists"), headers: [:])
        }
        let artists = try await client.artists()
        #expect(artists.count == 6)
        #expect(logins(transport) == 2, "initial login + one re-login")
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/rest/getArtists") == true }.count == 2)
    }

    /// §3a Re-login is only for 401 / 40 / 44: another Subsonic error (41, token auth unsupported) is
    /// surfaced without logging in again.
    @Test func otherSubsonicErrorsDoNotRelogin() async throws {
        let (client, transport) = makeClient()
        transport.stub(pathSuffix: "/rest/getArtists", body: failed(41))
        await #expect(throws: NavidromeError.api(code: 41, message: "x")) { try await client.artists() }
        #expect(logins(transport) == 1)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/rest/getArtists") == true }.count == 1)
    }

    /// §3a Re-login on the native API: a 401 from `/api/*` triggers one re-login and one retry with the new JWT.
    @Test func native401ReloginsOnceAndRetriesWithTheNewJWT() async throws {
        let transport = MockTransport()
        let loginCount = OSAllocatedUnfairLock(initialState: 0)
        transport.stub(pathSuffix: "/rest/ping", body: Fixtures.data("getOpenSubsonicExtensions"))
        transport.stub(method: "POST", pathSuffix: "/auth/login") { _ in
            let n = loginCount.withLock { v -> Int in v += 1; return v }
            let body = #"{"id":"u1","isAdmin":true,"name":"A","subsonicSalt":"s","subsonicToken":"t","token":"jwt-\#(n)","username":"admin"}"#
            return .init(status: 200, body: Data(body.utf8), headers: [:])
        }
        transport.stub(pathSuffix: "/api/song") { req in
            let jwt = req.value(forHTTPHeaderField: "X-ND-Authorization")
            return jwt == "Bearer jwt-1"
                ? .init(status: 401, body: Data(), headers: [:])
                : .init(status: 200, body: Fixtures.data("apiSongPage"), headers: ["X-Total-Count": "8"])
        }
        let client = NavidromeClient(endpoint: ServerEndpoint(bases: [testBase]), credentials: testCredentials,
                                     transport: transport)
        _ = try await client.connect()
        let page = try await client.songsPage(start: 0, end: 8)
        #expect(!page.songs.isEmpty)
        #expect(loginCount.withLock { $0 } == 2)
        let songCalls = transport.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }
        #expect(songCalls.map { $0.value(forHTTPHeaderField: "X-ND-Authorization") } == ["Bearer jwt-1", "Bearer jwt-2"])
        // The re-login does not re-probe (it keeps the address that answered).
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/rest/ping") == true }.count == 1)
    }

    /// §4: "token+salt on every Subsonic URL (including stream and cover URLs)", never the password.
    @Test func streamAndCoverURLsCarryTokenAndSaltNotThePassword() async throws {
        let (client, _) = makeClient()
        _ = try await client.connect()
        for url in [client.streamURL(songId: "s1", maxBitRate: nil, format: nil), client.coverArtURL(id: "al-1", size: 300)] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let names = Set(items.map(\.name))
            #expect(names.isSuperset(of: ["u", "t", "s", "v", "c", "f"]), "\(url)")
            #expect(!names.contains("p"))
            #expect(!url.absoluteString.contains(testCredentials.password))
        }
    }
}
