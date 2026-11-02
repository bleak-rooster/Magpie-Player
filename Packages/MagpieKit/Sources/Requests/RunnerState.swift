import Foundation
import MagpieCore

/// Y5: what the runner keeps on disk besides the requests (`runner-state-<instance>.json`, next to them).
///
/// - **Leases** (item 9.10, I1): the requests with a step running and the artists a Keep, Not for me, Bring in more
///   or MP3 removal is working on. Saved when taken and dropped when done; the holder renews `renewedAt` every pass.
///   Another runner (a background pass, a relaunch with the old one still finishing a write) treats a fresh lease as
///   busy; a lease not renewed for `RunnerState.staleAfter` is orphaned and dropped (its follow-up path then picks
///   the work up; nothing is ever started fresh from a lease).
/// - **Clock** (item 9.7, M4): Lidarr's clock offset and the history cursor in Lidarr's time.
/// - **Migrations** (§9): one flag per migration, set after its last step, so a crash re-runs it.
public struct RunnerState: Codable, Sendable, Equatable {
    public struct Lease: Codable, Sendable, Equatable {
        /// `artist:<id>` or `request:<uuid>`.
        public var key: String
        public var process: String
        public var startedAt: Date
        public var renewedAt: Date
    }

    public var leases: [Lease] = []
    /// Lidarr's clock minus the phone's, from the latest fresh `Date` header.
    public var clockOffset: TimeInterval?
    /// `history/since` cursor, in Lidarr's time.
    public var historyCursor: Date?
    public var migrated: [String: Date] = [:]

    public init() {}

    /// A lease not renewed for this long belongs to a runner that's gone (two passes in the background).
    public static let staleAfter: TimeInterval = 120
    /// Offsets larger than a day are a broken header, not a clock (M4).
    public static let maxOffset: TimeInterval = 24 * 3600

    /// `requests-<instance>.json` → `runner-state-<instance>.json`; any other name gets the prefix (never the same file).
    public static func url(forRequests requests: URL) -> URL {
        let name = requests.lastPathComponent
        let state = name.hasPrefix("requests-") ? "runner-state-" + name.dropFirst("requests-".count) : "runner-state-" + name
        return requests.deletingLastPathComponent().appending(path: String(state))
    }

    /// Nil file: in memory only. A damaged or missing file reads as empty (leases fail open to "not busy" only after
    /// they'd be stale anyway; a crash loses at most one pass of renewal).
    static func load(_ url: URL?) -> RunnerState {
        guard let url, let state = try? AtomicFile.read(RunnerState.self, from: url) else { return RunnerState() }
        return state
    }

    static func save(_ state: RunnerState, to url: URL?) {
        guard let url else { return }
        do { try AtomicFile.write(state, to: url) } catch {
            Log.logger("requests").error("runner state not saved")
        }
    }
}

extension RequestRunner {
    static func artistKey(_ id: Int) -> String { "artist:\(id)" }
    static func requestKey(_ id: RequestID) -> String { "request:\(id.description)" }

    /// Leases now, from this runner's in-memory sets, keeping other runners' fresh leases that are on disk.
    func saveLeases() {
        guard !stopped else { return }
        let t = now()
        var state = RunnerState.load(stateURL)
        let mine = Set(keepingArtists.map(Self.artistKey) + busy.map(Self.requestKey))
        state.leases.removeAll { $0.process == process && !mine.contains($0.key) }
        for key in mine where !state.leases.contains(where: { $0.key == key && $0.process == process }) {
            state.leases.append(.init(key: key, process: process, startedAt: t, renewedAt: t))
        }
        persistedState = state
        RunnerState.save(state, to: stateURL)
    }

    /// A retired runner (`stop`) drops all of its leases at once.
    func releaseLeases() {
        var state = RunnerState.load(stateURL)
        let before = state.leases.count
        state.leases.removeAll { $0.process == process }
        guard state.leases.count != before else { return }
        RunnerState.save(state, to: stateURL)
    }

    /// I1: renews this runner's leases and drops other runners' stale ones (logged). Called at the start of a pass.
    func renewLeases() {
        let t = now()
        var state = RunnerState.load(stateURL)
        let stale = state.leases.filter {
            $0.process != process && !(0..<RunnerState.staleAfter).contains(t.timeIntervalSince($0.renewedAt))
        }
        if !stale.isEmpty { Log.logger("requests").error("dropped \(stale.count) stale lease(s) of an earlier runner") }
        state.leases.removeAll { l in stale.contains(l) }
        for i in state.leases.indices where state.leases[i].process == process { state.leases[i].renewedAt = t }
        persistedState = state
        RunnerState.save(state, to: stateURL)
    }

    /// A fresh lease of another runner on `key` (read from disk now).
    func foreignLease(_ key: String) -> Bool {
        let t = now()
        return RunnerState.load(stateURL).leases.contains {
            $0.key == key && $0.process != process && (0..<RunnerState.staleAfter).contains(t.timeIntervalSince($0.renewedAt))
        }
    }

    /// Something is working on this artist: in this runner, or (a fresh lease) in another.
    func artistBusy(_ id: Int) -> Bool { keepingArtists.contains(id) || foreignLease(Self.artistKey(id)) }

    /// A step is running for this request, here or (a fresh lease) in another runner.
    func requestBusy(_ id: RequestID) -> Bool { busy.contains(id) || foreignLease(Self.requestKey(id)) }

    // MARK: - Lidarr's clock (item 9.7, M4)

    /// Lidarr's time now: the phone's clock plus the latest offset (0 until one is known).
    func serverNow() -> Date { now().addingTimeInterval(persistedState.clockOffset ?? 0) }

    /// Reads Lidarr's clock (`GET /system/status` `Date`, at most once a minute). Ignores a missing, cached or wild
    /// value (M4). A change of more than a minute restarts the history cursor (with its minute of overlap).
    func updateServerClock() async {
        if let last = lastClockRead, (0..<60).contains(now().timeIntervalSince(last)) { return }
        lastClockRead = now()
        guard let date = try? await lidarr.serverDate() else { return }
        let offset = date.timeIntervalSince(now())
        guard abs(offset) <= RunnerState.maxOffset else { return }
        var state = RunnerState.load(stateURL)
        if let old = state.clockOffset, abs(old - offset) > 60 { state.historyCursor = nil }
        guard state.clockOffset.map({ abs($0 - offset) >= 1 }) ?? true || state.historyCursor == nil else {
            persistedState = state
            return
        }
        state.clockOffset = offset
        persistedState = state
        RunnerState.save(state, to: stateURL)
    }

    func saveHistoryCursor(_ cursor: Date?) {
        var state = RunnerState.load(stateURL)
        state.historyCursor = cursor
        persistedState = state
        RunnerState.save(state, to: stateURL)
    }

    func markMigrated(_ name: String) {
        var state = RunnerState.load(stateURL)
        state.migrated[name] = now()
        persistedState = state
        RunnerState.save(state, to: stateURL)
    }
}
