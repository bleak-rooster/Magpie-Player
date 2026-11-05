import AurralKit
import CryptoKit
import Foundation

/// Round 14 A1: StubAurral's Aurral 2.13 Discover routes (shapes from Aurral 2.13.0's source:
/// `routes/discovery/handlers/*`, `services/discovery/trendingCharts.ts`, `services/discovery/editorialPlaylists.ts`,
/// `routes/artists/handlers/preview.ts`, `routes/search.ts`, `routes/playlists/handlers/*`, `routes/deezer.ts`).
/// Served only after `useAurral213()` (an Aurral without the API contract answers 404, as 2.10 does). Switches for the
/// round-14 UI tests: the chart region, sections never loaded, a genre chart not ready, slow or failing answers, a
/// user without `accessFlow`, no download source (StubAurral.setDownloadSources), and the preview's redirect.
public struct StubAurralDiscover: Sendable {
    public enum TrendingSection: String, Sendable, CaseIterable { case songs, albums, artists, genres }

    /// The chart region (`trending.region`), "AU" by default.
    var region = "AU"
    var missingSections: Set<TrendingSection> = []
    /// Genre charts that answer 404 "This genre chart isn't available yet".
    var genresNotReady: Set<Int> = []
    /// Each Discover answer waits this long first.
    var delay: Duration = .zero
    /// Each Discover answer fails with this status (`{"error": ...}`) instead.
    var failure: Int?
    /// Deezer playlist ids already added (Add flow answers `alreadyAdded`).
    var added: [String: String] = [:]
    /// Round 14 A4 fix round 1: Discover playlists (Deezer ids) Aurral can't read (404).
    var editorialMissing: Set<String> = []
    /// Where the preview redirects: a URL (302), or nil (404 "Preview not found").
    var previewTarget: String? = "https://cdnt-preview.dzcdn.net/api/1/1/a/b/c/preview.mp3?hdnea=exp=1790000000~hmac=stub"
    /// The preview answers this status instead (502: Deezer down; 200: the bytes).
    var previewStatus: Int?
    /// Round 14 A7: the size of the clip `?download` sends (Aurral fetches it from Deezer and sends the bytes itself).
    var previewClipSize = 2_048
    /// Round 14 A7: the content type the clip is sent with.
    var previewClipType = "audio/mpeg"
    /// Round 14 A7: the image proxy. Sources Aurral refuses (404 "Image not found"), and whether its file route fails.
    var imageProxyRefused: Set<String> = []
    var imageProxyFileStatus: Int?
    /// Round 14 A7: the image proxy's cache (key → source), as Aurral keeps it on disk.
    var imageProxyCache: [String: String] = [:]
    /// B1 fix round: the cover link the album search names for its first album (nil: none).
    var albumSearchCover: String?
    /// What was written: "METHOD /path" and its JSON body.: "METHOD /path" and its JSON body.
    var writes: [(String, Data)] = []

    public init() {}

    // MARK: - Fixtures

    static let artistA = "a74b1b7f-71a5-4011-9441-d0b5e4122711"
    static let artistB = "f59c5520-5f46-4d2c-b2c4-822eabf53419"
    static let artistC = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
    public static let releaseGroup = "1dc4c347-a1db-32aa-b14f-bc9cc507b843"

    static func song(_ id: Int, _ title: String, _ artist: String, position: Int? = nil, movement: Any? = nil) -> [String: Any] {
        var s: [String: Any] = [
            "key": String(id), "trackName": title, "artistName": artist, "albumName": "\(title) (Single)",
            "deezerAlbumId": String(id + 1_000), "durationMs": 180_000 + id % 60 * 1_000,
            "artworkUrl": "https://cdn-images.dzcdn.net/images/cover/\(id)/250x250-000000-80-0-0.jpg",
            "largeArtworkUrl": "https://cdn-images.dzcdn.net/images/cover/\(id)/1000x1000-000000-80-0-0.jpg",
            "preview_url": "/api/deezer/preview/\(id).mp3",
        ]
        if let position { s["position"] = position; s["movement"] = movement ?? NSNull() }
        return s
    }

