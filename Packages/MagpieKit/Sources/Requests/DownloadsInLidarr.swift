import Foundation
import LidarrKit
import MagpieCore

// Round 12 item 6 (D49): Settings › Downloads in Lidarr. Every download in Lidarr's queue, whoever asked for it, sorted
// into Active, Stalled and Failed, with Restart on the stalled and failed ones. The owner decided this screen may
// restart ANY download (it supersedes R17's "never touches downloads of anything else" for this screen only).
//
// Fix round 1: Stalled is only a copy that's actually downloading and not moving: Lidarr says it's stalled (a warning
// while downloading), or `sizeleft` hasn't changed past the limit. A copy that's queued, paused, held back by Lidarr
// (delay) or whose client can't be reached is never Stalled nor restartable (the gate refuses it too). Failed is a
// failed download or a blocked import. Each restart re-checks the row on a fresh read by the same rule.

/// How a queue row looked when it last changed: what R17's stall rule compares (`StallWatch.Signature` is this).
public struct QueueSignature: Sendable, Equatable {
    var sizeleft: Double
    var status: String
    var tracked: String
    var client: String?

    public init(_ item: QueueItem) {
        sizeleft = item.sizeleft; status = item.status.lowercased()
        tracked = item.trackedDownloadState.lowercased(); client = item.downloadClient?.lowercased()
    }
}

/// R17's stall rule without a request: each queue row that's downloading, and since when it hasn't changed. The clock
/// starts when the row is first seen (R20) and starts over on any change; a row that leaves is forgotten. Also the
/// download speed of every row, from `sizeleft` between two reads. Held by the app (not the screen), so it survives
/// leaving the page.
public struct QueueStallWatch: Sendable, Equatable {
    private struct Seen: Sendable, Equatable {
        var signature: QueueSignature
        var since: Date
    }

    private struct Read: Sendable, Equatable {
        var sizeleft: Double
        var at: Date
        var speed: Double?
    }

    private var seen: [Int: Seen] = [:]
    private var reads: [Int: Read] = [:]

    public init() {}

    /// One read of the queue. `soulseekClients`: lower-cased names (a Soulseek copy reads "warning" while downloading).
    public mutating func observe(_ items: [QueueItem], soulseekClients: Set<String>, at now: Date) {
        var next: [Int: Seen] = [:]
        var nextReads: [Int: Read] = [:]
        for item in items {
            guard let id = item.id else { continue }
            var speed: Double?
            if let last = reads[id], now > last.at {
                let moved = last.sizeleft - item.sizeleft
                speed = moved >= 0 ? moved / now.timeIntervalSince(last.at) : nil
            }
            nextReads[id] = Read(sizeleft: item.sizeleft, at: now, speed: speed)
            guard LidarrDownloads.isDownloading(item, soulseek: LidarrDownloads.isSoulseek(item, soulseekClients)) else {
                continue
            }
            let signature = QueueSignature(item)
            if let old = seen[id], old.signature == signature { next[id] = old } else { next[id] = Seen(signature: signature, since: now) }
        }
        seen = next
        reads = nextReads
    }

    /// How long row `id` has been downloading without a change, or nil when it isn't followed.
    public func unchangedFor(_ id: Int, at now: Date) -> TimeInterval? {
        seen[id].map { max(0, now.timeIntervalSince($0.since)) }
    }

    /// Bytes a second between the last two reads, or nil before a second read (or when it went backwards).
    public func speed(_ id: Int) -> Double? { reads[id]?.speed }
}

/// Fix round 3 N2: whether Lidarr itself grabbed each download (`LidarrClient.grabbed`, read only), for the rows that
/// could be restarted. On the owner's Lidarr most finished copies it couldn't import were never grabbed by it (another
/// tool's transfers), so the board shows them as another app's from the start. A grab is kept; "no grab" is asked again
/// after `recheckNoGrab`; at most `perRefresh` lookups per refresh, `concurrency` at a time. Held by the app per Lidarr.
/// The restarter and the gate still check the history themselves before anything is sent.
public struct GrabCache: Sendable, Equatable {
    public static let perRefresh = 10
    public static let concurrency = 4
    public static let recheckNoGrab: TimeInterval = 60

