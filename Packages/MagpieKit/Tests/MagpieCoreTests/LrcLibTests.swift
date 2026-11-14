import Foundation
import MagpieTestSupport
import os
import Testing
@testable import MagpieCore

/// Round 27 L (owner, 2026-11-14, Q1 yes): Find lyrics online asks LRCLIB's one route, `GET /api/get`, with only the
/// song's title, artist, album and length, a plain `User-Agent`, no credential; 404 is none; 429 backs off until
/// `Retry-After` (capped at an hour); the answer is capped at 512 KB (D311, D312). Every request goes to a mock: nothing
/// here reaches the internet.
@Suite struct LrcLibTests {
    /// A settable clock for the back-off.
    final class Clock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        var now: Date { lock.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    static func body(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static let found = body(["id": 7, "trackName": "Wide Open", "artistName": "Aurora Field", "albumName": "First Light",
                             "duration": 240, "instrumental": false, "plainLyrics": "One\nTwo",
                             "syncedLyrics": "[00:01.00] One\n[00:05.50] Two"])

    func client(_ mock: MockTransport, clock: Clock = Clock()) -> LrcLib {
        LrcLib(transport: mock, userAgent: LrcLib.userAgent(version: "1.2"), now: { clock.now })
    }

    func query(_ request: URLRequest?) -> [String: String] {
        let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }

    @Test func lrclib_exactQueryAndUserAgent() async throws {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/api/get", body: Self.found)
        let answer = await client(mock).get(title: "Wide Open", artist: "Aurora Field", album: "First Light", duration: 240.4)
        #expect(answer == .lines(Lyrics(synced: true, lines: [LyricLine(start: 1, text: "One"), LyricLine(start: 5.5, text: "Two")])))
        let request = try #require(mock.requests.first)
        #expect(mock.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https" && request.url?.host() == "lrclib.net" && request.url?.path == "/api/get")
        #expect(query(request) == ["track_name": "Wide Open", "artist_name": "Aurora Field", "album_name": "First Light",
                                   "duration": "240"])
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Magpie/1.2")
        #expect(request.httpBody == nil)
    }

    @Test func lrclib_albumAndLengthOnlyWhenKnownAndSensible() async throws {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/api/get", status: 404)
        let lrclib = client(mock)
        _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
        _ = await lrclib.get(title: "A", artist: "B", album: "  ", duration: 0.2)
        _ = await lrclib.get(title: "A", artist: "B", album: "C", duration: 3601)
        _ = await lrclib.get(title: "A", artist: "B", album: "C", duration: .infinity)
        _ = await lrclib.get(title: "A", artist: "B", album: "C", duration: .nan)
        _ = await lrclib.get(title: "A", artist: "B", album: "C", duration: 3600)
        let queries = mock.requests.map(query)
        #expect(queries.count == 6)
        #expect(queries[0] == ["track_name": "A", "artist_name": "B"])
        #expect(queries[1] == ["track_name": "A", "artist_name": "B"])
        #expect(queries[2] == ["track_name": "A", "artist_name": "B", "album_name": "C"])
        #expect(queries[3] == ["track_name": "A", "artist_name": "B", "album_name": "C"])
        #expect(queries[4] == ["track_name": "A", "artist_name": "B", "album_name": "C"])
        #expect(queries[5] == ["track_name": "A", "artist_name": "B", "album_name": "C", "duration": "3600"])
    }

    @Test func lrclib_noCallWithoutTitleOrArtist() async {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/api/get", body: Self.found)
        let lrclib = client(mock)
        #expect(await lrclib.get(title: " ", artist: "B", album: nil, duration: 100) == nil)
        #expect(await lrclib.get(title: "A", artist: "", album: nil, duration: 100) == nil)
        #expect(mock.requests.isEmpty)
    }

