import Foundation
import MagpieCore
import os

/// Y5: what the runner keeps on disk besides the requests (`runner-state-<instance>.json`, next to them).
///
/// - **Leases** (item 9.10, I1): the requests with a step running and the artists a Keep, Not for me, Bring in more
///   or MP3 removal is working on. Taken in one locked check-and-insert, dropped when done; the holder renews
///   `renewedAt` every pass and inside every long wait (fix I5). Another runner (a background pass, a relaunch with the
///   old one still finishing a write) treats a fresh lease as busy; a lease not renewed for `RunnerState.staleAfter` is
///   orphaned and dropped (its follow-up path then picks the work up; nothing is ever started fresh from a lease).
/// - **Clock** (item 9.7, M4): Lidarr's clock offset and the history cursor in Lidarr's time.
/// - **Migrations** (§9): one flag per migration, set only once every step finished (fix I6).
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

    /// Y5 fix I5: every read-modify-write of a state file goes under this process-wide lock (as the ledger's), so two
    /// runners never lose each other's leases, cursor or flags, and taking a lease is one check-and-insert.
    static let fileLock = OSAllocatedUnfairLock()

    /// Reads, changes and saves the file in one locked step; returns the saved state and what `change` returned.
    static func modify<T>(_ url: URL?, _ change: (inout RunnerState) -> T) -> (RunnerState, T) {
        withoutActuallyEscaping(change) { change in
            fileLock.withLockUnchecked {
                var state = load(url)
                let out = change(&state)
                save(state, to: url)
                return (state, out)
            }
        }
    }

    static func isFresh(_ lease: Lease, at t: Date) -> Bool {
        (0..<staleAfter).contains(t.timeIntervalSince(lease.renewedAt))
    }
}

extension RequestRunner {
    static func artistKey(_ id: Int) -> String { "artist:\(id)" }
    static func requestKey(_ id: RequestID) -> String { "request:\(id.description)" }

    /// Leases now, from this runner's in-memory sets, keeping other runners' leases that are on disk.
    func saveLeases() {
        guard !stopped else { return }
        let t = now()
        let mine = Set(keepingArtists.map(Self.artistKey) + busy.map(Self.requestKey))
        let me = process
        persistedState = RunnerState.modify(stateURL) { state in
            state.leases.removeAll { $0.process == me && !mine.contains($0.key) }
            for key in mine where !state.leases.contains(where: { $0.key == key && $0.process == me }) {
                state.leases.append(.init(key: key, process: me, startedAt: t, renewedAt: t))
            }
        }.0
    }

    /// Fix I5: takes the artist in one locked check-and-insert. False when another runner's fresh lease holds it, or
    /// this runner already works on it.
    func tryAcquireArtist(_ id: Int) -> Bool {
        guard !stopped, !keepingArtists.contains(id) else { return false }
        let t = now(), key = Self.artistKey(id), me = process
        let (state, taken) = RunnerState.modify(stateURL) { state -> Bool in
            if state.leases.contains(where: { $0.key == key && $0.process != me && RunnerState.isFresh($0, at: t) }) {
                return false
            }
            state.leases.removeAll { $0.key == key }
            state.leases.append(.init(key: key, process: me, startedAt: t, renewedAt: t))
            return true
        }
        persistedState = state
        if taken { keepingArtists.insert(id) }
        return taken
    }

    /// A retired runner (`stop`) drops all of its leases at once.
    func releaseLeases() {
        let me = process
        _ = RunnerState.modify(stateURL) { $0.leases.removeAll { $0.process == me } }
    }

    /// I1/I5: renews this runner's leases and drops other runners' stale ones (logged). Called at the start of every
    /// pass and inside every long wait (a heartbeat).
    func renewLeases() {
        guard !stopped else { return }
        let t = now(), me = process
        let (state, dropped) = RunnerState.modify(stateURL) { state -> Int in
            let before = state.leases.count
            state.leases.removeAll { $0.process != me && !RunnerState.isFresh($0, at: t) }
            for i in state.leases.indices where state.leases[i].process == me { state.leases[i].renewedAt = t }
            return before - state.leases.count
        }
        persistedState = state
        if dropped > 0 { Log.logger("requests").error("dropped \(dropped) stale lease(s) of an earlier runner") }
    }

    /// A fresh lease of another runner on `key` (read from disk now).
    func foreignLease(_ key: String) -> Bool {
        let t = now()
        return RunnerState.load(stateURL).leases.contains { $0.key == key && $0.process != process && RunnerState.isFresh($0, at: t) }
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
        persistedState = RunnerState.modify(stateURL) { state in
            if let old = state.clockOffset, abs(old - offset) > 60 { state.historyCursor = nil }
            state.clockOffset = offset
        }.0
    }

    func saveHistoryCursor(_ cursor: Date?) {
        persistedState = RunnerState.modify(stateURL) { $0.historyCursor = cursor }.0
    }

    func markMigrated(_ name: String) {
        let t = now()
        persistedState = RunnerState.modify(stateURL) { $0.migrated[name] = t }.0
    }
}
