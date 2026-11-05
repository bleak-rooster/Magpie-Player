import Foundation
import LidarrKit
import MagpieCore
import os

/// Round 15 C3 (D146): "Include singles for this artist", confirmed by the owner, for any artist, as a persisted journal
/// (one switch per artist). Every write is `ConfinedShape.singlesSwitch`; the gate allows them only for an artist whose
/// switch is in this journal, and only these values (`WriteConfinement.singlesEditor`).
///
/// The steps, each saved before its write (every write is idempotent, so a resumed step is safe to send again):
/// 1. `saved`: the original metadata profile id and `monitorNewItems`, the album list before (ids and release groups) and
///    the song asked for. Nothing is sent unless this save succeeds. A profile that already lists singles: no switch.
/// 2. `followOff`: `monitorNewItems` none (if it wasn't).
/// 3. `profileSwitched`: "<the artist's profile> + Singles (Magpie)", a superset of the artist's own, reused or made; never
///    narrower, never an existing profile modified (C1).
/// 4. `refreshSent`: RefreshArtist; its command id is required.
/// 5. `refreshed`: only once Lidarr says that command completed (else pending, following still off; resumed later).
/// 6. `extrasUnmonitored`: every release that appeared in the refresh, is monitored and isn't the target, unmonitored.
/// 7. `done`: `monitorNewItems` back to its saved value.
/// One that keeps failing is rolled back: the profile, a confirmed refresh, then following (re-review m4). Undo of a
/// finished switch does the same, only while the artist is still on the Magpie profile (m6).
public struct SinglesSwitchJob: Codable, Sendable, Equatable, Identifiable {
    public enum Step: String, Codable, Sendable {
        case saved, followOff, profileSwitched, refreshSent, refreshed, extrasUnmonitored, done, rolledBack, undone
        /// A roll-back or undo whose profile is back and whose refresh is being confirmed (following comes last).
        case puttingBack
    }

    public var artistId: Int
    public var target: MBID
    public var originalProfileId: Int
    public var originalFollow: String
    public var singlesProfileId: Int?
    public var beforeAlbumIds: [Int]
    public var beforeReleaseGroups: [MBID]
    public var refreshCommandId: Int?
    public var step: Step
    /// The step whose write is being sent (saved just before it).
    public var sending: Step?
    public var startedAt: Date
    public var failures: Int
    /// Re-review m5: the song the switch is for, asked for once the switch is done (also after a relaunch).
    public var recording: ExternalRecording?
    /// A put-back under way ends as this (`rolledBack` or `undone`).
    public var puttingBackTo: Step?

    public var id: Int { artistId }
    public var isOpen: Bool { step != .done && step != .rolledBack && step != .undone }

    public init(artistId: Int, target: MBID, originalProfileId: Int, originalFollow: String, beforeAlbumIds: [Int],
                beforeReleaseGroups: [MBID], startedAt: Date, recording: ExternalRecording? = nil) {
        self.artistId = artistId; self.target = target; self.originalProfileId = originalProfileId
        self.originalFollow = originalFollow; self.beforeAlbumIds = beforeAlbumIds; self.beforeReleaseGroups = beforeReleaseGroups
        self.step = .saved; self.startedAt = startedAt; self.failures = 0; self.recording = recording
    }
}