    /// Nothing but the song's own words goes out: no credential header, no cookie handling, no Navidrome host, user
    /// or token anywhere in the request.
    @Test func lrclib_noCredentialsOrServerNames() async throws {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/api/get", status: 404)
        _ = await client(mock).get(title: "Wide Open", artist: "Aurora Field", album: "First Light", duration: 240)
        let request = try #require(mock.requests.first)
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["user-agent"])
        #expect(request.httpShouldHandleCookies == false)
        let url = try #require(request.url?.absoluteString.lowercased())
        for leak in ["navidrome", "nas.local", "music.example", "192.168.", "jordan", "token", "u=", "t=", "s=", "apikey", "api_key"] {
            #expect(!url.contains(leak), "\(leak)")
        }
        #expect(request.url?.user == nil && request.url?.password == nil && request.url?.fragment == nil)
    }

    @Test func lrclib_requestIsOnlyEverTheOneRoute() throws {
        let request = try #require(LrcLib.request(title: "A/../../x?y=1#z", artist: "B&c=d", album: nil, duration: nil,
                                                  userAgent: "Magpie/1"))
        #expect(request.url?.host() == "lrclib.net" && request.url?.path == "/api/get" && request.url?.scheme == "https")
        #expect(query(request) == ["track_name": "A/../../x?y=1#z", "artist_name": "B&c=d"])
        #expect(LrcLib.getURL.absoluteString == "https://lrclib.net/api/get")
    }

    @Test func lrclib_404IsNone() async {
        let mock = MockTransport()
        mock.stub(pathSuffix: "/api/get", status: 404, body: Self.body(["code": 404, "name": "TrackNotFound"]))
        #expect(await client(mock).get(title: "A", artist: "B", album: nil, duration: nil) == nil)
    }

    @Test func lrclib_otherFailuresAreNone() async {
        for status in [500, 302, 401, 503] {
            let mock = MockTransport()
            mock.stub(pathSuffix: "/api/get", status: status, body: Self.found)
            #expect(await client(mock).get(title: "A", artist: "B", album: nil, duration: nil) == nil, "\(status)")
        }
        let garbage = MockTransport()
        garbage.stub(pathSuffix: "/api/get", body: Data("<html>not json</html>".utf8))
        #expect(await client(garbage).get(title: "A", artist: "B", album: nil, duration: nil) == nil)
        let wrongTypes = MockTransport()
        wrongTypes.stub(pathSuffix: "/api/get", body: Self.body(["syncedLyrics": 5, "plainLyrics": ["x"], "instrumental": "yes"]))
        #expect(await client(wrongTypes).get(title: "A", artist: "B", album: nil, duration: nil) == nil)
    }

    @Test func lrclib_429HonoursRetryAfter() async {
        let mock = MockTransport()
        let clock = Clock()
        mock.stub(pathSuffix: "/api/get", status: 429, headers: ["Retry-After": "120"])
        let lrclib = client(mock, clock: clock)
        #expect(await lrclib.get(title: "A", artist: "B", album: nil, duration: nil) == nil)
        #expect(mock.requests.count == 1)
        clock.advance(119)
        #expect(await lrclib.get(title: "C", artist: "D", album: nil, duration: nil) == nil)
        #expect(mock.requests.count == 1, "no call while LRCLIB asked us to wait")
        clock.advance(2)
        _ = await lrclib.get(title: "C", artist: "D", album: nil, duration: nil)
        #expect(mock.requests.count == 2, "asked again once the wait passed")
    }

    @Test func lrclib_retryAfterCappedAtAnHourAndDefaulted() async {
        for (header, wait) in [("999999", 3600.0), ("-5", LrcLib.defaultBackoff), ("soon", LrcLib.defaultBackoff),
                               (nil, LrcLib.defaultBackoff), ("99999999999999999999999", 3600.0)] as [(String?, TimeInterval)] {
            let mock = MockTransport()
            let clock = Clock()
            mock.stub(pathSuffix: "/api/get", status: 429, headers: header.map { ["Retry-After": $0] } ?? [:])
            let lrclib = client(mock, clock: clock)
            _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
            clock.advance(wait - 1)
            _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
            #expect(mock.requests.count == 1, "\(header ?? "none"): still waiting")
            clock.advance(2)
            _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
            #expect(mock.requests.count == 2, "\(header ?? "none"): asked again after \(wait) s")
        }
    }

    @Test func lrclib_retryAfterAsADate() async {
        let mock = MockTransport()
        let clock = Clock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: clock.now.addingTimeInterval(300))
        mock.stub(pathSuffix: "/api/get", status: 429, headers: ["Retry-After": header])
        let lrclib = client(mock, clock: clock)
        _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
        clock.advance(299)
        _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
        #expect(mock.requests.count == 1)
        clock.advance(2)
        _ = await lrclib.get(title: "A", artist: "B", album: nil, duration: nil)
        #expect(mock.requests.count == 2)
    }

    @Test func lrclib_bodyCap() async {
        let mock = MockTransport()
        let huge = String(repeating: "[00:01.00] la\n", count: 40_000)   // ~560 KB
        mock.stub(pathSuffix: "/api/get", body: Self.body(["syncedLyrics": huge]))
        #expect(await client(mock).get(title: "A", artist: "B", album: nil, duration: nil) == nil)
        #expect(LrcLib.maxResponseBytes == 512 * 1024)
    }

    @Test func lrclib_capIsPassedToTheTransport() async {
        final class Capturing: HTTPTransport, @unchecked Sendable {
            let caps = OSAllocatedUnfairLock(initialState: [Int]())
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.badURL) }
            func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
                caps.withLock { $0.append(maxBytes) }
                throw ResponseTooLarge()
            }
        }
        let capturing = Capturing()
        let lrclib = LrcLib(transport: capturing, userAgent: "Magpie/1")
        #expect(await lrclib.get(title: "A", artist: "B", album: nil, duration: nil) == nil)
        #expect(capturing.caps.withLock { $0 } == [512 * 1024])
    }

    @Test func lrclib_plainAndInstrumentalAnswers() async {
        let plain = MockTransport()
        plain.stub(pathSuffix: "/api/get", body: Self.body(["plainLyrics": "One\nTwo", "syncedLyrics": NSNull(), "instrumental": false]))
        #expect(await client(plain).get(title: "A", artist: "B", album: nil, duration: nil)
                == .lines(Lyrics(synced: false, lines: [LyricLine(text: "One"), LyricLine(text: "Two")])))
        let instrumental = MockTransport()
        instrumental.stub(pathSuffix: "/api/get", body: Self.body(["plainLyrics": NSNull(), "syncedLyrics": NSNull(), "instrumental": true]))
        #expect(await client(instrumental).get(title: "A", artist: "B", album: nil, duration: nil) == .instrumental)
    }

    @Test func lrclib_aConnectionFailureIsNone() async {
        final class Down: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        }
        #expect(await LrcLib(transport: Down(), userAgent: "Magpie/1").get(title: "A", artist: "B", album: nil, duration: 9) == nil)
    }

    @Test func userAgentIsJustTheAppAndVersion() {
        #expect(LrcLib.userAgent(version: "0.0.1") == "Magpie/0.0.1")
    }
}