    static var songs: [[String: Any]] { [
        song(3135556, "Harbour Lights", "Stub Arrows", position: 1, movement: 0),
        song(3135557, "Paper Moon", "Stub Arrows", position: 2, movement: 3),
        song(3135558, "Night Drive", "Low Tide Club", position: 3, movement: -1),
        song(3135559, "Southerly", "Mallee Fowl", position: 4, movement: "new"),
        song(3135560, "No Preview Song", "Mallee Fowl", position: 5),
    ] }

    /// Round 15 C2: Deezer's "Top Worldwide" chart playlist (ChartPlaylists.json's `worldwide`), served with 30 songs so
    /// a chart flow can hold 10, 20 or 25 of them.
    public static let worldwideChart = "3155776842"
    static var worldwideSongs: [[String: Any]] {
        (0..<30).map { song(3_140_000 + $0, "World Song \($0 + 1)", "World Artist \($0 % 7 + 1)") }
    }

    static func editorialSummary(_ id: String, _ name: String) -> [String: Any] {
        ["id": id, "name": name, "description": "\(name), updated weekly", "trackCount": 4,
         "artworkUrl": "https://cdn-images.dzcdn.net/images/playlist/\(id)/1000x1000.jpg", "curator": "Deezer Pop Editor"]
    }

    static func artist(_ id: String?, _ name: String, depth: Int, seeds: [String], days: Int) -> [String: Any] {
        ["id": id ?? NSNull(), "navigateTo": id ?? NSNull(), "name": name, "type": "Artist", "image": NSNull(),
         "tags": ["indie pop", "dream pop"], "matchedTags": ["indie pop"], "sourceArtist": seeds.first ?? NSNull(),
         "sourceArtists": seeds, "sourceType": "similar", "supportingSeeds": seeds.map { ["artistName": $0] },
         "discoveryTier": depth > 1 ? "further" : "close", "discoveryDepth": depth,
         "firstDiscoveredAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400)),
         "score": 0.82, "scoreTotal": 12, "matchPercent": 82, "popularityLabel": "Rising", "popularityRank": 3,
         "listeners": 120_000, "playcount": 2_400_000]
    }

    // MARK: - Serving

