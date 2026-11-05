import Foundation
import LidarrKit
import MagpieCore

/// Round 15 C3 (D146): "Include singles for this artist", confirmed by the owner, for any artist, as a persisted journal
/// (one switch per artist). Every write is `ConfinedShape.singlesSwitch`; the gate allows them only for an artist whose
/// switch is in this journal, and only these values (`WriteConfinement.singlesEditor`).
///
/// The steps, each saved before its write (every write is idempotent, so a resumed step is safe to send again):
/// 1. `saved`: the original metadata profile id and `monitorNewItems`, and the album list before (ids and release
///    groups). Nothing is sent unless this save succeeds. A current profile that already lists singles: no switch.
/// 2. `followOff`: `monitorNewItems` none (if it wasn't).
/// 3. `profileSwitched`: "<the artist's profile> + Singles (Magpie)", a superset of the artist's own (its primary types
///    plus Single, the same secondary types and release statuses), reused or made; never narrower, never an existing
///    profile modified (C1).
/// 4. `refreshSent`: RefreshArtist; its command id is required.
/// 5. `refreshed`: only once Lidarr says that command completed (a missing id, a timeout or failed reads leave the
///    switch pending, with following still off; it is resumed later).
/// 6. `extrasUnmonitored`: every release that appeared in the refresh (not there before by id or release group), is
///    monitored and isn't the target, unmonitored (the gate refuses any release with files).
/// 7. `done`: `monitorNewItems` back to its saved value.
/// An unfinished switch is resumed on runner start and on every poll; one that keeps failing is rolled back (following,
/// then the profile, then a refresh). Undo of a finished switch restores the profile and following, then refreshes.
public struct SinglesSwitchJob: Codable, Sendable, Equatable, Identifiable {
    public enum Step: String, Codable, Sendable {
        case saved, followOff, profileSwitched, refreshSent, refreshed, extrasUnmonitored, done, rolledBack, undone
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

    public var id: Int { artistId }
    public var isOpen: Bool { step != .done && step != .rolledBack && step != .undone }

    public init(artistId: Int, target: MBID, originalProfileId: Int, originalFollow: String, beforeAlbumIds: [Int],
                beforeReleaseGroups: [MBID], startedAt: Date) {
        self.artistId = artistId; self.target = target; self.originalProfileId = originalProfileId
        self.originalFollow = originalFollow; self.beforeAlbumIds = beforeAlbumIds; self.beforeReleaseGroups = beforeReleaseGroups
        self.step = .saved; self.startedAt = startedAt; self.failures = 0
    }
}

/// `Application Support/Magpie/singles-switch-<instance>.json`, one per Lidarr (atomic, excluded from backup, erased with
/// the requests on sign-out). One job per artist. The gate reads it (`original(artistId:)`).
public actor SinglesSwitchStore {
    public static func defaultURL(in directory: URL = URL.applicationSupportDirectory, instance: String) -> URL {
        directory.appending(path: "Magpie/singles-switch-\(instance).json")
    }

    nonisolated let fileURL: URL?
    private var memory: [SinglesSwitchJob] = []
    private var loaded = false

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public func jobs() throws -> [SinglesSwitchJob] {
        if !loaded, let fileURL {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data: Data
                do { data = try Data(contentsOf: fileURL) } catch { throw RequestStoreError.unavailable }
                memory = (try? JSONDecoder().decode([SinglesSwitchJob].self, from: data)) ?? []
            }
            loaded = true
        }
        return memory
    }

    public func job(_ artistId: Int) throws -> SinglesSwitchJob? { try jobs().first { $0.artistId == artistId } }

