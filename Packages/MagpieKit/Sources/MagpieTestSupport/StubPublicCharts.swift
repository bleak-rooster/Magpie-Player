import Foundation
import MagpieCore
import os

/// Round 14 A4: Deezer's Top Australia playlist and Apple's AU most-played albums, served in process (tests never reach
/// the internet, G0). Shapes from `api.deezer.com/playlist/:id/tracks` and Apple's RSS v2 feed. Switches: a failing
/// status, an answer that came from another host (a redirect off the pin), and an oversized body.
public final class StubPublicCharts: HTTPTransport, @unchecked Sendable {
    private struct State {
        var status = 200
        var answeredFrom: String?
        var oversized = false
        var requests: [URLRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var requests: [URLRequest] { state.withLock { $0.requests } }
    public func setStatus(_ status: Int) { state.withLock { $0.status = status } }
    /// The answer claims to come from this URL instead (as after a redirect).
    public func setAnsweredFrom(_ url: String?) { state.withLock { $0.answeredFrom = url } }
    public func setOversized(_ on: Bool) { state.withLock { $0.oversized = on } }

    public static func handles(_ request: URLRequest) -> Bool {
        ["api.deezer.com", "rss.marketingtools.apple.com"].contains(request.url?.host() ?? "")
    }

    public static var topAustralia: [[String: Any]] { [
        ["id": 4_100_001, "title": "Bluebottle", "duration": 201,
         "preview": "https://cdnt-preview.dzcdn.net/api/1/1/x/y/z/0.mp3?hdnea=exp=1~hmac=signed",
         "artist": ["id": 11, "name": "Southern Cross Band"],
         "album": ["id": 5_001, "title": "Bluebottle", "cover_medium": "https://cdn-images.dzcdn.net/images/cover/a/250x250.jpg",
                   "cover_xl": "https://cdn-images.dzcdn.net/images/cover/a/1000x1000.jpg"]],
        ["id": 4_100_002, "title": "Red Dirt", "duration": 188, "artist": ["id": 12, "name": "Outback Echo"],
         "album": ["id": 5_002, "title": "Red Dirt", "cover_medium": "https://evil.example.com/cover.jpg"]],
        ["id": "not-a-number", "title": "Junk", "artist": ["name": "Nobody"]],
        ["id": 4_100_003, "title": "No Artist"],
    ] }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let s = state.withLock { s -> State in s.requests.append(request); return s }
        let url = request.url!
        var body: Any = ["error": "not found"]
        var status = s.status
        if url.host() == "api.deezer.com", url.path == "/playlist/1313616925/tracks" {
            body = ["data": Self.topAustralia, "total": 4]
        } else if url.host() == "rss.marketingtools.apple.com", url.path == "/api/v2/au/music/most-played/100/albums.json" {
            body = ["feed": ["title": "Top Albums", "country": "au", "results": [
                ["artistName": "Southern Cross Band", "id": "1700000001", "name": "Coastline", "releaseDate": "2026-09-01",
                 "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg",
                 "genres": [["genreId": "20", "name": "Alternative"]]],
                ["artistName": "Outback Echo", "id": "1700000002", "name": "Dust", "artworkUrl100": "http://is1-ssl.mzstatic.com/x.jpg"],
                ["artistName": "Bad", "id": "javascript:alert(1)", "name": "Bad id"],
            ]]]
        } else if status == 200 {
            status = 404
        }
        var data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        if s.oversized { data = Data(repeating: 0x20, count: 2_000_000) }
        let answered = s.answeredFrom.flatMap(URL.init(string:)) ?? url
        return (data, HTTPURLResponse(url: answered, statusCode: status, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json"])!)
    }
}
