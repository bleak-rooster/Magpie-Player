import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex
import NavidromeKit

/// What the runner needs from the music library: a plain quick scan (A12: no path mapping in v1), scan
/// status, a match-index refresh, and "is this recording in the library now" (D7: Ready = Navidrome lists it).
public struct LibraryAccess: Sendable {
    public var startScan: @Sendable () async throws -> Void
    public var isScanning: @Sendable () async throws -> Bool
    public var refreshIndex: @Sendable () async throws -> Void
    public var songId: @Sendable (ExternalRecording) async -> String?

    public init(startScan: @escaping @Sendable () async throws -> Void,
                isScanning: @escaping @Sendable () async throws -> Bool,
                refreshIndex: @escaping @Sendable () async throws -> Void,
                songId: @escaping @Sendable (ExternalRecording) async -> String?) {
        self.startScan = startScan; self.isScanning = isScanning
        self.refreshIndex = refreshIndex; self.songId = songId
    }

    /// Straight to one Navidrome client and match index (`startScan` is always `fullScan=false`, G7).
    public static func navidrome(_ client: NavidromeClient, index: MatchIndexStore) -> LibraryAccess {
        LibraryAccess(startScan: { try await client.startScan(target: nil) },
                      isScanning: { try await client.scanStatus() },
                      refreshIndex: { try await index.refresh(using: client) },
                      songId: { await index.index.librarySong(for: $0) })
    }
}

