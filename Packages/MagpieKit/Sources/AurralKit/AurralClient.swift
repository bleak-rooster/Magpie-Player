import Foundation
import MagpieCore

/// Why an Aurral call didn't go through.
public enum AurralError: Error, Sendable, Equatable {
    /// Not one of `AurralRoute`'s allowed calls: refused in code, nothing sent.
    case forbidden(String)
    /// Refused: a 401 a fresh login didn't cure.
    case unauthorized
    /// Fix M2: Aurral knows the user but doesn't let them do this (403: a permission, such as accessFlow, is off).
    /// Not a lost session: never a new login, never "sign in again".
    case notPermitted
    /// Round 13: the username or password is wrong (the login answered 400 or 401).
    case badLogin
    /// Round 13: the session ended and Magpie can't log in again by itself (no saved password, or Aurral refused it):
    /// the owner signs in again in Settings.
    case signInNeeded
    /// Round 13: too many logins (Aurral allows 10 in 15 minutes).
    case rateLimited
    /// The route or the flow isn't there (404).
    case notFound
    /// Another HTTP status.
    case http(status: Int)
    /// The answer isn't Aurral's JSON.
    case decoding
    /// Refresh Flow while a run is under way: refused, nothing sent.
    case runActive
    /// Round 14: the server has no download source set up (Download songs answered 409).
    case noDownloader
}

/// Round 12 Y6, round 13, round 14 A1 (D81): the only calls Magpie may send to Aurral; everything else is refused in
/// code (`AurralClient.send`) and `scripts/check-writes.sh` pins the routes and the writes. Each route is its own case.
/// - Round 12/13: `GET /api/health` (version check), `GET /api/playlists/status` (flows, the worker's progress),
///   `GET /api/playlists/jobs` (each flow song), `GET /api/library/lookup/:mbid`, `POST /api/playlists/start/:flowId`
///   (Refresh Flow, only on the owner's tap), `POST /api/auth/login` and `POST /api/auth/logout`.
/// - Round 14 reads (Aurral 2.13): `GET /api/health/bootstrap` (features, permissions, download sources),
///   `GET /api/auth/me`, `GET /api/discover` (Recommended), `GET /api/discover/trending` and `.../genres/:id`,
///   `GET /api/discover/editorial`, `.../editorial/links` and `.../editorial/:id`, `GET /api/artists/:mbid/preview`,
///   `GET /api/artists/release-group/:mbid/tracks`, `GET /api/search` and `GET /api/search/unified`,
///   `GET /api/playlists/jobs/:playlistId`, and `GET /api/deezer/preview/<id>.mp3?download` (open: only
///   `PreviewResolver` sends it, never with the token; A7: Aurral sends the clip itself, never a redirect).
/// - Round 14 writes, each only on the owner's tap: `POST /api/discover/editorial/:id/library` (Add flow),
///   `POST /api/discover/feedback` (Not for me), `POST /api/playlists/flows/:flowId/download` (Download songs) and
///   `POST /api/playlists/shared-playlists/:playlistId/tracks/:jobId/research` (Retry a song).
/// Never `/api/settings` (every secret in clear), `/api/auth/api-key`, `/api/users`, `/api/discover/refresh` (admin),
/// `/api/discover/blocked-tags`, `/api/library/artists` or `/api/library/downloads/*` (adds go through Lidarr), or
/// `DELETE /api/library/tracks/*` (deletes Lidarr's file).
public enum AurralRoute: CaseIterable, Sendable {
    case health, playlistsStatus, playlistsJobs, libraryLookup, startFlow, login, logout
    case bootstrap, authMe, recommendations, trending, trendingGenre, editorialShelf, editorialLinks, editorialPlaylist
    case editorialAdd, discoverFeedback, artistPreview, releaseGroupTracks, search, searchUnified, playlistJobsById
    case flowDownload, trackResearch, deezerPreview

    var method: String {
        switch self {
        case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"
        case .startFlow: Self.startMethod
        case .login, .logout: Self.sessionMethod
        case .bootstrap, .authMe, .recommendations, .trending, .trendingGenre, .editorialShelf, .editorialLinks,
             .editorialPlaylist, .artistPreview, .releaseGroupTracks, .search, .searchUnified, .playlistJobsById,
             .deezerPreview: "GET"
        case .editorialAdd, .discoverFeedback, .flowDownload, .trackResearch: Self.discoverWriteMethod
        }
    }

