import Foundation
import MagpieCore

// G1: every Lidarr write goes through `LidarrWriteGate`. The HTTP channel to Lidarr (`LidarrConnection`) is
// defined in this file so that `fileprivate` confines non-GET requests to the gate: `LidarrClient` holds a
// connection but can only call `get`.

/// The one HTTP channel to a Lidarr server.
struct LidarrConnection: Sendable {
    fileprivate let endpoint: ServerEndpoint
    fileprivate let base: URL
    fileprivate let apiKey: String
    fileprivate let transport: HTTPTransport

    init(base: URL, apiKey: String, transport: HTTPTransport) {
        self.endpoint = ServerEndpoint(bases: [base])
        self.base = base
        self.apiKey = apiKey
        self.transport = transport
    }

    /// A GET under `api/v1/`. Reads only.
    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try await send("GET", path: path, query: query, body: nil)
    }

    fileprivate func send(_ method: String, path: String, query: [URLQueryItem], body: Data?) async throws
        -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(base, path: "api/v1/" + path, query: query))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        Log.request(request, category: "lidarr")
        return try await transport.send(request)
    }
}

// MARK: - Errors and the change log

public enum WriteGateError: Error, Sendable, Equatable {
    /// "Allow Magpie to change Lidarr" is off (G1).
    case disabled
    /// The call is on the never-call list (G3, G5); it was not sent.
    case forbidden(String)
    /// Not a write Magpie can express safely (method other than POST/PUT/DELETE, `..`, a full URL…).
    case invalidRequest(String)
    /// The change log could not be saved, so the write was not sent (the log is the owner's undo map).
    case logUnavailable
}

/// One line of the Lidarr change log: what Magpie asked Lidarr to change. Never carries secrets.
public struct ChangeLogEntry: Sendable, Equatable, Codable {
    public var date: Date
    public var method: String
    /// `/api/v1/…` with the query string; no host, secret query values masked.
    public var path: String
    /// Compact JSON of the request body with secret fields masked, at most `LidarrWriteGate.maxBodySummary` characters.
    public var bodySummary: String
    /// HTTP status of the answer; nil while in flight or when no answer came.
    public var status: Int?

    public init(date: Date, method: String, path: String, bodySummary: String, status: Int? = nil) {
        self.date = date; self.method = method; self.path = path; self.bodySummary = bodySummary; self.status = status
    }
}

// MARK: - Request normalisation and the never-call list

/// A write request reduced to the form Lidarr's router sees: upper-case method, fully percent-decoded path
/// segments (empty segments dropped, `api`/`api/vN` prefix removed) and decoded query items. The refusal
/// checks and the request that is sent are both built from this one value, so they cannot disagree.
struct WriteTarget: Equatable {
    let method: String
    /// Original case, for sending.
    let segments: [String]
    let query: [URLQueryItem]
    /// Lower-cased segments, for matching (Lidarr routes are case-insensitive).
    var key: [String] { segments.map { $0.lowercased() } }

    static let writeMethods: Set<String> = ["POST", "PUT", "DELETE"]

    init(method rawMethod: String, path rawPath: String) throws {
        let method = rawMethod.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.writeMethods.contains(method) else { throw WriteGateError.invalidRequest("method \(rawMethod)") }
        let text = rawPath.trimmingCharacters(in: .whitespaces)
        guard !text.contains("#"), !text.contains("\\"), !text.contains("://") else {
            throw WriteGateError.invalidRequest("path")
        }
        let parts = text.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)

