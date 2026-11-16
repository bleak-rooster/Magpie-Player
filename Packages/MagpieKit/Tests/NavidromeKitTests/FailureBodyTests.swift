import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import NavidromeKit

/// Round 28 O1 fix round 1 (security M3, D325): a failed answer is judged by its body, not its status. HTML or other
/// text that isn't JSON, at any status, is `unexpectedResponse` (a proxy, a portal, a CDN: not the library); an empty or
/// JSON body keeps its status (the library's own answer). Pings are capped at 16 KiB (security M2).
@Suite struct FailureBodyTests {
    let html = Data("<!DOCTYPE html><html><body>Error 1016 · Origin DNS error</body></html>".utf8)
    let subsonicError = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"boom"}}}"#.utf8)

    func connected(_ stubs: (MockTransport) -> Void) async throws -> NavidromeClient {
        let transport = MockTransport()
        stubs(transport)   // first match wins: the test's routes before the fixtures'
        let (client, _) = makeClient(transport: transport)
        _ = try await client.connect()
        return client
    }

    @Test func subsonicHTMLAtAnyStatusIsUnexpectedResponse() async throws {
        for status in [530, 403, 401, 502, 200] {
            let client = try await connected { $0.stub(pathSuffix: "/rest/getAlbumList2", status: status, body: html) }
            await #expect(throws: NavidromeError.unexpectedResponse, "\(status)") {
                _ = try await client.albumList(.newest, size: 1, offset: 0)
            }
        }
    }

    @Test func subsonicEmptyOrJSONBodyKeepsItsStatus() async throws {
        let empty = try await connected { $0.stub(pathSuffix: "/rest/getAlbumList2", status: 502) }
        await #expect(throws: NavidromeError.http(status: 502)) { _ = try await empty.albumList(.newest, size: 1, offset: 0) }
        let json = try await connected { $0.stub(pathSuffix: "/rest/getAlbumList2", status: 500, body: subsonicError) }
        await #expect(throws: NavidromeError.http(status: 500), "a 500 with a Subsonic body: the library answered") {
            _ = try await json.albumList(.newest, size: 1, offset: 0)
        }
    }

    @Test func nativeHTMLIsUnexpectedResponse() async throws {
        let client = try await connected { $0.stub(pathSuffix: "/api/library", status: 403, body: html) }
        await #expect(throws: NavidromeError.unexpectedResponse) { _ = try await client.libraries() }
        let json = try await connected { $0.stub(pathSuffix: "/api/library", status: 403, body: Data(#"{"error":"forbidden"}"#.utf8)) }
        await #expect(throws: NavidromeError.http(status: 403)) { _ = try await json.libraries() }
    }

    @Test func loginHTMLIsUnexpectedResponseNotARefusal() async throws {
        let transport = MockTransport()
        transport.stub(method: "POST", pathSuffix: "/auth/login", status: 403, body: html)
        let (portal, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.unexpectedResponse, "a portal's 403 page is not a wrong password") {
            _ = try await portal.connect()
        }
        let refused = MockTransport()
        refused.stub(method: "POST", pathSuffix: "/auth/login", status: 401)
        let (wrong, _) = makeClient(transport: refused)
        await #expect(throws: NavidromeError.badCredentials) { _ = try await wrong.connect() }
        let busy = MockTransport()
        busy.stub(method: "POST", pathSuffix: "/auth/login", status: 429, body: Data(#"{"error":"too many"}"#.utf8))
        let (limited, _) = makeClient(transport: busy)
        await #expect(throws: NavidromeError.http(status: 429)) { _ = try await limited.connect() }
        // Only the library's JSON is its answer at the login: an empty 500 is not (security L4 with M3).
        let empty = MockTransport()
        empty.stub(method: "POST", pathSuffix: "/auth/login", status: 500)
        let (bare, _) = makeClient(transport: empty)
        await #expect(throws: NavidromeError.unexpectedResponse) { _ = try await bare.connect() }
        let json = MockTransport()
        json.stub(method: "POST", pathSuffix: "/auth/login", status: 500, body: Data(#"{"error":"db locked"}"#.utf8))
        let (answered, _) = makeClient(transport: json)
        await #expect(throws: NavidromeError.http(status: 500)) { _ = try await answered.connect() }
    }

    /// Fix round 2 (security SN6): at the login a JSON failure counts as the library's only with its error shape (a
    /// Subsonic envelope, or Navidrome's `{"error": …}`); other JSON (a CDN's, a proxy's) is no answer.
    @Test func loginJSONCountsOnlyWithTheLibrarysShape() async throws {
        func login(_ status: Int, _ body: String) async -> Error? {
            let t = MockTransport()
            t.stub(method: "POST", pathSuffix: "/auth/login", status: status, body: Data(body.utf8))
            let (client, _) = makeClient(transport: t)
            do { _ = try await client.connect(); return nil } catch { return error }
        }
        #expect(await login(503, #"{"code":503,"cf_ray":"abc"}"#) as? NavidromeError == .unexpectedResponse)
        #expect(await login(403, #"{"message":"blocked by policy"}"#) as? NavidromeError == .unexpectedResponse)
        #expect(await login(500, #"{"error":"database is locked"}"#) as? NavidromeError == .http(status: 500))
        #expect(await login(403, #"{"error":"Invalid username or password"}"#) as? NavidromeError == .badCredentials)
        #expect(await login(500, #"{"subsonic-response":{"status":"failed","version":"1.16.1"}}"#) as? NavidromeError == .http(status: 500))
        // Fix round 3 (security SN15a): Navidrome's exact error object, not any object with an `error` string.
        #expect(await login(403, #"{"error":"blocked","cf_ray":"abc"}"#) as? NavidromeError == .unexpectedResponse)
        #expect(await login(500, #"{"error":"oops","status":500,"path":"/auth/login"}"#) as? NavidromeError == .unexpectedResponse)
        #expect(await login(500, #"{"error":7}"#) as? NavidromeError == .unexpectedResponse)
    }

    /// Fix round 2 (security SN5): the login's answer is capped at 64 KiB.
    @Test func loginAnswerOver64KiBIsRefused() async throws {
        let t = MockTransport()
        var big = Data(#"{"id":"u1","token":"jwt","pad":""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "x"), count: 65 * 1024))
        big.append(Data(#""}"#.utf8))
        t.stub(method: "POST", pathSuffix: "/auth/login", body: big)
        let (client, _) = makeClient(transport: t)
        await #expect(throws: NavidromeError.unexpectedResponse, "too big to be the library's answer") { _ = try await client.connect() }
        #expect(NavidromeClient.loginMaxBytes == 64 * 1024)
    }

    @Test func pingAnswerOver16KiBIsNotAServer() async throws {
        let transport = MockTransport()
        var big = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","pad":""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "x"), count: 17 * 1024))
        big.append(Data(#""}}"#.utf8))
        transport.stub(pathSuffix: "/rest/ping", body: big)
        let (client, _) = makeClient(transport: transport)
        await #expect(throws: NavidromeError.noReachableServer) { _ = try await client.connect() }
        #expect(NavidromeClient.pingMaxBytes == 16 * 1024)
    }
}
