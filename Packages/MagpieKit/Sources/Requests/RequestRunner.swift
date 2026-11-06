import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import MatchIndex
import NavidromeKit

/// What the runner needs from the music library: a plain quick scan (A12: no path mapping in v1), scan
/// status, a match-index refresh, and "is this recording in the library now" (D7: Ready = Navidrome lists it).
/// Keep (Task 6.2b, A3) adds a scan of both folders after a move and a look-up of the kept song by MBID.
public struct LibraryAccess: Sendable {
    public var startScan: @Sendable () async throws -> Void
    public var isScanning: @Sendable () async throws -> Bool
    public var refreshIndex: @Sendable () async throws -> Void
    public var songId: @Sendable (ExternalRecording) async -> String?
    /// After Keep's move: scan where the artist folder was and where it is now (Lidarr's paths), so the old
    /// entry goes missing and the new one appears (A3, A12).
    public var rescanMoved: @Sendable (_ from: String, _ to: String) async throws -> Void
    /// After Keep's move: the recording's song in the folder the artist moved to (Lidarr's path); nil while not
    /// listed there. Never the owner's own copy of the recording elsewhere.
    public var keptSong: @Sendable (MBID, _ artistPath: String) async throws -> Song?
    /// Y5 fix I7: a scan of exactly this artist folder (Lidarr's path) in the library it's in. False: it can't be
    /// placed (never a whole-library or full scan instead).
    public var scanFolder: @Sendable (_ artistFolder: String) async -> Bool
    /// Y5 (item 9.2): the library's songs titled like `title` inside Lidarr's artist folder, each with its path in
    /// Lidarr's terms (mapped from Navidrome's). Nil: can't tell. For files without MusicBrainz tags.
    public var songsTitled: @Sendable (_ title: String, _ artistFolder: String) async -> [(song: Song, lidarrPath: String)]?
    /// Whether the library still has the song with this id (a scan can re-identify a song). Nil: can't tell.
    public var songExists: @Sendable (_ songId: String) async -> Bool?

    /// `rescanMoved` nil: one plain quick scan. `keptSong` nil: never found (the request keeps its song id).
    public init(startScan: @escaping @Sendable () async throws -> Void,
                isScanning: @escaping @Sendable () async throws -> Bool,
                refreshIndex: @escaping @Sendable () async throws -> Void,
                songId: @escaping @Sendable (ExternalRecording) async -> String?,
                rescanMoved: (@Sendable (_ from: String, _ to: String) async throws -> Void)? = nil,
                keptSong: (@Sendable (MBID, _ artistPath: String) async throws -> Song?)? = nil,
                songsTitled: (@Sendable (_ title: String, _ artistFolder: String) async -> [(song: Song, lidarrPath: String)]?)? = nil,
                scanFolder: (@Sendable (_ artistFolder: String) async -> Bool)? = nil,
                songExists: (@Sendable (_ songId: String) async -> Bool?)? = nil) {
        self.scanFolder = scanFolder ?? { _ in false }
        self.songExists = songExists ?? { _ in nil }
        self.startScan = startScan; self.isScanning = isScanning
        self.refreshIndex = refreshIndex; self.songId = songId
        self.songsTitled = songsTitled ?? { _, _ in nil }
        self.rescanMoved = rescanMoved ?? { _, _ in try await startScan() }
        self.keptSong = keptSong ?? { _, _ in nil }
    }

    /// Straight to one Navidrome client and match index (`startScan` is always `fullScan=false`, G7).
    public static func navidrome(_ client: NavidromeClient, index: MatchIndexStore) -> LibraryAccess {
        LibraryAccess(startScan: { try await client.startScan(target: nil) },
                      isScanning: { try await client.scanStatus() },
                      refreshIndex: { try await index.refresh(using: client) },
                      songId: { await index.index.librarySong(for: $0) })
    }
}

