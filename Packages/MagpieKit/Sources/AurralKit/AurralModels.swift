import Foundation
import MagpieCore

// Aurral 2.10.0's answers (docs/research/aurral.md), read leniently: every field optional, a bad element dropped, never
// a crash on a newer or older shape. Measured before parsing (JSONNesting), like every other client.

private func object(_ data: Data) -> Any? { JSONNesting.object(with: data) }

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.isFinite && abs(d) < 1e12 ? Int(d) : nil
        }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func mbid(_ key: String) -> MBID? { string(key).flatMap(MBID.init) }
}

/// The version Magpie is built for.
public enum AurralVersion {
    public static let builtFor = (major: 2, minor: 10)

    public enum Compatibility: Sendable, Equatable {
        /// 2.10.x.
        case supported(String)
        /// Later than 2.10: tolerated (routes may be missing; each read copes).
        case newer(String)
        /// Earlier than 2.10.
        case older(String)
        /// No version said.
        case unknown
    }

    public static func compatibility(_ version: String?) -> Compatibility {
        guard var text = version?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .unknown }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let numbers = text.split(separator: ".").prefix(2).map { Int($0.prefix { $0.isNumber }) }
        guard numbers.count == 2, let major = numbers[0], let minor = numbers[1] else { return .unknown }
        if (major, minor) == builtFor { return .supported(text) }
        return (major, minor) > builtFor ? .newer(text) : .older(text)
    }
}

/// `GET /api/health`.
public struct AurralHealth: Sendable, Equatable {
    public var appVersion: String?
    public var compatibility: AurralVersion.Compatibility { AurralVersion.compatibility(appVersion) }

    public init(appVersion: String?) { self.appVersion = appVersion }

    static func decode(_ data: Data) -> AurralHealth {
        let o = object(data) as? [String: Any] ?? [:]
        return AurralHealth(appVersion: o.string("appVersion") ?? o.string("version"))
    }
}

/// One flow (`/api/playlists/status` `flows[]`).
public struct AurralFlow: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var ownerUsername: String?
    public var size: Int?
    public var nextRunAt: Date?
    /// When the flow's last run happened (a change says a run finished: Refresh Flow's latch, fix I3).
    public var lastRunAt: Date?

    public init(id: String, name: String, enabled: Bool = true, ownerUsername: String? = nil, size: Int? = nil,
                nextRunAt: Date? = nil, lastRunAt: Date? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.ownerUsername = ownerUsername; self.size = size
        self.nextRunAt = nextRunAt; self.lastRunAt = lastRunAt
    }
}

/// A flow's song counts (`flowStats[<flowId>]`).
public struct AurralFlowStats: Sendable, Equatable {
    public var total: Int?
    public var pending: Int?
    public var downloading: Int?
    public var done: Int?
    public var failed: Int?

    public init(total: Int? = nil, pending: Int? = nil, downloading: Int? = nil, done: Int? = nil, failed: Int? = nil) {
        self.total = total; self.pending = pending; self.downloading = downloading; self.done = done; self.failed = failed
    }
}

/// How far a flow's run has got.
public struct AurralProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// `GET /api/playlists/status`, the parts Magpie reads.
public struct AurralStatus: Sendable, Equatable {
    public var flows: [AurralFlow]
    public var flowStats: [String: AurralFlowStats]
    /// The worker is downloading something now.
    public var workerProcessing: Bool
    public var workerActiveCount: Int
    /// A flow is being generated or queued (`operationQueue`).
    public var operationProcessing: Bool
    public var operationPending: Int
    /// Aurral's own line ("Next update in 5 days").
    public var hint: Hint?

    public struct Hint: Sendable, Equatable {
        public var phase: String?
        public var message: String?
    }

    public init(flows: [AurralFlow], flowStats: [String: AurralFlowStats] = [:], workerProcessing: Bool = false,
                workerActiveCount: Int = 0, operationProcessing: Bool = false, operationPending: Int = 0, hint: Hint? = nil) {
        self.flows = flows; self.flowStats = flowStats; self.workerProcessing = workerProcessing
        self.workerActiveCount = workerActiveCount; self.operationProcessing = operationProcessing
        self.operationPending = operationPending; self.hint = hint
    }

    /// A run is under way for this flow (or Aurral is busy generating one): Refresh Flow is refused. A flow is busy
    /// while it has songs pending or downloading; Aurral as a whole while its operation queue works or waits.
    public func isRunActive(flowId: String) -> Bool {
        if operationProcessing || operationPending > 0 { return true }
        guard let stats = flowStats[flowId] else { return false }
        return (stats.pending ?? 0) + (stats.downloading ?? 0) > 0
    }

    /// The flow's run so far, while one is under way and its counts are known.
    public func progress(flowId: String) -> AurralProgress? {
        guard isRunActive(flowId: flowId), let stats = flowStats[flowId], let total = stats.total, total > 0 else { return nil }
        return AurralProgress(done: min(total, max(0, stats.done ?? 0)), total: total)
    }

