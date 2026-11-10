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
        /// Round 16: the recipe fields a create or edit sent (JSON object), shown in the status over the defaults.
        public var recipe: Data?
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
        /// Round 24 C fix round 1 (I4): a song's progress (sent as `progress`, which 2.13 doesn't have) and Aurral's
        /// words about it (sent as 2.13's `error`). Not sent when nil.
        public var progress: Double?
        public var message: String?
        /// Round 25 J: the static playlist this Library job is a song of (2.13's track `canonicalJobId`): listed under
        /// "library" in `/jobs`, and as that playlist's in its `jobs/:id`.
        public var referencedBy: String?
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
        /// Round 15 C2 fix round: each static playlist's `sourceName` (a chart flow's is "Charts"), the songs whose files
        /// Aurral deleted, and each chart flow create (id, name, failed for a taken name).
        var syncedSourceNames: [String: String] = [:]
        var deletedFiles: [String] = []
        var createAttempts: [(String, String, Bool)] = []
        /// Round 15 C2 fix round: every chart flow creation fails in the worker (as a taken name or a server error does).
        var chartFlowCreationFails = false
        /// Re-review I3: deletes 2.13 has queued: the playlist stays listed for this many more status reads.
        var pendingDeletes: [String: Int] = [:]
        var deleteDelayReads = 1
        /// Re-review M-c: the status read answers this status instead (nil: as usual).
        var statusFailure: Int?
        var creationDelayReads = 1
        /// Round 24 B: the jobs whose held copy was denied.
        var denied: [String] = []
    }

    struct PendingSynced {
        var flow: Flow
        var provider: String?
        var songs: [(title: String, artist: String, durationMs: Int)]
        var readsLeft: Int
        /// Round 15 C2: every song done once made (a chart flow), rather than `syncedJobStatuses`.
        var allDone = false
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
            guard s.synced.contains(where: { $0.id == id }), s.pendingDeletes[id] == nil else { return nil }
            return s.jobs.filter { $0.flowId == id }.map { ($0.trackName, $0.artistName) }
        }
    }

    /// Round 15 C2 (D131, fix round I1/I2): Aurral 2.13's own playlists, as `routes/playlists/handlers/staticPlaylists.ts`
    /// and its queued operations serve them (accessFlow; an admin passes):
    /// - `POST /api/playlists/shared-playlists {name, sourceName, tracks}` answers 200 with a new id **at once, whatever
    ///   the name** (2.13 queues `shared-playlist-create`); the worker then makes it, or, when the user already has a
    ///   playlist or a flow of that name (trimmed, case folded: `assertUniqueStaticPlaylistName`), fails the job and the
    ///   playlist never appears. Honours `setSyncedCreationDelay(reads:)` like Add flow.
    /// - `POST …/:id/tracks {tracks}` appends the songs it doesn't have yet (queued, done at once here).
    /// - `POST …/:id/track-removals {jobIds}` takes those songs out and deletes their files (`chartFlowDeletedFiles`).
    /// - `DELETE …/:id` removes it and deletes its songs' files. A playlist that isn't the user's is 404.
    /// Jobs left by removed songs are orphaned (`flowId` ""), so `job-<index>` ids stay put.
    func chartFlowAnswer(method: String, path: String, request: URLRequest, user: User) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "playlists", parts[2] == "shared-playlists",
              features != nil else { return nil }
        // G1 allowlist: stub aurral chart flows (the verbs the stub answers; it sends nothing).
        let verbs = (post: "POST", delete: "DELETE")
        let isCreate = method == verbs.post && parts.count == 3
        let isAppend = method == verbs.post && parts.count == 5 && parts[4] == "tracks"
        let isRemoval = method == verbs.post && parts.count == 5 && parts[4] == "track-removals"
        let isDelete = method == verbs.delete && parts.count == 4
        guard isCreate || isAppend || isRemoval || isDelete else { return nil }
        guard user.role == "admin" || user.permissions?["accessFlow"] == true else {
            return (403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
        }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let songs = ((body["tracks"] as? [[String: Any]]) ?? []).compactMap { t -> (title: String, artist: String, durationMs: Int)? in
            guard let title = (t["trackName"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let artist = (t["artistName"] as? String)?.trimmingCharacters(in: .whitespaces), !artist.isEmpty else { return nil }
            return (title, artist, t["durationMs"] as? Int ?? 0)
        }
        let jobIds = (body["jobIds"] as? [String]) ?? []
        let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let sourceName = body["sourceName"] as? String
        let sentTracks = body["tracks"] != nil
        // (status, the playlist's id, Aurral's error words, accepted job ids)
        let outcome = state.withLock { s -> (Int, String?, String?, [String]) in
            if isCreate {
                guard !name.isEmpty else { return (400, nil, "name is required", []) }
                if sentTracks, songs.isEmpty {
                    return (400, nil, "tracks are invalid", [])
                }
                let id = UUID().uuidString.lowercased()
                let key = name.lowercased()
                let taken = s.synced.contains { $0.name.lowercased() == key && $0.ownerUserId == user.id }
                    || s.pendingSynced.contains { $0.flow.name.lowercased() == key && $0.flow.ownerUserId == user.id }
                    || s.flows.contains { $0.name.lowercased() == key && ($0.ownerUserId ?? user.id) == user.id }
                let fails = taken || s.chartFlowCreationFails
                s.createAttempts.append((id, name, fails))
                guard !fails else { return (200, id, nil, []) }   // 2.13: the worker fails it later (name conflict)
                let flow = Flow(id: id, name: name, size: songs.count, ownerUserId: user.id)
                if let sourceName { s.syncedSourceNames[id] = sourceName }
                if s.creationDelayReads == 0 {
                    Self.create(&s, flow: flow, provider: nil, songs: songs, statuses: songs.map { _ in "done" })
                } else {
                    s.pendingSynced.append(PendingSynced(flow: flow, provider: nil, songs: songs, readsLeft: s.creationDelayReads,
                                                         allDone: true))
                }
                return (200, id, nil, [])
            }
            let id = parts[3]
            guard let index = s.synced.firstIndex(where: { $0.id == id && (user.role == "admin" || $0.ownerUserId == user.id) })
            else { return (404, nil, "Playlist not found", []) }
            func key(_ artist: String, _ title: String) -> String { "\(artist.lowercased())|\(title.lowercased())" }
            if isDelete {
                // 2.13 queues `shared-playlist-delete`: the worker deletes the files, then the playlist; until then the
                // status still lists it (one more read here).
                if s.pendingDeletes[id] == nil {
                    for job in s.jobs where job.flowId == id { s.deletedFiles.append(key(job.artistName, job.trackName)) }
                    s.pendingDeletes[id] = s.deleteDelayReads
                }
                _ = index
                return (200, id, nil, [])
            }
            if isRemoval {
                guard !jobIds.isEmpty else { return (400, nil, "jobIds must contain at least one track ID", []) }
                var accepted: [String] = []
                for jobId in jobIds {
                    guard jobId.hasPrefix("job-"), let i = Int(jobId.dropFirst(4)), s.jobs.indices.contains(i),
                          s.jobs[i].flowId == id else { continue }
                    s.deletedFiles.append(key(s.jobs[i].artistName, s.jobs[i].trackName))
                    s.jobs[i].flowId = ""
                    accepted.append(jobId)
                }
                s.synced[index].size = s.jobs.filter { $0.flowId == id }.count
                return (200, id, nil, accepted)
            }
            guard !songs.isEmpty else { return (400, nil, "tracks are required", []) }
            let have = Set(s.jobs.filter { $0.flowId == id }.map { key($0.artistName, $0.trackName) })
            for song in songs where !have.contains(key(song.artist, song.title)) {
                s.jobs.append(Job(flowId: id, artistName: song.artist, trackName: song.title, durationMs: song.durationMs,
                                  status: "done"))
            }
            s.synced[index].size = s.jobs.filter { $0.flowId == id }.count
            return (200, id, nil, [])
        }
        guard let id = outcome.1 else { return (outcome.0, ["error": outcome.2 ?? "Failed"]) }
        if isRemoval {
            return (200, ["queued": !outcome.3.isEmpty, "operationId": "op-remove", "acceptedJobIds": outcome.3,
                          "rejected": jobIds.filter { !outcome.3.contains($0) }.map { ["jobId": $0, "message": "Track not found in this playlist"] }])
        }
        return (200, ["success": true, "playlistId": id, "queued": true,
                      "operationId": isCreate ? "op-create" : isDelete ? "op-delete" : "op-append"])
    }

    /// Round 16: Aurral 2.13's recipe flows (`routes/playlists/handlers/flows.ts`; accessFlow, an admin passes):
    /// - `POST /api/playlists/flows {name, …}` makes the flow **off** at once and answers `{success, flow}`; a name the
    ///   user already has (a flow or a shared playlist, case folded) is a 400 "Flow name already exists";
    /// - `PUT …/:id/enabled {enabled}` turns it on (its first run: `size` songs, all done here) or off (its songs go);
    /// - `PUT …/:id {…}` merges the fields sent into the recipe (a rename is checked like a create);
    /// - `DELETE …/:id` queues the delete: its songs' files go (`chartFlowDeletedFiles`) and the flow stays listed for
    ///   `setDeleteDelay(reads:)` more status reads.
    /// A flow that isn't the user's is 404.
    func recipeFlowAnswer(method: String, path: String, request: URLRequest, user: User) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "playlists", parts[2] == "flows", features != nil else { return nil }
        // G1 allowlist: stub aurral recipe flows (the verbs the stub answers; it sends nothing).
        let verbs = (post: "POST", put: "PUT", delete: "DELETE")
        let isCreate = method == verbs.post && parts.count == 3
        let isEnable = method == verbs.put && parts.count == 5 && parts[4] == "enabled"
        let isUpdate = method == verbs.put && parts.count == 4
        let isDelete = method == verbs.delete && parts.count == 4
        guard isCreate || isEnable || isUpdate || isDelete else { return nil }
        guard user.role == "admin" || user.permissions?["accessFlow"] == true else {
            return (403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
        }
        let sent = request.httpBody
        let reply = state.withLock { s -> (Int, Data) in
            let body = sent.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            func json(_ status: Int, _ o: [String: Any]) -> (Int, Data) {
                (status, (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
            }
            func taken(_ name: String, except id: String?) -> Bool {
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                return s.flows.contains { $0.id != id && $0.name.lowercased() == key && ($0.ownerUserId ?? user.id) == user.id }
                    || s.synced.contains { $0.name.lowercased() == key && $0.ownerUserId == user.id }
            }
            func recipe(_ old: Data?, merging fields: [String: Any]) -> Data? {
                var o = old.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                for (key, value) in fields where key != "name" && key != "templateId" { o[key] = value }
                return try? JSONSerialization.data(withJSONObject: o)
            }
            if isCreate {
                let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return json(400, ["error": "name is required"]) }
                guard !taken(name, except: nil) else { return json(400, ["error": "Flow name already exists"]) }
                var flow = Flow(id: UUID().uuidString.lowercased(), name: name, enabled: false,
                                size: body["size"] as? Int ?? 30, ownerUserId: user.id)
                flow.autoDownload = body["autoDownload"] as? Bool ?? true
                flow.recipe = recipe(nil, merging: body)
                s.flows.append(flow)
                return json(200, ["success": true, "flow": ["id": flow.id, "name": flow.name, "enabled": false]])
            }
            guard let index = s.flows.firstIndex(where: { $0.id == parts[3] && (user.role == "admin" || $0.ownerUserId == user.id) }),
                  s.pendingDeletes[parts[3]] == nil
            else { return json(404, ["error": "Flow not found"]) }
            let id = parts[3]
            if isEnable {
                let on = body["enabled"] as? Bool ?? false
                s.flows[index].enabled = on
                s.jobs = s.jobs.map { var j = $0; if j.flowId == id { j.flowId = "" }; return j }
                if on {
                    for n in 1...max(1, s.flows[index].size) {
                        s.jobs.append(Job(flowId: id, artistName: "Recipe Artist \(n)", trackName: "Recipe Song \(n)", status: "done"))
                    }
                }
                return json(200, ["success": true, "flowId": id, "enabled": on])
            }
            if isDelete {
                for job in s.jobs where job.flowId == id {
                    s.deletedFiles.append("\(job.artistName.lowercased())|\(job.trackName.lowercased())")
                }
                s.pendingDeletes[id] = s.deleteDelayReads
                return json(200, ["success": true, "flowId": id, "queued": true, "operationId": "op-delete-flow"])
            }
            if let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespaces) {
                guard !name.isEmpty else { return json(400, ["error": "name is required"]) }
                guard !taken(name, except: id) else { return json(400, ["error": "Flow name already exists"]) }
                s.flows[index].name = name
            }
            if let size = body["size"] as? Int { s.flows[index].size = size }
            if let auto = body["autoDownload"] as? Bool { s.flows[index].autoDownload = auto }
            s.flows[index].recipe = recipe(s.flows[index].recipe, merging: body)
            return json(200, ["success": true, "flow": ["id": id, "name": s.flows[index].name]])
        }
        return (reply.0, (try? JSONSerialization.jsonObject(with: reply.1)) ?? [String: Any]())
    }

    /// Round 16: the recipe fields a flow holds now (as the status lists them), or nil when there is no such flow.
    public func recipeFlowFields(_ id: String) -> [String: Any]? {
        guard let flow = state.withLock({ s in s.flows.first(where: { $0.id == id }) }) else { return nil }
        var o = flow.recipe.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        o["name"] = flow.name
        o["enabled"] = flow.enabled
        return o
    }

    /// Round 15 C2 fix round: every chart flow creation from now fails in Aurral's worker (accepted, never made).
    public func setChartFlowCreationFails(_ on: Bool) { state.withLock { $0.chartFlowCreationFails = on } }
    /// Re-review M-c: `GET /api/playlists/status` answers this status (nil: as usual).
    public func setStatusFailure(_ status: Int?) { state.withLock { $0.statusFailure = status } }
    /// Re-review I3: how many more status reads a deleted playlist stays listed (2.13 runs the delete in its worker).
    public func setDeleteDelay(reads: Int) { state.withLock { $0.deleteDelayReads = max(0, reads) } }

    /// Round 15 C2 fix round: the songs ("artist|title", lower-cased) whose files Aurral deleted (track removals and
    /// playlist deletes), in order.
    public var chartFlowDeletedFiles: [String] { state.withLock { $0.deletedFiles } }
    /// Round 15 C2 fix round: each chart flow create asked for (id, name, and whether the worker failed it as a
    /// name already taken).
    public var chartFlowCreates: [(id: String, name: String, failed: Bool)] {
        state.withLock { $0.createAttempts.map { (id: $0.0, name: $0.1, failed: $0.2) } }
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
                    Self.create(&s, flow: p.flow, provider: p.provider, songs: p.songs,
                                statuses: p.allDone ? p.songs.map { _ in "done" } : s.syncedJobStatuses)
                } else {
                    p.readsLeft -= 1
                    waiting.append(p)
                }
            }
            s.pendingSynced = waiting
            for (id, left) in s.pendingDeletes {
                if left > 0 { s.pendingDeletes[id] = left - 1; continue }
                s.pendingDeletes[id] = nil
                s.synced.removeAll { $0.id == id }
                s.flows.removeAll { $0.id == id }   // round 16: a recipe flow's queued delete
                s.syncedProviders[id] = nil
                for i in s.jobs.indices where s.jobs[i].flowId == id { s.jobs[i].flowId = "" }
            }
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

    /// Round 23 R23F: one song (`job-<index>`) now has this status (Aurral found it, gave up on it, …).
    public func setJobStatus(_ jobId: String, _ status: String) {
        guard jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)) else { return }
        state.withLock { s in if s.jobs.indices.contains(index) { s.jobs[index].status = status } }
    }

    /// Round 24 C fix round 1 (I4): one song's (`job-<index>`) progress and Aurral's words about it.
    public func setJobDetail(_ jobId: String, progress: Double?, message: String?) {
        guard jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)) else { return }
        state.withLock { s in
            guard s.jobs.indices.contains(index) else { return }
            s.jobs[index].progress = progress
            s.jobs[index].message = message
        }
    }

    /// Round 24 B: one song's status now (`job-<index>`), nil when there is no such job.
    public func jobStatus(_ jobId: String) -> String? {
        guard jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)) else { return nil }
        return state.withLock { s in s.jobs.indices.contains(index) ? s.jobs[index].status : nil }
    }

    /// Round 24 B: the songs whose held copy was denied (Aurral's `recordDeniedSource`), in order.
    public var deniedJobs: [String] { state.withLock { $0.denied } }

    /// Round 24 B (D209): Aurral 2.13's review of a song held back (`routes/playlists/handlers/jobs.ts`,
    /// `blockedJobReview.ts`; accessFlow, an admin passes, and, as upstream, no check of whose song it is):
    /// - `POST /api/playlists/jobs/:jobId/approve` imports the held copy (the job `done`);
    /// - `POST …/deny` discards it, records its source as denied and sets the job `pending` again;
    /// - either on a job that isn't `blocked` (or doesn't exist) is 404 "Blocked job not found".
    func heldSongAnswer(method: String, path: String, user: User) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        // G1 allowlist: stub aurral held songs (the verb the stub answers, as 2.13 routes only POST; it sends nothing).
        let verb = "POST"
        guard method == verb, parts.count == 5, parts[0] == "api", parts[1] == "playlists", parts[2] == "jobs",
              parts[4] == "approve" || parts[4] == "deny", features != nil else { return nil }
        guard user.role == "admin" || user.permissions?["accessFlow"] == true else {
            return (403, ["error": "Forbidden", "message": "Missing permission: accessFlow"])
        }
        let jobId = parts[3], approve = parts[4] == "approve"
        let done = state.withLock { s -> Bool in
            guard jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)), s.jobs.indices.contains(index),
                  s.jobs[index].status == "blocked" else { return false }
            if approve {
                s.jobs[index].status = "done"
            } else {
                s.jobs[index].status = "pending"
                s.denied.append(jobId)
            }
            return true
        }
        guard done else { return (404, ["error": "Blocked job not found"]) }
        var body: [String: Any] = ["success": true]
        if approve { body["path"] = "/music/aurral/" + jobId + ".flac" }
        return (200, body)
    }

    /// Round 23 R23F: the research route's refusals (2.13 `enqueueResearchTrack`) for a user allowed to ask: a song of
    /// another playlist is 404, one pending or downloading 409. Nil: answered as before.
    func researchRefusal(playlistId: String, jobId: String, user: User) -> (Int, Any)? {
        guard user.role == "admin" || user.permissions?["accessFlow"] == true,
              jobId.hasPrefix("job-"), let index = Int(jobId.dropFirst(4)) else { return nil }
        let job = state.withLock { s in s.jobs.indices.contains(index) ? s.jobs[index] : nil }
        guard let job else { return nil }
        if job.flowId != playlistId { return (404, ["error": "Track not found"]) }
        if job.status == "pending" || job.status == "downloading" {
            return (409, ["error": "Track is already being processed"])
        }
        return nil
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
    /// Round 25 J: the static playlist's songs become references to Library jobs, as Aurral 2.13 keeps a track added
    /// from the Library (`canonicalJobId`): `GET /api/playlists/jobs` lists them as the Library's (`playlistId`
    /// "library"), and only `GET /api/playlists/jobs/:playlistId` lists them as the playlist's (2.13's `jobs.ts`
    /// rewrites a referenced job's `playlistId` to the playlist asked for). `titles`: only these songs (nil: every one).
    /// Fix round 1 (M3): the reference is kept on the job itself, so it goes with it (`setJobs` replaces both).
    public func referenceLibrarySongs(playlistId: String, titles: Set<String>? = nil) {
        state.withLock { s in
            for i in s.jobs.indices where s.jobs[i].flowId == playlistId && titles.map({ $0.contains(s.jobs[i].trackName) }) ?? true {
                s.jobs[i].flowId = "library"
                s.jobs[i].referencedBy = playlistId
            }
        }
    }
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
            if flowId == "library" { return true }   // Round 25 J: 2.13's canAccessJobType ("library" is everyone's)
            return snapshot.flows.first(where: { $0.id == flowId })?.ownerUserId == user.id
                || snapshot.synced.first(where: { $0.id == flowId })?.ownerUserId == user.id
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
        case ("GET", "/api/playlists/status") where snapshot.statusFailure != nil:
            return answer(snapshot.statusFailure ?? 500, ["error": "Stub failure"])
        case ("GET", "/api/playlists/status"):
            advanceCreations()   // round 14 A4 fix round 1: a queued Add flow is created after its reads
            var scoped = state.withLock { $0 }
            scoped.flows = snapshot.flows.filter { visible($0.id) }
            // Round 25 J: as 2.13's getStaticPlaylistsForUser, a user who isn't an admin is shown only their own.
            scoped.synced = scoped.synced.filter { user.role == "admin" || $0.ownerUserId == user.id }
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
            if let (status, body) = recipeFlowAnswer(method: method, path: path, request: request, user: user) {
                return answer(status, body)
            }
            if let (status, body) = heldSongAnswer(method: method, path: path, user: user) { return answer(status, body) }
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
        // Round 25 J: the playlist's references to Library jobs too, as the playlist's (2.13's `jobs.ts`).
        return (200, s.jobs.enumerated().filter { $0.element.flowId == flowId || $0.element.referencedBy == flowId }
            .map { item -> [String: Any] in
                var job = item.element
                job.flowId = flowId
                return Self.jobBody(job, index: item.offset, hidePaths: true)
            })
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
                var o: [String: Any] = ["id": f.id, "name": f.name, "ownerUserId": f.ownerUserId.map { $0 as Any } ?? NSNull(),
                 "ownerUsername": (s.users.first { $0.id == f.ownerUserId }?.username).map { $0 as Any } ?? NSNull(), "enabled": f.enabled,
                 "size": f.size, "autoDownload": f.autoDownload.map { $0 as Any } ?? NSNull(),
                 "scheduleDays": [5], "scheduleTime": "00:00", "nextRunAt": "2026-11-06T00:00:00.000Z",
                 "lastRunAt": s.lastRunAt[f.id] ?? "2026-10-30T00:00:00.000Z", "mix": ["discover": 100], "lidarrFeedToken": "secret-feed-token"]
                for (key, value) in f.recipe.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] {
                    o[key] = value
                }
                o["name"] = f.name
                return o
            },
            // Round 14 A4: the synced playlists Add flow made (Aurral 2.13 lists them beside the flows).
            // Fix round 1 (M1): upstream 2.13's shape (playlistStatusSnapshot.ts staticPlaylistsWithOwners).
            "sharedPlaylists": s.synced.map { p in
                ["id": p.id, "name": p.name, "ownerUserId": p.ownerUserId.map { $0 as Any } ?? NSNull(),
                 "ownerUsername": (s.users.first { $0.id == p.ownerUserId }?.username).map { $0 as Any } ?? NSNull(),
                 "trackCount": s.jobs.filter { $0.flowId == p.id }.count, "sourceName": (s.syncedSourceNames[p.id] ?? (s.syncedProviders[p.id] == "deezer-playlist" ? "Deezer" : nil)).map { $0 as Any } ?? NSNull(), "sourceFlowId": NSNull(),
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
        if let v = j.progress { body["progress"] = v }
        if let v = j.message { body["error"] = v }
        return body
    }
}