    private var grabbed: Set<String> = []
    private var noGrab: [String: Date] = [:]

    public init() {}

    /// True: Lidarr grabbed it; false: no grab in its history; nil: not looked up yet.
    public func status(_ downloadId: String) -> Bool? {
        if grabbed.contains(downloadId) { return true }
        return noGrab[downloadId] != nil ? false : nil
    }

    public mutating func record(_ downloadId: String, grabbed isGrabbed: Bool, at now: Date) {
        if isGrabbed {
            grabbed.insert(downloadId)
            noGrab[downloadId] = nil
        } else {
            noGrab[downloadId] = now
        }
    }

    /// Looks up the downloads of rows that are stalled, failed or couldn't import (as `watch` and `stallLimit` say) and
    /// aren't known yet, or had no grab more than `recheckNoGrab` ago; at most `perRefresh`. Returns how many it asked
    /// about. A lookup that fails stays unknown (not restartable).
    @discardableResult
    public mutating func lookUp(_ items: [QueueItem], soulseekClients: Set<String>, lidarr: LidarrClient, now: Date,
                                watch: QueueStallWatch = QueueStallWatch(),
                                stallLimit: TimeInterval = .infinity) async -> Int {
        var wanted: [String] = []
        for item in items {
            guard let id = item.id, let downloadId = item.downloadId, !item.saysNotGrabbedByLidarr,
                  !wanted.contains(downloadId) else { continue }
            let soulseek = LidarrDownloads.isSoulseek(item, soulseekClients)
            let (section, _, _) = LidarrDownloads.classify(item, soulseek: soulseek, unchanged: watch.unchangedFor(id, at: now),
                                                           limit: stallLimit)
            guard [.stalled, .failed, .couldntImport].contains(section) else { continue }
            switch status(downloadId) {
            case true?: continue
            case false?: if let last = noGrab[downloadId], now.timeIntervalSince(last) < Self.recheckNoGrab { continue }
            case nil: break
            }
            wanted.append(downloadId)
            if wanted.count == Self.perRefresh { break }
        }
        var answers: [(String, Bool)] = []
        for batch in stride(from: 0, to: wanted.count, by: Self.concurrency) {
            let ids = Array(wanted[batch..<min(batch + Self.concurrency, wanted.count)])
            await withTaskGroup(of: (String, Bool?).self) { group in
                for id in ids { group.addTask { (id, try? await lidarr.grabbed(downloadId: id)) } }
                for await (id, answer) in group { if let answer { answers.append((id, answer)) } }
            }
        }
        for (id, answer) in answers { record(id, grabbed: answer, at: now) }
        return wanted.count
    }
}

/// The queue as the screen shows it.
public struct LidarrDownloads: Sendable, Equatable {
    /// Fix round 2: `couldntImport`, a finished copy Lidarr couldn't import (restarted only one at a time, after its own
    /// confirmation, never by Restart all); `notStarted`, a transfer Lidarr lists but never grabbed (another tool's;
    /// read-only).
    public enum Section: Sendable, Equatable { case active, stalled, failed, couldntImport, notStarted }

    /// What a row is doing, for its status line (text plus a symbol in the app, D3).
    public enum Phase: Sendable, Equatable {
        case downloading, queued, paused, clientUnavailable, waitingToImport, importing, stalled, failed, couldntImport,
             notStarted
    }

    /// Why a row is Stalled.
    public enum StallReason: Sendable, Equatable {
        /// Lidarr says so: a warning while downloading (e.g. a torrent with no connections). Shown at once.
        case lidarr
        /// Downloading, and `sizeleft` hasn't changed for the limit.
        case noProgress
    }

    /// Other clients than Soulseek are stalled by the timer only after at least this long (the owner's "Give up on a
    /// stuck copy after" setting was made for Soulseek copies; R17).
    public static let nonSoulseekMinimum: TimeInterval = 600