    /// Whether the call carries the session token (`/api/health` is public; the login has nothing to carry yet; the
    /// preview is open, and asked with `?download` only: A7).
    var isAuthorised: Bool {
        switch self {
        case .health, .login, .deezerPreview: false
        default: true
        }
    }

    /// The only query names the route may carry (round 14): anything else is refused.
    public var queryNames: [String] {
        switch self {
        case .recommendations: ["limit", "offset"]
        case .search: ["q", "scope", "limit", "offset"]
        case .searchUnified: ["q", "mode", "limit"]
        case .editorialLinks: ["artist", "album", "albumId"]
        case .artistPreview: ["artistName"]
        case .releaseGroupTracks: ["artistMbid", "artistName", "albumTitle", "deezerAlbumId"]
        case .deezerPreview: ["download"]
        default: []
        }
    }

    // G1 allowlist: aurral start flow (Refresh Flow, the one write Magpie sends to Aurral's data).
    static let startMethod = "POST"
    // G1 allowlist: aurral session (round 13: the login and logout, which change only Aurral's own sessions).
    static let sessionMethod = "POST"
    // G1 allowlist: aurral discover writes (round 14: Add flow, Not for me, Download songs, Retry a song).
    static let discoverWriteMethod = "POST"

    /// Plain ids only: letters, digits, `-` and `_` (an id with anything else would name another route).
    static func isPlainId(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// 1 to `max` ASCII digits (Deezer ids, Aurral's genre ids).
    static func isDigits(_ s: Substring, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// A MusicBrainz id, as Aurral checks it.
    static func isMBID(_ s: Substring) -> Bool { MBID(String(s)) != nil && UUID(uuidString: String(s)) != nil }

    /// `<deezer track id>.mp3`, as Aurral's preview route takes it.
    static func isPreviewFile(_ s: Substring) -> Bool {
        s.hasSuffix(".mp3") && isDigits(s.dropLast(4), max: 20)
    }

    /// The route `method path` is, if it is an allowed one; `path` is relative to the Aurral base, exactly as sent
    /// (no leading slash, no query, no encoding).
    static func route(method: String, path: String) -> AurralRoute? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), parts[0] == "api" else { return nil }
        let rest = Array(parts.dropFirst())
        let route: AurralRoute? = switch rest.count {
        case 1 where rest[0] == "health": .health
        case 2 where rest == ["playlists", "status"]: .playlistsStatus
        case 2 where rest == ["playlists", "jobs"]: .playlistsJobs
        case 3 where rest[0] == "library" && rest[1] == "lookup" && MBID(String(rest[2])) != nil
            && UUID(uuidString: String(rest[2])) != nil: .libraryLookup
        case 3 where rest[0] == "playlists" && rest[1] == "start" && isPlainId(rest[2]): .startFlow
        case 2 where rest == ["auth", "login"]: .login
        case 2 where rest == ["auth", "logout"]: .logout
        case 2 where rest == ["health", "bootstrap"]: .bootstrap
        case 2 where rest == ["auth", "me"]: .authMe
        case 1 where rest[0] == "discover": .recommendations
        case 2 where rest == ["discover", "trending"]: .trending
        case 4 where rest[0] == "discover" && rest[1] == "trending" && rest[2] == "genres" && isDigits(rest[3], max: 6): .trendingGenre
        case 2 where rest == ["discover", "editorial"]: .editorialShelf
        case 3 where rest == ["discover", "editorial", "links"]: .editorialLinks
        case 3 where rest[0] == "discover" && rest[1] == "editorial" && isDigits(rest[2], max: 20): .editorialPlaylist
        case 4 where rest[0] == "discover" && rest[1] == "editorial" && isDigits(rest[2], max: 20) && rest[3] == "library": .editorialAdd
        case 2 where rest == ["discover", "feedback"]: .discoverFeedback
        case 3 where rest[0] == "artists" && isMBID(rest[1]) && rest[2] == "preview": .artistPreview
        case 4 where rest[0] == "artists" && rest[1] == "release-group" && isMBID(rest[2]) && rest[3] == "tracks": .releaseGroupTracks
        case 1 where rest[0] == "search": .search
        case 2 where rest == ["search", "unified"]: .searchUnified
        case 3 where rest[0] == "playlists" && rest[1] == "jobs" && isPlainId(rest[2]): .playlistJobsById
        case 4 where rest[0] == "playlists" && rest[1] == "flows" && isPlainId(rest[2]) && rest[3] == "download": .flowDownload
        case 6 where rest[0] == "playlists" && rest[1] == "shared-playlists" && isPlainId(rest[2]) && rest[3] == "tracks"
            && isPlainId(rest[4]) && rest[5] == "research": .trackResearch
        case 3 where rest[0] == "deezer" && rest[1] == "preview" && isPreviewFile(rest[2]): .deezerPreview
        default: nil
        }
        guard let route, route.method == method else { return nil }
        return route
    }

