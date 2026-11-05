import Foundation
import AurralKit
import MagpieCore
import os

/// Round 12 Y6: a stub Aurral (v2.10.0 shapes, from docs/research/aurral.md) for tests, in process. Never the owner's
/// Aurral: it answers only its own host (`aurral-stub` by default: a single-label name, so a home address) and fails every other request without sending it.
///
/// It serves the routes Magpie may call (health, playlists status and jobs, library lookup, a flow's start, round 13's
/// login and logout, and after `useAurral213()` round 14's 2.13 routes: StubAurral+Discover.swift) and answers 404 to
/// anything else, recording every request so tests can check what was
/// (and wasn't) asked. Round 13: Aurral 2.10's user sessions. `POST /api/auth/login` checks a user's password and
/// hands out a Bearer token; every other call but `/api/health` needs a live token (401 otherwise, as Aurral's
/// `SESSION_INVALID`), and an API key is never accepted. Like Aurral, an admin sees every user's flows and a user only
/// their own. Starting a flow makes a run active (`operationQueue.processing`) until `finishRun()`.
public final class StubAurral: HTTPTransport, @unchecked Sendable {
    public struct Flow: Sendable {
        public var id: String
        public var name: String
        public var enabled: Bool
        public var size: Int
        /// The Aurral user who owns it (nil: a flow from before users, an admin's).
        public var ownerUserId: Int?
        /// Round 14 A4: Aurral 2.13's `autoDownload` (nil: not sent, as 2.10).
        public var autoDownload: Bool?
        public init(id: String, name: String, enabled: Bool = true, size: Int = 20, ownerUserId: Int? = 1) {
            self.id = id; self.name = name; self.enabled = enabled; self.size = size; self.ownerUserId = ownerUserId
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

    public struct User: Sendable {
        public var id: Int
        public var username: String
        public var password: String
        public var role: String
        /// Round 14: Aurral's permissions for the user (nil: Aurral 2.13's non-admin defaults).
        public var permissions: [String: Bool]? = nil
    }

    private struct State {
        var users = [User(id: 1, username: StubAurral.defaultUsername, password: StubAurral.defaultPassword, role: "admin")]
        /// Live sessions: token → user id.
        var sessions: [String: Int] = [:]
        var logins = 0
        var loginRateLimited = false
        var loginDown = false
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
        /// Round 14: the API contract's features (`api.features`); nil: no contract (2.10).
        var features: [String]?
        /// Round 14: whether a download source is configured (the bootstrap's `downloadSources`).
        var downloadSourcesConfigured = true
        /// Round 14 A4: synced playlists made by Add flow (status `sharedPlaylists`), and their songs' job statuses.
        var synced: [Flow] = []
        var syncedJobStatuses = ["done", "done", "downloading", "failed"]
        /// Fix round 1 (I1, M1): each static playlist's `importSource.provider` (nil: made by hand), and the Add flow
        /// creations Aurral has queued but not run yet (2.13 queues `shared-playlist-create`): each waits this many
        /// status reads, and until then its jobs answer 404 and the status doesn't list it.
        var syncedProviders: [String: String] = [:]
        var pendingSynced: [PendingSynced] = []
        var creationDelayReads = 1
    }

    struct PendingSynced {
        var flow: Flow
        var provider: String?
        var songs: [(title: String, artist: String, durationMs: Int)]
        var readsLeft: Int
    }

    /// Fix round 1 (I1): how many status reads an Add flow's playlist stays queued before Aurral creates it (0: at once).
    public func setSyncedCreationDelay(reads: Int) { state.withLock { $0.creationDelayReads = max(0, reads) } }

    /// Fix round 1 (I2): a static playlist made another way (`provider` "spotify-playlist", "youtube-playlist", or nil
    /// for one made by hand), with every song done, as Aurral 2.13 lists it too.
    public func addSharedPlaylist(id: String, name: String, provider: String?, owner: Int = 1,
                                  songs: [(title: String, artist: String, durationMs: Int)]) {
        state.withLock { s in
            Self.create(&s, flow: Flow(id: id, name: name, size: songs.count, ownerUserId: owner), provider: provider,
                        songs: songs, statuses: songs.map { _ in "done" })
        }
    }

    /// Round 15 C2: a static playlist's songs as Aurral holds them now (title and artist, in order); nil when there is
    /// no such playlist.
    public func sharedPlaylistSongs(_ id: String) -> [(title: String, artist: String)]? {
        state.withLock { s in
            guard s.synced.contains(where: { $0.id == id }) else { return nil }
            return s.jobs.filter { $0.flowId == id }.map { ($0.trackName, $0.artistName) }
        }
    }

    /// Round 15 C2 (D131): Aurral 2.13's own playlists, as `routes/playlists/handlers/staticPlaylists.ts` serves them
    /// (accessFlow; an admin passes): `POST /api/playlists/shared-playlists {name, sourceName, tracks}` makes one (400
    /// "Playlist name already exists" for a name the user has), `PUT .../:id {tracks}` replaces its songs (a song still
    /// in keeps its job; the rest leave; new ones are queued) and `DELETE .../:id` removes it (404 for one not the
    /// user's). Its songs are done at once (jobs left by removed songs are orphaned, so `job-<index>` ids stay put).
    func chartFlowAnswer(method: String, path: String, request: URLRequest, user: User) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "playlists", parts[2] == "shared-playlists",
              features != nil else { return nil }
        // G1 allowlist: stub aurral chart flows (the verbs the stub answers; it sends nothing).
        let verbs = (create: "POST", update: "PUT", delete: "DELETE")
        let isCreate = method == verbs.create && parts.count == 3
        let isUpdate = method == verbs.update && parts.count == 4
        let isDelete = method == verbs.delete && parts.count == 4
        guard isCreate || isUpdate || isDelete else { return nil }
        guard user.role == "admin" || user.permissions?["accessFlow"] == true else {
            return (403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
        }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let songs = ((body["tracks"] as? [[String: Any]]) ?? []).compactMap { t -> (title: String, artist: String, durationMs: Int)? in
            guard let title = (t["trackName"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let artist = (t["artistName"] as? String)?.trimmingCharacters(in: .whitespaces), !artist.isEmpty else { return nil }
            return (title, artist, t["durationMs"] as? Int ?? 0)
        }
        let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // (status, the playlist's id, Aurral's error words)
        let outcome = state.withLock { s -> (Int, String?, String?) in
            if isCreate {
                guard !name.isEmpty else { return (400, nil, "name is required") }
                if s.synced.contains(where: { $0.name.lowercased() == name.lowercased() && $0.ownerUserId == user.id }) {
                    return (400, nil, "Playlist name already exists")
                }
                let id = UUID().uuidString.lowercased()
                Self.create(&s, flow: Flow(id: id, name: name, size: songs.count, ownerUserId: user.id), provider: nil,
                            songs: songs, statuses: songs.map { _ in "done" })
                return (200, id, nil)
            }
            let id = parts[3]
            guard let index = s.synced.firstIndex(where: { $0.id == id && (user.role == "admin" || $0.ownerUserId == user.id) })
            else { return (404, nil, "Playlist not found") }
            var statuses: [String: String] = [:]
            for i in s.jobs.indices where s.jobs[i].flowId == id {
                statuses["\(s.jobs[i].artistName.lowercased())|\(s.jobs[i].trackName.lowercased())"] = s.jobs[i].status
                s.jobs[i].flowId = ""
            }
            if isDelete {
                s.synced.remove(at: index)
                s.syncedProviders[id] = nil
                return (200, id, nil)
            }
            // Aurral keeps the playlist in the order sent; a song still in keeps its status, a new one is queued.
            for song in songs {
                let status = statuses["\(song.artist.lowercased())|\(song.title.lowercased())"] ?? "done"
                s.jobs.append(Job(flowId: id, artistName: song.artist, trackName: song.title, durationMs: song.durationMs,
                                  status: status))
            }
            s.synced[index].size = songs.count
            return (200, id, nil)
        }
        guard let id = outcome.1 else { return (outcome.0, ["error": outcome.2 ?? "Failed"]) }
        return (200, ["success": true, "playlistId": id, "queued": true,
                      "operationId": isCreate ? "op-create" : isDelete ? "op-delete" : "op-update"])
    }

    /// Upstream-shaped id for the playlist Add flow makes from Deezer playlist `deezerId` (2.13: a random UUID).
    public static func syncedId(_ deezerId: String) -> String {
        "a4000000-0000-4000-8000-" + String(repeating: "0", count: max(0, 12 - deezerId.count)) + deezerId.suffix(12)
    }

    private static func create(_ s: inout State, flow: Flow, provider: String?,
                               songs: [(title: String, artist: String, durationMs: Int)], statuses: [String]) {
        guard !s.synced.contains(where: { $0.id == flow.id }) else { return }
        s.synced.append(flow)
        if let provider { s.syncedProviders[flow.id] = provider }
        for (index, song) in songs.enumerated() {
            s.jobs.append(Job(flowId: flow.id, artistName: song.artist, trackName: song.title, durationMs: song.durationMs,
                              status: index < statuses.count ? statuses[index] : "pending"))
        }
    }

    /// One status read: a queued creation's wait goes down; one whose wait is over is created now.
    private func advanceCreations() {
        state.withLock { s in
            var waiting: [PendingSynced] = []
            for var p in s.pendingSynced {
                if p.readsLeft <= 0 {
                    Self.create(&s, flow: p.flow, provider: p.provider, songs: p.songs, statuses: s.syncedJobStatuses)
                } else {
                    p.readsLeft -= 1
                    waiting.append(p)
                }
            }
            s.pendingSynced = waiting
        }
    }

    /// Round 14 A4: what each of a new synced playlist's songs is doing (its jobs, in the editorial fixture's order).
    public func setSyncedJobStatuses(_ statuses: [String]) { state.withLock { $0.syncedJobStatuses = statuses } }

    /// Round 14 A4: every job of every synced playlist takes this status now (its songs finished, say).
    public func setSyncedJobs(to status: String) {
        state.withLock { s in
            let ids = Set(s.synced.map(\.id))
            for i in s.jobs.indices where ids.contains(s.jobs[i].flowId) { s.jobs[i].status = status }
        }
    }

    /// Round 14 A4: Retry a song: its job (`job-<index>`) is searched for again (pending).
    func retryJob(_ jobId: String) {
        guard jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)) else { return }
        state.withLock { s in if s.jobs.indices.contains(index) { s.jobs[index].status = "pending" } }
    }

    /// Round 14 A4: Add flow made a synced playlist `id` named `name` for `owner`: Aurral queues every song (its jobs).
    /// Fix round 1: queued as 2.13 does; created after `creationDelayReads` status reads (at once with 0).
    func addSynced(id: String, name: String, owner: Int, songs: [(title: String, artist: String, durationMs: Int)]) {
        state.withLock { s in
            guard !s.synced.contains(where: { $0.id == id }), !s.pendingSynced.contains(where: { $0.flow.id == id })
            else { return }
            let flow = Flow(id: id, name: name, size: songs.count, ownerUserId: owner)
            if s.creationDelayReads == 0 {
                Self.create(&s, flow: flow, provider: "deezer-playlist", songs: songs, statuses: s.syncedJobStatuses)
            } else {
                s.pendingSynced.append(PendingSynced(flow: flow, provider: "deezer-playlist", songs: songs,
                                                     readsLeft: s.creationDelayReads))
            }
        }
    }

    public static let defaultUsername = "magpie"
    public static let defaultPassword = "stub-aurral-password"

    public let host: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Round 14: the Discover fixtures and their switches (StubAurral+Discover.swift).
    let discover = OSAllocatedUnfairLock(initialState: StubAurralDiscover())

    public init(host: String = "aurral-stub") {
        self.host = host
    }

    public var base: URL { URL(string: "http://\(host):3001")! }

    // MARK: - Set-up

    public func setVersion(_ version: String?) { state.withLock { $0.version = version } }
    /// Round 14: Aurral 2.13.0, with its API contract (every Discover route served).
    public func useAurral213() {
        state.withLock { $0.version = "2.13.0"; $0.features = Self.features213 }
    }
    /// Round 14: the API contract's feature list (nil: none, as 2.10).
    public func setFeatures(_ features: [String]?) { state.withLock { $0.features = features } }
    /// Round 14: a download source configured (Soulseek) or none at all.
    public func setDownloadSources(configured: Bool) { state.withLock { $0.downloadSourcesConfigured = configured } }
    /// Round 14: the user's role ("admin" passes every permission).
    public func setRole(_ role: String, for username: String) {
        state.withLock { s in for i in s.users.indices where s.users[i].username == username { s.users[i].role = role } }
    }
    /// Round 14: the user's Aurral permissions.
    public func setPermissions(_ permissions: AurralPermissions, for username: String) {
        state.withLock { s in
            for i in s.users.indices where s.users[i].username == username {
                s.users[i].permissions = ["accessFlow": permissions.accessFlow, "addArtist": permissions.addArtist,
                                          "addAlbum": permissions.addAlbum, "changeMonitoring": false]
            }
        }
    }

    /// Aurral 2.13.0's `config/apiContract.ts`.
    public static let features213 = ["discover", "flows", "playlistCoverTemplates", "activity", "review", "trackDownloads",
                                     "linkSearch", "downloadCancel", "shareImports", "trending", "flowAutoDownload"]
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

    // MARK: - Users and sessions (round 13)

    public func addUser(id: Int, username: String, password: String, role: String = "user") {
        state.withLock { $0.users.append(User(id: id, username: username, password: password, role: role)) }
    }
    public func setPassword(_ password: String, for username: String) {
        state.withLock { s in
            for i in s.users.indices where s.users[i].username == username { s.users[i].password = password }
        }
    }
    /// Aurral forgets every session (they expired, or the owner signed out everywhere).
    public func expireAllSessions() { state.withLock { $0.sessions = [:] } }
    /// The login answers 429 (Aurral allows 10 logins in 15 minutes).
    public func setLoginRateLimited(_ on: Bool) { state.withLock { $0.loginRateLimited = on } }
    /// Only the login fails with "can't connect".
    public func setLoginDown(_ on: Bool) { state.withLock { $0.loginDown = on } }
    /// A live session for the user, as if they had logged in (without a request).
    public func issueToken(username: String = StubAurral.defaultUsername) -> String {
        state.withLock { s in
            let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            s.sessions[token] = s.users.first { $0.username == username }?.id ?? 0
            return token
        }
    }
    public func isSessionLive(_ token: String) -> Bool { state.withLock { $0.sessions[token] != nil } }
    /// How many logins were asked for (right or wrong).
    public var loginCount: Int { state.withLock { $0.logins } }

    // MARK: - What was asked

    public var requests: [URLRequest] { state.withLock { $0.requests } }
    /// Each request as "METHOD /path".
    public var asked: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }

