import Foundation
import MagpieCore

/// Why an Aurral call didn't go through.
public enum AurralError: Error, Sendable, Equatable {
    /// Not one of the five allowed calls: refused in code, nothing sent.
    case forbidden(String)
    /// The key was refused (401/403).
    case unauthorized
    /// The route or the flow isn't there (404).
    case notFound
    /// Another HTTP status.
    case http(status: Int)
    /// The answer isn't Aurral's JSON.
    case decoding
    /// Refresh Flow while a run is under way: refused, nothing sent.
    case runActive
}

/// Round 12 Y6: the only calls Magpie may send to Aurral (plan item 7). Aurral's API key is full admin, so everything
/// else is refused in code (`AurralClient.send`) and `scripts/check-writes.sh` pins the one write:
/// - `GET /api/health` (version check),
/// - `GET /api/playlists/status` (flows, the worker's progress),
/// - `GET /api/playlists/jobs` (each flow song's artist and recording ids, and Aurral's file paths),
/// - `GET /api/library/lookup/:mbid`,
/// - `POST /api/playlists/start/:flowId` (Refresh Flow, only on the owner's tap, refused while a run is active).
/// Never `/api/settings` (every secret in clear), `/api/auth/api-key` (reads or creates the key), `GET /api/discover`
/// (starts a refresh), or `DELETE /api/library/tracks/*` (deletes Lidarr's file).
public enum AurralRoute: CaseIterable, Sendable {
    case health, playlistsStatus, playlistsJobs, libraryLookup, startFlow

    var method: String {
        switch self {
        case .health, .playlistsStatus, .playlistsJobs, .libraryLookup: "GET"
        case .startFlow: Self.startMethod
        }
    }

    // G1 allowlist: aurral start flow (Refresh Flow, the one write Magpie sends to Aurral).
    static let startMethod = "POST"

    /// Plain ids only: letters, digits, `-` and `_` (an id with anything else would name another route).
    static func isPlainId(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The route `method path` is, if it is one of the five; `path` is relative to the Aurral base, exactly as sent
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
        default: nil
        }
        guard let route, route.method == method else { return nil }
        return route
    }

    public static func isAllowed(method: String, path: String) -> Bool { route(method: method, path: path) != nil }
}

/// Aurral's JSON API (`<base>/api`, header `X-Api-Key`), limited to `AurralRoute`'s five calls. The key is sent only in
/// the header (never in a URL), logged only redacted, and hidden from the client's description.
public struct AurralClient: Sendable, CustomDebugStringConvertible, CustomReflectable {
    private let endpoint: ServerEndpoint
    public let base: URL
    private let apiKey: String
    private let transport: HTTPTransport
    private let log: @Sendable (String) -> Void

    /// `log` receives each request's sanitised line (tests); by default the "aurral" logger, at debug level.
    public init(base: URL, apiKey: String, transport: HTTPTransport, log: (@Sendable (String) -> Void)? = nil) {
        self.endpoint = ServerEndpoint(bases: [base])
        self.base = base
        self.apiKey = apiKey
        self.transport = transport
        self.log = log ?? { line in Log.logger("aurral").debug("\(line, privacy: .public)") }
    }

    public var debugDescription: String { "AurralClient(\(Redactor.sanitize(base)))" }
    public var customMirror: Mirror { Mirror(self, children: ["base": Redactor.sanitize(base)]) }

    // MARK: - The five calls

    /// Aurral's version (`appVersion`) and how it compares with 2.10.0, which this is built for. Answers without the
    /// key on 2.10, so a 401 on the next call is what says the key is wrong.
    public func health() async throws -> AurralHealth {
        AurralHealth.decode(try await ok(method: "GET", path: "api/health"))
    }

    public func status() async throws -> AurralStatus {
        try AurralStatus.decode(try await ok(method: "GET", path: "api/playlists/status"))
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

    private func ok(method: String, path: String, body: Data? = nil) async throws -> Data {
        let (data, response) = try await send(method: method, path: path, body: body)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw AurralError.unauthorized
        case 404: throw AurralError.notFound
        default: throw AurralError.http(status: response.statusCode)
        }
    }

    /// Sends `method path` only when it is one of `AurralRoute`'s five; anything else is refused before a request is
    /// even built.
    func send(method: String, path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard AurralRoute.isAllowed(method: method, path: path),
              let url = endpoint.url(base, path: path) else { throw AurralError.forbidden("\(method) \(path)") }
        var request = URLRequest(url: url)
        // G1 allowlist: aurral start flow. The verb is GET, or POST for the start route only (checked just above).
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        log(Log.describe(request))
        return try await transport.send(request)
    }
}