/// `Application Support/Magpie/singles-switch-<instance>.json`, one per Lidarr (atomic, excluded from backup, erased with
/// the requests on sign-out). One job per artist. The gate reads it (`original(artistId:)`).
///
/// Re-review R1: one store per file (`shared(fileURL:)`), so two switchers never hold stale copies; `close()` (sign-out,
/// disconnect, a rebuild for another Lidarr) makes every later save refuse, so nothing writes the file again.
/// Re-review m3: an unreadable file is moved aside (never silently dropped) and `damagedAt` says so; rows that don't
/// decode are dropped one by one.
public actor SinglesSwitchStore {
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/singles-switch-\(instance).json")
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [URL: SinglesSwitchStore]())

    /// The one store for `fileURL` (made on first use; a closed one is replaced).
    public static func shared(fileURL: URL) -> SinglesSwitchStore {
        registry.withLock { all in
            if let open = all[fileURL], !open.closedFlag.withLock({ $0 }) { return open }
            let store = SinglesSwitchStore(fileURL: fileURL)
            all[fileURL] = store
            return store
        }
    }

    public enum StoreError: Error { case closed }

    public nonisolated let fileURL: URL?
    nonisolated let closedFlag = OSAllocatedUnfairLock(initialState: false)
    private var memory: [SinglesSwitchJob] = []
    private var loaded = false
    /// The file couldn't be read (it was moved aside): a switch may need a look.
    public private(set) var damagedAt: Date?

    init(fileURL: URL?) { self.fileURL = fileURL }

    /// Sign-out or a rebuild: nothing is saved from here on.
    public nonisolated func close() { closedFlag.withLock { $0 = true } }
    public nonisolated var isClosed: Bool { closedFlag.withLock { $0 } }

    public func jobs() throws -> [SinglesSwitchJob] {
        if !loaded, let fileURL {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data: Data
                do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
                if let rows = try? JSONDecoder().decode([Lenient].self, from: data) {
                    memory = rows.compactMap(\.value)
                    if memory.count < rows.count { damagedAt = Date() }
                } else {
                    let aside = fileURL.deletingLastPathComponent()
                        .appending(path: "\(fileURL.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
                    try? FileManager.default.moveItem(at: fileURL, to: aside)
                    damagedAt = Date()
                    memory = []
                }
            }
            loaded = true
        }
        return memory
    }

    public func job(_ artistId: Int) throws -> SinglesSwitchJob? { try jobs().first { $0.artistId == artistId } }

    /// Saves `job` (replacing the artist's). Throws when it can't be saved, or the store is closed: nothing is sent then.
    public func save(_ job: SinglesSwitchJob) throws {
        guard !isClosed else { throw StoreError.closed }
        var all = try jobs().filter { $0.artistId != job.artistId }
        all.append(job)
        if let fileURL {
            try AtomicFile.write(all, to: fileURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = fileURL
            try? file.setResourceValues(values)
        }
        memory = all
    }

    /// What the gate may restore for the artist: nil without a job, after its undo, or once closed.
    public func original(artistId: Int) -> WriteConfinement.SinglesOriginal? {
        guard !isClosed, let job = try? job(artistId), job.step != .undone else { return nil }
        return .init(profileId: job.originalProfileId, follow: job.originalFollow, open: job.isOpen,
                     singlesProfileId: job.singlesProfileId)
    }

    private struct Lenient: Decodable {
        let value: SinglesSwitchJob?
        init(from decoder: Decoder) throws { value = try? SinglesSwitchJob(from: decoder) }
    }
}

public enum SinglesSwitchError: Error, Equatable {
    case changesOff
    /// The journal couldn't be saved: nothing was sent.
    case notSaved
    /// Lidarr couldn't be read, or the artist's profile isn't there: nothing was sent.
    case unavailable
    /// A same-named "+ Singles (Magpie)" profile is set up differently: nothing was sent.
    case profileConflict(String)
    /// Undo without a finished switch.
    case nothingToUndo
    /// Re-review m6: the owner changed the artist's profile since the switch; Undo leaves it as it is.
    case changedByOwner
    /// Re-review R1: this switcher was retired (a rebuild or sign-out); it sends nothing more.
    case stopped
}