    // MARK: - Serving

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.host?.lowercased() == host.lowercased() else {
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
        if path == "/api/auth/login", method != "GET" {
            state.withLock { $0.logins += 1 }
            if snapshot.loginDown { throw URLError(.cannotConnectToHost) }
            if snapshot.loginRateLimited { return answer(429, ["error": "Too many requests"]) }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let password = body["password"] as? String ?? ""
            guard !username.isEmpty, !password.isEmpty else { return answer(400, ["error": "Username and password are required"]) }
            guard let user = snapshot.users.first(where: { $0.username.lowercased() == username && $0.password == password }) else {
                return answer(401, ["error": "Invalid username or password"])
            }
            let token = issueToken(username: user.username)
            let expiresAt = (Date().timeIntervalSince1970 + 30 * 86_400) * 1000
            return answer(200, ["token": token, "expiresAt": expiresAt, "user": Self.userBody(user)])
        }
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let bearer = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : nil
        // Round 14: the bootstrap is open; signed in, it also names the user and the download sources.
        if path == "/api/health/bootstrap", method == "GET" {
            let caller = bearer.flatMap { b in state.withLock { $0.sessions[b] } }.flatMap { id in snapshot.users.first { $0.id == id } }
            return answer(200, Self.bootstrapBody(snapshot, user: caller))
        }
        // Round 14: the preview is open too (Aurral answers with a redirect to Deezer's CDN).
        if let preview = previewAnswer(method: method, path: path, url: url) { return preview }
        // Round 14 A7: the image proxy's file route is open as well (2.13 `guards.ts` isOpen).
        if let file = imageProxyFileAnswer(method: method, path: path, url: url) { return file }
        guard let bearer, let userId = state.withLock({ $0.sessions[bearer] }),
              let user = snapshot.users.first(where: { $0.id == userId }) else {
            return answer(401, ["error": "Unauthorized", "code": bearer == nil ? "AUTH_REQUIRED" : "SESSION_INVALID"])
        }
        if let (status, body) = imageProxyAnswer(method: method, path: path, request: request) { return answer(status, body) }
        func visible(_ flowId: String?) -> Bool {
            if user.role == "admin" { return true }   // Aurral: an admin sees everything
            return snapshot.flows.first(where: { $0.id == flowId })?.ownerUserId == user.id
        }
        switch (method, path) {
        case (let m, "/api/auth/logout") where m != "GET":
            state.withLock { _ = $0.sessions.removeValue(forKey: bearer) }
            return answer(200, ["success": true])
        case ("GET", "/api/auth/me"):
            return answer(200, ["user": Self.userBody(user), "expiresAt": NSNull()])
        // Round 14: Aurral 2.13 guards the flow reads with accessFlow (`requireFlowAccess`; an admin passes).
        case ("GET", "/api/playlists/status") where !Self.mayAccessFlows(user, snapshot),
             ("GET", "/api/playlists/jobs") where !Self.mayAccessFlows(user, snapshot):
            return answer(403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
        case ("GET", "/api/playlists/status"):
            advanceCreations()   // round 14 A4 fix round 1: a queued Add flow is created after its reads
            var scoped = state.withLock { $0 }
            scoped.flows = snapshot.flows.filter { visible($0.id) }
            return answer(200, statusBody(scoped))
        case ("GET", "/api/playlists/jobs"):
            guard snapshot.jobsRoute else { return answer(404, ["error": "Not found"]) }
            return answer(200, snapshot.jobs.enumerated().filter { visible($0.element.flowId) }
                .map { Self.jobBody($0.element, index: $0.offset, hidePaths: snapshot.features != nil) })
        case (_, let p) where p.hasPrefix("/api/library/lookup/") && method == "GET":
            let mbid = String(p.dropFirst("/api/library/lookup/".count))
            let exists = snapshot.inAurralLibrary.contains(mbid)
            return answer(200, ["exists": exists, "artist": exists ? ["foreignArtistId": mbid] : NSNull(), "albums": []])
        case (let m, let p) where p.hasPrefix("/api/playlists/start/") && m != "GET":
            let flowId = String(p.dropFirst("/api/playlists/start/".count))
            guard snapshot.flows.contains(where: { $0.id == flowId }), visible(flowId) else { return answer(404, ["error": "Flow not found"]) }
            state.withLock { s in
                switch s.start {
                case .runs: s.running.insert(flowId)
                case .finishesAtOnce: s.lastRunAt[flowId] = "2026-11-03T12:00:00.000Z"
                case .neverSeen: break
                }
            }
            return answer(200, ["success": true, "flowId": flowId, "queued": true, "operationId": "op-1"])
        default:
            if let (status, body) = chartFlowAnswer(method: method, path: path, request: request, user: user) {
                return answer(status, body)
            }
            if let (status, body) = try await discoverAnswer(method: method, path: path, url: url, request: request,
                                                             user: user, version: snapshot.version) {
                return answer(status, body)
            }
            return answer(404, ["error": "Not found"])
        }
    }

    /// Round 14: the API contract's features (nil before `useAurral213()`).
    var features: [String]? { state.withLock { $0.features } }
    /// Round 14: a download source is configured.
    var hasDownloadSource: Bool { state.withLock { $0.downloadSourcesConfigured } }

    /// Round 14: `GET /api/playlists/jobs/:playlistId`, one flow's songs (as the user may see them; 404 otherwise).
    func jobsAnswer(flowId: String, user: User) -> (Int, Any) {
        let s = state.withLock { $0 }
        // Round 14 A4 fix round 1: a playlist Aurral doesn't have (yet) is 404 for everyone (2.13 canAccessPlaylistType).
        let known = s.flows.contains { $0.id == flowId } || s.synced.contains { $0.id == flowId }
        let mine = known && (user.role == "admin" || s.flows.first(where: { $0.id == flowId })?.ownerUserId == user.id
            || s.synced.first(where: { $0.id == flowId })?.ownerUserId == user.id)
        guard mine else { return (404, ["error": "Playlist not found"]) }
        guard Self.mayAccessFlows(user, s) else { return (403, ["error": "Forbidden"]) }
        return (200, s.jobs.enumerated().filter { $0.element.flowId == flowId }
            .map { Self.jobBody($0.element, index: $0.offset, hidePaths: true) })
    }

    /// The user as Aurral's login, `/api/auth/me` and bootstrap name them (2.13: with permissions).
    private static func userBody(_ user: User) -> [String: Any] {
        let defaults: [String: Bool] = ["accessFlow": false, "addArtist": true, "addAlbum": true, "changeMonitoring": false]
        return ["id": user.id, "username": user.username, "role": user.role, "permissions": user.permissions ?? defaults]
    }

    private static func bootstrapBody(_ s: State, user: User?) -> [String: Any] {
        var body: [String: Any] = ["status": "ok", "authRequired": true, "onboardingRequired": false,
                                   "timestamp": "2026-11-04T00:00:00.000Z"]
        if let version = s.version { body["appVersion"] = version }
        if let features = s.features {
            body["api"] = ["version": 1, "features": features]
            body["matcher"] = ["available": true, "policyVersion": "aurral-native-6"]
        }
        if let user {
            body["user"] = userBody(user)
            body["authUser"] = user.username
            if s.features != nil {
                let on = s.downloadSourcesConfigured
                body["downloadSources"] = [
                    "slskd": ["id": "slskd", "label": "Soulseek", "enabled": on, "configured": on, "priority": 1],
                    "usenet": ["id": "usenet", "label": "Usenet", "enabled": false, "configured": false, "priority": 2,
                               "prowlarrConfigured": false, "nzbgetConfigured": false, "sabnzbdConfigured": false,
                               "tidarrConfigured": false],
                    "deemix": ["id": "deemix", "label": "Deemix", "enabled": false, "configured": false, "priority": 3],
                    "ytdlp": ["id": "ytdlp", "label": "yt-dlp", "enabled": false, "configured": false, "priority": 4],
                ]
                body["slskdConfigured"] = on
            }
        }
        return body
    }

    private func statusBody(_ s: State) -> [String: Any] {
        var flowStats: [String: Any] = [:]
        for flow in s.flows + s.synced {
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
                ["id": f.id, "name": f.name, "ownerUserId": f.ownerUserId.map { $0 as Any } ?? NSNull(),
                 "ownerUsername": (s.users.first { $0.id == f.ownerUserId }?.username).map { $0 as Any } ?? NSNull(), "enabled": f.enabled,
                 "size": f.size, "autoDownload": f.autoDownload.map { $0 as Any } ?? NSNull(),
                 "scheduleDays": [5], "scheduleTime": "00:00", "nextRunAt": "2026-11-06T00:00:00.000Z",
                 "lastRunAt": s.lastRunAt[f.id] ?? "2026-10-30T00:00:00.000Z", "mix": ["discover": 100], "lidarrFeedToken": "secret-feed-token"]
            },
            // Round 14 A4: the synced playlists Add flow made (Aurral 2.13 lists them beside the flows).
            // Fix round 1 (M1): upstream 2.13's shape (playlistStatusSnapshot.ts staticPlaylistsWithOwners).
            "sharedPlaylists": s.synced.map { p in
                ["id": p.id, "name": p.name, "ownerUserId": p.ownerUserId.map { $0 as Any } ?? NSNull(),
                 "ownerUsername": (s.users.first { $0.id == p.ownerUserId }?.username).map { $0 as Any } ?? NSNull(),
                 "trackCount": s.jobs.filter { $0.flowId == p.id }.count, "sourceName": p.name, "sourceFlowId": NSNull(),
                 "importedAt": "2026-11-04T00:00:00.000Z", "createdAt": "2026-11-04T00:00:00.000Z",
                 "recordHistory": false, "showTrackAvailability": true, "artworkRevision": 1,
                 "importSource": s.syncedProviders[p.id].map { provider -> Any in
                     ["provider": provider, "syncEnabled": true, "syncIntervalHours": 24, "keepRemovedTracks": true]
                 } ?? NSNull()] as [String: Any]
            },
            "operationQueue": ["processing": busy, "pending": 0, "currentLabel": busy ? "Generating flow" : NSNull()],
            "hint": ["phase": busy ? "running" : "idle", "message": busy ? "Getting songs" : "Next update in 5 days"],
        ]
    }

    /// 2.10 lets every signed-in user read flows; 2.13 needs accessFlow (an admin passes).
    private static func mayAccessFlows(_ user: User, _ s: State) -> Bool {
        s.features == nil || user.role == "admin" || user.permissions?["accessFlow"] == true
    }

    /// One job as Aurral answers it. Round 14: Aurral 2.13's `toPublicJob` drops `finalPath` (`hidePaths`).
    private static func jobBody(_ j: Job, index: Int, hidePaths: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["id": "job-\(index)", "artistName": j.artistName, "trackName": j.trackName,
                                   "albumName": j.albumName, "playlistId": j.flowId, "playlistType": j.flowId,
                                   "managedBy": "aurral", "status": j.status, "downloadSource": "slskd"]
        if let v = j.artistMbid { body["artistMbid"] = v }
        if let v = j.trackMbid { body["trackMbid"] = v }
        if let v = j.durationMs { body["durationMs"] = v }
        if let v = j.finalPath, !hidePaths { body["finalPath"] = v }
        return body
    }
}