    public static func decode(_ data: Data) throws -> AurralStatus {
        guard let o = object(data) as? [String: Any] else { throw AurralError.decoding }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ text: String?) -> Date? { text.flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }
        let flows = (o["flows"] as? [Any] ?? []).compactMap { item -> AurralFlow? in
            guard let f = item as? [String: Any], let id = f.string("id"), let name = f.string("name") else { return nil }
            return AurralFlow(id: id, name: name, enabled: f.bool("enabled") ?? true, ownerUsername: f.string("ownerUsername"),
                              size: f.int("size"), nextRunAt: date(f.string("nextRunAt")), lastRunAt: date(f.string("lastRunAt")))
        }
        var stats: [String: AurralFlowStats] = [:]
        for (id, value) in o.dict("flowStats") ?? [:] {
            guard let s = value as? [String: Any] else { continue }
            stats[id] = AurralFlowStats(total: s.int("total"), pending: s.int("pending"), downloading: s.int("downloading"),
                                        done: s.int("done"), failed: s.int("failed"))
        }
        let worker = o.dict("worker") ?? [:]
        let queue = o.dict("operationQueue") ?? [:]
        let hint = o.dict("hint").map { Hint(phase: $0.string("phase"), message: $0.string("message")) }
        return AurralStatus(flows: flows, flowStats: stats, workerProcessing: worker.bool("processing") ?? false,
                            workerActiveCount: worker.int("activeCount") ?? 0,
                            operationProcessing: queue.bool("processing") ?? false,
                            operationPending: queue.int("pending") ?? 0, hint: hint)
    }
}

/// One flow song (`GET /api/playlists/jobs`).
public struct AurralJob: Sendable, Equatable, Hashable {
    public var id: String
    /// The flow it belongs to (`playlistId`, else `playlistType`).
    public var flowId: String?
    public var artistName: String
    public var trackName: String
    public var albumName: String?
    public var artistMBID: MBID?
    public var trackMBID: MBID?
    public var durationMs: Int?
    /// Where Aurral put the file (container path).
    public var finalPath: String?
    public var status: String?

    public init(id: String, flowId: String?, artistName: String, trackName: String, albumName: String? = nil,
                artistMBID: MBID? = nil, trackMBID: MBID? = nil, durationMs: Int? = nil, finalPath: String? = nil,
                status: String? = nil) {
        self.id = id; self.flowId = flowId; self.artistName = artistName; self.trackName = trackName
        self.albumName = albumName; self.artistMBID = artistMBID; self.trackMBID = trackMBID; self.durationMs = durationMs
        self.finalPath = finalPath; self.status = status
    }

    public var duration: TimeInterval? { durationMs.map { TimeInterval($0) / 1000 } }

    /// The file is Aurral's own download in its flow folder (`…/_flows/<flowId>/…`), not a Lidarr file it reused.
    public var isAurralsOwnFile: Bool {
        guard let path = finalPath else { return false }
        return path.split(separator: "/").contains("_flows")
    }

    /// The jobs array, bare or as `{"jobs": [...]}`; jobs without an id, artist or track are dropped.
    public static func decodeList(_ data: Data) throws -> [AurralJob] {
        let root = object(data)
        guard let items = (root as? [Any]) ?? ((root as? [String: Any])?["jobs"] as? [Any]) else {
            throw AurralError.decoding
        }
        return items.compactMap { item in
            guard let j = item as? [String: Any], let id = j.string("id") ?? j.int("id").map(String.init),
                  let artist = j.string("artistName"), let track = j.string("trackName") else { return nil }
            return AurralJob(id: id, flowId: j.string("playlistId") ?? j.string("playlistType"), artistName: artist,
                             trackName: track, albumName: j.string("albumName"), artistMBID: j.mbid("artistMbid"),
                             trackMBID: j.mbid("trackMbid"), durationMs: j.int("durationMs"), finalPath: j.string("finalPath"),
                             status: j.string("status"))
        }
    }
}

/// `GET /api/library/lookup/:mbid`.
public struct AurralArtistLookup: Sendable, Equatable {
    public var exists: Bool
    public init(exists: Bool) { self.exists = exists }

    static func decode(_ data: Data) -> AurralArtistLookup {
        AurralArtistLookup(exists: (object(data) as? [String: Any])?.bool("exists") ?? false)
    }
}

/// `POST /api/playlists/start/:flowId`'s answer.
public struct AurralStartResult: Sendable, Equatable {
    public var queued: Bool
    public init(queued: Bool) { self.queued = queued }

    static func decode(_ data: Data) -> AurralStartResult {
        let o = object(data) as? [String: Any] ?? [:]
        return AurralStartResult(queued: o.bool("queued") ?? o.bool("success") ?? true)
    }
}
