import Foundation
import MagpieCore
import os

/// Round 12 Y6: a stub Aurral (v2.10.0 shapes, from docs/research/aurral.md) for tests, in process. Never the owner's
/// Aurral: it answers only its own host (`aurral-stub` by default: a single-label name, so a home address) and fails every other request without sending it.
///
/// It serves the five routes Magpie may call (health, playlists status and jobs, library lookup, a flow's start) and
/// answers 404 to anything else, recording every request so tests can check what was (and wasn't) asked. A wrong or
/// missing `X-Api-Key` gets 401. Starting a flow makes a run active (`operationQueue.processing`) until `finishRun()`.
public final class StubAurral: HTTPTransport, @unchecked Sendable {
    public struct Flow: Sendable {
        public var id: String
        public var name: String
        public var enabled: Bool
        public var size: Int
        public init(id: String, name: String, enabled: Bool = true, size: Int = 20) {
            self.id = id; self.name = name; self.enabled = enabled; self.size = size
        }
    }

    public struct Job: Sendable {
        public var flowId: String
        public var artistName: String
        public var trackName: String
        public var albumName: String
        public var artistMbid: String?
        public var trackMbid: String?
        public var durationMs: Int?
        public var status: String
        public var finalPath: String?
        public init(flowId: String, artistName: String, trackName: String, albumName: String = "Single",
                    artistMbid: String? = nil, trackMbid: String? = nil, durationMs: Int? = nil, status: String = "done",
                    finalPath: String? = nil) {
            self.flowId = flowId; self.artistName = artistName; self.trackName = trackName; self.albumName = albumName
            self.artistMbid = artistMbid; self.trackMbid = trackMbid; self.durationMs = durationMs; self.status = status
            self.finalPath = finalPath
        }
    }

    /// What a flow's start does: a run Aurral's status shows (default), one that finishes before the next status read
    /// (`lastRunAt` moves, never seen active), or one never seen at all (failed at once).
    public enum StartBehaviour: Sendable { case runs, finishesAtOnce, neverSeen }

    private struct State {
        var start = StartBehaviour.runs
        var lastRunAt: [String: String] = [:]
        var version: String? = "2.10.0"
        var flows: [Flow] = []
        var jobs: [Job] = []
        var jobsRoute = true
        var running: Set<String> = []
        var inAurralLibrary: Set<String> = []
        var requests: [URLRequest] = []
        var down = false
    }

    public let host: String
    public let apiKey: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(host: String = "aurral-stub", apiKey: String = "stub-aurral-key") {
        self.host = host
        self.apiKey = apiKey
    }

    public var base: URL { URL(string: "http://\(host):3001")! }

    // MARK: - Set-up

    public func setVersion(_ version: String?) { state.withLock { $0.version = version } }
    public func setFlows(_ flows: [Flow]) { state.withLock { $0.flows = flows } }
    public func setJobs(_ jobs: [Job]) { state.withLock { $0.jobs = jobs } }
    /// Off: `/api/playlists/jobs` answers 404 (an Aurral without the route).
    public func setJobsRoute(_ on: Bool) { state.withLock { $0.jobsRoute = on } }
    /// The flow's run is active (as after a start) or not.
    public func setRunning(_ flowId: String, _ on: Bool) {
        state.withLock { if on { $0.running.insert(flowId) } else { $0.running.remove(flowId) } }
    }
    public func setStartBehaviour(_ behaviour: StartBehaviour) { state.withLock { $0.start = behaviour } }
    public func finishRun() { state.withLock { $0.running = [] } }
    public func setArtistInAurralLibrary(_ mbid: String) { state.withLock { _ = $0.inAurralLibrary.insert(mbid) } }
    /// Down: every request fails with "can't connect".
    public func setDown(_ down: Bool) { state.withLock { $0.down = down } }

    // MARK: - What was asked

