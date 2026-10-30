import CryptoKit
import Foundation
import MagpieCore
import os

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

    /// Hash of the address and API key (`LidarrClient.instanceScope`); the key itself never leaves this type.
    var instanceScope: String {
        var text = base.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        let digest = SHA256.hash(data: Data("\(text)|\(apiKey)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A GET under `api/v1/`. Reads only.
    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try await send("GET", path: path, query: query, body: nil)
    }

    fileprivate func send(_ method: String, path: String, query: [URLQueryItem], body: Data?) async throws
        -> (Data, HTTPURLResponse) {
        guard let url = endpoint.url(base, path: "api/v1/" + path, query: query) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
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
    /// The call is on the never-call list or not on the allow list (G3, G5); it was not sent.
    case forbidden(String)
    /// Not a write Magpie can express safely (method other than POST/PUT/DELETE, `..`, a full URL…).
    case invalidRequest(String)
    /// The change log could not be saved, so the write was not sent (the log is the owner's undo map).
    case logUnavailable
    /// A delete or move the gate confines (FM1, `WriteConfinement`) couldn't be checked: the ledger or Lidarr
    /// couldn't be read right now. It was not sent.
    case unconfirmed
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
/// segments (empty segments dropped, a leading `api/v1` removed) and decoded query items. The refusal
/// checks and the request that is sent are both built from this one value, so they cannot disagree.
struct WriteTarget: Equatable {
    let method: String
    /// Original case, for sending.
    let segments: [String]
    let query: [URLQueryItem]
    /// The path began with `api` but not `api/v1` (e.g. `/api/missing`): never sent (the gate only writes
    /// under `<base>/api/v1/`).
    let foreignPrefix: Bool
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
                || s.unicodeScalars.contains { !$0.isASCII || CharacterSet.controlCharacters.contains($0) || $0 == "?" }
            if unsafe { throw WriteGateError.invalidRequest("path segment") }
        }
        var foreignPrefix = false
        if segments.first?.lowercased() == "api" {
            if segments.count > 1, segments[1].lowercased() == "v1" { segments.removeFirst(2) } else { foreignPrefix = true }
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
                guard name.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
                    throw WriteGateError.invalidRequest("query name")
                }
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        self.method = method
        self.foreignPrefix = foreignPrefix
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

/// Which writes the gate lets through (G1, G3, G5, fix-round ruling 1). Two layers:
/// 1. the never-call list, checked first as defence in depth;
/// 2. an allow list of request shapes. Anything not on it is refused.
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
    /// `applyTags` values allowed in `PUT /artist/editor` (`replace` would wipe the owner's tags, A4).
    static let allowedApplyTags: Set<String> = ["add", "remove"]
    /// `monitorNewItems` values allowed in `PUT /artist/editor` (Follow new releases, Task 7.1b): only `new`. Never
    /// `none` (Magpie only ever adds; it doesn't stop following anything) and never `all` (that would also monitor
    /// old albums Lidarr's next refresh discovers).
    static let allowedMonitorNewItems: Set<String> = ["new"]

    /// Why the request is refused, or nil when it may be sent.
    static func reason(_ t: WriteTarget, body: Data?) -> String? {
        if t.foreignPrefix { return "not under /api/v1" }
        // Checked on the exact bytes that will be sent, before anything reads the body as a dictionary.
        if let body, let why = JSONKeyScan.problem(in: body) { return why }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        if body != nil, json == nil { return "body is not JSON" }
        if let why = neverCall(t, json: json) { return why }
        return allowListed(t, json: json)
    }

    // MARK: Layer 1: the never-call list

    static func neverCall(_ t: WriteTarget, json: Any?) -> String? {
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
        if let json, let flag = truthyFlag(in: json) { return "\(flag) must be false" }
        return nil
    }

    /// FM1: the allow-listed writes that can delete, move or change an artist, which the gate's confinement must
    /// also pass (`WriteConfinement`). Nil for every other write.
    static func confined(_ t: WriteTarget, json: Any?) -> WriteConfinement.Write? {
        let key = t.key
        guard key.count == 2 else { return nil }
        switch (t.method, key[0]) {
        case ("PUT", "artist") where key[1] == "editor":
            return .editor(json as? [String: Any] ?? [:])
        case ("DELETE", "artist"):
            return Int(key[1]).map { .artistDelete($0) } ?? .trackFileDelete([])
        case ("DELETE", "trackfile"):
            if key[1] == "bulk" {
                let ids = (json as? [String: Any])?["trackFileIds"] as? [Any] ?? []
                return .trackFileDelete(ids.compactMap { ($0 as? NSNumber)?.intValue })
            }
            return .trackFileDelete([Int(key[1])].compactMap { $0 })
        case ("PUT", "album") where key[1] == "monitor":
            let object = json as? [String: Any] ?? [:]
            let value = { (name: String) in object.first { $0.key.lowercased() == name }?.value }
            let ids = (value("albumids") as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            return .albumMonitor(albumIds: ids, monitored: (value("monitored") as? NSNumber)?.boolValue ?? true)
        default:
            return nil
        }
    }

    // MARK: Layer 2: the allow list

    private static func isId(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }

    static func allowListed(_ t: WriteTarget, json: Any?) -> String? {
        let key = t.key
        let notAllowed = "\(t.method) /\(key.joined(separator: "/")) is not on the allow list"
        let noQuery: String? = t.query.isEmpty ? nil : "no query allowed on \(t.method) /\(key[0])"
        switch (t.method, key.count) {
        case ("POST", 1) where ["tag", "qualityprofile", "metadataprofile", "artist"].contains(key[0]):
            return noQuery
        case ("POST", 1) where key[0] == "command":
            return noQuery ?? commandReason(json)
        case ("PUT", 2) where key[0] == "artist" && key[1] == "editor":
            return noQuery ?? editorReason(json)
        // Security L9 / FM1: never `PUT /artist/{id}` or `PUT /album/{id}` (a whole resource: anything could change).
        case ("PUT", 2) where key[0] == "album" && key[1] == "monitor":
            return noQuery ?? albumMonitorReason(json)
        case ("DELETE", 2) where key[0] == "artist" && isId(key[1]):
            return artistDeleteReason(t.query)
        // Not for me (A16): the bulk route, falling back to one file at a time.
        case ("DELETE", 2) where key[0] == "trackfile" && key[1] == "bulk":
            return noQuery ?? trackFileBulkReason(json)
        case ("DELETE", 2) where key[0] == "trackfile" && isId(key[1]):
            return noQuery ?? (json == nil ? nil : "no body allowed on DELETE /trackfile/{id}")
        default:
            return notAllowed
        }
    }

    /// `DELETE /artist/{id}` only with explicit `deleteFiles=false` and `addImportListExclusion=false`, nothing else.
    private static func artistDeleteReason(_ query: [URLQueryItem]) -> String? {
        var seen = Set<String>()
        for item in query {
            let name = item.name.lowercased()
            guard falseOnlyFlags.contains(name), isFalse(item.value) else { return "artist delete needs deleteFiles=false and addImportListExclusion=false only" }
            seen.insert(name)
        }
        return seen == falseOnlyFlags ? nil : "artist delete needs explicit deleteFiles=false and addImportListExclusion=false"
    }

    /// `DELETE /trackfile/bulk`: exactly `{"trackFileIds": [<positive integers>]}`, at least one id.
    private static func trackFileBulkReason(_ json: Any?) -> String? {
        guard let object = json as? [String: Any], object.count == 1, let ids = object["trackFileIds"] as? [Any],
              !ids.isEmpty, ids.allSatisfy(isPositiveInteger) else {
            return "track file delete needs exactly a list of track file ids"
        }
        return nil
    }

    /// `PUT /album/monitor`: exactly `{albumIds: [positive ids, at least one], monitored: true|false}`. Which
    /// albums, the gate's confinement decides (H2b fix 1).
    private static func albumMonitorReason(_ json: Any?) -> String? {
        guard let object = json as? [String: Any], object.count == 2 else { return "album monitor needs albumIds and monitored only" }
        let value = { (name: String) in object.first { $0.key.lowercased() == name }?.value }
        guard let ids = value("albumids") as? [Any], !ids.isEmpty, ids.allSatisfy(isPositiveInteger),
              let monitored = value("monitored"), isBoolean(monitored) else {
            return "album monitor needs albumIds and monitored only"
        }
        return nil
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func isPositiveInteger(_ value: Any) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.int64Value > 0 && Double(n.int64Value) == n.doubleValue
    }

    /// Exactly one `name` key (any case), naming an allowed command.
    private static func commandReason(_ json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return "command needs a body" }
        let names = object.filter { $0.key.lowercased() == "name" }
        guard names.count == 1, let name = names.first?.value as? String,
              allowedCommands.contains(name.lowercased()) else { return "command not allowed" }
        return nil
    }

    /// The only fields Keep, its restore and Bring in more send (FM1). Never `monitored`, `metadataProfileId`…
    static let editorKeys: Set<String> = ["artistids", "rootfolderpath", "movefiles", "qualityprofileid", "tags",
                                          "applytags", "monitornewitems", "monitored"]

    /// Only `editorKeys`, exactly one artist id, no `deleteFiles` / `addImportListExclusion` key at any depth;
    /// `applyTags` (at most one) is add or remove and comes with `tags`; `moveFiles` is a boolean and comes with a
    /// `rootFolderPath` string. A body with `monitorNewItems` (Follow new releases) is exactly `{artistIds: [one id],
    /// monitorNewItems: new}`. A body with `monitored` (P3 "Monitor", for an artist Magpie added) is exactly
    /// `{artistIds: [one id], monitored: true}`: Magpie never unmonitors an artist. Where an artist may be moved, and
    /// which artist, the gate's confinement decides (FM1).
    private static func editorReason(_ json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return "artist editor needs a body" }
        if let flag = anyKey(falseOnlyFlags, in: object) { return "artist editor body must not carry \(flag)" }
        if let other = object.keys.first(where: { !editorKeys.contains($0.lowercased()) }) {
            return "artist editor can't change \(other)"
        }
        let value = { (name: String) in object.first { $0.key.lowercased() == name }?.value }
        guard let ids = value("artistids") as? [Any], ids.count == 1, isPositiveInteger(ids[0]) else {
            return "artist editor changes exactly one artist"
        }
        if (value("tags") == nil) != (value("applytags") == nil) { return "tags and applyTags go together" }
        if let move = value("movefiles") {
            guard isBoolean(move), value("rootfolderpath") is String else { return "moveFiles needs a root folder" }
        }
        if let root = value("rootfolderpath"), !(root is String) { return "rootFolderPath must be a path" }
        let apply = object.filter { $0.key.lowercased() == "applytags" }
        guard apply.count <= 1 else { return "applyTags given twice" }
        if let value = apply.first?.value {
            guard let s = value as? String, allowedApplyTags.contains(s.lowercased()) else { return "applyTags must be add or remove" }
        }
        let monitoring = object.filter { $0.key.lowercased() == "monitored" }
        if let monitored = monitoring.first?.value {
            guard monitoring.count == 1, object.count == 2, isBoolean(monitored), (monitored as? NSNumber)?.boolValue == true,
                  let ids = value("artistids") as? [Any], ids.count == 1, isPositiveInteger(ids[0]) else {
                return "monitoring changes one artist to monitored and nothing else"
            }
        }
        if let follow = object.first(where: { $0.key.lowercased() == "monitornewitems" })?.value {
            guard let s = follow as? String, allowedMonitorNewItems.contains(s.lowercased()) else {
                return "monitorNewItems must be new"
            }
            guard object.count == 2,
                  let ids = object.first(where: { $0.key.lowercased() == "artistids" })?.value as? [Any],
                  ids.count == 1, isPositiveInteger(ids[0]) else {
                return "following new releases changes one artist and nothing else"
            }
        }
        return nil
    }

    private static func anyKey(_ names: Set<String>, in value: Any) -> String? {
        switch value {
        case let d as [String: Any]:
            for (k, v) in d {
                if names.contains(k.lowercased()) { return k }
                if let inner = anyKey(names, in: v) { return inner }
            }
            return nil
        case let a as [Any]:
            return a.lazy.compactMap { anyKey(names, in: $0) }.first
        default:
            return nil
        }
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
/// sends only allow-listed writes; logs every write (method, path, body without secrets) before sending it.
///
/// Nothing is cached per instance: the switch is read from UserDefaults on every send, and the change log is
/// re-read from disk (under a process-wide lock) before each append, so several gates on the same suite and
/// log file stay consistent.
public actor LidarrWriteGate {
    /// The switch's UserDefaults key prefix. The switch itself is per Lidarr instance (security M3):
    /// `enabledKey(scope:)`, so another Lidarr (or a new API key) always starts with writes off.
    public static let enabledDefaultsKey = "magpie.lidarr.writesEnabled"

    /// The switch's key for one Lidarr instance (`LidarrClient.instanceScope`).
    public static func enabledKey(scope: String) -> String { "\(enabledDefaultsKey).\(scope)" }
    public static let maxBodySummary = 1_000
    /// Oldest entries are dropped beyond this.
    public static let maxLogEntries = 5_000

    /// Where the change log lives by default: `Application Support/Magpie/lidarr-change-log.json`.
    public static func defaultLogURL(in directory: URL = URL.applicationSupportDirectory) -> URL {
        LocalFile.url("lidarr-change-log.json", in: directory)
    }

    /// Serialises read-modify-write of change-log files across all gate instances.
    private static let logLock = OSAllocatedUnfairLock()

    private let connection: LidarrConnection
    /// Reads for the confinement checks (GETs only).
    private let reader: LidarrClient
    /// FM1: nil refuses every write the confinement decides (deletes, the artist editor).
    private let confinement: WriteConfinement?
    private let logURL: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// `defaultsSuite` names the UserDefaults suite holding the switch (nil: standard defaults; tests pass their own).
    /// `confinement` (FM1): the ledger and the owner's roots the gate checks deletes and artist edits against;
    /// without it they are refused.
    public init(client: LidarrClient, logURL: URL, defaultsSuite: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, confinement: WriteConfinement? = nil) {
        self.connection = client.connection
        self.reader = client
        self.confinement = confinement
        self.logURL = logURL
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.now = now
    }

    /// The "Allow Magpie to change Lidarr" switch. Persisted; false until the owner turns it on.
    public var enabled: Bool { defaults.bool(forKey: Self.enabledKey(scope: connection.instanceScope)) }

    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey(scope: connection.instanceScope))
    }

    /// The change log as saved on disk. Empty when there is none or it cannot be read right now.
    public func changeLog() -> [ChangeLogEntry] {
        (try? Self.logLock.withLock { [logURL] in try Self.readLog(logURL) }) ?? []
    }

    private func refused(_ target: WriteTarget, _ why: String) -> WriteGateError {
        Log.logger("lidarr").error("refused \(target.method, privacy: .public) \(target.logPath, privacy: .public): \(why, privacy: .public)")
        return .forbidden(why)
    }

    private static func readLog(_ url: URL) throws -> [ChangeLogEntry] {
        try LocalFile.load([ChangeLogEntry].self, from: url, fallback: [], category: "lidarr")
    }

    /// Sends one write. `path` is relative to `<base>/api/v1/` (`artist/12?deleteFiles=false&…`; a leading
    /// `/api/v1/` is accepted, any other `/api/…` is refused). Returns the response body on 2xx.
    public func send(_ method: String, _ path: String, body: (any Encodable & Sendable)?) async throws -> Data {
        let target = try WriteTarget(method: method, path: path)
        let data = try body.map { try JSONEncoder().encode($0) }
        if let why = ForbiddenWrites.reason(target, body: data) { throw refused(target, why) }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        let confined = ForbiddenWrites.confined(target, json: json)
        if confined != nil, confinement == nil { throw refused(target, "deletes and artist edits need the ledger") }
        guard enabled else { throw WriteGateError.disabled }
        guard let confined, let confinement else { return try await deliver(target, data) }
        // FM1: checked from the ledger and fresh reads, after the switch (so nothing is read while it's off). H2b fix
        // 1: confined writes go one at a time, from their checks to Lidarr's answer, so no other confined write can
        // slip in between a check and its send.
        await takeConfinedTurn()
        defer { passConfinedTurn() }
        let artists: Set<Int>
        switch await confinement.check(confined, lidarr: reader) {
        case .confined(let touched): artists = touched
        case .refused(let why): throw refused(target, why)
        case .unknown:
            Log.logger("lidarr").error("not confirmed \(target.method, privacy: .public) \(target.logPath, privacy: .public)")
            throw WriteGateError.unconfirmed
        }
        guard enabled else { throw WriteGateError.disabled }   // turned off during the reads
        // The ledger once more, right before a delete: kept meanwhile (Keep saves "kept" before it writes) refuses.
        switch await confinement.stillUnkept(artists) {
        case true?: break
        case false?: throw refused(target, "the artist was kept meanwhile")
        case nil: throw WriteGateError.unconfirmed
        }
        return try await deliver(target, data)
    }

    private var confinedBusy = false
    private var confinedWaiting: [CheckedContinuation<Void, Never>] = []

    /// FIFO: waits until no other confined write is between its checks and its answer.
    private func takeConfinedTurn() async {
        guard confinedBusy else { confinedBusy = true; return }
        await withCheckedContinuation { confinedWaiting.append($0) }
    }

    private func passConfinedTurn() {
        if confinedWaiting.isEmpty { confinedBusy = false } else { confinedWaiting.removeFirst().resume() }
    }

    /// Logs the write, sends it, and records Lidarr's answer.
    private func deliver(_ target: WriteTarget, _ data: Data?) async throws -> Data {
        let entry = ChangeLogEntry(date: now(), method: target.method, path: target.logPath,
                                   bodySummary: BodySummary.make(data, apiKey: connection.apiKey, limit: Self.maxBodySummary))
        do {
            try Self.logLock.withLock { [logURL] in
                var log = try Self.readLog(logURL)
                log.append(entry)
                if log.count > Self.maxLogEntries { log.removeFirst(log.count - Self.maxLogEntries) }
                try LocalFile.save(log, to: logURL)
            }
        } catch {
            throw WriteGateError.logUnavailable
        }

        let (responseData, response) = try await connection.send(
            target.method, path: target.segments.joined(separator: "/"), query: target.query, body: data)
        try? Self.logLock.withLock { [logURL] in
            var log = try Self.readLog(logURL)
            if let index = log.lastIndex(of: entry) {
                log[index].status = response.statusCode
                try LocalFile.save(log, to: logURL)
            }
        }
        switch response.statusCode {
        case 200..<300: return responseData
        case 401, 403: throw LidarrError.unauthorized
        default: throw LidarrError.http(status: response.statusCode)
        }
    }
}

// MARK: - Raw body key scan

/// Scans the exact bytes that will be sent for JSON object keys Lidarr could read differently from us:
/// - non-ASCII keys (.NET case-insensitive binding folds e.g. U+017F "ſ" to "S", so `deleteFileſ` binds as
///   `deleteFiles` while our lower-cased comparisons miss it);
/// - duplicate keys, compared case-insensitively (JSONSerialization keeps one, System.Text.Json the last).
/// Returns why the body is refused, or nil.
enum JSONKeyScan {
    private struct Refusal: Error { let reason: String }
    private static let maxDepth = 64

    static func problem(in data: Data) -> String? {
        var scanner = Scanner(bytes: Array(data))
        do {
            scanner.skipSpace()
            try scanner.value(depth: 0)
            scanner.skipSpace()
            guard scanner.atEnd else { return "body has trailing data" }
            return nil
        } catch let r as Refusal {
            return r.reason
        } catch {
            return "body is not JSON"
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        var atEnd: Bool { i >= bytes.count }
        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func skipSpace() {
            while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 }
        }

        mutating func expect(_ b: UInt8) throws {
            guard peek == b else { throw Refusal(reason: "body is not JSON") }
            i += 1
        }

        mutating func value(depth: Int) throws {
            guard depth < JSONKeyScan.maxDepth else { throw Refusal(reason: "body nested too deeply") }
            switch peek {
            case UInt8(ascii: "{"): try object(depth: depth)
            case UInt8(ascii: "["): try array(depth: depth)
            case UInt8(ascii: "\""): _ = try string()   // control characters are fine in values
            case .some:
                // Number or literal: consume up to the next delimiter.
                let start = i
                while let b = peek, !(b == UInt8(ascii: ",") || b == UInt8(ascii: "]") || b == UInt8(ascii: "}")
                                      || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) { i += 1 }
                guard i > start else { throw Refusal(reason: "body is not JSON") }
            case .none:
                throw Refusal(reason: "body is not JSON")
            }
        }

        mutating func object(depth: Int) throws {
            try expect(UInt8(ascii: "{"))
            var keys = Set<String>()
            skipSpace()
            if peek == UInt8(ascii: "}") { i += 1; return }
            while true {
                skipSpace()
                let (key, ascii, control) = try string()
                guard ascii else { throw Refusal(reason: "non-ASCII key in body") }
                // Security L6: `\t`, `\u0000`… in a key: refused, so the key checked is the key Lidarr parses.
                guard !control else { throw Refusal(reason: "control character in a body key") }
                guard keys.insert(key.lowercased()).inserted else { throw Refusal(reason: "duplicate key \(key) in body") }
                skipSpace()
                try expect(UInt8(ascii: ":"))
                skipSpace()
                try value(depth: depth + 1)
                skipSpace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                try expect(UInt8(ascii: "}"))
                return
            }
        }

        mutating func array(depth: Int) throws {
            try expect(UInt8(ascii: "["))
            skipSpace()
            if peek == UInt8(ascii: "]") { i += 1; return }
            while true {
                skipSpace()
                try value(depth: depth + 1)
                skipSpace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                try expect(UInt8(ascii: "]"))
                return
            }
        }

        /// The decoded string, whether every character in it is ASCII (escapes included: `ſ` is not), and
        /// whether it holds a control character (< 0x20, raw or escaped, `\t` `\n` `\b` `\f` `\r` included).
        mutating func string() throws -> (String, ascii: Bool, control: Bool) {
            try expect(UInt8(ascii: "\""))
            var out = ""
            var ascii = true
            var control = false
            while let b = peek {
                i += 1
                switch b {
                case UInt8(ascii: "\""):
                    return (out, ascii, control)
                case UInt8(ascii: "\\"):
                    guard let e = peek else { throw Refusal(reason: "body is not JSON") }
                    i += 1
                    switch e {
                    case UInt8(ascii: "u"):
                        guard i + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                            throw Refusal(reason: "body is not JSON")
                        }
                        i += 4
                        if code < 0x20 { control = true }
                        if code < 0x80, let s = Unicode.Scalar(code) { out.unicodeScalars.append(s) } else { ascii = false }
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                        out.unicodeScalars.append(Unicode.Scalar(e))
                    case UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        control = true
                        out.unicodeScalars.append(Unicode.Scalar(e))
                    default:
                        throw Refusal(reason: "body is not JSON")
                    }
                default:
                    if b < 0x20 { control = true }
                    if b >= 0x80 { ascii = false } else { out.unicodeScalars.append(Unicode.Scalar(b)) }
                }
            }
            throw Refusal(reason: "body is not JSON")
        }
    }
}