        // Path: decode (repeatedly, so `%252F` cannot hide a separator), then split on `/`.
        let decodedPath = try Self.fullyDecoded(parts[0])
        var segments = decodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for s in segments {
            let unsafe = s == "." || s == ".." || s.contains(";")
                || s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "?" }
            if unsafe { throw WriteGateError.invalidRequest("path segment") }
        }
        if segments.first?.lowercased() == "api" {
            segments.removeFirst()
            if let v = segments.first?.lowercased(), v.count > 1, v.hasPrefix("v"), v.dropFirst().allSatisfy(\.isNumber) {
                segments.removeFirst()
            }
        }
        guard !segments.isEmpty else { throw WriteGateError.invalidRequest("empty path") }

        // Query: `&` or `;` separated, `+` is a space, names and values fully decoded.
        var items: [URLQueryItem] = []
        if parts.count > 1 {
            for pair in parts[1].split(whereSeparator: { $0 == "&" || $0 == ";" }) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let name = try Self.fullyDecoded(kv[0].replacingOccurrences(of: "+", with: " "))
                let value = try kv.count > 1 ? Self.fullyDecoded(kv[1].replacingOccurrences(of: "+", with: " ")) : nil
                guard !name.isEmpty else { continue }
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        self.method = method
        self.segments = segments
        self.query = items
    }

    private static func fullyDecoded(_ s: String) throws -> String {
        var current = s
        for _ in 0..<8 {
            guard let next = current.removingPercentEncoding else { throw WriteGateError.invalidRequest("encoding") }
            if next == current { return next }
            current = next
        }
        throw WriteGateError.invalidRequest("encoding")
    }

    /// `/api/v1/…?…` for the change log, with secret query values masked.
    var logPath: String {
        let path = "/api/v1/" + segments.joined(separator: "/")
        guard !query.isEmpty else { return path }
        return path + "?" + query.map { item in
            guard let value = item.value else { return item.name }
            return item.name + "=" + (BodySummary.isSecret(item.name) ? Redactor.mask : value)
        }.joined(separator: "&")
    }
}

/// The never-call list (G3, G5, brief ruling 2). Checked on the normalised `WriteTarget` and the body.
enum ForbiddenWrites {
    /// Owner configuration resources Magpie never writes to, by any method (G5).
    static let ownerResources: Set<String> = [
        "rootfolder", "indexer", "downloadclient", "notification", "importlist", "importlistexclusion", "system",
    ]
    /// Profiles may only be created (`POST /qualityprofile`), never changed or deleted (G5).
    static let createOnlyResources: Set<String> = ["qualityprofile", "metadataprofile"]
    /// Query/body flags that must be absent or exactly `false`.
    static let falseOnlyFlags: Set<String> = ["deletefiles", "addimportlistexclusion"]
    /// `POST /command` names Magpie may start. Anything else (rename, retag, backup, reset API key…) is refused.
    static let allowedCommands: Set<String> = ["albumsearch", "artistsearch", "refreshartist", "refreshalbum"]

    /// Why the request is refused, or nil when it may be sent.
    static func reason(_ t: WriteTarget, body: Data?) -> String? {
        let key = t.key
        let resource = key[0]

        if resource == "config" { return "owner configuration (\(key.joined(separator: "/")))" }
        if ownerResources.contains(resource) { return "owner configuration (\(resource))" }
        if createOnlyResources.contains(resource), !(t.method == "POST" && key.count == 1) {
            return "\(resource) can only be created"
        }
        if resource == "missing" || (resource == "wanted" && key.count > 1 && key[1] == "missing") {
            return "missing-files cleanup"
        }
        if t.method == "DELETE", resource == "artist", key.count > 1, key[1] == "editor" {
            return "bulk artist delete"
        }
        for item in t.query where falseOnlyFlags.contains(item.name.lowercased().trimmingCharacters(in: .whitespaces)) {
            if !isFalse(item.value) { return "\(item.name) must be false" }
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        if let json, let flag = truthyFlag(in: json) { return "\(flag) must be false" }
        if resource == "command", t.method == "POST" {
            guard key.count == 1, let name = (json as? [String: Any])?.first(where: { $0.key.lowercased() == "name" })?.value as? String,
                  allowedCommands.contains(name.lowercased()) else { return "command not allowed" }
        }
        return nil
    }

    private static func isFalse(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespaces).lowercased() == "false"
    }

    /// A `deleteFiles` / `addImportListExclusion` anywhere in the body that is not false.
    private static func truthyFlag(in value: Any) -> String? {
        switch value {
        case let d as [String: Any]:
            for (k, v) in d {
                if falseOnlyFlags.contains(k.lowercased()) {
                    let isFalse: Bool = switch v {
                    case let b as Bool: !b
                    case let s as String: Self.isFalse(s)
                    case is NSNull: true
                    default: false
                    }
                    if !isFalse { return k }
                }
                if let inner = truthyFlag(in: v) { return inner }
            }
            return nil
        case let a as [Any]:
            return a.lazy.compactMap(truthyFlag).first
        default:
            return nil
        }
    }
}