    /// Saves `job` (replacing the artist's). Throws when it can't be saved: the caller sends nothing then.
    public func save(_ job: SinglesSwitchJob) throws {
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

    /// What the gate may restore for the artist: nil without a job, or after its undo.
    public func original(artistId: Int) -> WriteConfinement.SinglesOriginal? {
        guard let job = try? job(artistId), job.step != .undone else { return nil }
        return .init(profileId: job.originalProfileId, follow: job.originalFollow, open: job.isOpen)
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
}

public actor SinglesSwitcher {
    public enum Outcome: Equatable, Sendable {
        /// The artist's profile already lists singles: nothing was switched.
        case alreadyListed
        case finished
        /// Not finished yet (the refresh not confirmed, Lidarr unreachable…): following stays off, resumed later.
        case pending
        /// It couldn't be finished, so it was put back (following and the profile, then a refresh).
        case rolledBack
    }

    let lidarr: LidarrClient
    let gate: LidarrWriteGate
    public let store: SinglesSwitchStore
    let checks: Int
    let pause: Duration
    let now: @Sendable () -> Date
    /// Failures of one switch before it is rolled back.
    public static let maxFailures = 5

    private var busy: Set<Int> = []
    private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, store: SinglesSwitchStore, checks: Int = 30,
                pause: Duration = .seconds(2), now: @escaping @Sendable () -> Date = Date.init) {
        self.lidarr = lidarr; self.gate = gate; self.store = store; self.checks = checks; self.pause = pause; self.now = now
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

    /// The owner confirmed the switch for `artistId`, to bring in the single `target`. A switch already under way for the
    /// artist is joined (never a second one, never Magpie's profile saved as the original).
    public func start(artistId: Int, target: MBID) async throws -> Outcome {
        await acquire(artistId)
        defer { release(artistId) }
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
                                   startedAt: now())
        do { try await store.save(job) } catch { throw SinglesSwitchError.notSaved }
        await gate.note(LidarrWriteGate.singlesNote(artistId: artistId, metadataProfileId: profileId,
                                                    monitorNewItems: job.originalFollow))
        return await advance(job, current: current)
    }

    /// Every unfinished switch, resumed (runner start, every poll). Returns what happened to each.
    public func resumeAll() async -> [Int: Outcome] {
        guard let jobs = try? await store.jobs() else { return [:] }
        var out: [Int: Outcome] = [:]
        for job in jobs where job.isOpen {
            await acquire(job.artistId)
            if let fresh = try? await store.job(job.artistId), fresh.isOpen { out[job.artistId] = await advance(fresh) }
            release(job.artistId)
        }
        return out
    }

    /// Undo of a finished switch: the saved profile and following back, then a refresh. The journal is the source.
    public func undo(artistId: Int) async throws {
        await acquire(artistId)
        defer { release(artistId) }
        guard var job = try await store.job(artistId), job.step == .done else { throw SinglesSwitchError.nothingToUndo }
        guard await gate.enabled else { throw SinglesSwitchError.changesOff }
        try await putBack(job)
        job.step = .undone
        try await store.save(job)
    }

    // MARK: - The steps

    private struct Pending: Error {}

    private func advance(_ start: SinglesSwitchJob, current: JSONValue? = nil) async -> Outcome {
        var job = start
        do {
            while true {
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
                        do {
                            job.singlesProfileId = try await Provisioner().ensureSinglesSuperset(of: base, gate: gate, client: lidarr)
                        } catch ProvisionError.conflict(let name) {
                            throw SinglesSwitchError.profileConflict(name)
                        }
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
                case .done:
                    return .finished
                case .rolledBack, .undone:
                    return .rolledBack
                }
            }
        } catch {
            job.failures += 1
            let conflict = error is SinglesSwitchError
            if conflict || job.failures >= Self.maxFailures, (try? await rollBack(&job)) != nil { return .rolledBack }
            try? await store.save(job)
            return .pending
        }
    }

    private func sending(_ job: inout SinglesSwitchJob, _ step: SinglesSwitchJob.Step) async throws {
        job.sending = step
        try await store.save(job)
    }

    private func saved(_ job: inout SinglesSwitchJob, _ step: SinglesSwitchJob.Step) async throws {
        job.step = step
        job.sending = nil
        try await store.save(job)
    }

    private enum RefreshState { case completed, failed, unknown }

    /// The RefreshArtist command's end, read from Lidarr (at most `checks` reads, `pause` apart). Anything else: unknown.
    private func refreshState(_ id: Int) async -> RefreshState {
        for i in 0..<checks {
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

    /// Following, the profile, then a refresh, as saved. Marks the job rolled back.
    private func rollBack(_ job: inout SinglesSwitchJob) async throws {
        try await putBack(job)
        job.step = .rolledBack
        try await store.save(job)
    }

    private func putBack(_ job: SinglesSwitchJob) async throws {
        _ = try await gate.send("PUT", "artist/editor", body: FollowBody(artistIds: [job.artistId], monitorNewItems: job.originalFollow), confinedAs: .singlesSwitch)
        _ = try await gate.send("PUT", "artist/editor", body: ProfileBody(artistIds: [job.artistId], metadataProfileId: job.originalProfileId), confinedAs: .singlesSwitch)
        _ = try await gate.send("POST", "command", body: RefreshBody(name: "RefreshArtist", artistId: job.artistId), confinedAs: .singlesSwitch)
    }

    private struct FollowBody: Encodable, Sendable { var artistIds: [Int]; var monitorNewItems: String }
    private struct ProfileBody: Encodable, Sendable { var artistIds: [Int]; var metadataProfileId: Int }
    private struct RefreshBody: Encodable, Sendable { var name: String; var artistId: Int }
    private struct UnmonitorBody: Encodable, Sendable { var albumIds: [Int]; var monitored: Bool }
}