    public struct Row: Sendable, Equatable, Identifiable {
        /// Lidarr's queue item id.
        public var id: Int
        public var item: QueueItem
        public var section: Section
        public var phase: Phase
        public var stall: StallReason?
        /// Its client is a Soulseek one.
        public var soulseek: Bool
        /// Stalled or failed, Lidarr names its download, and nothing of that download is importing or done (the
        /// gate checks the same again from its own read).
        public var canRestart: Bool
        public var artist: String
        public var album: String
        public var client: String?
        public var progress: Double?
        /// Bytes a second, from the last two reads.
        public var speed: Double?
        /// Lidarr's own words for a stalled or failed copy.
        public var message: String?

        public init(id: Int, item: QueueItem, section: Section, phase: Phase, stall: StallReason? = nil,
                    soulseek: Bool = false, canRestart: Bool, artist: String, album: String, client: String?,
                    progress: Double?, speed: Double? = nil, message: String?) {
            self.id = id; self.item = item; self.section = section; self.phase = phase; self.stall = stall
            self.soulseek = soulseek; self.canRestart = canRestart; self.artist = artist; self.album = album
            self.client = client; self.progress = progress; self.speed = speed; self.message = message
        }
    }

    public var active: [Row] = []
    public var stalled: [Row] = []
    public var failed: [Row] = []
    public var couldntImport: [Row] = []
    public var notStarted: [Row] = []

    /// Rows that need the owner (N2): stalled, failed or couldn't import, grabbed by Lidarr and restartable now.
    public var attention: Int { (stalled + failed + couldntImport).filter(\.canRestart).count }

    public init() {}

    /// `soulseekClients`: the Soulseek download clients' names, lower-cased (`DownloadClientInfo.isSoulseek`). `watch`
    /// has seen this read already (`observe`). `grabs` (N2): a row with no grab in Lidarr's history is another app's
    /// (read-only); one not looked up yet keeps its section but can't be restarted.
    public init(_ items: [QueueItem], soulseekClients: Set<String>, watch: QueueStallWatch, grabs: GrabCache = GrabCache(),
                stallLimit: TimeInterval, now: Date) {
        let done = Set(items.filter(\.isImportingOrDone).compactMap(\.downloadId))
        for item in items {
            guard let id = item.id else { continue }   // can't be named to Lidarr, so not shown
            let soulseek = Self.isSoulseek(item, soulseekClients)
            var (section, phase, stall) = Self.classify(item, soulseek: soulseek,
                                                        unchanged: watch.unchangedFor(id, at: now), limit: stallLimit)
            let grabbed = item.downloadId.flatMap(grabs.status)
            if [.stalled, .failed, .couldntImport].contains(section), grabbed == false {
                (section, phase, stall) = (.notStarted, .notStarted, nil)
            }
            let canRestart = ![.active, .notStarted].contains(section) && grabbed == true
                && item.downloadId.map { !done.contains($0) } == true
            let message = (item.statusMessages.first ?? item.errorMessage).flatMap { $0.isEmpty ? nil : $0 }
            let row = Row(id: id, item: item, section: section, phase: phase, stall: stall, soulseek: soulseek,
                          canRestart: canRestart, artist: item.artistName ?? "", album: item.albumTitle ?? item.title ?? "",
                          client: item.downloadClient, progress: item.progress,
                          speed: phase == .downloading ? watch.speed(id) : nil,
                          message: section == .active && stall == nil ? nil : message)
            switch section {
            case .active: active.append(row)
            case .stalled: stalled.append(row)
            case .failed: failed.append(row)
            case .couldntImport: couldntImport.append(row)
            case .notStarted: notStarted.append(row)
            }
        }
    }

    static func isSoulseek(_ item: QueueItem, _ names: Set<String>) -> Bool {
        item.downloadClient.map { names.contains($0.lowercased()) } ?? false
    }

    /// Waiting its turn, paused (often on purpose), held back by Lidarr, or the client can't be reached: not stuck.
    static let waitingStatuses: Set<String> = ["queued", "paused", "delay", "downloadclientunavailable", "fallback"]