/// Body text for the change log: compact JSON, secret-looking fields masked, length capped.
enum BodySummary {
    static let secretFragments = ["apikey", "api_key", "token", "password", "passwd", "secret", "authorization",
                                  "passphrase", "cookie"]

    static func isSecret(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretFragments.contains { n.contains($0) }
    }

    static func make(_ body: Data?, apiKey: String, limit: Int) -> String {
        guard let body, !body.isEmpty else { return "" }
        var text: String
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
           let data = try? JSONSerialization.data(withJSONObject: masked(json),
                                                  options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "<\(body.count) bytes, not JSON>"
        }
        if !apiKey.isEmpty { text = text.replacingOccurrences(of: apiKey, with: Redactor.mask) }
        if text.count > limit { text = String(text.prefix(limit - 1)) + "…" }
        return text
    }

    private static func masked(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            d.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = isSecret(pair.key) ? Redactor.mask : masked(pair.value)
            }
        case let a as [Any]: a.map(masked)
        default: value
        }
    }
}

// MARK: - The gate

/// The only way Magpie changes Lidarr (G1). Off until the owner turns on "Allow Magpie to change Lidarr";
/// refuses the never-call list; logs every write (method, path, body without secrets) before sending it.
public actor LidarrWriteGate {
    public static let enabledDefaultsKey = "magpie.lidarr.writesEnabled"
    public static let maxBodySummary = 1_000
    /// Oldest entries are dropped beyond this.
    public static let maxLogEntries = 5_000

    /// Where the change log lives by default: `Application Support/Magpie/lidarr-change-log.json`.
    public static func defaultLogURL(in directory: URL = URL.applicationSupportDirectory) -> URL {
        LocalFile.url("lidarr-change-log.json", in: directory)
    }

    private let connection: LidarrConnection
    private let logURL: URL
    private let defaults: UserDefaults
    private var log: [ChangeLogEntry]
    private let now: @Sendable () -> Date

    /// The "Allow Magpie to change Lidarr" switch. Persisted; false until the owner turns it on.
    public private(set) var enabled: Bool

    /// `defaultsSuite` names the UserDefaults suite holding the switch (nil: standard defaults; tests pass their own).
    public init(client: LidarrClient, logURL: URL, defaultsSuite: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.connection = client.connection
        self.logURL = logURL
        self.defaults = defaults
        self.now = now
        self.enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        self.log = LocalFile.load([ChangeLogEntry].self, from: logURL, fallback: [], category: "lidarr")
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledDefaultsKey)
    }

    public func changeLog() -> [ChangeLogEntry] { log }

    /// Sends one write. `path` is relative to the API root (`artist/12?deleteFiles=false`; a leading
    /// `/api/v1/` is accepted). Returns the response body on 2xx.
    public func send(_ method: String, _ path: String, body: (any Encodable & Sendable)?) async throws -> Data {
        let target = try WriteTarget(method: method, path: path)
        let data = try body.map { try JSONEncoder().encode($0) }
        if let why = ForbiddenWrites.reason(target, body: data) {
            Log.logger("lidarr").error("refused \(target.method, privacy: .public) \(target.logPath, privacy: .public): \(why, privacy: .public)")
            throw WriteGateError.forbidden(why)
        }
        guard enabled else { throw WriteGateError.disabled }

        let entry = ChangeLogEntry(date: now(), method: target.method, path: target.logPath,
                                   bodySummary: BodySummary.make(data, apiKey: connection.apiKey, limit: Self.maxBodySummary))
        var next = log + [entry]
        if next.count > Self.maxLogEntries { next.removeFirst(next.count - Self.maxLogEntries) }
        do { try LocalFile.save(next, to: logURL) } catch { throw WriteGateError.logUnavailable }
        log = next

        let (responseData, response) = try await connection.send(
            target.method, path: target.segments.joined(separator: "/"), query: target.query, body: data)
        // Other writes may have been appended (or old entries trimmed) meanwhile: find ours again.
        if let index = log.lastIndex(of: entry) {
            log[index].status = response.statusCode
            try? LocalFile.save(log, to: logURL)
        }
        switch response.statusCode {
        case 200..<300: return responseData
        case 401, 403: throw LidarrError.unauthorized
        default: throw LidarrError.http(status: response.statusCode)
        }
    }
}