/// Runs Try requests against Lidarr. Fallback mode (M5): the album goes into the owner's main root folder.
/// Finds mode (Task 6.2a, `Setup.finds`): a new artist goes into the confirmed Finds root instead, tagged
/// `magpie` + `magpie-find`, after the Finds root is checked again against fresh root folders (G2).
///
/// Effects of `RequestMachine` are executed here:
/// - new artist: one atomic `POST /artist` built from `artist/lookup` (A6: the Finds root in Finds mode, else
///   the main root);
/// - existing artist: `PUT /album/monitor` + `AlbumSearch` on one album it already has (A7, G6), never a
///   change to the artist;
/// - dedupe by release group against running requests, the ledger and Lidarr; at most 5 active (G7);
/// - Ready only when the match index finds the recording after a plain `startScan` (A12, D7);
/// - Cancel unmonitors the album only when Magpie monitored it, and never deletes anything (G6);
/// - Keep (RequestRunner+Keep.swift) and Not for me (RequestRunner+NotForMe.swift) act on ready finds only;
///   Bring in more (RequestRunner+BringInMore.swift) on kept, moved finds only.
///
/// Every write goes through `LidarrWriteGate` (G1) and every album Magpie touches is in the `Ledger` first.
/// Call `tick()` on a timer (5 s in the foreground, 30 s otherwise); it does nothing for finished requests.
public actor RequestRunner {
    public static let maxActive = 5
    /// Match-index refresh while a request is importing: at most every 30 s at first, backing off with the
    /// request's time in `importing` (half of it) up to 5 minutes (brief ruling 4).
    public static let indexRefreshInterval: ClosedRange<TimeInterval> = 30...300
    /// Index refreshes while Navidrome reports a scan running: at least this far apart.
    public static let scanningRefreshInterval: TimeInterval = 120
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

    /// Where adds go and how they are set up (from provisioning, the owner's root choice and Finds setup).
    public struct Setup: Sendable, Equatable {
        /// The main root folder: fallback-mode adds, and Finds-mode adds whose Finds root no longer checks out.
        public var rootFolderPath: String
        public var qualityProfileId: Int
        public var metadataProfileId: Int
        /// Fallback-mode tags (`magpie`).
        public var tagIds: [Int]
        /// Finds mode: set only when "Use a Finds folder" is on and the Finds setup is complete. Nil: fallback.
        public var finds: Finds?

        /// Where Finds-mode adds go: the owner-confirmed Finds root (G2), tagged `magpie` + `magpie-find`.
        public struct Finds: Sendable, Equatable {
            public var rootFolderPath: String
            public var tagIds: [Int]

            public init(rootFolderPath: String, tagIds: [Int]) {
                self.rootFolderPath = rootFolderPath; self.tagIds = tagIds
            }
        }

        /// Round 15 C3 (D136): "Magpie Lossless Preferred" (FLAC, MP3 only as a fallback): new artists Add to library
        /// brings into the main library. Nil until provisioned.
        public var libraryQualityProfileId: Int?

        public init(rootFolderPath: String, qualityProfileId: Int, metadataProfileId: Int, tagIds: [Int],
                    finds: Finds? = nil, libraryQualityProfileId: Int? = nil) {
            self.rootFolderPath = rootFolderPath; self.qualityProfileId = qualityProfileId
            self.metadataProfileId = metadataProfileId; self.tagIds = tagIds; self.finds = finds
            self.libraryQualityProfileId = libraryQualityProfileId
        }
    }

    /// Round 15 C3: why a Try was asked for.
    public enum Intent: Sendable, Equatable {
        /// As before round 15 (the car, Save to playlist, the outside pages' Try this album).
        case plain
        /// Try: temporary, with Keep or Reject (a trial in the main library for a library artist, D139).
        case trial
        /// Add to library: permanent (D135).
        case library
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

    // Internal (not private) where RequestRunner+Keep.swift needs them.
    let lidarr: LidarrClient
    let gate: LidarrWriteGate
    let ledger: Ledger
    let mb: MusicBrainzClient
    let library: LibraryAccess
    let store: RequestStore
    private let setup: @Sendable () async -> Setup?
    let keepSetup: @Sendable () async -> KeepSetup?
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async -> Void
    private let onReady: @Sendable (MagpieRequest) -> Void
    /// Round 17: a request just failed (nothing holding the song could be brought in, or Lidarr said no).
    private let onFailed: @Sendable (MagpieRequest) -> Void
    let onRelinked: @Sendable (MagpieRequest, _ before: String?, Song) -> Void
    /// Y5 (M1): the kept find's MP3 was removed: the app drops queue entries and the phone's download of that song.
    let onMP3Removed: @Sendable (MagpieRequest, _ songId: String?) -> Void
    /// A ready find's song was found again under another id (the library re-identified it; `before` is gone). The
    /// request carries the id now.
    let onRefound: @Sendable (MagpieRequest, _ before: String) -> Void
    /// Tests and the dev-stack IT: a shorter MP3 grace than 7 days.
    var mp3GraceOverride: TimeInterval?
    /// Fix I7: artist folders waiting for Navidrome's scan (since when), the last scan, and its backoff.
    var pendingScans: [String: Date] = [:]
    var lastFolderScan: Date?
    var scanBackoff: TimeInterval = 60
    /// Fix I10 (chaos suite): a test kills the runner at a named step.
    var faultHook: (@Sendable (FaultPoint) -> Bool)?
    var orphanChecks: Date?

    /// The steps the chaos suite kills the app at (design §10).
    public enum FaultPoint: String, Sendable, CaseIterable {
        case intentSaved, beforePut, afterPut, ledgerCommitted, requestCommitted, refreshSent, beforeDelete, afterDelete
    }

    public func setFaultHook(_ hook: (@Sendable (FaultPoint) -> Bool)?) { faultHook = hook }

    /// A test's kill at this step: the runner stops (as a dead process would) and the caller returns.
    func crashed(_ point: FaultPoint) -> Bool {
        guard let faultHook, faultHook(point) else { return false }
        stop()
        return true
    }
    public func setMP3Grace(_ seconds: TimeInterval?) { mp3GraceOverride = seconds }

    private(set) var list: [MagpieRequest] = []
    private var loaded = false
    /// The read of the saved list in flight, shared by every `load()` meanwhile.
    private var loading: Task<[MagpieRequest], Error>?
    /// Requests with a step running (internal for R17's stall handling and Search again).
    var busy: Set<RequestID> = [] { didSet { if busy != oldValue { saveLeases() } } }
    /// Requests whose clean-up is running: Cancel's and a pass's must not run side by side (both would read the album
    /// still monitored across the GET and both unmonitor it: a double write).
    var cleaningUp: Set<RequestID> = []
    /// Y5 (RunnerState.swift): this runner's id for its leases, where they and Lidarr's clock are kept, and the last
    /// copy read or written.
    let process = UUID().uuidString
    var stateURL: URL? { store.fileURL.map(RunnerState.url(forRequests:)) }
    var persistedState = RunnerState()
    var lastClockRead: Date?
    /// Y5 throttles (in memory: a relaunch only checks sooner).
    var factChecks: [RequestID: Date] = [:]
    var adoptedChecks: [RequestID: Date] = [:]
    var fallbackChecks: [RequestID: Date] = [:]
    /// Ready finds' song ids: when each was last looked at and how long until the next look (backoff).
    var refindChecks: [RequestID: (last: Date, wait: TimeInterval)] = [:]
    /// R17 (RequestRunner+Stall.swift): each Soulseek download being watched, by queue id; the Soulseek clients'
    /// names (read once per runner); how long a download may sit unchanged.
    var stallWatch: [Int: StallWatch] = [:]
    var soulseekClients: Set<String>?
    /// The pass the Soulseek clients were last read in (item 9.6: once per pass).
    var clientsReadInPass = -1
    /// Non-Soulseek "warning" downloads by queue id: their `sizeleft` and since when (item 9.6).
    var warningWatch: [Int: (sizeleft: Double, since: Date)] = [:]
    var stallLimit: TimeInterval = StallLimit.standard.seconds
    /// N1: requests whose next search follows a copy just removed: that search goes out even at the cap (the cap
    /// stops further removals, not the search that belongs to the last one).
    var searchAfterRemoval: Set<RequestID> = []
    /// Lidarr artists a Keep, a Not for me or a Bring in more is working on right now (RequestRunner+Keep.swift,
    /// RequestRunner+NotForMe.swift, RequestRunner+BringInMore.swift): one at a time per artist, so they never run
    /// together on one artist.
    var keepingArtists: Set<Int> = [] { didSet { if keepingArtists != oldValue { saveLeases() } } }
    /// The artists in `keepingArtists` that a Not for me holds (so Keep can say why it can't go ahead).
    var lettingGoArtists: Set<Int> = []
    /// When the kept song was last looked up, per request (throttles `relink`).
    var relinkChecks: [RequestID: Date] = [:]
    /// When Bring in more's releases were last checked, per request (throttles `followBringIns`).
    var bringInChecks: [RequestID: Date] = [:]
    private var inFlight: [RequestID: Task<Void, Never>] = [:]
    private var ticking = false
    private(set) var stopped = false
    private var lastIndexRefresh: Date?
    var lastLidarrContact: Date
    private var watchers: [UUID: AsyncStream<[MagpieRequest]>.Continuation] = [:]

    /// `keepSetup` (Task 6.2b): where Keep moves finds; nil while Finds or the lossless profile aren't set up.
    /// `onRelinked`: a kept song was found again in the library (its id before, the library song now).
    public init(lidarr: LidarrClient, gate: LidarrWriteGate, ledger: Ledger, mb: MusicBrainzClient,
                library: LibraryAccess, store: RequestStore,
                setup: @escaping @Sendable () async -> Setup?,
                keepSetup: @escaping @Sendable () async -> KeepSetup? = { nil },
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                onReady: @escaping @Sendable (MagpieRequest) -> Void = { _ in },
                onRelinked: @escaping @Sendable (MagpieRequest, _ before: String?, Song) -> Void = { _, _, _ in },
                onMP3Removed: @escaping @Sendable (MagpieRequest, _ songId: String?) -> Void = { _, _ in },
                onRefound: @escaping @Sendable (MagpieRequest, _ before: String) -> Void = { _, _ in },
                onFailed: @escaping @Sendable (MagpieRequest) -> Void = { _ in }) {
        self.lidarr = lidarr; self.gate = gate; self.ledger = ledger; self.mb = mb
        self.library = library; self.store = store; self.setup = setup; self.keepSetup = keepSetup
        self.now = now; self.sleep = sleep; self.onReady = onReady; self.onRelinked = onRelinked
        self.onMP3Removed = onMP3Removed; self.onRefound = onRefound; self.onFailed = onFailed
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

    /// Round 12 M5: the runner's state file was damaged and kept aside (`.corrupt`): leases, Lidarr's clock and the
    /// migration flags started over, and a destructive migration step won't run again. Needs a look.
    public var stateNeedsAttention: Bool { persistedState.damagedAt != nil }

    /// Whether `tick()` has anything to do: an active request, a clean-up still owed, or a Keep or Not for me
    /// to follow.
    public var needsPolling: Bool {
        list.contains {
            ($0.isActive && !$0.isNotListed) || $0.cleanupPending || $0.keep != nil || $0.relinkPending == true
                || $0.notForMe != nil || ($0.lossless?.isActive ?? false)
        }
    }

    /// Loads the saved requests (resume after relaunch). Safe to call again.
    @discardableResult
    public func load() async -> Bool {
        if loaded { return true }
        // X5 fix I1: callers that arrive while the read is in flight share it, and only the first to resume sets
        // the list, so a late copy from disk never overwrites changes made in memory since (e.g. `addSent`).
        let task: Task<[MagpieRequest], Error>
        if let loading {
            task = loading
        } else {
            storeLoads += 1
            let store = store
            task = Task { try await store.load() }
            loading = task
        }
        do {
            let saved = try await task.value
            if !loaded {
                // Round 12 M5: an unreadable runner state fails the load (the pass is skipped, nothing saved over it).
                let state = try RunnerState.read(stateURL)
                list = saved
                loaded = true
                persistedState = state
                publish()
            }
            loading = nil
            return true
        } catch {
            if loading == task { loading = nil }   // a later call reads again
            return false
        }
    }

    /// Asks for `recording`. A request for the same song that is still on its way (or ready) is returned
    /// instead of a new one. Work continues in the background; watch `updates`.
    /// - Parameters:
    ///   - album: R19 "Try this album": bring in this release group (one request per album).
    ///   - releaseGroup: the album the song was picked from, when known: a live request for it is this Try (R20).
    ///   - intent: round 15 C3 (D135, D139): `.library` is "Add to library" (permanent), `.trial` the Try (temporary).
    ///     A live request this Try is becomes Add to library when asked so; nothing else about it changes.
    ///   - libraryAdd: D136 (review M2): a new artist's Add to library uses the owner's own Add defaults (the metadata
    ///     profile for their release types, and whether new releases are followed).
    public func tryRecording(_ recording: ExternalRecording, tier: Tier, album: MBID? = nil,
                             releaseGroup: MBID? = nil, intent: Intent = .plain,
                             libraryAdd: LibraryAddProfile? = nil) async throws -> RequestID {
        guard !stopped, await load() else { throw TryError.unavailable }
        if let existing = liveTry(recording, album: album, releaseGroup: releaseGroup) {
            if intent == .library, !existing.addToLibrary { await mutate(existing.id) { $0.addToLibrary = true } }
            return existing.id
        }
        guard await gate.enabled else { throw TryError.changesOff }
        guard await setup() != nil else { throw TryError.notSetUp }
        guard activeCount < Self.maxActive else { throw TryError.tooMany }
        var request = MagpieRequest(recording: recording, tier: tier, createdAt: now())
        request.albumTarget = album
        request.onlyTheSong = album == nil ? true : nil   // round 18: one song, not the release it comes on
        request.addToLibrary = intent == .library
        request.askedAsTry = intent == .trial
        request.libraryMetadataProfileId = libraryAdd?.metadataProfileId
        request.libraryFollow = libraryAdd?.follow
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
        await apply(id, .cancel, deferCleanup: requestBusy(id))
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

    /// Removes a finished (or ready) request from the list, only when `canBeRemoved` (FL6: never one whose Keep or
    /// Not for me is still going or needs a look, or that still has follow-ups owed).
    public func forget(_ id: RequestID) async {
        guard let r = request(id), r.canBeRemoved, !artistBusy(r.lidarrArtistId ?? -1) else { return }
        list.removeAll { $0.id == id }
        await changed()
    }

    /// Retires this runner (sign-out, another Lidarr): no further steps, writes or saves. A write already
    /// on the wire still completes; nothing follows it. Call before another runner loads the same store.
    public func stop() {
        stopped = true
        for c in watchers.values { c.finish() }
        watchers = [:]
        releaseLeases()   // a retired runner holds nothing (its step in flight writes nothing more)
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
    /// How many ticks have started (tests: whether polling ran).
    public private(set) var tickCount = 0
    /// Passes that ran (tests: overlapping ticks run one).
    private(set) var passCount = 0
    /// Reads of the saved list (tests: concurrent loads share one).
    private(set) var storeLoads = 0

    public func tick() async { await tick(shouldStop: { false }) }

    /// One pass that ends early, between steps (never during one, so never mid-write), once `shouldStop` says so: a
    /// background pass whose time iOS takes back (R16, X5 fix round 1).
    public func tick(shouldStop: @Sendable () -> Bool) async {
        tickCount += 1
        // X5 fix I1: claimed before the load, so a tick arriving meanwhile (a background pass at a cold launch,
        // the app's first poll) runs no second pass.
        guard !ticking, !stopped else { return }
        ticking = true
        defer { ticking = false }
        guard await load() else { return }
        passCount += 1
        // Y5: leases renewed (I1), Lidarr's clock (item 9.7), the one-time migration (§9), then the facts (§3).
        renewLeases()
        if shouldStop() { return }
        await updateServerClock()
        await migrateY5()
        if shouldStop() { return }
        await recoverOrphanIntents()   // fix I2
        if shouldStop() { return }
        await foldFacts()
        for r in list where r.isActive {
            if shouldStop() { return }
            await advance(r.id)
        }
        if shouldStop() { return }
        await discoverAlbums()
        if shouldStop() { return }
        await pollLidarr()
        if shouldStop() { return }
        await checkLibrary()
        for r in list where r.cleanupPending && !requestBusy(r.id) {
            if shouldStop() { return }
            await cleanup(r.id)
        }
        if shouldStop() { return }
        await followKeeps()
        if shouldStop() { return }
        await followAdopted()
        if shouldStop() { return }
        await followReadyFinds()
        if shouldStop() { return }
        await trimToSongs()
        if shouldStop() { return }
        await followLossless()
        if shouldStop() { return }
        await flushFolderScans()   // fix I7
        if shouldStop() { return }
        await followNotForMes()
        if shouldStop() { return }
        await followBringIns()
    }

    /// G7: the places taken in the limit of 5: requests on their way and releases Bring in more is bringing in (FL4).
    var activeCount: Int { list.reduce(0) { $0 + $1.activePlaces } }

    // MARK: - The machine

    func request(_ id: RequestID) -> MagpieRequest? { list.first { $0.id == id } }

    func mutate(_ id: RequestID, _ change: (inout MagpieRequest) -> Void) async {
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
            Log.logger("requests").error("requests not saved: \(Log.category(of: error), privacy: .public)")
        }
        publish()
    }

    /// M6: the request list on disk *now*. Called before every Lidarr write, so what the write depends on
    /// (`addSent`, the album and artist ids, the cancelled state) survives a relaunch. Throws when the save
    /// fails: the write is not sent and the request waits.
    func persist() async throws {
        guard !stopped else { throw Superseded() }
        do { try await store.save(list) } catch {
            Log.logger("requests").error("requests not saved; Lidarr write postponed")
            throw NotSaved()
        }
    }

    /// Round 18 (`recoverFind`): a request put back from the ledger joins the list, saved before anyone sees it. False
    /// (nothing added): the list couldn't be saved.
    func adopt(_ r: MagpieRequest) async -> Bool {
        guard !stopped, !list.contains(where: { $0.id == r.id }) else { return false }
        list.append(r)
        do { try await persist() } catch {
            list.removeAll { $0.id == r.id }
            return false
        }
        publish()
        return true
    }

    /// The request list could not be saved before a Lidarr write (M6): nothing was sent; wait and retry.
    private struct NotSaved: Error {}

    private func publish() {
        for c in watchers.values { c.yield(list) }
    }

    /// Re-runs whatever step the request is in when nothing is running for it (after a relaunch, a retry
    /// timer, or `tryRecording`).
    private func advance(_ id: RequestID) async {
        guard !requestBusy(id), let r = request(id) else { return }
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

    func apply(_ id: RequestID, _ event: RequestEvent, deferCleanup: Bool = false) async {
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
        if case .failed = next { onFailed(r) }
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
        guard var artistMBID = r.recording.artistMBID ?? recording.artistIds.first else {
            return await apply(id, .error(.noRelease))
        }
        let artists: [LidarrArtist]
        do { artists = try await lidarr.artists() } catch { return await apply(id, .lidarrUnavailable) }
        lastLidarrContact = now()
        // Round 19: for an artist not in Lidarr yet, Lidarr's metadata says which of the song's releases it knows and
        // whose they are: a release is listed under its own artist (HUNTR/X's "Golden" under the film's cast), so that
        // artist is the one added; one Lidarr doesn't know is never waited for.
        var unknownToLidarr = Set<MBID>()
        if r.albumTarget == nil, !artists.contains(where: { $0.foreignArtistId == artistMBID }) {
            let listing = await lidarrListing(recording)
            unknownToLidarr = listing.unknown
            if let owner = listing.owner, owner != artistMBID {
                Log.logger("requests").info("the song's release is filed under another artist in Lidarr: adding that one")
                artistMBID = owner
            }
        }

        let plan: Plan
        let title: String?
        var alternates: [MBID] = []   // round 17: the other releases holding the song, best first
        if let artist = artists.first(where: { $0.foreignArtistId == artistMBID }) {
            // A7: only release groups the artist already has in Lidarr; its profiles are never changed.
            let albums: [LidarrAlbum]
            do { albums = try await lidarr.albums(artistId: artist.id) } catch { return await apply(id, .lidarrUnavailable) }
            let available = Set(albums.compactMap(\.foreignAlbumId))
            // An artist Magpie just added may not list its albums yet (Lidarr's refresh): pick as for a new artist.
            let magpies = (try? await ledger.createdArtist(artist)) == true
            let fits = Set(recording.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id))
            guard let rg = Self.albumTarget(r.albumTarget, allowed: r.albumTarget.map { available.contains($0) || (magpies && fits.contains($0)) } ?? false)
                    ?? (r.albumTarget != nil ? nil : ReleasePicker.smallest(containing: recording, available: available)
                        ?? (magpies ? ReleasePicker.smallest(containing: recording, available: fits) : nil)) else {
                return await apply(id, .error(.notInCatalogue))
            }
            plan = Plan(recordingMBID: recordingId, releaseGroupMBID: rg, artistMBID: artistMBID,
                        lidarrArtistId: artist.id, mode: .fallback)
            title = albums.first { $0.foreignAlbumId == rg }?.title
            alternates = ReleasePicker.ordered(containing: recording, available: magpies ? available.union(fits) : available)
            await mutate(id) { $0.artistExisted = true }   // round 15 C3 (D139): a Try here is a trial in the library
        } else {
            // A1: the "Magpie Finds" metadata profile only has official Album/EP/Single studio releases, so
            // only those can be monitored after the add.
            var fits = Set(recording.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id)).subtracting(unknownToLidarr)
            // Round 19: a song only on a soundtrack or a remix release (HUNTR/X "Golden", a film's song): the artist is
            // added with "Magpie Finds Extras", which lists those too.
            let studioHasIt = r.albumTarget.map(fits.contains) ?? (ReleasePicker.smallest(containing: recording, available: fits) != nil)
            var extras = false
            if !studioHasIt {
                let wider = Set(recording.releases.filter(Self.fitsFindsExtras).map(\.releaseGroup.id)).subtracting(unknownToLidarr)
                if !wider.isEmpty { fits = wider; extras = true }
            }
            guard let rg = Self.albumTarget(r.albumTarget, allowed: r.albumTarget.map(fits.contains) ?? false)
                    ?? (r.albumTarget != nil ? nil : ReleasePicker.smallest(containing: recording, available: fits)) else {
                return await apply(id, .error(.noRelease))
            }
            await mutate(id) { $0.findsExtras = extras ? true : nil }
            // Finds mode is the intent here; the add checks the Finds root again and may fall back (G2, B8).
            // Round 15 C3 (D135): Add to library never makes a find.
            let findsOn = await setup()?.finds != nil
            plan = Plan(recordingMBID: recordingId, releaseGroupMBID: rg, artistMBID: artistMBID,
                        lidarrArtistId: nil, mode: findsOn && !r.addToLibrary ? .finds : .fallback)
            title = recording.releases.first { $0.releaseGroup.id == rg }?.title
            alternates = ReleasePicker.ordered(containing: recording, available: fits)
        }
        await mutate(id) {
            $0.plan = plan
            // "Try this album" asked for that one release: nothing else stands in for it.
            $0.releaseAlternates = $0.albumTarget == nil ? alternates.filter { $0 != plan.releaseGroupMBID } : []
            if let title, !title.isEmpty { $0.albumTitle = title }
            // Help the match ladder find the song once it lands (ISRC, artist MBID).
            if $0.recording.isrcs.isEmpty { $0.recording.isrcs = recording.isrcs }
            if $0.recording.artistMBID == nil { $0.recording.artistMBID = artistMBID }
        }
        await apply(id, .resolved(plan))
    }

    /// MusicBrainz's "Various Artists".
    static let variousArtists = MBID("89ad4ac3-39f7-470e-963a-56509c546377")!

    /// The most of a song's releases checked with Lidarr's metadata before an add (each one read).
    static let listingChecks = 4

    /// Round 19: the song's releases a find could bring in (studio first, else soundtrack or remix), best first, each
    /// asked of Lidarr's metadata (`album/lookup`) until one is known: its artist (`owner`), and the ones before it Lidarr
    /// doesn't know (`unknown`). A read that fails ends the look with what is known so far (nothing changes then).
    func lidarrListing(_ recording: MBRecording) async -> (owner: MBID?, unknown: Set<MBID>) {
        var candidates = ReleasePicker.ordered(containing: recording,
                                               available: Set(recording.releases.filter(Self.fitsFindsProfile).map(\.releaseGroup.id)))
        if candidates.isEmpty {
            candidates = ReleasePicker.ordered(containing: recording,
                                               available: Set(recording.releases.filter(Self.fitsFindsExtras).map(\.releaseGroup.id)))
        }
        var unknown = Set<MBID>()
        for rg in candidates.prefix(Self.listingChecks) {
            guard let listed = try? await lidarr.albumOwner(releaseGroup: rg) else { return (nil, unknown) }
            lastLidarrContact = now()
            // A release filed under "Various Artists" is never brought in as an artist of its own.
            if listed.known, listed.artist != Self.variousArtists { return (listed.artist, unknown) }
            unknown.insert(rg)
        }
        return (nil, unknown)
    }

    /// Round 19: what "Magpie Finds Extras" adds: an official Album, EP or Single that is a soundtrack or a remix (and
    /// nothing else besides).
    static func fitsFindsExtras(_ release: MBRelease) -> Bool {
        let primary = release.releaseGroup.primaryType?.lowercased() ?? ""
        let secondary = Set(release.releaseGroup.secondaryTypes.map { $0.lowercased() })
        return ["album", "ep", "single"].contains(primary) && !secondary.isEmpty && secondary.isSubset(of: ["soundtrack", "remix"])
            && release.status?.lowercased() == "official"
    }

    static func fitsFindsProfile(_ release: MBRelease) -> Bool {
        let primary = release.releaseGroup.primaryType?.lowercased() ?? ""
        return ["album", "ep", "single"].contains(primary) && release.releaseGroup.secondaryTypes.isEmpty
            && release.status?.lowercased() == "official"
    }

    public static func sameSong(_ a: ExternalRecording, _ b: ExternalRecording) -> Bool {
        if let x = a.recordingMBID, let y = b.recordingMBID { return x == y }
        let fold = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return fold(a.title) == fold(b.title) && fold(a.artist) == fold(b.artist)
    }

    // MARK: - Add or monitor (A6, A7, G6, G7)

    struct AlbumMonitorBody: Encodable, Sendable {
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
                if let mode = leader.plan?.mode { $0.plan?.mode = mode }   // a find only if the leader's is one
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
        if let entry = try await ledger.entry(albumId: albumId), Self.isOwnPending(entry, id) {
            return try await resolveOwnPending(id, entry, monitored: album.monitored, artistId: artistId, albumId: albumId)
        }
        let settling = r.addSent && now().timeIntervalSince(r.addedAt ?? r.createdAt) < Self.addSettleTime
        guard album.monitored || settling else { throw AddFailure(reason: .stoppedInLidarr) }
    }

    /// An open entry of this request whose monitor isn't known to have applied (`notSent` or `unclear`).
    static func isOwnPending(_ entry: LedgerEntry, _ id: RequestID) -> Bool {
        entry.isOpen && !entry.isApplied && entry.requestId == id.description
    }

    /// The fix-round-3 table for this request's own pending entry, used by both `retrySearchOnly` and
    /// `monitorExisting` (security H1: never replace an `unclear` entry with a fresh `notSent` one):
    /// - not sent + monitored now: the owner did it (wasMonitoredBefore = true, never undone);
    /// - not sent + unmonitored: send it now (`sendMonitor`);
    /// - unclear + monitored: Magpie's write landed (applied);
    /// - unclear + unmonitored: maybe it landed and the owner undid it: stop, no write.
    private func resolveOwnPending(_ id: RequestID, _ entry: LedgerEntry, monitored: Bool,
                                   artistId: Int, albumId: Int) async throws {
        var e = entry
        switch (entry.send, monitored) {
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
    }

    /// Sends `PUT /album/monitor` for an entry already in the ledger (fix rounds 4–5).
    ///
    /// The entry is saved as `unclear` *before* the PUT, so if the app dies while it is in flight the entry
    /// never claims "not sent". If that save fails, nothing is sent. Afterwards:
    /// - success: `applied`;
    /// - `WriteGateError`: `notSent` (the gate throws every one of them before anything leaves the device);
    /// - a 4xx answer actually received from Lidarr (a definitive rejection): `notSent`;
    /// - anything else (timeout, connection error, 5xx): a confirming GET that shows the album monitored
    ///   makes it `applied`; otherwise it stays `unclear`. "Unmonitored" proves nothing here: the PUT may
    ///   still be in flight after a client-side timeout and land after the GET.
    /// If saving the outcome fails, the entry stays `unclear` (never more permissive than the truth).
    /// Rethrows any failure so the request waits.
    private func sendMonitor(_ entry: LedgerEntry, artistId: Int, albumId: Int) async throws {
        try await persist()   // M6: the request's ids are on disk before anything can land in Lidarr
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
            if Self.isDefinitiveRejection(error) {
                e.send = .notSent
                try? await ledger.record(e)
            } else if (try? await lidarr.albums(artistId: artistId))?.first(where: { $0.id == albumId })?.monitored
                        == true {
                e.send = .applied
                try? await ledger.record(e)
            }
            throw error
        }
        e.send = .applied
        try await ledger.record(e)
    }

    /// Lidarr answered the write with a 4xx: it was received and refused, so it did not apply.
    static func isDefinitiveRejection(_ error: Error) -> Bool {
        switch error as? LidarrError {
        case .http(let status)?: return (400..<500).contains(status)
        case .unauthorized?: return true   // 401 / 403
        default: return false
        }
    }

    /// The add was sent but its outcome was unclear (timeout, relaunch) and the artist exists now: it is
    /// Magpie's. Adopt it, ledger it at artist level at once, and wait for its album (no second POST).
    private func adoptCreatedArtist(_ id: RequestID, _ r: MagpieRequest, artist: LidarrArtist, rg: MBID) async throws {
        try ensure(id, .adding)
        try await ledger.record(LedgerEntry(lidarrArtistId: artist.id, albumId: nil, rgMbid: rg, createdArtist: true,
                                            wasMonitoredBefore: false, root: r.root ?? artist.rootFolderPath ?? "",
                                            mode: r.plan?.mode ?? .fallback, requestId: id.description,
                                            artistMbid: artist.foreignArtistId))
        await mutate(id) {
            $0.lidarrArtistId = artist.id
            $0.skipNextSearch = true
        }
        await discoverAlbum(id)
    }

    /// A7 / G6: monitor the one album and search; no tags, no profile or artist change.
    ///
    /// Order (fix rounds 2–4): the ledger gets a `notSent` entry, the request learns the ids (so clean-up can
    /// always find the album), then `sendMonitor` saves the request, marks the entry `unclear`, sends the PUT
    /// and records the outcome. Only applied entries are ever undone.
    ///
    /// This request's own pending entry (its ids were lost, e.g. a failed save before a relaunch) is resolved
    /// by `resolveOwnPending`, never overwritten (security H1).
    private func monitorExisting(_ id: RequestID, _ r: MagpieRequest, artist: LidarrArtist, rg: MBID) async throws {
        // G6: an artist that was already there never becomes a find (a Finds-mode intent ends here), unless it is
        // a find right now (D29, final fix 2 A-I1): then its songs are finds too (never scrobbled). Either way
        // nothing about the artist is written.
        let mode: LedgerMode = try await isFindNow(artist) ? .finds : .fallback
        if r.plan?.mode != mode { await mutate(id) { $0.plan?.mode = mode } }
        let albums = try await lidarr.albums(artistId: artist.id)
        guard let album = albums.first(where: { $0.foreignAlbumId == rg }) else {
            // Magpie's own artist whose album isn't listed yet: wait for it (no write), with the usual give-up.
            guard try await ledger.createdArtist(artist) else { throw AddFailure(reason: .notInCatalogue) }
            try ensure(id, .adding)
            await mutate(id) {
                $0.lidarrArtistId = artist.id
                $0.skipNextSearch = true
            }
            return
        }
        let prior = try await ledger.entry(albumId: album.id)
        if let prior, Self.isOwnPending(prior, id) {
            try ensure(id, .adding)
            await mutate(id) {
                $0.lidarrArtistId = artist.id
                $0.albumId = album.id
            }
            return try await resolveOwnPending(id, prior, monitored: album.monitored, artistId: artist.id,
                                               albumId: album.id)
        }
        // Monitored now: the owner's, unless an open entry of this request or of a live request says Magpie
        // did it. Closed entries (finished requests) are never inherited: the owner may have monitored it since.
        let liveIds = Set(list.filter { $0.isActive }.map(\.id.description)).union([id.description])
        let livePrior = prior.flatMap { p in p.isOpen && p.isApplied && p.requestId.map(liveIds.contains) == true ? p : nil }
        // A-M1: the open, applied entry of a ready (or kept) request on an artist Magpie created is that request's
        // record (a find's own monitor and mode): a second Try of the same release inherits it, never replaces it.
        let readyIds = Set(list.filter { $0.state == .ready || $0.state == .kept }.map(\.id.description))
        let readyPrior = prior.flatMap { p in
            p.isOpen && p.isApplied && p.created(artist) && p.requestId.map(readyIds.contains) == true ? p : nil
        }
        let wasMonitoredBefore = album.monitored
            ? (livePrior?.wasMonitoredBefore ?? readyPrior?.wasMonitoredBefore ?? true) : false
        let needsMonitor = !album.monitored
        try ensure(id, .adding)
        var entry = LedgerEntry(
            lidarrArtistId: artist.id, albumId: album.id, rgMbid: rg,
            createdArtist: (try? await ledger.createdArtist(artist)) == true,
            wasMonitoredBefore: wasMonitoredBefore,
            root: readyPrior?.root ?? artist.rootFolderPath ?? r.root ?? artist.path ?? "", mode: readyPrior?.mode ?? .fallback,
            keptAt: prior?.keptAt, send: needsMonitor ? .notSent : .applied,   // C5: carry-over (Y5 fix I4)
            requestId: needsMonitor ? id.description : (readyPrior?.requestId ?? id.description),
            artistMbid: artist.foreignArtistId)
        // Y5 fix I4: a Try on this album never drops a Keep under way or the find's file record (Ledger.record merges too).
        entry.keepIntentAt = prior?.keepIntentAt
        entry.findFiles = prior?.findFiles
        let trial = markTrial(&entry, r, mode: mode, needsMonitor: needsMonitor, album: album)   // round 15 C3 (D147)
        try await ledger.record(entry)
        await mutate(id) {
            $0.lidarrArtistId = artist.id
            $0.albumId = album.id
            if trial { $0.trialExpiresAt = entry.trialExpiresAt }
        }
        guard needsMonitor else { return }
        try ensure(id, .adding)
        try await sendMonitor(entry, artistId: artist.id, albumId: album.id)
    }

    /// D29 (final fix 2 A-I1): the fresh artist is a find right now: Magpie created it (ledger), it carries
    /// `magpie-find`, and its folder is inside the Finds root, checked against fresh root folders (G2). Only an
    /// artist Magpie created costs the root-folder read; an owner's artist is never a find (G6). A failed read
    /// throws: the request waits rather than guess.
    private func isFindNow(_ artist: LidarrArtist) async throws -> Bool {
        guard let setup = await setup(), let finds = setup.finds, try await ledger.createdArtist(artist) else {
            return false
        }
        let findTags = Set(finds.tagIds).subtracting(setup.tagIds)
        guard !findTags.isEmpty, findTags.isSubset(of: artist.tags), let path = artist.path else { return false }
        let roots = try await lidarr.rootFolders().map(\.path)
        lastLidarrContact = now()
        guard Self.findsRootStillValid(finds.rootFolderPath, main: setup.rootFolderPath, roots: roots) else { return false }
        return Self.findsGuard(findsRoot: finds.rootFolderPath, mainRoot: setup.rootFolderPath, roots: roots).isInside(path)
    }

    /// A6: one atomic `POST /artist` built from the lookup row: Fast Start, "Magpie Finds" metadata, nothing
    /// new monitored, only this release group, no search on add (round 16, owner 2026-11-05: the runner sends the
    /// release's own AlbumSearch once Lidarr lists it monitored, `startSearch`, as D135 does for Add to library;
    /// Lidarr's post-add `MissingAlbumSearch` never reached the owner's downloader). Finds mode: the Finds root and tags `magpie` +
    /// `magpie-find`, if the Finds root still checks out against fresh root folders (`findsRootStillValid`);
    /// otherwise, and in fallback mode, the main root and tag `magpie`.
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
        let library = request(id)?.addToLibrary == true
        let target = library ? try Self.libraryDestination(setup) : try await destination(setup)
        var findSetup = target.setup
        if !library, request(id)?.findsExtras == true {   // round 19: a soundtrack or remix release
            findSetup.metadataProfileId = try await Provisioner().ensureFindsExtras(gate: gate, client: lidarr)
        }
        let body = library ? try Self.addLibraryArtistBody(lookup: lookup, setup: target.setup, request: request(id))
                           : try Self.addArtistBody(lookup: lookup, setup: findSetup, releaseGroup: plan.releaseGroupMBID)
        // Item 9.8: the command list before the add, so only Lidarr's RefreshArtist for this add counts.
        let baseline = (try? await lidarr.commands())?.map(\.id).max()
        try ensure(id, .adding)
        await mutate(id) {
            $0.addCommandBaseline = baseline
            $0.addSent = true
            $0.addedAt = self.now()
            $0.root = target.setup.rootFolderPath
            $0.plan?.mode = target.mode
            $0.findsUnavailable = setup.finds != nil && target.mode == .fallback
        }
        func nothingSent() async { await mutate(id) { $0.addSent = false; $0.addedAt = nil } }
        do { try await persist() } catch {   // M6: `addSent` is on disk before the POST, or nothing is sent
            await nothingSent()
            throw error
        }
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
                                                root: target.setup.rootFolderPath, mode: target.mode,
                                                requestId: id.description, artistMbid: plan.artistMBID))
        } catch {
            Log.logger("requests").error("ledger not written for a new artist; retried with its album")
        }
        await mutate(id) {
            $0.lidarrArtistId = artistId
            $0.skipNextSearch = false   // round 16 (D135 for a Try too): the runner searches the release once listed
        }
        await discoverAlbum(id)
    }

    /// Where a new artist goes. Finds mode reads Lidarr's root folders now (a failure throws: the request waits,
    /// nothing is added) and uses the Finds root only if it still passes; else the main root (B8).
    private func destination(_ setup: Setup) async throws -> (setup: Setup, mode: LedgerMode) {
        guard let finds = setup.finds else { return (setup, .fallback) }
        let roots = try await lidarr.rootFolders().map(\.path)
        lastLidarrContact = now()
        guard Self.findsRootStillValid(finds.rootFolderPath, main: setup.rootFolderPath, roots: roots) else {
            Log.logger("requests").error("Finds root no longer checks out; adding to the main root")
            return (setup, .fallback)
        }
        var target = setup
        target.rootFolderPath = finds.rootFolderPath
        target.tagIds = finds.tagIds
        return (target, .finds)
    }

    /// G2, re-checked before every Finds-mode add: the Finds root is still one of Lidarr's root folders (same
    /// spelling, byte for byte, after standardising), and neither equals, holds nor sits inside any other root
    /// folder or the main root.
    static func findsRootStillValid(_ finds: String, main: String, roots: [String]) -> Bool {
        PathGuard.findsRootStillValid(finds, main: main, roots: roots)
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
                "searchForMissingAlbums": .bool(false),
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
            guard r.isActive, !following else { return }
            // Item 9.8: once Lidarr's refresh of the new artist completed, a missing album won't appear.
            switch await addRefresh(r, artistId: artistId) {
            case .completed?:
                // Read once more: the refresh may have completed just after the first read.
                if let again = try? await lidarr.albums(artistId: artistId), again.contains(where: { $0.foreignAlbumId == rg }) {
                    return
                }
                await nextRelease(id, otherwise: .error(.noRelease))   // round 17: another release holding the song
            case .failed?:
                await apply(id, .lidarrUnavailable)
            case nil:
                if now().timeIntervalSince(r.addedAt ?? r.searchStartedAt ?? r.createdAt) > Self.albumAppearLimit {
                    await nextRelease(id, otherwise: .error(.noRelease))
                }
            }
            return
        }
        if r.addSent {
            do {
                // Lidarr monitored it through `albumsToMonitor` of Magpie's own add: Magpie's to undo.
                try await ledger.record(LedgerEntry(lidarrArtistId: artistId, albumId: album.id, rgMbid: rg,
                                                    createdArtist: true, wasMonitoredBefore: false,
                                                    root: r.root ?? "", mode: r.plan?.mode ?? .fallback,
                                                    send: .applied, requestId: id.description,
                                                    artistMbid: r.plan?.artistMBID))
            } catch {
                return   // no ledger, no album id: tried again next tick
            }
        }
        await mutate(id) {
            $0.lidarrArtistId = artistId
            $0.albumId = album.id
            $0.albumSeen = true
        }
    }

    enum RefreshOutcome { case completed, failed }

    /// I12: Lidarr's RefreshArtist for this request's add: newer than the baseline saved before `POST /artist`, with
    /// non-empty artist ids naming the artist (a global refresh never counts). Nil: unknown (none seen, still
    /// running, pruned, or Lidarr unreadable): the fixed limits apply.
    func addRefresh(_ r: MagpieRequest, artistId: Int) async -> RefreshOutcome? {
        if r.addRefreshDone == true { return .completed }
        guard r.addSent, let baseline = r.addCommandBaseline, let commands = try? await lidarr.commands() else { return nil }
        guard let refresh = commands.filter({
            $0.id > baseline && $0.name.lowercased() == "refreshartist" && !$0.artistIds.isEmpty && $0.artistIds.contains(artistId)
        }).max(by: { $0.id < $1.id }) else { return nil }
        switch refresh.status.lowercased() {
        case "completed":
            await mutate(r.id) { $0.addRefreshDone = true }
            return .completed
        case "failed", "aborted", "cancelled", "orphaned":
            return .failed
        default:
            return nil
        }
    }

    private func discoverAlbums() async {
        for r in list where (r.isActive || r.cleanupPending) && r.albumId == nil && r.plan != nil
                            && !requestBusy(r.id) {
            switch r.state {
            case .pending, .resolving, .adding: continue
            default: await discoverAlbum(r.id)
            }
        }
    }

    // MARK: - Search and progress (A14)

    private func startSearch(_ id: RequestID) async {
        guard let r = request(id) else { return }
        // M3 ruling: once five copies were dropped, Magpie sends no searches of its own for this request; Lidarr's
        // own monitoring carries on and the request stays live until its normal expiry.
        let afterRemoval = searchAfterRemoval.remove(id) != nil
        // Round 16 (owner, 2026-11-05): Magpie's own add sends no search with it; its AlbumSearch waits until Lidarr
        // lists the album monitored (its refresh of the new artist applies `albumsToMonitor`), never counted as sent.
        if !r.skipNextSearch, r.addSent, r.joinedTo == nil, !(r.removalsUsedUp && !afterRemoval),
           !(await addedAlbumSearchable(r)) {
            if afterRemoval { searchAfterRemoval.insert(id) }
            return
        }
        if r.skipNextSearch || r.albumId == nil || (r.removalsUsedUp && !afterRemoval) {
            await mutate(id) {
                $0.skipNextSearch = false
                if $0.searchStartedAt == nil {
                    $0.searchStartedAt = self.now()
                    $0.searchStartedAtServer = self.serverNow()
                }
            }
            return await apply(id, .searchStarted)
        }
        do {
            try ensure(id, .searching)
            try await persist()
            let data = try await gate.send("POST", "command", body: CommandBody(name: "AlbumSearch", albumIds: [r.albumId!]))
            let commandId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue
            await mutate(id) {
                $0.searchStartedAt = self.now()
                $0.searchStartedAtServer = self.serverNow()
                $0.searchCommandId = commandId
                $0.grabbed = false
            }
            await searchDiscography(id)
            await apply(id, .searchStarted)
        } catch is Superseded {
            return
        } catch {
            await apply(id, Self.event(for: error))
        }
    }

    /// Round 16: the album of Magpie's own add may be searched: Lidarr lists it monitored (its refresh applied
    /// `albumsToMonitor`), or lists it and the refresh is done or `addSettleTime` passed (searched as it is: the
    /// owner asked for it). Not yet: false, and a later pass looks again (`discoverAlbum`'s give-up still applies).
    func addedAlbumSearchable(_ r: MagpieRequest) async -> Bool {
        guard let albumId = r.albumId, let artistId = r.lidarrArtistId,
              let albums = try? await lidarr.albums(artistId: artistId) else { return false }
        lastLidarrContact = now()
        guard let album = albums.first(where: { $0.id == albumId }) else { return false }
        if album.monitored { return true }
        if await addRefresh(r, artistId: artistId) == .completed { return true }
        return now().timeIntervalSince(r.addedAt ?? r.createdAt) >= Self.addSettleTime
    }

    static let finishedCommandStates: Set<String> = ["completed", "failed", "aborted", "cancelled", "orphaned"]

    private func pollLidarr() async {
        let polled = list.filter { r in
            guard r.albumId != nil, !requestBusy(r.id) else { return false }
            switch r.state {
            case .searching, .downloading, .waiting: return r.searchStartedAt != nil
            default: return false
            }
        }
        guard !polled.isEmpty else { return }
        let albumIds = Array(Set(polled.compactMap(\.albumId))).sorted()
        // Item 9.7: Lidarr's time throughout (its history dates are its own clock's).
        let pollStart = serverNow()
        // PROMOTED B: only what's new since the last poll (with a minute of overlap), never more than a day.
        let earliest = (polled.map(serverStart).min() ?? pollStart).addingTimeInterval(-60)
        let since = max(persistedState.historyCursor ?? earliest, earliest, pollStart.addingTimeInterval(-Self.historyLookback))
        let queue: [QueueItem], history: [HistoryEvent]
        do {
            queue = try await lidarr.queueDetails(albumIds: albumIds)
            history = try await lidarr.historySince(since)
            lastLidarrContact = now()
            saveHistoryCursor(pollStart.addingTimeInterval(-60))
            // Y5 follow-up 4: forget "warning" downloads that left the queue.
            let present = Set(queue.compactMap(\.id))
            warningWatch = warningWatch.filter { present.contains($0.key) }
        } catch {
            guard now().timeIntervalSince(lastLidarrContact) >= Self.lidarrSilenceLimit else { return }
            for r in polled where r.state != .importing { await apply(r.id, .lidarrUnavailable) }
            return
        }
        for r in polled {
            guard let current = request(r.id), let albumId = current.albumId, current.searchStartedAt != nil else { continue }
            let started = serverStart(current)
            let items = queue.filter { $0.albumId == albumId }
            let events = history.filter { $0.albumId == albumId && ($0.date ?? started) >= started.addingTimeInterval(-60) }
            if events.contains(where: { $0.kind == .imported }) {
                await apply(r.id, .imported)
                continue
            }
            if await handledStall(r.id, items) { continue }   // R17 (RequestRunner+Stall.swift)
            // Item 9.6: a download in "warning" (any client) is stalled only once it hasn't moved for the stall limit.
            if let stalled = staleWarning(items) {
                await mutate(r.id) {
                    $0.grabbed = true
                    $0.note = Self.shortNote(stalled)
                }
                if case .waiting = current.state {} else { await apply(r.id, .downloadFailed) }
                continue
            }
            if let stuck = items.first(where: { Self.isStuck($0) && !Self.isWarningDownloading($0) }) {
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
            // A14 "nothing found": the search finished, nothing queued, nothing grabbed. Round 19: Lidarr decides its grab
            // inside the AlbumSearch command (a delay profile's hold shows as a pending queue row), so once Lidarr says the
            // command finished, `noGrabAfterFinishedSearch` is enough; when it can't say, the old 10 minutes.
            let elapsed = now().timeIntervalSince(current.searchStartedAt ?? now())
            if current.state == .searching, !current.grabbed, lastGrab == nil, elapsed >= Self.noGrabAfterFinishedSearch {
                var searchDone = elapsed >= RequestMachine.noGrabThreshold
                if let commandId = current.searchCommandId, let command = try? await lidarr.command(id: commandId) {
                    searchDone = Self.finishedCommandStates.contains(command.status.lowercased())
                }
                // Round 17: another format for a find, else the next release holding the song, else it fails.
                if searchDone { await nothingFound(r.id) }
            }
        }
    }

    /// Round 19: how long after the search started "nothing found" may be said once Lidarr reports its search finished.
    public static let noGrabAfterFinishedSearch: TimeInterval = 150

    /// When the request's search started, in Lidarr's time (stored since Y5; older requests: the phone's + offset).
    func serverStart(_ r: MagpieRequest) -> Date {
        r.searchStartedAtServer ?? (r.searchStartedAt ?? now()).addingTimeInterval(persistedState.clockOffset ?? 0)
    }

    /// Still downloading, with a warning (slskd shows this while it works; other clients for slow peers).
    static func isWarningDownloading(_ item: QueueItem) -> Bool {
        item.trackedDownloadState.lowercased() == "downloading" && item.status.lowercased() == "warning"
    }

    /// A non-Soulseek "warning" download whose `sizeleft` hasn't changed for the stall limit (Soulseek ones are
    /// R17's, removed and searched again by `handledStall`).
    func staleWarning(_ items: [QueueItem]) -> QueueItem? {
        let t = now()
        for item in items where Self.isWarningDownloading(item) && !isSoulseek(item) {
            guard let id = item.id else { continue }
            if let seen = warningWatch[id], seen.sizeleft == item.sizeleft {
                if t.timeIntervalSince(seen.since) >= stallLimit { return item }
            } else {
                warningWatch[id] = (item.sizeleft, t)
            }
        }
        return nil
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
        for r in list where r.state == .importing && r.notListedAt == nil && !requestBusy(r.id)
            && t.timeIntervalSince(r.importingSince ?? r.updatedAt) >= Self.importingLimit {
            await mutate(r.id) { $0.notListedAt = t }
        }
        let importing = list.filter { $0.state == .importing && $0.notListedAt == nil && !requestBusy($0.id) }
        if !importing.isEmpty {
            // A scan status stuck at "scanning" must not hide a song Navidrome already lists (it lists files as
            // the scan reaches them): the index is refreshed either way; a new scan only starts when none runs.
            let scanning = try? await library.isScanning()
            let youngest = importing.map { t.timeIntervalSince($0.importingSince ?? t) }.min() ?? 0
            // While a scan runs, refresh at most every `scanningRefreshInterval` (each refresh pages the whole
            // library); still refresh, so a scan status stuck at "scanning" recovers.
            let backoff = Self.clamp(youngest / 2, Self.indexRefreshInterval)
            let refreshEvery = scanning == true ? max(backoff, Self.scanningRefreshInterval) : backoff
            if lastIndexRefresh.map({ t.timeIntervalSince($0) >= refreshEvery }) ?? true {
                lastIndexRefresh = t
                do { try await library.refreshIndex() } catch {
                    Log.logger("requests").error("index refresh failed: \(Log.category(of: error), privacy: .public)")
                }
            }
            let rescanEvery = Self.clamp(youngest / 2, Self.rescanInterval)
            if scanning == false,
               importing.contains(where: { $0.lastScanAt.map { t.timeIntervalSince($0) >= rescanEvery } ?? true }) {
                try? await library.startScan()
                for r in importing { await mutate(r.id) { $0.lastScanAt = t } }
            }
        }
        // Ground truth from any pre-ready state: the library lists the song (an in-memory index lookup).
        for r in list where r.isActive && !requestBusy(r.id) {
            if let songId = await library.songId(r.recording) {
                await apply(r.id, .visibleInLibrary(songId: songId))
            } else if r.state == .importing, r.notListedAt == nil {
                await matchWithoutTags(r.id)   // Y5 item 9.2
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
        // One at a time per request (actor re-entrancy across the awaits below); a later pass picks up what's left.
        guard !cleaningUp.contains(id), let r = request(id), r.cleanupPending else { return }
        cleaningUp.insert(id)
        defer { cleaningUp.remove(id) }
        func done() async {
            // Round 16: a stopped find's artist leaves Lidarr when nothing of it is left (`removeStoppedFindArtist`);
            // until that is settled the clean-up stays pending and a later pass looks again.
            guard await removeStoppedFindArtist(id) else { return }
            await mutate(id) { $0.cleanupPending = false }
        }
        guard let rg = r.plan?.releaseGroupMBID else { return await done() }
        let shared = list.contains { other in
            other.id != id && other.plan?.releaseGroupMBID == rg
                && (other.isActive || other.state == .ready || other.state == .kept)
        }
        if shared { return await done() }   // the entry stays open: the other request still relies on it
        // Item 9.8: settled once Lidarr's refresh of the add completed (it applies `albumsToMonitor`), else by time.
        var settling = r.addSent && r.joinedTo == nil && r.addRefreshDone != true
            && now().timeIntervalSince(r.addedAt ?? r.createdAt) < Self.addSettleTime
        if r.albumId == nil { await discoverAlbum(id) }
        var albumId = request(id)?.albumId, artistId = request(id)?.lidarrArtistId
        if albumId == nil, let mine = try? await ledger.entries.last(where: {
            $0.requestId == id.description && $0.albumId != nil && $0.isOpen
        }) {
            albumId = mine.albumId
            artistId = mine.lidarrArtistId
        }
        // Round 16: asked here too, so a Stop looking soon after the add settles once the refresh is done (not after
        // `addSettleTime`); read before the album, whose monitored flag is final from then on.
        if settling, let artistId, await addRefresh(request(id) ?? r, artistId: artistId) == .completed { settling = false }
        guard let albumId, let artistId else {
            if !settling { await done() }   // the album may still appear
            return
        }
        do {
            guard let entry = try await ledger.entry(albumId: albumId) else { return await done() }
            // Only an open, applied entry of Magpie's own monitor is undone (never an intent, a kept album or
            // an album the owner had monitored).
            if entry.isOpen, entry.isApplied, !entry.wasMonitoredBefore, !entry.isKeptOrKeeping {
                let albums = try await lidarr.albums(artistId: artistId)
                if let album = albums.first(where: { $0.id == albumId }), album.monitored {
                    try await persist()
                    _ = try await gate.send("PUT", "album/monitor", body: AlbumMonitorBody(albumIds: [albumId], monitored: false))
                }
            }
            guard !settling else { return }
            // Round 20 (owner: stopped, the artist went, then the album was grabbed anyway): a search Lidarr is still
            // running for the album can grab after the stop (a search Magpie started ignores "monitored"). Wait for it
            // to finish, then take out any copy it grabbed (from the client too), before the entry closes and the
            // artist may go.
            guard await drained(id, albumId: albumId), await removeLateImport(id, albumId: albumId, artistId: artistId) else { return }
            if entry.isOpen {
                var closed = entry
                closed.closedAt = now()
                try await ledger.record(closed)
            }
            await done()
        } catch {
            // Lidarr unreachable, changes switched off or the ledger unreadable: try again on a later tick.
            Log.logger("requests").error("clean-up postponed: \(Log.category(of: error), privacy: .public)")
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
            case .disabled, .logUnavailable, .unconfirmed: return .lidarrUnavailable
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