    /// Failed: a failed download (fix round 2: a finished copy that couldn't be imported is `couldntImport`).
    static func isFailed(_ item: QueueItem) -> Bool {
        let tracked = item.trackedDownloadState.lowercased()
        if ["downloadfailed", "downloadfailedpending", "failedpending"].contains(tracked) { return true }
        return item.status.lowercased() == "failed"
    }

    /// Fix round 2: a finished copy Lidarr couldn't import (blocked, e.g. "Artist name mismatch", or failed, e.g. "Has
    /// missing tracks").
    static func couldntImport(_ item: QueueItem) -> Bool {
        ["importblocked", "importfailed"].contains(item.trackedDownloadState.lowercased())
    }

    /// Failed, couldn't import, or not Lidarr's: never "downloading" nor "stalled".
    static func isBroken(_ item: QueueItem) -> Bool {
        isFailed(item) || couldntImport(item) || item.saysNotGrabbedByLidarr
    }

    /// Actually downloading before import: Lidarr tracks it as downloading and the client says downloading (or, for a
    /// Soulseek copy, "warning", which it shows all along; R17).
    static func isDownloading(_ item: QueueItem, soulseek: Bool) -> Bool {
        guard item.isDownloadingBeforeImport, !isBroken(item) else { return false }
        let status = item.status.lowercased()
        return status == "downloading" || (soulseek && status == "warning")
    }

    /// Lidarr itself says the copy is stuck: a warning (or "stalled") while downloading. Not for Soulseek, whose
    /// warning is always on; the timer looks after those.
    static func lidarrSaysStalled(_ item: QueueItem, soulseek: Bool) -> Bool {
        guard !soulseek, item.isDownloadingBeforeImport, !isBroken(item) else { return false }
        let status = item.status.lowercased(), trackedStatus = item.trackedDownloadStatus.lowercased()
        if waitingStatuses.contains(status) { return false }
        return ["warning", "stalled"].contains(status) || ["warning", "stalled"].contains(trackedStatus)
    }

    static func limit(_ stallLimit: TimeInterval, soulseek: Bool) -> TimeInterval {
        soulseek ? stallLimit : max(stallLimit, nonSoulseekMinimum)
    }

    static func classify(_ item: QueueItem, soulseek: Bool, unchanged: TimeInterval?, limit stallLimit: TimeInterval)
        -> (Section, Phase, StallReason?) {
        let status = item.status.lowercased(), tracked = item.trackedDownloadState.lowercased()
        // Fix round 2 N1: another tool's transfer Lidarr only lists. Read-only, whatever else it says.
        if item.saysNotGrabbedByLidarr { return (.notStarted, .notStarted, nil) }
        // Waiting to import with a warning: shown with the ones that couldn't import, but Lidarr may still import it,
        // so it isn't restartable (its download is importing or done).
        if tracked == "importpending", item.trackedDownloadStatus.lowercased() == "warning" {
            return (.couldntImport, .couldntImport, nil)
        }
        if item.isImportingOrDone {
            return (.active, tracked == "importing" ? .importing : .waitingToImport, nil)
        }
        if couldntImport(item) { return (.couldntImport, .couldntImport, nil) }
        if isFailed(item) { return (.failed, .failed, nil) }
        if waitingStatuses.contains(status) {
            switch status {
            case "paused": return (.active, .paused, nil)
            case "downloadclientunavailable": return (.active, .clientUnavailable, nil)
            default: return (.active, .queued, nil)
            }
        }
        if lidarrSaysStalled(item, soulseek: soulseek) { return (.stalled, .stalled, .lidarr) }
        if isDownloading(item, soulseek: soulseek), let unchanged, unchanged >= limit(stallLimit, soulseek: soulseek) {
            return (.stalled, .stalled, .noProgress)
        }
        return (.active, .downloading, nil)
    }

