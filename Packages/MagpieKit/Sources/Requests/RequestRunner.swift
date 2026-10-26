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
    /// Match-index refresh while a request is importing: at most every 30 s at first, backing off with the
    /// request's time in `importing` (half of it) up to 5 minutes (brief ruling 4).
    public static let indexRefreshInterval: ClosedRange<TimeInterval> = 30...300
    /// Another `startScan` while a request is importing and still not listed: 2 minutes, backing off to 10.
    public static let rescanInterval: ClosedRange<TimeInterval> = 120...600
    /// Imported but still not listed after this long: Needs attention, and the library is left alone for it
    /// until Check again.
    public static let importingLimit: TimeInterval = 20 * 60
    /// `history/since` never reaches further back than this (first poll after a relaunch).
    public static let historyLookback: TimeInterval = 24 * 3600
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
    /// `history/since` cursor: the last successful poll, minus an overlap (PROMOTED B).
    private var historyCursor: Date?
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
        // Critical: ids are only meaningful on their own server. A ledger for another Lidarr disables the runner.
        if ledger.instance != lidarr.instanceScope {
            Log.logger("requests").fault("ledger is unscoped or for another Lidarr; requests disabled")
            self.stopped = true
        }
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
    public var needsPolling: Bool { list.contains { ($0.isActive && !$0.isNotListed) || $0.cleanupPending } }

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
    /// While a step is in flight for it, only the state changes here; the clean-up runs after that step
    /// (which re-checks the state before any write).
    public func cancel(_ id: RequestID) async {
        await apply(id, .cancel, deferCleanup: busy.contains(id))
    }

    /// Needs attention "Not showing up in your library yet": scan and look again.
    public func checkAgain(_ id: RequestID) async {
        guard let r = request(id), r.isNotListed else { return }
        await mutate(id) {
            $0.notListedAt = nil
            $0.importingSince = self.now()
            $0.lastScanAt = nil
        }
        lastIndexRefresh = nil
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

    private func apply(_ id: RequestID, _ event: RequestEvent, deferCleanup: Bool = false) async {
        guard var r = request(id) else { return }
        let (next, effects) = RequestMachine.step(r.state, event, now: now(), prior: r.priorWait)
        guard next != r.state || !effects.isEmpty else { return }
        r.state = next
        switch next {
        case .waiting(let reason, _): r.priorWait = reason
        case .downloading, .importing, .ready: r.priorWait = nil
        default: break
        }
        if next == .importing, r.importingSince == nil || request(id)?.state != .importing {
            r.importingSince = now()
            r.notListedAt = nil
        }
        if case .visibleInLibrary(let songId) = event { r.songId = songId }
        if effects.contains(.cleanup) { r.cleanupPending = true }
        await mutate(id) { $0 = r }
        for effect in effects where !(deferCleanup && effect == .cleanup) { await perform(effect, id) }
    }

    /// Thrown when a request moved on (cancelled, failed, retired runner) while a step awaited: the step
    /// stops before its next write.
    private struct Superseded: Error {}

    private func ensure(_ id: RequestID, _ expected: RequestState) throws {
        guard !stopped, request(id)?.state == expected else { throw Superseded() }
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
        // A retry keeps what was decided: no MusicBrainz again, never a different release group (ruling 3).
        if let plan = r.plan { return await apply(id, .resolved(plan)) }
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
            // An artist Magpie just added may not list its albums yet (Lidarr's refresh): pick as for a new artist.
            let magpies = (try? await ledger.createdArtist(artist.id)) == true
            let fits = Set(recording.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id))
            guard let rg = ReleasePicker.smallest(containing: recording, available: available)
                    ?? (magpies ? ReleasePicker.smallest(containing: recording, available: fits) : nil) else {
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
                $0.lidarrArtistId = $0.lidarrArtistId ?? leader.lidarrArtistId
                $0.albumId = $0.albumId ?? leader.albumId
                $0.searchStartedAt = leader.searchStartedAt
                $0.searchCommandId = leader.searchCommandId
                $0.grabbed = leader.grabbed
                $0.skipNextSearch = true
            }
            return await apply(id, .added)
        }
        if r.joinedTo != nil { await mutate(id) { $0.joinedTo = nil } }   // its leader is gone: stand alone

        do {
            if let albumId = r.albumId, let artistId = r.lidarrArtistId {
                try await retrySearchOnly(id, r, albumId: albumId, artistId: artistId)
            } else {
                let artists = try await lidarr.artists()
                lastLidarrContact = now()
                if let artist = artists.first(where: { $0.foreignArtistId == plan.artistMBID }) {
                    if r.addSent {
                        try await adoptCreatedArtist(id, r, artist: artist, rg: rg)
                    } else {
                        try await monitorExisting(id, r, artist: artist, rg: rg)
                    }
                } else {
                    try await addArtist(id, plan: plan)
                }
            }
            try ensure(id, .adding)
            await apply(id, .added)
        } catch is Superseded {
            return
        } catch let failure as AddFailure {
            await apply(id, .error(failure.reason))
        } catch {
            await apply(id, Self.event(for: error))
        }
    }

    private struct AddFailure: Error { var reason: FailReason }

    /// Ruling 3: once the album is known, a retry only searches again. If the album is no longer monitored
    /// (or gone), that is the owner's decision in Lidarr: stop, write nothing. Exceptions: right after Magpie
    /// added the artist (Lidarr's refresh may not have applied `albumsToMonitor` yet), and this request's own
    /// monitor that isn't applied yet, resolved by the fix-round-3 rules ("when in doubt, don't write"):
    /// - not sent + monitored now: the owner did it (wasMonitoredBefore = true, never undone);
    /// - not sent + unmonitored: send it now (`sendMonitor`);
    /// - unclear + monitored: Magpie's write landed (applied);
    /// - unclear + unmonitored: maybe it landed and the owner undid it (or a send was cut off by a crash):
    ///   stop, no write.
    private func retrySearchOnly(_ id: RequestID, _ r: MagpieRequest, albumId: Int, artistId: Int) async throws {
        let albums = try await lidarr.albums(artistId: artistId)
        lastLidarrContact = now()
        guard let album = albums.first(where: { $0.id == albumId }) else { throw AddFailure(reason: .stoppedInLidarr) }
        if let entry = try await ledger.entry(albumId: albumId), entry.isOpen, !entry.isApplied,
           entry.requestId == id.description {
            var e = entry
            switch (entry.send, album.monitored) {
            case (.notSent, true):
                e.wasMonitoredBefore = true
                e.send = .applied
                try await ledger.record(e)
            case (.notSent, false):
                try ensure(id, .adding)
                try await sendMonitor(e, artistId: artistId, albumId: albumId)
            case (.unclear, true):
                e.send = .applied
                try await ledger.record(e)
            case (.unclear, false):
                throw AddFailure(reason: .stoppedInLidarr)
            case (.applied, _):
                break
            }
            return
        }
        let settling = r.addSent && now().timeIntervalSince(r.addedAt ?? r.createdAt) < Self.addSettleTime
        guard album.monitored || settling else { throw AddFailure(reason: .stoppedInLidarr) }
    }

    /// Sends `PUT /album/monitor` for an entry already in the ledger (fix round 4).
    ///
    /// The entry is saved as `unclear` *before* the PUT, so if the app dies while it is in flight the entry
    /// never claims "not sent". If that save fails, nothing is sent. Afterwards:
    /// - success: `applied`;
    /// - `WriteGateError`: `notSent` (the gate throws every one of them before anything leaves the device);
    /// - any other error: a confirming GET decides. Monitored: `applied`; unmonitored: `notSent` (verifiably
    ///   not in Lidarr, so a retry may send it); GET failed or album gone: stays `unclear`.
    /// If saving the outcome fails, the entry stays `unclear` (never more permissive than the truth).
    /// Rethrows any failure so the request waits.
    private func sendMonitor(_ entry: LedgerEntry, artistId: Int, albumId: Int) async throws {
        var e = entry
        e.send = .unclear
        try await ledger.record(e)
        do {
            _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: true))
        } catch let refusal as WriteGateError {
            e.send = .notSent
            try? await ledger.record(e)
            throw refusal
        } catch {
            if let album = (try? await lidarr.albums(artistId: artistId))?.first(where: { $0.id == albumId }) {
                e.send = album.monitored ? .applied : .notSent
                try? await ledger.record(e)
            }
            throw error
        }
        e.send = .applied
        try await ledger.record(e)
    }

    /// The add was sent but its outcome was unclear (timeout, relaunch) and the artist exists now: it is
    /// Magpie's. Adopt it, ledger it at artist level at once, and wait for its album (no second POST).
    private func adoptCreatedArtist(_ id: RequestID, _ r: MagpieRequest, artist: LidarrArtist, rg: MBID) async throws {
        try ensure(id, .adding)
        try await ledger.record(LedgerEntry(lidarrArtistId: artist.id, albumId: nil, rgMbid: rg, createdArtist: true,
                                            wasMonitoredBefore: false, root: r.root ?? artist.rootFolderPath ?? "",
                                            mode: .fallback, requestId: id.description))
        await mutate(id) {
            $0.lidarrArtistId = artist.id
            $0.skipNextSearch = true
        }
        await discoverAlbum(id)
    }

    /// A7 / G6: monitor the one album and search; no tags, no profile or artist change.
    ///
    /// Order (fix rounds 2–4): the ledger gets a `notSent` entry, the request learns the ids (so clean-up can
    /// always find the album), then `sendMonitor` marks it `unclear`, sends the PUT and records the outcome.
    /// Only applied entries are ever undone.
    private func monitorExisting(_ id: RequestID, _ r: MagpieRequest, artist: LidarrArtist, rg: MBID) async throws {
        let albums = try await lidarr.albums(artistId: artist.id)
        guard let album = albums.first(where: { $0.foreignAlbumId == rg }) else {
            // Magpie's own artist whose album isn't listed yet: wait for it (no write), with the usual give-up.
            guard try await ledger.createdArtist(artist.id) else { throw AddFailure(reason: .notInCatalogue) }
            try ensure(id, .adding)
            await mutate(id) {
                $0.lidarrArtistId = artist.id
                $0.skipNextSearch = true
            }
            return
        }
        let prior = try await ledger.entry(albumId: album.id)
        // Monitored now: the owner's, unless an open entry of this request or of a live request says Magpie
        // did it. Closed entries (finished requests) are never inherited: the owner may have monitored it since.
        let liveIds = Set(list.filter { $0.isActive }.map(\.id.description)).union([id.description])
        let livePrior = prior.flatMap { p in p.isOpen && p.isApplied && p.requestId.map(liveIds.contains) == true ? p : nil }
        let wasMonitoredBefore = album.monitored ? (livePrior?.wasMonitoredBefore ?? true) : false
        let needsMonitor = !album.monitored
        try ensure(id, .adding)
        let entry = LedgerEntry(
            lidarrArtistId: artist.id, albumId: album.id, rgMbid: rg,
            createdArtist: (try? await ledger.createdArtist(artist.id)) == true,
            wasMonitoredBefore: wasMonitoredBefore,
            root: artist.rootFolderPath ?? r.root ?? artist.path ?? "", mode: .fallback, keptAt: prior?.keptAt,
            send: needsMonitor ? .notSent : .applied, requestId: id.description)
        try await ledger.record(entry)
        await mutate(id) {
            $0.lidarrArtistId = artist.id
            $0.albumId = album.id
        }
        guard needsMonitor else { return }
        try ensure(id, .adding)
        try await sendMonitor(entry, artistId: artist.id, albumId: album.id)
    }

    /// A6: one atomic `POST /artist` built from the lookup row: main root, Fast Start, "Magpie Finds"
    /// metadata, tag `magpie`, nothing new monitored, only this release group, search on add.
    ///
    /// `addOptions.monitor` is deliberately left out (Lidarr reads it as "unknown"). Verified on Lidarr
    /// 3.2.0.5144: with `monitor: "none"` Lidarr also unmonitors the *artist*, so `searchForMissingAlbums`
    /// searches 0 albums and nothing ever downloads; without it the artist stays monitored and
    /// `albumsToMonitor` alone decides, monitoring exactly this release group.
    private func addArtist(_ id: RequestID, plan: Plan) async throws {
        guard let setup = await setup() else { throw WriteGateError.disabled }   // set-up removed meanwhile: wait
        guard let lookup = try await lidarr.artistLookupJSON(mbid: plan.artistMBID) else {
            throw AddFailure(reason: .noRelease)
        }
        let body = try Self.addArtistBody(lookup: lookup, setup: setup, releaseGroup: plan.releaseGroupMBID)
        try ensure(id, .adding)
        await mutate(id) {
            $0.addSent = true
            $0.addedAt = self.now()
            $0.root = setup.rootFolderPath
        }
        func nothingSent() async { await mutate(id) { $0.addSent = false; $0.addedAt = nil } }
        let data: Data
        do {
            data = try await gate.send("POST", "artist", body: body)
        } catch let e as WriteGateError {
            await nothingSent()   // refused or switched off before anything left the device (PROMOTED A)
            throw e
        } catch let e as EncodingError {
            await nothingSent()
            throw e
        } catch LidarrError.http(let status) where (400..<500).contains(status) {
            await nothingSent()   // Lidarr refused it: nothing was added
            throw AddFailure(reason: .addFailed)
        }
        guard let artistId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else {
            throw AddFailure(reason: .addFailed)
        }
        // Ledgered at artist level at once (IMPORTANT 2): the album may take a while, or never appear.
        do {
            try await ledger.record(LedgerEntry(lidarrArtistId: artistId, albumId: nil, rgMbid: plan.releaseGroupMBID,
                                                createdArtist: true, wasMonitoredBefore: false,
                                                root: setup.rootFolderPath, mode: .fallback, requestId: id.description))
        } catch {
            Log.logger("requests").error("ledger not written for a new artist; retried with its album")
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
        var following = false
        if let leaderId = r.joinedTo {
            let leader = request(leaderId)
            if artistId == nil { artistId = leader?.lidarrArtistId }
            following = leader?.isActive == true
            if !following {
                // The request it followed stopped: stand alone (IMPORTANT 6). Without an artist id it can only
                // retry from scratch shortly; with one it keeps looking for the album, with the same give-up.
                await mutate(id) {
                    $0.joinedTo = nil
                    if $0.lidarrArtistId == nil { $0.lidarrArtistId = artistId }
                }
                if artistId == nil, r.isActive { return await apply(id, .lidarrUnavailable) }
            }
        }
        guard let artistId else { return }
        guard let albums = try? await lidarr.albums(artistId: artistId) else { return }
        lastLidarrContact = now()
        guard let album = albums.first(where: { $0.foreignAlbumId == rg }) else {
            if r.isActive, !following,
               now().timeIntervalSince(r.addedAt ?? r.searchStartedAt ?? r.createdAt) > Self.albumAppearLimit {
                await apply(id, .error(.noRelease))
            }
            return
        }
        if r.addSent {
            do {
                // Lidarr monitored it through `albumsToMonitor` of Magpie's own add: Magpie's to undo.
                try await ledger.record(LedgerEntry(lidarrArtistId: artistId, albumId: album.id, rgMbid: rg,
                                                    createdArtist: true, wasMonitoredBefore: false,
                                                    root: r.root ?? "", mode: .fallback, send: .applied,
                                                    requestId: id.description))
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
            try ensure(id, .searching)
            let data = try await gate.send("POST", "command", body: CommandBody(name: "AlbumSearch", albumIds: [r.albumId!]))
            let commandId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue
            await mutate(id) {
                $0.searchStartedAt = self.now()
                $0.searchCommandId = commandId
                $0.grabbed = false
            }
            await apply(id, .searchStarted)
        } catch is Superseded {
            return
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
        let pollStart = now()
        // PROMOTED B: only what's new since the last poll (with a minute of overlap), never more than a day.
        let earliest = (polled.compactMap(\.searchStartedAt).min() ?? pollStart).addingTimeInterval(-60)
        let since = max(historyCursor ?? earliest, earliest, pollStart.addingTimeInterval(-Self.historyLookback))
        let queue: [QueueItem], history: [HistoryEvent]
        do {
            queue = try await lidarr.queueDetails(albumIds: albumIds)
            history = try await lidarr.historySince(since)
            lastLidarrContact = now()
            historyCursor = pollStart.addingTimeInterval(-60)
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
            if let stuck = items.first(where: Self.isStuck) {
                // IMPORTANT 5: blocked or failed import sits in the queue at 100%: that is a wait, not progress.
                await mutate(r.id) {
                    $0.grabbed = true
                    $0.note = Self.shortNote(stuck)
                }
                if case .waiting = current.state {} else { await apply(r.id, .downloadFailed) }
                continue
            }
            if let item = items.first {
                let progress = items.compactMap(\.progress).max() ?? 0
                await mutate(r.id) {
                    $0.grabbed = true
                    $0.note = Self.shortNote(item)
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

    /// Queue states that won't finish without help: Lidarr's import blocked or failed, or the download failed.
    static func isStuck(_ item: QueueItem) -> Bool {
        let tracked = item.trackedDownloadState.lowercased()
        let status = item.status.lowercased()
        return ["importblocked", "importfailed", "failedpending", "failed"].contains(tracked)
            || ["failed", "warning"].contains(status)
    }

    /// The first status message, on one line, without control characters, at most 120 characters.
    static func shortNote(_ item: QueueItem) -> String? {
        guard let raw = item.statusMessages.first else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let line = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    // MARK: - Library (A12, D7)

    private func scan(_ id: RequestID) async {
        try? await library.startScan()
        await mutate(id) { $0.lastScanAt = self.now() }
    }

    /// IMPORTANT 4: while a request is importing, scans and index refreshes back off with its time there, and
    /// after `importingLimit` it goes to Needs attention and the library is left alone for it.
    private func checkLibrary() async {
        let t = now()
        for r in list where r.state == .importing && r.notListedAt == nil && !busy.contains(r.id)
            && t.timeIntervalSince(r.importingSince ?? r.updatedAt) >= Self.importingLimit {
            await mutate(r.id) { $0.notListedAt = t }
        }
        let importing = list.filter { $0.state == .importing && $0.notListedAt == nil && !busy.contains($0.id) }
        if !importing.isEmpty, let scanning = try? await library.isScanning(), !scanning {
            let youngest = importing.map { t.timeIntervalSince($0.importingSince ?? t) }.min() ?? 0
            let refreshEvery = Self.clamp(youngest / 2, Self.indexRefreshInterval)
            if lastIndexRefresh.map({ t.timeIntervalSince($0) >= refreshEvery }) ?? true {
                lastIndexRefresh = t
                do { try await library.refreshIndex() } catch {
                    Log.logger("requests").error("index refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let rescanEvery = Self.clamp(youngest / 2, Self.rescanInterval)
            if importing.contains(where: { $0.lastScanAt.map { t.timeIntervalSince($0) >= rescanEvery } ?? true }) {
                try? await library.startScan()
                for r in importing { await mutate(r.id) { $0.lastScanAt = t } }
            }
        }
        // Ground truth from any pre-ready state: the library lists the song (an in-memory index lookup).
        for r in list where r.isActive && !busy.contains(r.id) {
            if let songId = await library.songId(r.recording) {
                await apply(r.id, .visibleInLibrary(songId: songId))
            }
        }
    }

    private static func clamp(_ x: TimeInterval, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
        min(max(x, range.lowerBound), range.upperBound)
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
        if shared { return await done() }   // the entry stays open: the other request still relies on it
        let settling = r.addSent && r.joinedTo == nil
            && now().timeIntervalSince(r.addedAt ?? r.createdAt) < Self.addSettleTime
        if r.albumId == nil { await discoverAlbum(id) }
        var albumId = request(id)?.albumId, artistId = request(id)?.lidarrArtistId
        if albumId == nil, let mine = try? await ledger.entries.last(where: {
            $0.requestId == id.description && $0.albumId != nil && $0.isOpen
        }) {
            albumId = mine.albumId
            artistId = mine.lidarrArtistId
        }
        guard let albumId, let artistId else {
            if !settling { await done() }   // the album may still appear
            return
        }
        do {
            guard let entry = try await ledger.entry(albumId: albumId) else { return await done() }
            // Only an open, applied entry of Magpie's own monitor is undone (never an intent, a kept album or
            // an album the owner had monitored).
            if entry.isOpen, entry.isApplied, !entry.wasMonitoredBefore, entry.keptAt == nil {
                let albums = try await lidarr.albums(artistId: artistId)
                if let album = albums.first(where: { $0.id == albumId }), album.monitored {
                    _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: false))
                }
            }
            guard !settling else { return }
            if entry.isOpen {
                var closed = entry
                closed.closedAt = now()
                try await ledger.record(closed)
            }
            await done()
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