    public static func isAllowed(method: String, path: String) -> Bool { route(method: method, path: path) != nil }

    /// The call is allowed with exactly these query names (each at most once, each one the route takes).
    static func isAllowed(method: String, path: String, query: [URLQueryItem]) -> Bool {
        guard let route = route(method: method, path: path) else { return false }
        let names = query.map(\.name)
        return Set(names).count == names.count && names.allSatisfy(route.queryNames.contains)
    }
}

/// Aurral's JSON API (`<base>/api`), limited to `AurralRoute`'s calls, signed in as a user (round 13: Aurral's
/// playlists are per user; the API key is gone). The session token is sent only as `Authorization: Bearer` (never in a
/// URL), logged only redacted, and hidden from the client's description; a 401 logs in again once through the
/// `AurralSession` (with the saved password) and sends the call again.
public struct AurralClient: Sendable, CustomDebugStringConvertible, CustomReflectable {
    public let base: URL
    private let session: AurralSession
    private let transport: HTTPTransport
    private let log: @Sendable (String) -> Void

    /// `log` receives each request's sanitised line (tests); by default the "aurral" logger, at debug level.
    public init(base: URL, session: AurralSession, transport: HTTPTransport, log: (@Sendable (String) -> Void)? = nil) {
        self.base = base
        self.session = session
        self.transport = transport
        self.log = log ?? Self.defaultLog
    }

    static let defaultLog: @Sendable (String) -> Void = { line in Log.logger("aurral").debug("\(line, privacy: .public)") }