    /// I1: `fresh` (just read) is still what `row` was when the board was made: still failed; still stalled by Lidarr's
    /// word; or still downloading with nothing changed since (same signature). Anything that moved or stopped
    /// downloading is left alone.
    public static func stillRestartable(_ fresh: QueueItem, as row: Row) -> Bool {
        guard !fresh.isImportingOrDone, !fresh.saysNotGrabbedByLidarr else { return false }
        switch (row.section, row.stall) {
        case (.failed, _): return isFailed(fresh)
        case (.couldntImport, _): return couldntImport(fresh)
        case (.stalled, .lidarr?): return lidarrSaysStalled(fresh, soulseek: row.soulseek)
        case (.stalled, .noProgress?):
            return isDownloading(fresh, soulseek: row.soulseek) && QueueSignature(fresh) == QueueSignature(row.item)
        default: return false
        }
    }

    /// Restart all: the stalled and failed rows that may be restarted, stalled first.
    public var restartable: [Row] { (stalled + failed).filter(\.canRestart) }
}

/// Restart: `DELETE /queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true` through the gate's
/// `queueRestartAny` shape (it re-reads the queue itself), then an AlbumSearch for the albums that download carried.
/// A download of a Magpie request's album goes through the runner (`restartFromDownloads`), so the request's five
/// removals stay counted and the search is its own. One restart at a time; Restart all does at most `maxPerTap`.
public actor LidarrDownloadRestarter {
    public static let maxPerTap = 25
    /// Restart all stops after this many in a row that couldn't reach Lidarr.
    static let maxUnavailableInARow = 2
    /// The only query the restart's delete carries (pinned by scripts/check-writes.sh; the gate refuses any other).
    static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"

    public enum Outcome: Sendable, Equatable {
        case restarted
        /// Removed, but the new search didn't start (Lidarr will still look on its own schedule).
        case removedNotSearched
        /// I1: it started moving again (or stopped being stuck or failed) since the list was read: left alone.
        case skipped
        /// No longer in the queue.
        case gone
        /// Importing or done, or its download is shared with a copy that is.
        case importingOrDone
        /// Lidarr doesn't name its download, so what it shares can't be checked.
        case unnamed
        /// A Magpie request for that album is between steps.
        case magpieBusy
        /// Fix round 2 N1: Lidarr never grabbed it (another tool's transfer): left alone.
        case notStartedByLidarr
        /// The gate refused (its own fresh read disagreed).
        case refused(String)
        /// A Magpie request's download whose five removals are used up.
        case limitReached
        /// "Allow Magpie to change your library" is off (G1).
        case changesOff
        /// The change log couldn't be saved, so nothing was sent.
        case logUnavailable
        /// Lidarr couldn't be read or didn't answer.
        case unavailable
    }

    private struct SearchBody: Encodable, Sendable {
        var name: String
        var albumIds: [Int]
    }

    private let lidarr: LidarrClient
    private let gate: LidarrWriteGate
    private let runner: RequestRunner?
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, runner: RequestRunner?) {
        self.lidarr = lidarr; self.gate = gate; self.runner = runner
    }

    /// Restarts one row, if it's still what the board showed.
    public func restart(_ row: LidarrDownloads.Row) async -> Outcome {
        await takeTurn()
        defer { passTurn() }
        return await restartOne(row)
    }

    /// Restart all: the first `maxPerTap` rows, one after another (each re-checked, deleted and searched before the
    /// next). Stops when changes are switched off, or after two in a row couldn't reach Lidarr.
    public func restartAll(_ rows: [LidarrDownloads.Row]) async -> [Outcome] {
        await takeTurn()
        defer { passTurn() }
        var outcomes: [Outcome] = []
        var unavailableInARow = 0
        for row in rows.prefix(Self.maxPerTap) {
            // Fix round 2: a finished copy that couldn't be imported is only ever restarted on its own (after its own
            // confirmation), and another tool's transfer never.
            guard [.stalled, .failed].contains(row.section) else { outcomes.append(.skipped); continue }
            let outcome = await restartOne(row)
            outcomes.append(outcome)
            if outcome == .changesOff { break }
            unavailableInARow = outcome == .unavailable ? unavailableInARow + 1 : 0
            if unavailableInARow >= Self.maxUnavailableInARow { break }
        }
        return outcomes
    }

    private func takeTurn() async {
        guard running else { running = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func passTurn() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }

    private func restartOne(_ row: LidarrDownloads.Row) async -> Outcome {
        guard row.canRestart else { return .skipped }
        guard await gate.enabled else { return .changesOff }
        let queueId = row.id
        let queue: [QueueItem]
        do { queue = try await lidarr.queueDetails(albumIds: []) } catch { return .unavailable }
        guard let item = queue.first(where: { $0.id == queueId }) else { return .gone }
        guard let downloadId = item.downloadId else { return .unnamed }
        let rows = queue.filter { $0.downloadId == downloadId }
        guard !rows.contains(where: \.isImportingOrDone) else { return .importingOrDone }
        // Fix round 2 N1: only a download Lidarr grabbed itself (its message, then its grab history, read fresh; the
        // gate checks both again).
        guard !rows.contains(where: \.saysNotGrabbedByLidarr) else { return .notStartedByLidarr }
        do {
            guard try await lidarr.grabbed(downloadId: downloadId) else { return .notStartedByLidarr }
        } catch {
            return .unavailable
        }
        guard LidarrDownloads.stillRestartable(item, as: row) else { return .skipped }
        var albums: [Int] = []
        for album in rows.compactMap(\.albumId) where !albums.contains(album) { albums.append(album) }
        var searched: Int?
        do {
            if let runner, let album = try await runner.restartFromDownloads(item, albums: Set(albums)) {
                searched = album
            } else {
                _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny)
            }
        } catch {
            return Self.outcome(error)
        }
        let rest = albums.filter { $0 != searched }
        guard !rest.isEmpty else { return .restarted }
        do {
            _ = try await gate.send("POST", "command", body: SearchBody(name: "AlbumSearch", albumIds: rest))
            return .restarted
        } catch {
            Log.logger("requests").error("restart: search not started: \(Log.category(of: error), privacy: .public)")
            return .removedNotSearched
        }
    }

    private static func outcome(_ error: Error) -> Outcome {
        switch error {
        case WriteGateError.disabled: .changesOff
        case WriteGateError.forbidden(let why): .refused(why)
        case WriteGateError.logUnavailable: .logUnavailable
        case RequestRunner.DownloadRestartError.limitReached: .limitReached
        case RequestRunner.DownloadRestartError.notNow: .magpieBusy
        default: .unavailable
        }
    }
}