public actor SinglesSwitcher {
    public enum Outcome: Equatable, Sendable {
        /// The artist's profile already lists singles: nothing was switched.
        case alreadyListed
        case finished
        /// Not finished yet (the refresh not confirmed, Lidarr unreachable…): following stays off, resumed later.
        case pending
        /// It couldn't be finished, so it was put back (the profile, a refresh, then following).
        case rolledBack
    }

    let lidarr: LidarrClient
    let gate: LidarrWriteGate
    public nonisolated let store: SinglesSwitchStore
    let checks: Int
    let pause: Duration
    let now: @Sendable () -> Date
    /// Failures of one switch before it is rolled back.
    public static let maxFailures = 5

    private var busy: Set<Int> = []
    private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// Re-review R1: retired (a rebuild, sign-out): checked before every send and save.
    private var stopped = false

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, store: SinglesSwitchStore, checks: Int = 30,
                pause: Duration = .seconds(2), now: @escaping @Sendable () -> Date = Date.init) {
        self.lidarr = lidarr; self.gate = gate; self.store = store; self.checks = checks; self.pause = pause; self.now = now
    }

    /// The runner was torn down or rebuilt: nothing more is sent or saved by this switcher.
    public func stop() { stopped = true }

    private func running() throws {
        if stopped || store.isClosed { throw SinglesSwitchError.stopped }
    }

    // MARK: - One switch per artist (I3)

    private func acquire(_ artistId: Int) async {
        guard busy.contains(artistId) else { busy.insert(artistId); return }
        await withCheckedContinuation { waiting[artistId, default: []].append($0) }
    }

    private func release(_ artistId: Int) {
        if var queue = waiting[artistId], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[artistId] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(artistId)
        }
    }

    // MARK: - Start, resume, undo

    /// The owner confirmed the switch for `artistId`, to bring in the single `target` (the song `recording`, asked for once
    /// done). A switch already under way for the artist is joined (never a second one, never Magpie's profile saved as the
    /// original).
    public func start(artistId: Int, target: MBID, recording: ExternalRecording? = nil) async throws -> Outcome {
        await acquire(artistId)
        defer { release(artistId) }
        try running()
        guard await gate.enabled else { throw SinglesSwitchError.changesOff }
        if let open = try? await store.job(artistId), open.isOpen { return await advance(open) }
        let artist: LidarrArtist, profiles: [JSONValue], albums: [LidarrAlbum]
        do {
            artist = try await lidarr.artist(id: artistId)
            profiles = try await lidarr.metadataProfilesJSON()
            albums = try await lidarr.albums(artistId: artistId)
        } catch { throw SinglesSwitchError.unavailable }
        guard let profileId = artist.metadataProfileId,
              let current = profiles.first(where: { $0["id"]?.intValue == profileId }) else { throw SinglesSwitchError.unavailable }
        if Provisioner.includesSingle(current) { return .alreadyListed }
        let job = SinglesSwitchJob(artistId: artistId, target: target, originalProfileId: profileId,
                                   originalFollow: artist.monitorNewItems ?? "none",
                                   beforeAlbumIds: albums.map(\.id), beforeReleaseGroups: albums.compactMap(\.foreignAlbumId),
                                   startedAt: now(), recording: recording)
        try running()
        do { try await store.save(job) } catch { throw SinglesSwitchError.notSaved }
        await gate.note(LidarrWriteGate.singlesNote(artistId: artistId, metadataProfileId: profileId,
                                                    monitorNewItems: job.originalFollow))
        return await advance(job, current: current)
    }

    /// Every unfinished switch, resumed (runner start, every poll). Returns what happened to each.
    public func resumeAll() async -> [Int: Outcome] {
        guard !stopped, let jobs = try? await store.jobs() else { return [:] }
        var out: [Int: Outcome] = [:]
        for job in jobs where job.isOpen {
            await acquire(job.artistId)
            if !stopped, let fresh = try? await store.job(job.artistId), fresh.isOpen { out[job.artistId] = await advance(fresh) }
            release(job.artistId)
        }
        return out
    }

    /// Re-review m5: the song a finished switch was for, once (cleared in the journal).
    public func takeRecording(_ artistId: Int) async -> ExternalRecording? {
        guard !stopped, var job = try? await store.job(artistId), job.step == .done, let recording = job.recording else { return nil }
        job.recording = nil
        guard (try? await store.save(job)) != nil else { return nil }
        return recording
    }

    /// Undo of a finished switch: the saved profile back, a confirmed refresh, then following. The journal is the source.
    /// Re-review m6: only while the artist is still on the Magpie profile; a profile the owner changed since is left.
    public func undo(artistId: Int) async throws {
        await acquire(artistId)
        defer { release(artistId) }
        try running()
        guard var job = try await store.job(artistId), job.step == .done || (job.step == .puttingBack && job.puttingBackTo == .undone) else {
            throw SinglesSwitchError.nothingToUndo
        }
        guard await gate.enabled else { throw SinglesSwitchError.changesOff }
        if job.step == .done {
            guard let current = try? await lidarr.artist(id: artistId).metadataProfileId else { throw SinglesSwitchError.unavailable }
            guard current == job.singlesProfileId else { throw SinglesSwitchError.changedByOwner }
            job.puttingBackTo = .undone
        }
        guard try await putBack(&job) else { throw SinglesSwitchError.unavailable }
    }

    /// Re-review m3: a journal that couldn't be read lost the switch; the change log's line still has what was saved. This
    /// puts the artist back from it (the profile, a confirmed refresh, then following), journaled like any roll-back.
    public func restoreFromNote(artistId: Int, profileId: Int, follow: String) async throws -> Bool {
        await acquire(artistId)
        defer { release(artistId) }
        try running()
        guard await gate.enabled else { throw SinglesSwitchError.changesOff }
        if let existing = try? await store.job(artistId), existing.isOpen { throw SinglesSwitchError.nothingToUndo }
        var job = SinglesSwitchJob(artistId: artistId, target: MBID("00000000-0000-0000-0000-000000000000")!, originalProfileId: profileId,
                                   originalFollow: follow, beforeAlbumIds: [], beforeReleaseGroups: [], startedAt: now())
        job.puttingBackTo = .rolledBack
        do { try await store.save(job) } catch { throw SinglesSwitchError.notSaved }
        return try await putBack(&job)
    }

    // MARK: - The steps

    private struct Pending: Error {}

    private func advance(_ start: SinglesSwitchJob, current: JSONValue? = nil) async -> Outcome {
        var job = start
        do {
            while true {
                try running()
                switch job.step {
                case .saved:
                    if job.originalFollow.lowercased() != "none" {
                        try await sending(&job, .followOff)
                        _ = try await gate.send("PUT", "artist/editor", body: FollowBody(artistIds: [job.artistId], monitorNewItems: "none"), confinedAs: .singlesSwitch)
                    }
                    try await saved(&job, .followOff)
                case .followOff:
                    if job.singlesProfileId == nil {
                        let base: JSONValue
                        if let current { base = current } else {
                            guard let found = try await lidarr.metadataProfilesJSON().first(where: { $0["id"]?.intValue == job.originalProfileId })
                            else { throw Pending() }
                            base = found
                        }
                        try running()
                        do {
                            job.singlesProfileId = try await Provisioner().ensureSinglesSuperset(of: base, gate: gate, client: lidarr)
                        } catch ProvisionError.conflict(let name) {
                            throw SinglesSwitchError.profileConflict(name)
                        }
                        try running()
                        try await store.save(job)
                    }
                    try await sending(&job, .profileSwitched)
                    _ = try await gate.send("PUT", "artist/editor", body: ProfileBody(artistIds: [job.artistId], metadataProfileId: job.singlesProfileId!), confinedAs: .singlesSwitch)
                    try await saved(&job, .profileSwitched)
                case .profileSwitched:
                    try await sending(&job, .refreshSent)
                    let data = try await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: job.artistId), confinedAs: .singlesSwitch)
                    guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else { throw Pending() }
                    job.refreshCommandId = id
                    try await saved(&job, .refreshSent)
                case .refreshSent:
                    guard let id = job.refreshCommandId else { job.step = .profileSwitched; continue }
                    switch await refreshState(id) {
                    case .completed: try await saved(&job, .refreshed)
                    case .failed:   // sent again on the next pass
                        job.refreshCommandId = nil
                        job.step = .profileSwitched
                        throw Pending()
                    case .unknown: throw Pending()
                    }
                case .refreshed:
                    let before = Set(job.beforeAlbumIds), groups = Set(job.beforeReleaseGroups)
                    let extras = try await lidarr.albums(artistId: job.artistId).filter { album in
                        album.monitored && !before.contains(album.id) && album.foreignAlbumId != job.target
                            && !(album.foreignAlbumId.map(groups.contains) ?? false)
                    }.map(\.id)
                    if !extras.isEmpty {
                        try await sending(&job, .extrasUnmonitored)
                        _ = try await gate.send("PUT", "album/monitor", body: UnmonitorBody(albumIds: extras, monitored: false), confinedAs: .singlesSwitch)
                    }
                    try await saved(&job, .extrasUnmonitored)
                case .extrasUnmonitored:
                    if job.originalFollow.lowercased() != "none" {
                        try await sending(&job, .done)
                        _ = try await gate.send("PUT", "artist/editor", body: FollowBody(artistIds: [job.artistId], monitorNewItems: job.originalFollow), confinedAs: .singlesSwitch)
                    }
                    try await saved(&job, .done)
                    return .finished
                case .puttingBack:
                    guard try await putBack(&job) else { throw Pending() }
                    return job.step == .undone ? .finished : .rolledBack
                case .done:
                    return .finished
                case .rolledBack, .undone:
                    return .rolledBack
                }
            }
        } catch SinglesSwitchError.stopped {
            return .pending   // retired: the new switcher carries on from the journal
        } catch {
            guard !stopped, !store.isClosed else { return .pending }
            job.failures += 1
            let conflict = error is SinglesSwitchError
            if conflict || job.failures >= Self.maxFailures {
                job.puttingBackTo = .rolledBack
                if (try? await putBack(&job)) == true { return .rolledBack }
            }
            try? await store.save(job)
            return .pending
        }
    }

    private func sending(_ job: inout SinglesSwitchJob, _ step: SinglesSwitchJob.Step) async throws {
        try running()
        job.sending = step
        try await store.save(job)
        try running()
    }

    private func saved(_ job: inout SinglesSwitchJob, _ step: SinglesSwitchJob.Step) async throws {
        try running()
        job.step = step
        job.sending = nil
        try await store.save(job)
    }

    private enum RefreshState { case completed, failed, unknown }

    /// The RefreshArtist command's end, read from Lidarr (at most `checks` reads, `pause` apart). Anything else: unknown.
    private func refreshState(_ id: Int) async -> RefreshState {
        for i in 0..<checks {
            if stopped { return .unknown }
            if let c = try? await lidarr.command(id: id) {
                switch c.status.lowercased() {
                case "completed": return .completed
                case "failed", "aborted", "cancelled", "orphaned": return .failed
                default: break
                }
            }
            if i < checks - 1 { try? await Task.sleep(for: pause) }
        }
        return .unknown
    }

    /// Re-review m4: the profile back first, then a refresh whose completion is confirmed, then following (so a refresh
    /// never lands while following "all" on the superset profile). Journaled as `puttingBack`; true once finished (the
    /// job then `rolledBack` or `undone`), false while the refresh isn't confirmed yet (resumed later).
    private func putBack(_ job: inout SinglesSwitchJob) async throws -> Bool {
        let end = job.puttingBackTo ?? .rolledBack
        if job.step != .puttingBack {
            try running()
            job.step = .puttingBack
            job.refreshCommandId = nil
            try await store.save(job)
            try running()
            _ = try await gate.send("PUT", "artist/editor", body: ProfileBody(artistIds: [job.artistId], metadataProfileId: job.originalProfileId), confinedAs: .singlesSwitch)
        }
        if job.refreshCommandId == nil {
            try running()
            let data = try await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: job.artistId), confinedAs: .singlesSwitch)
            job.refreshCommandId = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue
            try await store.save(job)
        }
        guard let id = job.refreshCommandId else { return false }
        switch await refreshState(id) {
        case .completed: break
        case .failed:
            job.refreshCommandId = nil
            try await store.save(job)
            return false
        case .unknown: return false
        }
        try running()
        _ = try await gate.send("PUT", "artist/editor", body: FollowBody(artistIds: [job.artistId], monitorNewItems: job.originalFollow), confinedAs: .singlesSwitch)
        job.step = end
        job.sending = nil
        try await store.save(job)
        return true
    }

    private struct FollowBody: Encodable, Sendable { var artistIds: [Int]; var monitorNewItems: String }
    private struct ProfileBody: Encodable, Sendable { var artistIds: [Int]; var metadataProfileId: Int }
    private struct RefreshBody: Encodable, Sendable { var name: String; var artistId: Int }
    private struct UnmonitorBody: Encodable, Sendable { var albumIds: [Int]; var monitored: Bool }
}