    public var debugDescription: String { "AurralClient(\(Redactor.sanitize(base)))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": Redactor.sanitize(base)]) }

    // MARK: - Signing in (round 13)

    /// Logs in as `username` (`POST /api/auth/login`, the password only in the JSON body). Throws `badLogin` for a
    /// wrong username or password, `rateLimited` after too many tries.
    public static func signIn(base: URL, username: String, password: String, transport: HTTPTransport,
                              log: (@Sendable (String) -> Void)? = nil) async throws -> AurralLogin {
        try await logIn(base: base, username: username, password: password, transport: transport, log: log ?? defaultLog)
    }

    private static func logIn(base: URL, username: String, password: String, transport: HTTPTransport,
                              log: @escaping @Sendable (String) -> Void) async throws -> AurralLogin {
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await send(base: base, method: AurralRoute.sessionMethod, path: "api/auth/login",
                                              token: nil, body: body, transport: transport, log: log)
        switch response.statusCode {
        case 200..<300: return try AurralLogin.decode(data)
        case 400, 401, 403: throw AurralError.badLogin
        case 429: throw AurralError.rateLimited
        case 404: throw AurralError.notFound
        default: throw AurralError.http(status: response.statusCode)
        }
    }

    /// Ends the session in Aurral (`POST /api/auth/logout`). Never logs in again for it: a session Aurral already
    /// forgot is as good as ended.
    public func logout() async throws {
        guard let token = await session.currentToken else { return }
        let (_, response) = try await send(method: AurralRoute.sessionMethod, path: "api/auth/logout", token: token)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 401 else {
            throw AurralError.http(status: response.statusCode)
        }
    }

    // MARK: - The calls

    /// Aurral's version (`appVersion`) and how it compares with 2.10.0, which this is built for. Public on 2.10: sent
    /// without the token.
    public func health() async throws -> AurralHealth {
        AurralHealth.decode(try await ok(method: "GET", path: "api/health"))
    }

    /// The flows and the worker's progress, kept to the signed-in user's flows (Aurral shows an admin everyone's).
    public func status() async throws -> AurralStatus {
        let status = try AurralStatus.decode(try await ok(method: "GET", path: "api/playlists/status"))
        return status.scoped(to: await session.user)   // Z1 fix M3: no user, no flows
    }

    /// Every flow song Aurral knows. Nil when this Aurral has no such route (404): tolerated.
    public func jobs() async throws -> [AurralJob]? {
        do { return try AurralJob.decodeList(try await ok(method: "GET", path: "api/playlists/jobs")) }
        catch AurralError.notFound { return nil }
    }

    /// Whether Aurral's own library has the artist. A missing route reads as "not there".
    public func artistLookup(mbid: MBID) async throws -> AurralArtistLookup? {
        do { return AurralArtistLookup.decode(try await ok(method: "GET", path: "api/library/lookup/" + mbid.rawValue)) }
        catch AurralError.notFound { return AurralArtistLookup(exists: false) }
    }

    /// Refresh Flow: Aurral regenerates the flow and replaces its songs. Only on the owner's confirmed tap; the caller
    /// checks no run is active first (`AurralStatus.isRunActive`).
    public func startFlow(_ flowId: String) async throws -> AurralStartResult {
        guard AurralRoute.isPlainId(Substring(flowId)) else { throw AurralError.forbidden("start \(flowId.count) chars") }
        let body = Data("{}".utf8)
        return AurralStartResult.decode(try await ok(method: AurralRoute.startMethod, path: "api/playlists/start/" + flowId,
                                                     body: body))
    }

    // MARK: - Plumbing (the one place a request is built)

    /// Sends the call with the session's token; on a 401, logs in again once (shared with any other call that met
    /// it) and sends it again.
    func ok(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let authorised = AurralRoute.route(method: method, path: path)?.isAuthorised ?? true
        let logIn: @Sendable (String, String) async throws -> AurralLogin = { [base, transport, log] username, password in
            try await Self.logIn(base: base, username: username, password: password, transport: transport, log: log)
        }
        let token = authorised ? try await session.token(logIn: logIn) : nil
        var (data, response) = try await send(method: method, path: path, query: query, token: token, body: body)
        if authorised, response.statusCode == 401 {
            let fresh = try await session.renew(after: token, logIn: logIn)
            (data, response) = try await send(method: method, path: path, query: query, token: fresh, body: body)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw AurralError.unauthorized
        case 403: throw AurralError.notPermitted
        case 404: throw AurralError.notFound
        default: throw AurralError.http(status: response.statusCode)
        }
    }

    /// Sends `method path` only when it is one of `AurralRoute`'s calls, with only the query names that route takes;
    /// anything else is refused before a request is even built.
    func send(method: String, path: String, query: [URLQueryItem] = [], token: String? = nil,
              body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await Self.send(base: base, method: method, path: path, query: query, token: token, body: body,
                            transport: transport, log: log)
    }

    private static func send(base: URL, method: String, path: String, query: [URLQueryItem] = [], token: String?,
                             body: Data?, transport: HTTPTransport,
                             log: @Sendable (String) -> Void) async throws -> (Data, HTTPURLResponse) {
        guard AurralRoute.isAllowed(method: method, path: path),
              AurralRoute.isAllowed(method: method, path: path, query: query),
              let url = ServerEndpoint(bases: [base]).url(base, path: path, query: query)
        else { throw AurralError.forbidden("\(method) \(path)") }
        var request = URLRequest(url: url)
        // G1 allowlist: aurral start flow, aurral session, aurral discover writes. The verb is GET, or POST for the
        // start, login, logout and round-14 write routes only (checked just above).
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        log(Log.describe(request))
        return try await transport.send(request)
    }
}