extension RequestRunner {
    public enum DownloadRestartError: Error, Equatable {
        /// The request's five removals (automatic and by hand together) are used up.
        case limitReached
        /// The request is between steps, or not at a step where a copy can be swapped.
        case notNow
    }

    /// Settings › Downloads in Lidarr restarts a download that carries one of `albums`: when a live request (not following
    /// another) is bringing one of them home, the removal goes through `removeCounting` (counted toward its five, before
    /// it's sent) as the gate's `queueRestartAny` shape, and the runner's own search follows, as with Find another copy.
    /// Returns that request's album, or nil when no request of Magpie's is waiting on any of them.
    func restartFromDownloads(_ item: QueueItem, albums: Set<Int>) async throws -> Int? {
        guard let r = list.first(where: { $0.isActive && $0.joinedTo == nil && $0.albumId.map(albums.contains) == true }),
              let albumId = r.albumId else { return nil }
        guard !stopped, r.canSearchAgain, !busy.contains(r.id) else { throw DownloadRestartError.notNow }
        guard !r.removalsUsedUp else { throw DownloadRestartError.limitReached }
        busy.insert(r.id)
        defer { busy.remove(r.id) }
        guard try await removeCounting([item], for: r.id, manual: true, restartAny: true) > 0 else {
            throw DownloadRestartError.limitReached
        }
        let t = now()
        await mutate(r.id) {
            $0.searchAgainAt = t
            $0.sourceStalledAt = nil
        }
        await searchAgainNow(r.id)
        return albumId
    }
}