/// Runs Try requests against Lidarr in fallback mode (M5): the album goes into the owner's main root folder.
///
/// Effects of `RequestMachine` are executed here:
/// - new artist: one atomic `POST /artist` built from `artist/lookup` (A6, main root instead of Finds root);
/// - existing artist: `PUT /album/monitor` + `AlbumSearch` on one album it already has (A7, G6), never a
///   change to the artist;
/// - dedupe by release group against running requests, the ledger and Lidarr; at most 5 active (G7);
/// - Ready only when the match index finds the recording after a plain `startScan` (A12, D7);
/// - Cancel unmonitors the album only when Magpie monitored it, and never deletes anything (G6).
///
/// Every write goes through `LidarrWriteGate` (G1) and every album Magpie touches is in the `Ledger` first.
/// Call `tick()` on a timer (5 s in the foreground, 30 s otherwise); it does nothing for finished requests.
public actor RequestRunner {
    public static let maxActive = 5
    /// At most one match-index refresh per this many seconds (brief ruling 4).
    public static let indexRefreshInterval: TimeInterval = 30
    /// Another `startScan` while a request is importing and still not listed.
    public static let rescanInterval: TimeInterval = 120
    /// Lidarr unanswered this long while polling: the request waits (`serviceUnavailable`).
    public static let lidarrSilenceLimit: TimeInterval = 300
    /// A newly added artist's album has this long to appear (Lidarr refreshes the artist asynchronously).
    public static let albumAppearLimit: TimeInterval = 15 * 60
    /// After adding an artist, Lidarr may still (re)apply `albumsToMonitor` this long; Cancel keeps checking.
    public static let addSettleTime: TimeInterval = 10 * 60

    public static func pollInterval(foreground: Bool) -> Duration { foreground ? .seconds(5) : .seconds(30) }

    /// Where fallback-mode adds go and how they are set up (from provisioning and the owner's root choice).
    public struct Setup: Sendable, Equatable {
        public var rootFolderPath: String
        public var qualityProfileId: Int
        public var metadataProfileId: Int
        public var tagIds: [Int]

        public init(rootFolderPath: String, qualityProfileId: Int, metadataProfileId: Int, tagIds: [Int]) {
            self.rootFolderPath = rootFolderPath; self.qualityProfileId = qualityProfileId
            self.metadataProfileId = metadataProfileId; self.tagIds = tagIds
        }
    }

    public enum TryError: Error, Equatable {
        /// "Allow Magpie to change Lidarr" is off (G1).
        case changesOff
        /// Not provisioned, or no main root folder chosen.
        case notSetUp
        /// Five requests are already on their way (G7).
        case tooMany
        /// Saved requests can't be read right now.
        case unavailable
    }

    private let lidarr: LidarrClient
    private let gate: LidarrWriteGate
    private let ledger: Ledger
    private let mb: MusicBrainzClient
    private let library: LibraryAccess
    private let store: RequestStore
    private let setup: @Sendable () async -> Setup?
    private let now: @Sendable () -> Date
    private let onReady: @Sendable (MagpieRequest) -> Void

    private var list: [MagpieRequest] = []
    private var loaded = false
    private var busy: Set<RequestID> = []
    private var inFlight: [RequestID: Task<Void, Never>] = [:]
    private var ticking = false
    private var stopped = false
    private var lastIndexRefresh: Date?
    private var lastLidarrContact: Date
    private var watchers: [UUID: AsyncStream<[MagpieRequest]>.Continuation] = [:]

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, ledger: Ledger, mb: MusicBrainzClient,
                library: LibraryAccess, store: RequestStore,
                setup: @escaping @Sendable () async -> Setup?,
                now: @escaping @Sendable () -> Date = { Date() },
                onReady: @escaping @Sendable (MagpieRequest) -> Void = { _ in }) {
        self.lidarr = lidarr; self.gate = gate; self.ledger = ledger; self.mb = mb
        self.library = library; self.store = store; self.setup = setup; self.now = now; self.onReady = onReady
        self.lastLidarrContact = now()
    }

    // MARK: - Public surface

    public var requests: [MagpieRequest] { list }

    /// The request list now and after every change.
    public var updates: AsyncStream<[MagpieRequest]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [MagpieRequest].self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        watchers[key] = continuation
        continuation.yield(list)
        continuation.onTermination = { [weak self] _ in Task { await self?.unwatch(key) } }
        return stream
    }

    private func unwatch(_ key: UUID) { watchers[key] = nil }

    /// Whether `tick()` has anything to do: an active request or a clean-up still owed.
    public var needsPolling: Bool { list.contains { $0.isActive || $0.cleanupPending } }

    /// Loads the saved requests (resume after relaunch). Safe to call again.
    @discardableResult
    public func load() async -> Bool {
        if loaded { return true }
        do {
            list = try await store.load()
            loaded = true
            publish()
            return true
        } catch {
            return false
        }
    }

    /// Asks for `recording`. A request for the same song that is still on its way (or ready) is returned
    /// instead of a new one. Work continues in the background; watch `updates`.
    public func tryRecording(_ recording: ExternalRecording, tier: Tier) async throws -> RequestID {
        guard !stopped, await load() else { throw TryError.unavailable }
        if let existing = list.first(where: { ($0.isActive || $0.state == .ready) && Self.sameSong($0.recording, recording) }) {
            return existing.id
        }
        guard await gate.enabled else { throw TryError.changesOff }
        guard await setup() != nil else { throw TryError.notSetUp }
        guard list.filter(\.isActive).count < Self.maxActive else { throw TryError.tooMany }
        let request = MagpieRequest(recording: recording, tier: tier, createdAt: now())
        list.append(request)
        await changed()
        let id = request.id
        inFlight[id] = Task {
            await self.advance(id)
            self.finished(id)
        }
        return id
    }

    /// G6: stops the request. Unmonitors the album only if Magpie monitored it; never deletes anything.
    public func cancel(_ id: RequestID) async {
        await apply(id, .cancel)
    }

    /// Removes a finished (or ready) request from the list. Clean-up still owed keeps it.
    public func forget(_ id: RequestID) async {
        guard let r = request(id), !r.isActive, !r.cleanupPending else { return }
        list.removeAll { $0.id == id }
        await changed()
    }

    /// Retires this runner (sign-out, another Lidarr): no further steps, writes or saves. A write already
    /// on the wire still completes; nothing follows it. Call before another runner loads the same store.
    public func stop() {
        stopped = true
        for c in watchers.values { c.finish() }
        watchers = [:]
    }

    /// Waits for work started by `tryRecording` (tests).
    public func settle() async {
        while let entry = inFlight.first {
            await entry.value.value
            inFlight[entry.key] = nil
        }
    }

    private func finished(_ id: RequestID) { inFlight[id] = nil }

    /// One pass: resume interrupted steps, retry what is due, poll Lidarr, scan and check the library.
    public func tick() async {
        guard !ticking, !stopped, await load() else { return }
        ticking = true
        defer { ticking = false }
        for r in list where r.isActive { await advance(r.id) }
        await discoverAlbums()
        await pollLidarr()
        await checkLibrary()
        for r in list where r.cleanupPending && !busy.contains(r.id) { await cleanup(r.id) }
    }

    // MARK: - The machine

    private func request(_ id: RequestID) -> MagpieRequest? { list.first { $0.id == id } }

    private func mutate(_ id: RequestID, _ change: (inout MagpieRequest) -> Void) async {
        guard !stopped, let i = list.firstIndex(where: { $0.id == id }) else { return }
        var r = list[i]
        change(&r)
        guard r != list[i] else { return }
        r.updatedAt = now()
        list[i] = r
        await changed()
    }

    private func changed() async {
        guard !stopped else { return }
        do { try await store.save(list) } catch {
            Log.logger("requests").error("requests not saved: \(error.localizedDescription, privacy: .public)")
        }
        publish()
    }

    private func publish() {
        for c in watchers.values { c.yield(list) }
    }

    /// Re-runs whatever step the request is in when nothing is running for it (after a relaunch, a retry
    /// timer, or `tryRecording`).
    private func advance(_ id: RequestID) async {
        guard !busy.contains(id), let r = request(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        switch r.state {
        case .pending:
            await apply(id, .start)
        case .resolving:
            await perform(.resolveRelease, id)
        case .adding:
            if let plan = r.plan { await perform(.addOrMonitor(plan), id) } else { await perform(.resolveRelease, id) }
        case .searching where r.searchStartedAt == nil:
            await perform(.startSearch, id)
        case .waiting(_, let retryAt) where now() >= retryAt:
            await apply(id, .retryDue)
        default:
            break
        }
        if request(id)?.cleanupPending == true { await cleanup(id) }
    }

    private func apply(_ id: RequestID, _ event: RequestEvent) async {
        guard var r = request(id) else { return }
        let (next, effects) = RequestMachine.step(r.state, event, now: now(), prior: r.priorWait)
        guard next != r.state || !effects.isEmpty else { return }
        r.state = next
        switch next {
        case .waiting(let reason, _): r.priorWait = reason
        case .downloading, .importing, .ready: r.priorWait = nil
        default: break
        }
        if case .visibleInLibrary(let songId) = event { r.songId = songId }
        if effects.contains(.cleanup) { r.cleanupPending = true }
        await mutate(id) { $0 = r }
        for effect in effects { await perform(effect, id) }
    }

    private func perform(_ effect: Effect, _ id: RequestID) async {
        guard !stopped else { return }
        switch effect {
        case .resolveRelease: await resolve(id)
        case .addOrMonitor(let plan): await addOrMonitor(id, plan)
        case .startSearch: await startSearch(id)
        case .scan: await scan(id)
        case .notifyReady: if let r = request(id) { onReady(r) }
        case .cleanup: await cleanup(id)
        case .poll, .scheduleRetry: break   // `tick()` polls and checks retry times
        }
    }

    // MARK: - Resolve (A8: MusicBrainz on Try only)

    private func resolve(_ id: RequestID) async {
        guard let r = request(id) else { return }
        guard let recordingId = r.recording.recordingMBID else { return await apply(id, .error(.noRelease)) }
        let recording: MBRecording
        do {
            recording = try await mb.recording(recordingId)
        } catch MusicBrainzError.notFound {
            return await apply(id, .error(.noRelease))
        } catch {
            return await apply(id, .lidarrUnavailable)
        }
        guard let artistMBID = r.recording.artistMBID ?? recording.artistIds.first else {
            return await apply(id, .error(.noRelease))
        }
        let artists: [LidarrArtist]
        do { artists = try await lidarr.artists() } catch { return await apply(id, .lidarrUnavailable) }
        lastLidarrContact = now()

        let plan: Plan
        let title: String?
        if let artist = artists.first(where: { $0.foreignArtistId == artistMBID }) {
            // A7: only release groups the artist already has in Lidarr; its profiles are never changed.
            let albums: [LidarrAlbum]
            do { albums = try await lidarr.albums(artistId: artist.id) } catch { return await apply(id, .lidarrUnavailable) }
            let available = Set(albums.compactMap(\.foreignAlbumId))
            guard let rg = ReleasePicker.smallest(containing: recording, available: available) else {
                return await apply(id, .error(.notInCatalogue))
            }
            plan = Plan(recordingMBID: recordingId, releaseGroupMBID: rg, artistMBID: artistMBID,
                        lidarrArtistId: artist.id, mode: .fallback)
            title = albums.first { $0.foreignAlbumId == rg }?.title
        } else {
            // A1: the "Magpie Finds" metadata profile only has official Album/EP/Single studio releases, so
            // only those can be monitored after the add.
            let fits = Set(recording.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id))
            guard let rg = ReleasePicker.smallest(containing: recording, available: fits) else {
                return await apply(id, .error(.noRelease))
            }
            plan = Plan(recordingMBID: recordingId, releaseGroupMBID: rg, artistMBID: artistMBID,
                        lidarrArtistId: nil, mode: .fallback)
            title = recording.releases.first { $0.releaseGroup.id == rg }?.title
        }
        await mutate(id) {
            $0.plan = plan
            if let title, !title.isEmpty { $0.albumTitle = title }
            // Help the match ladder find the song once it lands (ISRC, artist MBID).
            if $0.recording.isrcs.isEmpty { $0.recording.isrcs = recording.isrcs }
            if $0.recording.artistMBID == nil { $0.recording.artistMBID = artistMBID }
        }
        await apply(id, .resolved(plan))
    }

    static func fitsFindsProfile(_ release: MBRelease) -> Bool {
        let primary = release.releaseGroup.primaryType?.lowercased() ?? ""
        return ["album", "ep", "single"].contains(primary) && release.releaseGroup.secondaryTypes.isEmpty
            && release.status?.lowercased() == "official"
    }

    static func sameSong(_ a: ExternalRecording, _ b: ExternalRecording) -> Bool {
        if let x = a.recordingMBID, let y = b.recordingMBID { return x == y }
        let fold = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return fold(a.title) == fold(b.title) && fold(a.artist) == fold(b.artist)
    }

    // MARK: - Add or monitor (A6, A7, G6, G7)

    private struct AlbumMonitorBody: Encodable, Sendable {
        var albumIds: [Int]
        var monitored: Bool
    }

    private struct CommandBody: Encodable, Sendable {
        var name: String
        var albumIds: [Int]
    }

    private func addOrMonitor(_ id: RequestID, _ plan: Plan) async {
        guard let r = request(id) else { return }
        let rg = plan.releaseGroupMBID

        // G7: another request is already bringing this release group home. Follow it; write nothing.
        if let leader = list.first(where: { $0.id != id && $0.isActive && $0.plan?.releaseGroupMBID == rg
                                             && $0.joinedTo == nil }) {
            await mutate(id) {
                $0.joinedTo = leader.id
                $0.lidarrArtistId = leader.lidarrArtistId
                $0.albumId = leader.albumId
                $0.searchStartedAt = leader.searchStartedAt
                $0.searchCommandId = leader.searchCommandId
                $0.grabbed = leader.grabbed
                $0.skipNextSearch = true
            }
            return await apply(id, .added)
        }

        do {
            let artists = try await lidarr.artists()
            lastLidarrContact = now()
            if let artist = artists.first(where: { $0.foreignArtistId == plan.artistMBID }) {
                try await monitorExisting(id, r, artist: artist, rg: rg)
            } else {
                try await addArtist(id, plan: plan)
            }
            await apply(id, .added)
        } catch let failure as AddFailure {
            await apply(id, .error(failure.reason))
        } catch {
            await apply(id, Self.event(for: error))
        }
    }

    private struct AddFailure: Error { var reason: FailReason }

    /// A7 / G6: monitor the one album and search; no tags, no profile or artist change. The ledger is written
    /// before the album is touched.
    private func monitorExisting(_ id: RequestID, _ r: MagpieRequest, artist: LidarrArtist, rg: MBID) async throws {
        let albums = try await lidarr.albums(artistId: artist.id)
        guard let album = albums.first(where: { $0.foreignAlbumId == rg }) else { throw AddFailure(reason: .notInCatalogue) }
        let prior = try await ledger.entry(albumId: album.id)
        // Monitored now: by the owner, unless Magpie's own earlier request (ledger) or add (this request) did it.
        let wasMonitoredBefore = album.monitored ? (r.addSent ? false : (prior?.wasMonitoredBefore ?? true)) : false
        try await ledger.record(LedgerEntry(
            lidarrArtistId: artist.id, albumId: album.id, rgMbid: rg,
            createdArtist: r.addSent || prior?.createdArtist == true,
            wasMonitoredBefore: wasMonitoredBefore,
            root: artist.rootFolderPath ?? r.root ?? artist.path ?? "", mode: .fallback, keptAt: prior?.keptAt))
        await mutate(id) {
            $0.lidarrArtistId = artist.id
            $0.albumId = album.id
        }
        if !album.monitored {
            _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [album.id], monitored: true))
        }
    }

    /// A6: one atomic `POST /artist` built from the lookup row: main root, Fast Start, "Magpie Finds"
    /// metadata, tag `magpie`, nothing new monitored, only this release group, search on add.
    private func addArtist(_ id: RequestID, plan: Plan) async throws {
        guard let setup = await setup() else { throw WriteGateError.disabled }   // set-up removed meanwhile: wait
        guard let lookup = try await lidarr.artistLookupJSON(mbid: plan.artistMBID) else {
            throw AddFailure(reason: .noRelease)
        }
        let body = try Self.addArtistBody(lookup: lookup, setup: setup, releaseGroup: plan.releaseGroupMBID)
        await mutate(id) {
            $0.addSent = true
            $0.addedAt = self.now()
            $0.root = setup.rootFolderPath
        }
        let data: Data
        do {
            data = try await gate.send("POST", "artist", body: body)
        } catch LidarrError.http(let status) where (400..<500).contains(status) {
            await mutate(id) { $0.addSent = false }   // Lidarr refused it: nothing was added
            throw AddFailure(reason: .addFailed)
        }
        guard let artistId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else {
            throw AddFailure(reason: .addFailed)
        }
        await mutate(id) {
            $0.lidarrArtistId = artistId
            $0.skipNextSearch = true   // `searchForMissingAlbums` starts the search
        }
        await discoverAlbum(id)
    }

    static func addArtistBody(lookup: JSONValue, setup: Setup, releaseGroup: MBID) throws -> JSONValue {
        guard var o = lookup.objectValue else { throw AddFailure(reason: .noRelease) }
        let overrides: [String: JSONValue] = [
            "rootFolderPath": .string(setup.rootFolderPath),
            "qualityProfileId": .int(setup.qualityProfileId),
            "metadataProfileId": .int(setup.metadataProfileId),
            "monitored": .bool(true),
            "monitorNewItems": .string("none"),
            "tags": .array(setup.tagIds.map { .int($0) }),
            "addOptions": .object([
                "monitor": .string("none"),
                "albumsToMonitor": .array([.string(releaseGroup.rawValue)]),
                "searchForMissingAlbums": .bool(true),
            ]),
        ]
        // Drop any key that only differs in case, so the body never carries two spellings (the gate refuses those).
        let folded = Set(overrides.keys.map { $0.lowercased() } + ["id"])
        o = o.filter { !folded.contains($0.key.lowercased()) }
        o.merge(overrides) { _, new in new }
        return .object(o)
    }

    /// Finds the album for the request's release group once Lidarr has it, and records it in the ledger
    /// (new artists: Lidarr's refresh after the add is asynchronous).
    private func discoverAlbum(_ id: RequestID) async {
        guard let r = request(id), r.albumId == nil, let rg = r.plan?.releaseGroupMBID else { return }
        var artistId = r.lidarrArtistId
        if let leaderId = r.joinedTo {
            let leader = request(leaderId)
            if artistId == nil { artistId = leader?.lidarrArtistId }
            // The request it followed stopped before Lidarr had the album: stand alone and retry shortly.
            if artistId == nil, leader?.isActive != true, r.isActive {
                await mutate(id) { $0.joinedTo = nil }
                return await apply(id, .lidarrUnavailable)
            }
        }
        guard let artistId else { return }
        guard let albums = try? await lidarr.albums(artistId: artistId) else { return }
        lastLidarrContact = now()
        guard let album = albums.first(where: { $0.foreignAlbumId == rg }) else {
            if r.isActive, now().timeIntervalSince(r.addedAt ?? r.searchStartedAt ?? r.createdAt) > Self.albumAppearLimit,
               r.joinedTo == nil {
                await apply(id, .error(.noRelease))
            }
            return
        }
        if r.addSent, r.joinedTo == nil {
            do {
                try await ledger.record(LedgerEntry(lidarrArtistId: artistId, albumId: album.id, rgMbid: rg,
                                                    createdArtist: true, wasMonitoredBefore: false,
                                                    root: r.root ?? "", mode: .fallback))
            } catch {
                return   // no ledger, no album id: tried again next tick
            }
        }
        await mutate(id) {
            $0.lidarrArtistId = artistId
            $0.albumId = album.id
        }
    }

    private func discoverAlbums() async {
        for r in list where (r.isActive || r.cleanupPending) && r.albumId == nil && r.plan != nil
                            && !busy.contains(r.id) {
            switch r.state {
            case .pending, .resolving, .adding: continue
            default: await discoverAlbum(r.id)
            }
        }
    }

    // MARK: - Search and progress (A14)

    private func startSearch(_ id: RequestID) async {
        guard let r = request(id) else { return }
        if r.skipNextSearch || r.albumId == nil {
            await mutate(id) {
                $0.skipNextSearch = false
                if $0.searchStartedAt == nil { $0.searchStartedAt = self.now() }
            }
            return await apply(id, .searchStarted)
        }
        do {
            let data = try await gate.send("POST", "command", body: CommandBody(name: "AlbumSearch", albumIds: [r.albumId!]))
            let commandId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue
            await mutate(id) {
                $0.searchStartedAt = self.now()
                $0.searchCommandId = commandId
                $0.grabbed = false
            }
            await apply(id, .searchStarted)
        } catch {
            await apply(id, Self.event(for: error))
        }
    }

    private static let finishedCommandStates: Set<String> = ["completed", "failed", "aborted", "cancelled", "orphaned"]

    private func pollLidarr() async {
        let polled = list.filter { r in
            guard r.albumId != nil, !busy.contains(r.id) else { return false }
            switch r.state {
            case .searching, .downloading, .waiting: return r.searchStartedAt != nil
            default: return false
            }
        }
        guard !polled.isEmpty else { return }
        let albumIds = Array(Set(polled.compactMap(\.albumId))).sorted()
        let since = (polled.compactMap(\.searchStartedAt).min() ?? now()).addingTimeInterval(-60)
        let queue: [QueueItem], history: [HistoryEvent]
        do {
            queue = try await lidarr.queueDetails(albumIds: albumIds)
            history = try await lidarr.historySince(since)
            lastLidarrContact = now()
        } catch {
            guard now().timeIntervalSince(lastLidarrContact) >= Self.lidarrSilenceLimit else { return }
            for r in polled where r.state != .importing { await apply(r.id, .lidarrUnavailable) }
            return
        }
        for r in polled {
            guard let current = request(r.id), let albumId = current.albumId, let started = current.searchStartedAt else { continue }
            let items = queue.filter { $0.albumId == albumId }
            let events = history.filter { $0.albumId == albumId && ($0.date ?? started) >= started.addingTimeInterval(-60) }
            if events.contains(where: { $0.kind == .imported }) {
                await apply(r.id, .imported)
                continue
            }
            if let item = items.first {
                let progress = items.compactMap(\.progress).max() ?? 0
                await mutate(r.id) {
                    $0.grabbed = true
                    $0.note = item.statusMessages.first
                }
                await apply(r.id, .queueProgress(progress))
                continue
            }
            let lastGrab = events.filter { $0.kind == .grabbed }.compactMap(\.date).max()
            if lastGrab != nil, !current.grabbed { await mutate(r.id) { $0.grabbed = true } }
            if let failure = events.filter({ $0.kind == .waiting }).compactMap(\.date).max(),
               failure >= (lastGrab ?? .distantPast), failure > (current.failureSeenAt ?? .distantPast) {
                await mutate(r.id) { $0.failureSeenAt = failure }
                await apply(r.id, .downloadFailed)
                continue
            }
            // A14 "nothing found": the search finished, nothing queued, nothing grabbed for 10 minutes.
            let elapsed = now().timeIntervalSince(started)
            if current.state == .searching, !current.grabbed, lastGrab == nil, elapsed >= RequestMachine.noGrabThreshold {
                var searchDone = true
                if let commandId = current.searchCommandId, let command = try? await lidarr.command(id: commandId) {
                    searchDone = Self.finishedCommandStates.contains(command.status.lowercased())
                }
                if searchDone { await apply(r.id, .noGrabAfter(elapsed)) }
            }
        }
    }

    // MARK: - Library (A12, D7)

    private func scan(_ id: RequestID) async {
        try? await library.startScan()
        await mutate(id) { $0.lastScanAt = self.now() }
    }

    private func checkLibrary() async {
        let importing = list.filter { $0.state == .importing && !busy.contains($0.id) }
        if !importing.isEmpty, let scanning = try? await library.isScanning(), !scanning {
            let t = now()
            if lastIndexRefresh.map({ t.timeIntervalSince($0) >= Self.indexRefreshInterval }) ?? true {
                lastIndexRefresh = t
                do { try await library.refreshIndex() } catch {
                    Log.logger("requests").error("index refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if importing.contains(where: { $0.lastScanAt.map { t.timeIntervalSince($0) >= Self.rescanInterval } ?? true }) {
                try? await library.startScan()
                for r in importing { await mutate(r.id) { $0.lastScanAt = t } }
            }
        }
        // Ground truth from any pre-ready state: the library lists the song.
        for r in list where r.isActive && !busy.contains(r.id) {
            if let songId = await library.songId(r.recording) {
                await apply(r.id, .visibleInLibrary(songId: songId))
            }
        }
    }

    // MARK: - Clean-up (G6)

    /// Fallback mode never deletes. It unmonitors the album only when the ledger says Magpie monitored it
    /// (`wasMonitoredBefore == false`), it is not kept, no other live request needs it, and a fresh GET
    /// shows it still monitored. For an artist Magpie just added, it keeps checking for `addSettleTime`:
    /// Lidarr applies `albumsToMonitor` when its refresh finishes, possibly after the Cancel.
    private func cleanup(_ id: RequestID) async {
        guard let r = request(id), r.cleanupPending else { return }
        func done() async { await mutate(id) { $0.cleanupPending = false } }
        guard let rg = r.plan?.releaseGroupMBID else { return await done() }
        let shared = list.contains { other in
            other.id != id && other.plan?.releaseGroupMBID == rg
                && (other.isActive || other.state == .ready || other.state == .kept)
        }
        if shared { return await done() }
        let settling = r.addSent && r.joinedTo == nil
            && now().timeIntervalSince(r.addedAt ?? r.createdAt) < Self.addSettleTime
        if r.albumId == nil { await discoverAlbum(id) }
        guard let current = request(id), let albumId = current.albumId, let artistId = current.lidarrArtistId else {
            if !settling { await done() }   // the album may still appear
            return
        }
        do {
            guard let entry = try await ledger.entry(albumId: albumId), !entry.wasMonitoredBefore, entry.keptAt == nil else {
                return await done()
            }
            let albums = try await lidarr.albums(artistId: artistId)
            if let album = albums.first(where: { $0.id == albumId }), album.monitored {
                _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: false))
            }
            if !settling { await done() }
        } catch {
            // Lidarr unreachable, changes switched off or the ledger unreadable: try again on a later tick.
            Log.logger("requests").error("clean-up postponed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Errors

    /// Refusals and 4xx answers fail the request; everything else (unreachable, changes off, log unavailable)
    /// waits and retries.
    static func event(for error: Error) -> RequestEvent {
        switch error {
        case let e as WriteGateError:
            switch e {
            case .forbidden, .invalidRequest: return .error(.addFailed)
            case .disabled, .logUnavailable: return .lidarrUnavailable
            }
        case let e as LidarrError:
            if case .http(let status) = e, (400..<500).contains(status), status != 408, status != 429 {
                return .error(.addFailed)
            }
            return .lidarrUnavailable
        default:
            return .lidarrUnavailable
        }
    }
}