    func answer(method: String, path: String, query: [String: String], body: [String: Any], user: StubAurral.User,
                hasDownloader: Bool) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts) {
        case ("GET", ["api", "discover"]):
            let all = [Self.artist(Self.artistA, "Stub Arrows", depth: 1, seeds: ["Seed One"], days: 2),
                       Self.artist(Self.artistB, "Low Tide Club", depth: 1, seeds: ["Seed One"], days: 30),
                       Self.artist(Self.artistC, "Mallee Fowl", depth: 2, seeds: ["Seed Two"], days: 3),
                       Self.artist(nil, "No Id Band", depth: 3, seeds: [], days: 40)]
            let offset = max(0, Int(query["offset"] ?? "") ?? 0)
            let limit = min(200, max(1, Int(query["limit"] ?? "") ?? all.count))
            let page = Array(all.dropFirst(offset).prefix(limit))
            return (200, ["recommendations": page, "recommendationCount": all.count,
                          "globalTop": [Self.artist(Self.artistB, "Low Tide Club", depth: 1, seeds: [], days: 1)],
                          "basedOn": [["name": "Seed One", "source": "library"], ["name": "Seed Two", "source": "listenbrainz"]],
                          "topTags": ["indie pop"], "topGenres": ["indie", "pop"], "lastUpdated": "2026-11-04T00:00:00.000Z",
                          "recommendationQuality": "good", "isEnriching": false, "configured": true,
                          "provider": "brainzmash", "discoveryMode": "balanced"])
        case ("GET", ["api", "discover", "trending"]):
            let genres: [[String: Any]] = [(132, "Pop"), (116, "Rap/Hip Hop"), (152, "Rock")].map { id, name in
                ["id": id, "name": name, "covers": Self.songs.prefix(4).compactMap { $0["artworkUrl"] },
                 "artists": ["Stub Arrows", "Low Tide Club"]]
            }
            func section(_ s: TrendingSection, _ value: Any) -> Any { missingSections.contains(s) ? NSNull() : value }
            return (200, [
                "region": region, "updatedAt": 1_793_000_000_000,
                "songs": section(.songs, ["playlistId": "1313616925", "playlistName": "Top Australia",
                                          "libraryPlaylistId": added["1313616925"].map { $0 as Any } ?? NSNull(), "items": Self.songs,
                                          "spotlight": ["ranks": [3, 2, 1, NSNull(), 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
                                                        "daysAtTop": 9]]),
                "albums": section(.albums, [["key": "1440857781", "name": "Wide Open", "artistName": "Stub Arrows",
                                             "artworkUrl": "https://is1-ssl.mzstatic.com/image/thumb/x/500x500bb.jpg",
                                             "releaseDate": "2026-10-01", "genre": "Alternative", "position": 1],
                                            ["key": "1440857782", "name": "Shoreline", "artistName": "Mallee Fowl",
                                             "artworkUrl": NSNull(), "releaseDate": NSNull(), "genre": NSNull(), "position": 2]]),
                "genreShare": section(.albums, ["total": 2, "other": 0, "genres": [["name": "Alternative", "count": 1]]]),
                "artists": section(.artists, [["key": "27", "name": "Stub Arrows", "imageUrl": "https://cdn-images.dzcdn.net/images/artist/27/1000x1000.jpg",
                                               "fans": 1_200, "mbid": Self.artistA, "position": 1],
                                              ["key": "28", "name": "Unknown Guess", "imageUrl": NSNull(), "fans": NSNull(),
                                               "mbid": NSNull(), "position": 2]]),
                "genres": missingSections.contains(.genres) ? [] : genres,
            ])
        case ("GET", let p) where p.count == 5 && p[2] == "trending" && p[3] == "genres":
            guard let id = Int(p[4]), !genresNotReady.contains(id) else {
                return (404, ["error": "This genre chart isn't available yet"])
            }
            return (200, ["id": id, "name": id == 132 ? "Pop" : "Genre \(id)", "region": region,
                          "updatedAt": 1_793_000_000_000, "items": Self.songs])
        case ("GET", ["api", "discover", "editorial"]):
            return (200, ["forYou": [Self.editorialSummary("908622995", "Indie Pop Picks"),
                                     Self.editorialSummary("1479458365", "Dream Pop")],
                          "genres": [["id": 0, "name": "Popular", "playlists": [Self.editorialSummary("1313616925", "Top Australia")]],
                                     ["id": 132, "name": "Pop", "playlists": [Self.editorialSummary("1282483245", "Pop Hits")]]]])
        case ("GET", ["api", "discover", "editorial", "links"]):
            guard query["artist"]?.isEmpty == false else { return (400, ["error": "Failed to find this artist or album",
                                                                        "message": "artistName is required"]) }
            return (200, ["artistMbid": Self.artistA, "albumMbid": query["album"] == nil ? NSNull() as Any : Self.releaseGroup])
        case ("GET", let p) where p.count == 4 && p[2] == "editorial":
            if editorialMissing.contains(p[3]) { return (404, ["error": "Playlist not found"]) }
            let tracks = (p[3] == Self.worldwideChart ? Self.worldwideSongs : Array(Self.songs.prefix(4))).map { s -> [String: Any] in
                var t = s
                t["key"] = nil; t["largeArtworkUrl"] = nil; t["position"] = nil; t["movement"] = nil
                return t
            }
            let name = p[3] == "1313616925" ? "Top Australia" : p[3] == Self.worldwideChart ? "Top Worldwide" : "Indie Pop Picks"
            return (200, ["id": p[3], "name": name, "description": "Fresh indie pop", "curator": "Deezer Pop Editor",
                          "artworkUrl": "https://cdn-images.dzcdn.net/images/playlist/\(p[3])/1000x1000.jpg",
                          "tracks": tracks, "libraryPlaylistId": added[p[3]].map { $0 as Any } ?? NSNull()])
        case (let m, let p) where m != "GET" && p.count == 5 && p[2] == "editorial" && p[4] == "library":
            guard user.role == "admin" || user.permissions?["accessFlow"] == true else {
                return (403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
            }
            if let existing = added[p[3]] {
                return (200, ["playlistId": existing, "name": "Indie Pop Picks", "alreadyAdded": true])
            }
            return (200, ["playlistId": StubAurral.syncedId(p[3]), "name": "Indie Pop Picks", "alreadyAdded": false, "tracksQueued": 4])
        case (let m, ["api", "discover", "feedback"]) where m != "GET":
            let actions = ["more_like_this", "less_like_this", "block_artist"]
            guard let action = body["action"] as? String, actions.contains(action),
                  (body["artistId"] as? String)?.isEmpty == false || (body["artistName"] as? String)?.isEmpty == false else {
                return (400, ["error": "Failed to save discovery feedback", "message": "Invalid discovery feedback action"])
            }
            return (200, ["success": true, "feedback": body.merging(["id": "fb-1"]) { a, _ in a }, "feedbackList": [body]])
        case ("GET", let p) where p.count == 4 && p[1] == "artists" && p[3] == "preview":
            return (200, ["tracks": Self.songs.prefix(3).map { s in
                ["id": s["key"]!, "title": s["trackName"]!, "album": s["albumName"]!, "artworkUrl": s["artworkUrl"]!,
                 "preview_url": s["preview_url"]!, "duration_ms": s["durationMs"]!]
            }])
        case ("GET", let p) where p.count == 5 && p[2] == "release-group" && p[4] == "tracks":
            return (200, (1...4).map { n -> [String: Any] in
                let recording = "\(n)c5d7c4e-1f3b-4a6e-9d2c-7b1a2f3e4d5\(n)"
                return ["id": recording, "mbid": recording, "title": "Track \(n)", "trackName": "Track \(n)",
                        "trackNumber": n, "discNumber": 1, "position": n, "releaseMbid": "b5cdfb5f-35a5-4bc5-bbca-57839a71813a",
                        "length": 200_000 + n * 1_000, "preview_url": n == 4 ? NSNull() : "/api/deezer/preview/\(3135555 + n).mp3",
                        "previewProvider": n == 4 ? NSNull() : "deezer", "previewTrackId": n == 4 ? NSNull() : String(3135555 + n)]
            })
        case ("GET", ["api", "search", "unified"]):
            let q = query["q"] ?? ""
            guard !q.isEmpty else { return (400, ["error": "q parameter is required"]) }
            return (200, ["query": q, "mode": query["mode"] ?? "suggest", "top": NSNull(),
                          "catalog": ["artists": [["type": "artist", "source": "brainzmash", "id": Self.artistA, "key": Self.artistA,
                                                   "name": "Stub Arrows", "sortName": "Arrows, Stub", "inLibrary": true,
                                                   "hasMbid": true, "score": 100],
                                                  ["type": "artist", "source": "brainzmash", "id": Self.artistB, "key": Self.artistB,
                                                   "name": "Low Tide Club", "sortName": "Low Tide Club", "inLibrary": false,
                                                   "hasMbid": true, "score": 80]],
                                      "albums": [["type": "album", "source": "brainzmash", "id": Self.releaseGroup,
                                                  "key": Self.releaseGroup, "title": "Wide Open", "artistName": "Stub Arrows",
                                                  "artistMbid": Self.artistA, "primaryType": "Album", "secondaryTypes": [],
                                                  "releaseDate": "2026-10-01", "coverUrl": "/api/artists/release-group/\(Self.releaseGroup)/cover",
                                                  "inLibrary": false]],
                                      "tracks": []],
                          "localSearchConfigured": true, "filters": [:]])
        case ("GET", ["api", "search"]):
            let q = query["q"] ?? ""
            guard !q.isEmpty else { return (400, ["error": "q parameter is required"]) }
            let total = 30
            let offset = max(0, Int(query["offset"] ?? "") ?? 0)
            let limit = max(1, Int(query["limit"] ?? "") ?? 24)
            let range = offset < total ? Array(offset..<min(total, offset + limit)) : []
            if query["scope"] == "album" {
                let cover: Any = albumSearchCover ?? NSNull()
                return (200, ["scope": "album", "query": q, "sort": "relevance", "count": total, "offset": offset,
                              "hasMore": offset + range.count < total,
                              "items": range.map { i in ["type": "album", "id": String(format: "00000000-0000-4000-8000-%012d", i),
                                                         "title": "\(q) album \(i)", "artistName": "Stub Arrows",
                                                         "artistMbid": Self.artistA, "primaryType": "Album", "secondaryTypes": [],
                                                         "releaseDate": NSNull(), "coverUrl": i == 0 ? cover : NSNull(), "inLibrary": i == 0,
                                                         "status": "missing", "score": 100 - i] }])
            }
            return (200, ["scope": "artist", "query": q, "count": total, "offset": offset,
                          "items": range.map { i in ["type": "artist", "id": String(format: "00000000-0000-4000-9000-%012d", i),
                                                     "name": "\(q) \(i)", "sortName": "\(q) \(i)", "image": NSNull(),
                                                     "imageUrl": NSNull(), "inLibrary": false, "score": 0] }])
        case (let m, let p) where m != "GET" && p.count == 5 && p[2] == "flows" && p[4] == "download":
            guard user.role == "admin" || user.permissions?["accessFlow"] == true else { return (403, ["error": "Forbidden"]) }
            guard hasDownloader else {
                let message = "No download source is configured"
                return (409, ["error": message, "message": message])
            }
            return (200, ["success": true, "flowId": p[3], "queued": true, "operationId": "op-download"])
        case (let m, let p) where m != "GET" && p.count == 7 && p[2] == "shared-playlists" && p[6] == "research":
            guard user.role == "admin" || user.permissions?["accessFlow"] == true else { return (403, ["error": "Forbidden"]) }
            return (200, ["success": true, "jobId": p[5], "playlistId": p[3], "queued": true, "operationId": "op-research"])
        default:
            return nil
        }
    }
}