    public var requests: [URLRequest] { state.withLock { $0.requests } }
    /// Each request as "METHOD /path".
    public var asked: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }

    // MARK: - Serving

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host == host else {
            throw URLError(.cannotFindHost)   // never anywhere else: not sent
        }
        let snapshot = state.withLock { s -> State in
            s.requests.append(request)
            return s
        }
        if snapshot.down { throw URLError(.cannotConnectToHost) }
        func answer(_ status: Int, _ object: Any = [String: Any]()) -> (Data, HTTPURLResponse) {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (data, http)
        }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        if path == "/api/health" {
            var body: [String: Any] = ["status": "ok", "library": ["artistCount": 3]]
            if let version = snapshot.version { body["appVersion"] = version }
            return answer(200, body)
        }
        guard request.value(forHTTPHeaderField: "X-Api-Key") == apiKey else { return answer(401, ["error": "Unauthorized"]) }
        switch (method, path) {
        case ("GET", "/api/playlists/status"):
            return answer(200, statusBody(snapshot))
        case ("GET", "/api/playlists/jobs"):
            guard snapshot.jobsRoute else { return answer(404, ["error": "Not found"]) }
            return answer(200, snapshot.jobs.enumerated().map { Self.jobBody($0.element, index: $0.offset) })
        case (_, let p) where p.hasPrefix("/api/library/lookup/") && method == "GET":
            let mbid = String(p.dropFirst("/api/library/lookup/".count))
            let exists = snapshot.inAurralLibrary.contains(mbid)
            return answer(200, ["exists": exists, "artist": exists ? ["foreignArtistId": mbid] : NSNull(), "albums": []])
        case (let m, let p) where p.hasPrefix("/api/playlists/start/") && m != "GET":
            let flowId = String(p.dropFirst("/api/playlists/start/".count))
            guard snapshot.flows.contains(where: { $0.id == flowId }) else { return answer(404, ["error": "Flow not found"]) }
            state.withLock { s in
                switch s.start {
                case .runs: s.running.insert(flowId)
                case .finishesAtOnce: s.lastRunAt[flowId] = "2026-11-03T12:00:00.000Z"
                case .neverSeen: break
                }
            }
            return answer(200, ["success": true, "flowId": flowId, "queued": true, "operationId": "op-1"])
        default:
            return answer(404, ["error": "Not found"])
        }
    }

    private func statusBody(_ s: State) -> [String: Any] {
        var flowStats: [String: Any] = [:]
        for flow in s.flows {
            let jobs = s.jobs.filter { $0.flowId == flow.id }
            func count(_ status: String) -> Int { jobs.filter { $0.status == status }.count }
            let running = s.running.contains(flow.id)
            flowStats[flow.id] = ["total": running ? flow.size : jobs.count,
                                  "pending": running ? flow.size / 2 : count("pending"),
                                  "downloading": running ? 2 : count("downloading"),
                                  "done": running ? flow.size / 2 - 2 : count("done"),
                                  "failed": count("failed"), "blocked": count("blocked")]
        }
        let busy = !s.running.isEmpty
        return [
            "worker": ["running": true, "processing": busy, "activeCount": busy ? 2 : 0,
                       "stats": ["total": s.jobs.count, "pending": 0, "downloading": 0, "blocked": 0,
                                 "done": s.jobs.count, "failed": 0],
                       "settings": ["concurrency": 3, "existingFileMode": "reuse"]],
            "slskd": ["configured": true, "connected": true],
            "flowStats": flowStats,
            "flows": s.flows.map { f in
                ["id": f.id, "name": f.name, "ownerUsername": "admin", "enabled": f.enabled, "size": f.size,
                 "scheduleDays": [5], "scheduleTime": "00:00", "nextRunAt": "2026-11-06T00:00:00.000Z",
                 "lastRunAt": s.lastRunAt[f.id] ?? "2026-10-30T00:00:00.000Z", "mix": ["discover": 100], "lidarrFeedToken": "secret-feed-token"]
            },
            "sharedPlaylists": [],
            "operationQueue": ["processing": busy, "pending": 0, "currentLabel": busy ? "Generating flow" : NSNull()],
            "hint": ["phase": busy ? "running" : "idle", "message": busy ? "Getting songs" : "Next update in 5 days"],
        ]
    }

    private static func jobBody(_ j: Job, index: Int) -> [String: Any] {
        var body: [String: Any] = ["id": "job-\(index)", "artistName": j.artistName, "trackName": j.trackName,
                                   "albumName": j.albumName, "playlistId": j.flowId, "playlistType": j.flowId,
                                   "managedBy": "aurral", "status": j.status, "downloadSource": "slskd"]
        if let v = j.artistMbid { body["artistMbid"] = v }
        if let v = j.trackMbid { body["trackMbid"] = v }
        if let v = j.durationMs { body["durationMs"] = v }
        if let v = j.finalPath { body["finalPath"] = v }
        return body
    }
}
