import Foundation
import MagpieCore

/// Why an Aurral call didn't go through.
public enum AurralError: Error, Sendable, Equatable {
    /// Not one of the seven allowed calls: refused in code, nothing sent.
    case forbidden(String)
    /// Refused (403, or a 401 a fresh login didn't cure).
    case unauthorized
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
}

/// Round 12 Y6: the only calls Magpie may send to Aurral (plan item 7); everything else is refused in code
/// (`AurralClient.send`) and `scripts/check-writes.sh` pins the routes and the writes:
/// - `GET /api/health` (version check),
/// - `GET /api/playlists/status` (flows, the worker's progress),
/// - `GET /api/playlists/jobs` (each flow song's artist and recording ids, and Aurral's file paths),
/// - `GET /api/library/lookup/:mbid`,
/// - `POST /api/playlists/start/:flowId` (Refresh Flow, only on the owner's tap, refused while a run is active),
/// - round 13: `POST /api/auth/login` (username and password → a session token) and `POST /api/auth/logout` (Settings'
///   Sign out, and Magpie's own sign-out).
/// Never `/api/settings` (every secret in clear), `/api/auth/api-key` (reads or creates the key), `GET /api/discover`
/// (starts a refresh), or `DELETE /api/library/tracks/*` (deletes Lidarr's file).
public enum AurralRoute: CaseIterable, Sendable {
    case health, playlistsStatus, playlistsJobs, libraryLookup, startFlow, login, logout

    var method: String {
        switch self {
        case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"
        case .startFlow: Self.startMethod
        case .login, .logout: Self.sessionMethod
        }
    }

    /// Whether the call carries the session token (`/api/health` is public; the login has nothing to carry yet).
    var isAuthorised: Bool {
        switch self {
        case .health, .login: false
        case .playlistsStatus, .playlistsJobs, .libraryLookup, .startFlow, .logout: true
        }
    }

    // G1 allowlist: aurral start flow (Refresh Flow, the one write Magpie sends to Aurral's data).
    static let startMethod = "POST"
    // G1 allowlist: aurral session (round 13: the login and logout, which change only Aurral's own sessions).
    static let sessionMethod = "POST"

    /// Plain ids only: letters, digits, `-` and `_` (an id with anything else would name another route).
    static func isPlainId(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The route `method path` is, if it is one of the seven; `path` is relative to the Aurral base, exactly as sent
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
        default: nil
        }
        guard let route, route.method == method else { return nil }
        return route
    }

    public static func isAllowed(method: String, path: String) -> Bool { route(method: method, path: path) != nil }
}

/// Aurral's JSON API (`<base>/api`), limited to `AurralRoute`'s seven calls, signed in as a user (round 13: Aurral's
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
    private func ok(method: String, path: String, body: Data? = nil) async throws -> Data {
        let authorised = AurralRoute.route(method: method, path: path)?.isAuthorised ?? true
        let logIn: @Sendable (String, String) async throws -> AurralLogin = { [base, transport, log] username, password in
            try await Self.logIn(base: base, username: username, password: password, transport: transport, log: log)
        }
        let token = authorised ? try await session.token(logIn: logIn) : nil
        var (data, response) = try await send(method: method, path: path, token: token, body: body)
        if authorised, response.statusCode == 401 {
            let fresh = try await session.renew(after: token, logIn: logIn)
            (data, response) = try await send(method: method, path: path, token: fresh, body: body)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw AurralError.unauthorized
        case 404: throw AurralError.notFound
        default: throw AurralError.http(status: response.statusCode)
        }
    }

    /// Sends `method path` only when it is one of `AurralRoute`'s seven; anything else is refused before a request is
    /// even built.
    func send(method: String, path: String, token: String? = nil, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await Self.send(base: base, method: method, path: path, token: token, body: body, transport: transport, log: log)
    }

    private static func send(base: URL, method: String, path: String, token: String?, body: Data?, transport: HTTPTransport,
                             log: @Sendable (String) -> Void) async throws -> (Data, HTTPURLResponse) {
        guard AurralRoute.isAllowed(method: method, path: path),
              let url = ServerEndpoint(bases: [base]).url(base, path: path) else { throw AurralError.forbidden("\(method) \(path)") }
        var request = URLRequest(url: url)
        // G1 allowlist: aurral start flow, aurral session. The verb is GET, or POST for the start, login and logout
        // routes only (checked just above).
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