public extension StubAurral {
    // MARK: - Round 14 switches

    /// The chart region Aurral reports (Deezer's geo-IP of the server).
    func setTrendingRegion(_ region: String) { discover.withLock { $0.region = region } }
    /// These Trending sections have never loaded (`null`; genres: an empty list).
    func setTrendingMissing(_ sections: Set<StubAurralDiscover.TrendingSection>) { discover.withLock { $0.missingSections = sections } }
    /// The genre chart answers 404 "not available yet".
    func setGenreChartReady(_ id: Int, _ ready: Bool) {
        discover.withLock { if ready { $0.genresNotReady.remove(id) } else { $0.genresNotReady.insert(id) } }
    }
    /// Every Discover answer waits this long (a slow Aurral).
    func setDiscoverDelay(_ delay: Duration) { discover.withLock { $0.delay = delay } }
    /// Every Discover answer fails with this status (nil: answers again).
    func setDiscoverFailure(_ status: Int?) { discover.withLock { $0.failure = status } }
    /// Where the preview redirects (nil: no preview, 404).
    func setPreviewTarget(_ target: String?) { discover.withLock { $0.previewTarget = target } }
    /// The preview answers this status instead of its redirect (nil: the redirect again).
    func setPreviewStatus(_ status: Int?) { discover.withLock { $0.previewStatus = status } }
    /// Round 14 A7: the size of the clip `?download` sends.
    func setPreviewClipSize(_ size: Int) { discover.withLock { $0.previewClipSize = size } }
    /// Round 14 A7: the content type the clip is sent with.
    func setPreviewClipType(_ type: String) { discover.withLock { $0.previewClipType = type } }
    /// Round 14 A7: a stand-in MP3 clip of `size` bytes (an ID3 header, then frame-sync bytes).
    static func previewClip(size: Int) -> Data {
        var data = Data("ID3".utf8)
        data.append(Data(repeating: 0xFF, count: max(0, size - 3)))
        return data
    }
    /// Round 14 A7: Aurral's image proxy refuses this source (404 "Image not found", as for a private host).
    func setImageProxyRefused(_ src: String) { discover.withLock { _ = $0.imageProxyRefused.insert(src) } }
    /// Round 14 A7: `GET /api/image-proxy/<key>` answers this status instead (nil: the picture again).
    func setImageProxyFileStatus(_ status: Int?) { discover.withLock { $0.imageProxyFileStatus = status } }
    /// Round 14 A7: Aurral forgets its cached pictures (its cache was cleared): the file route answers 404 until the
    /// source is asked for again.
    func clearImageProxyCache() { discover.withLock { $0.imageProxyCache = [:] } }
    /// B1 fix round: the album search names this cover for its first album (`00000000-0000-4000-8000-000000000000`).
    public func setAlbumSearchCover(_ link: String?) { discover.withLock { $0.albumSearchCover = link } }
    /// Round 14 A7: the `src` of each `POST /api/image-proxy`, in order.
    var imageProxySources: [String] {
        requests.filter { $0.httpMethod != "GET" && $0.url?.path == "/api/image-proxy" }.compactMap { request in
            (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["src"] as? String
        }
    }
    /// Round 14 A7: a 1×1 PNG, the picture the stub's image proxy serves.
    static let proxiedPicture = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    /// The Deezer playlist is already in the user's flows (Add flow answers `alreadyAdded`).
    func setEditorialMissing(_ deezerId: String) { discover.withLock { _ = $0.editorialMissing.insert(deezerId) } }
    /// Round 14 A4: Add flow already made a playlist for this Deezer playlist.
    func setEditorialAdded(_ deezerId: String, as playlistId: String) { discover.withLock { $0.added[deezerId] = playlistId } }
    /// The round-14 writes, as "METHOD /path" and their JSON bodies.
    var discoverWrites: [(String, [String: Any])] {
        discover.withLock { $0.writes }.map { ($0.0, (try? JSONSerialization.jsonObject(with: $0.1) as? [String: Any]) ?? [:]) }
    }

    // MARK: - Serving (called from StubAurral.send)

    internal func discoverAnswer(method: String, path: String, url: URL, request: URLRequest, user: User,
                                 version: String?) async throws -> (Int, Any)? {
        let parts = path.split(separator: "/")
        let isDiscover = parts.count >= 2 && ["discover", "artists", "search"].contains(parts[1])
            || path.hasPrefix("/api/playlists/flows/") || path.hasPrefix("/api/playlists/shared-playlists/")
            || path.hasPrefix("/api/playlists/jobs/")
        guard isDiscover, features != nil else { return nil }
        let (delay, failure) = discover.withLock { ($0.delay, $0.failure) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { return (failure, ["error": "Stub failure"]) }
        if method == "GET", parts.count == 4, parts[1] == "playlists", parts[2] == "jobs" {
            return jobsAnswer(flowId: String(parts[3]), user: user)
        }
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let hasDownloader = hasDownloadSource
        let answer = discover.withLock { $0 }.answer(method: method, path: path, query: query, body: body, user: user,
                                                     hasDownloader: hasDownloader)
        if method != "GET", let answer, (200..<300).contains(answer.0) {
            // Round 14 A4: a new synced playlist queues its songs; a retried song is searched for again.
            let p = path.split(separator: "/").map(String.init)
            if p.count == 5, p[2] == "editorial", p[4] == "library", discover.withLock({ $0.added[p[3]] }) == nil {
                let songs = StubAurralDiscover.songs.prefix(4).compactMap { s -> (String, String, Int)? in
                    guard let t = s["trackName"] as? String, let a = s["artistName"] as? String,
                          let d = s["durationMs"] as? Int else { return nil }
                    return (t, a, d)
                }
                addSynced(id: StubAurral.syncedId(p[3]), name: p[3] == "1313616925" ? "Top Australia" : "Indie Pop Picks", owner: user.id,
                          songs: songs.map { (title: $0.0, artist: $0.1, durationMs: $0.2) })
            }
            if p.count == 7, p[2] == "shared-playlists", p[6] == "research" { retryJob(p[5]) }
            discover.withLock { d in
                d.writes.append(("\(method) \(path)", request.httpBody ?? Data()))
                let parts = path.split(separator: "/").map(String.init)
                if parts.count == 5, parts[2] == "editorial", parts[4] == "library", d.added[parts[3]] == nil {
                    d.added[parts[3]] = StubAurral.syncedId(parts[3])
                }
            }
        }
        return answer
    }

    /// `GET /api/deezer/preview/<id>.mp3`: open (no session needed), a 302 to Deezer's CDN, 404 without a preview.
    /// Round 14 A7: with `?download` (2.13 `routes/deezer.ts`) Aurral fetches the clip itself and answers 200
    /// `audio/mpeg` with the bytes; the phone never meets Deezer's CDN.
    internal func previewAnswer(method: String, path: String, url: URL) -> (Data, HTTPURLResponse)? {
        guard method == "GET", path.hasPrefix("/api/deezer/preview/"), features != nil else { return nil }
        let (target, status, clipSize, clipType) = discover.withLock {
            ($0.previewTarget, $0.previewStatus, $0.previewClipSize, $0.previewClipType)
        }
        let download = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "download" } == true
        // Like CFNetwork, the answer's URL is canonical (scheme and host lower-cased), not an echo of the request's.
        var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let scheme = canonical.scheme?.lowercased(), lowerHost = canonical.host?.lowercased()
        canonical.scheme = scheme
        canonical.host = lowerHost
        let answerURL = canonical.url ?? url
        func reply(_ code: Int, _ headers: [String: String], _ body: Data = Data()) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: answerURL, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        let file = path.dropFirst("/api/deezer/preview/".count)
        guard file.hasSuffix(".mp3"), file.dropLast(4).allSatisfy(\.isNumber), !file.dropLast(4).isEmpty, !file.hasPrefix("3135560") else {
            return reply(404, ["Content-Type": "application/json"], Data(#"{"error":"Preview not found"}"#.utf8))
        }
        if let status { return reply(status, ["Content-Type": status == 200 ? "audio/mpeg" : "application/json"]) }
        guard let target else { return reply(404, ["Content-Type": "application/json"], Data(#"{"error":"Preview not found"}"#.utf8)) }
        if download {
            return reply(200, ["Content-Type": clipType, "Cache-Control": "no-store"], StubAurral.previewClip(size: clipSize))
        }
        return reply(302, ["Location": target, "Cache-Control": "no-store"])
    }

    /// Round 14 A7: `POST /api/image-proxy {src}` (signed in): Aurral fetches and caches the picture, and answers
    /// `{url: "/api/image-proxy/<sha256>.<ext>"}`; a source it can't fetch (a private host, a 404) is 404
    /// "Image not found"; no http(s) source is 400 (2.13 `routes/imageProxy.ts`).
    internal func imageProxyAnswer(method: String, path: String, request: URLRequest) -> (Int, Any)? {
        guard method != "GET", method != "HEAD", path == "/api/image-proxy" else { return nil }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let src = (body["src"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard src.lowercased().hasPrefix("http://") || src.lowercased().hasPrefix("https://") else {
            return (400, ["error": "An http or https image URL is required"])
        }
        let key = Self.sha256Hex(src)
        let cached = discover.withLock { d -> Bool in
            if d.imageProxyRefused.contains(src) { return false }
            d.imageProxyCache[key] = src
            return true
        }
        return cached ? (200, ["url": "/api/image-proxy/\(key).png"]) : (404, ["error": "Image not found"])
    }

    /// Round 14 A7: `GET /api/image-proxy/<key>[.ext]`: open (no session needed), the cached picture or 404.
    internal func imageProxyFileAnswer(method: String, path: String, url: URL) -> (Data, HTTPURLResponse)? {
        guard method == "GET" || method == "HEAD", path.hasPrefix("/api/image-proxy/") else { return nil }
        let raw = path.dropFirst("/api/image-proxy/".count)
        let key = String(raw.split(separator: ".", maxSplits: 1).first ?? "").lowercased()
        let (cached, status) = discover.withLock { ($0.imageProxyCache[key] != nil, $0.imageProxyFileStatus) }
        func reply(_ code: Int, _ type: String, _ body: Data) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
        }
        if let status { return reply(status, "application/json", Data(#"{"error":"Stub"}"#.utf8)) }
        guard cached else { return reply(404, "application/json", Data(#"{"error":"Image not found"}"#.utf8)) }
        return reply(200, "image/png", StubAurral.proxiedPicture)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
