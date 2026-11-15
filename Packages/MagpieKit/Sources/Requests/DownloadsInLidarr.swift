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
//
// Round 13 item 6 (D63, supersedes D49's refusals): every row that isn't importing or imported offers Restart, another
// app's too. A row still going (downloading, waiting, paused, client unreachable) asks first; a stalled or failed one
// restarts at once; a copy that couldn't import keeps its own confirmation; a download Lidarr never grabbed asks with
// the flagged confirmation, the only place `allowForeign` is set. Restart all takes stalled, failed and couldn't-import
// copies, and another app's only when the owner turns that on in its confirmation.
//
// Round 27 R (owner, 2026-11-14, D292): Clear all downloads and search again. Every download not importing or done,
// another app's too (owner's Q2), at most 100 a run, each removed through the same removal as Restart (one at a time,
// re-checked on a fresh read); the searches go only once every removal has been tried.

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
            // Round 13 (D63): another app's copy may be restarted too, so its clock runs as well.
            guard LidarrDownloads.isDownloading(item, soulseek: LidarrDownloads.isSoulseek(item, soulseekClients),
                                                ignoringGrab: true) else {
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

    /// Looks up the downloads of rows that aren't known yet, or had no grab more than `recheckNoGrab` ago; at most
    /// `perRefresh`. Rows that are stalled, failed or couldn't import (as `watch` and `stallLimit` say) first, then the
    /// rest that could be restarted (round 13, D63: any row not importing or done). Returns how many it asked about. A
    /// lookup that fails stays unknown (not restartable).
    @discardableResult
    public mutating func lookUp(_ items: [QueueItem], soulseekClients: Set<String>, lidarr: LidarrClient, now: Date,
                                watch: QueueStallWatch = QueueStallWatch(),
                                stallLimit: TimeInterval = .infinity) async -> Int {
        var stuck: [String] = [], rest: [String] = []
        for item in items {
            guard let id = item.id, let downloadId = item.downloadId, !item.saysNotGrabbedByLidarr, !item.isImportingOrDone,
                  !stuck.contains(downloadId), !rest.contains(downloadId) else { continue }
            switch status(downloadId) {
            case true?: continue
            case false?: if let last = noGrab[downloadId], now.timeIntervalSince(last) < Self.recheckNoGrab { continue }
            case nil: break
            }
            let soulseek = LidarrDownloads.isSoulseek(item, soulseekClients)
            let (section, _, _) = LidarrDownloads.classify(item, soulseek: soulseek, unchanged: watch.unchangedFor(id, at: now),
                                                           limit: stallLimit)
            if [.stalled, .failed, .couldntImport].contains(section) { stuck.append(downloadId) } else { rest.append(downloadId) }
        }
        let wanted = Array((stuck + rest).prefix(Self.perRefresh))
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

    /// Round 13 (D63): what a row's Restart asks first.
    public enum Ask: Sendable, Equatable {
        /// Stalled or failed: restarts at once.
        case none
        /// Still going (downloading, waiting, paused, client unreachable): "Restart it anyway?"
        case stillGoing
        /// A finished copy Lidarr couldn't import: its own confirmation (fix round 2).
        case couldntImport
        /// Lidarr never grabbed it: the flagged confirmation, the only place `allowForeign` is set.
        case foreign
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
        /// Round 13 (D63): Lidarr names its download, nothing of that download is importing or done, and whether
        /// Lidarr grabbed it is known (the restarter and the gate check again from their own reads).
        public var canRestart: Bool
        public var artist: String
        public var album: String
        public var client: String?
        public var progress: Double?
        /// Bytes a second, from the last two reads.
        public var speed: Double?
        /// Lidarr's own words for a stalled or failed copy.
        public var message: String?
        /// Round 13 (D63): Lidarr never grabbed it (its message, or no grab in its history): another app's.
        public var foreign: Bool
        /// What the row is, whoever started it: never `.notStarted` (another app's stuck copy is `.stalled`, `.failed`
        /// or `.couldntImport` here; Restart all and the re-check go by this).
        public var underlying: Section
        public var ask: Ask

        public init(id: Int, item: QueueItem, section: Section, phase: Phase, stall: StallReason? = nil,
                    soulseek: Bool = false, canRestart: Bool, artist: String, album: String, client: String?,
                    progress: Double?, speed: Double? = nil, message: String?, foreign: Bool = false,
                    underlying: Section? = nil, ask: Ask = .none) {
            self.foreign = foreign; self.underlying = underlying ?? section; self.ask = ask
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

    /// Rows that need the owner (N2): stalled, failed or couldn't import, grabbed by Lidarr and restartable now (another
    /// app's are in `notStarted`).
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
            // Round 13 (D63): what it is whoever started it, then whose it is.
            let (underlying, underlyingPhase, stall) = Self.classify(item, soulseek: soulseek,
                                                                     unchanged: watch.unchangedFor(id, at: now),
                                                                     limit: stallLimit, ignoringGrab: true)
            let grabbed: Bool? = item.saysNotGrabbedByLidarr ? false : item.downloadId.flatMap(grabs.status)
            let foreign = grabbed == false
            var (section, phase) = (underlying, underlyingPhase)
            if foreign, item.saysNotGrabbedByLidarr || [.stalled, .failed, .couldntImport].contains(underlying) {
                (section, phase) = (.notStarted, .notStarted)
            }
            // Not importing or done (nor anything of its download), and whose it is is known.
            let canRestart = grabbed != nil && item.downloadId.map { !done.contains($0) } == true
            let ask: Ask = foreign ? .foreign : underlying == .couldntImport ? .couldntImport
                : underlying == .active ? .stillGoing : .none
            let message = (item.statusMessages.first ?? item.errorMessage).flatMap { $0.isEmpty ? nil : $0 }
            let row = Row(id: id, item: item, section: section, phase: phase, stall: stall, soulseek: soulseek,
                          canRestart: canRestart, artist: item.artistName ?? "", album: item.albumTitle ?? item.title ?? "",
                          client: item.downloadClient, progress: item.progress,
                          speed: phase == .downloading ? watch.speed(id) : nil,
                          message: section == .active && stall == nil ? nil : message, foreign: foreign,
                          underlying: underlying, ask: ask)
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

    /// Failed, couldn't import, or not Lidarr's: never "downloading" nor "stalled". `ignoringGrab` (round 13): what
    /// the copy is doing whoever started it.
    static func isBroken(_ item: QueueItem, ignoringGrab: Bool = false) -> Bool {
        isFailed(item) || couldntImport(item) || (!ignoringGrab && item.saysNotGrabbedByLidarr)
    }

    /// Actually downloading before import: Lidarr tracks it as downloading and the client says downloading (or, for a
    /// Soulseek copy, "warning", which it shows all along; R17).
    static func isDownloading(_ item: QueueItem, soulseek: Bool, ignoringGrab: Bool = false) -> Bool {
        guard item.isDownloadingBeforeImport, !isBroken(item, ignoringGrab: ignoringGrab) else { return false }
        let status = item.status.lowercased()
        return status == "downloading" || (soulseek && status == "warning")
    }

    /// Lidarr itself says the copy is stuck: a warning (or "stalled") while downloading. Not for Soulseek, whose
    /// warning is always on; the timer looks after those.
    static func lidarrSaysStalled(_ item: QueueItem, soulseek: Bool, ignoringGrab: Bool = false) -> Bool {
        guard !soulseek, item.isDownloadingBeforeImport, !isBroken(item, ignoringGrab: ignoringGrab) else { return false }
        let status = item.status.lowercased(), trackedStatus = item.trackedDownloadStatus.lowercased()
        if waitingStatuses.contains(status) { return false }
        return ["warning", "stalled"].contains(status) || ["warning", "stalled"].contains(trackedStatus)
    }

    static func limit(_ stallLimit: TimeInterval, soulseek: Bool) -> TimeInterval {
        soulseek ? stallLimit : max(stallLimit, nonSoulseekMinimum)
    }

    /// `ignoringGrab` (round 13, D63): what the copy is doing, even when it says Lidarr didn't grab it (never
    /// `.notStarted` then).
    static func classify(_ item: QueueItem, soulseek: Bool, unchanged: TimeInterval?, limit stallLimit: TimeInterval,
                         ignoringGrab: Bool = false) -> (Section, Phase, StallReason?) {
        let status = item.status.lowercased(), tracked = item.trackedDownloadState.lowercased()
        // Fix round 2 N1: another tool's transfer Lidarr only lists.
        if !ignoringGrab, item.saysNotGrabbedByLidarr { return (.notStarted, .notStarted, nil) }
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
        if lidarrSaysStalled(item, soulseek: soulseek, ignoringGrab: ignoringGrab) { return (.stalled, .stalled, .lidarr) }
        if isDownloading(item, soulseek: soulseek, ignoringGrab: ignoringGrab), let unchanged,
           unchanged >= limit(stallLimit, soulseek: soulseek) {
            return (.stalled, .stalled, .noProgress)
        }
        return (.active, .downloading, nil)
    }

    /// I1: `fresh` (just read) is still what `row` was when the board was made: still failed; still stalled by Lidarr's
    /// word; or still downloading with nothing changed since (same signature). Anything that moved or stopped
    /// downloading is left alone. Round 13 (D63): a row that was still going stays restartable until it's importing or
    /// done (the owner confirmed restarting it as it was). Whose it is, the restarter checks on its own.
    public static func stillRestartable(_ fresh: QueueItem, as row: Row) -> Bool {
        guard !fresh.isImportingOrDone else { return false }
        switch (row.underlying, row.stall) {
        case (.active, _): return true
        case (.failed, _): return isFailed(fresh)
        case (.couldntImport, _): return couldntImport(fresh)
        case (.stalled, .lidarr?): return lidarrSaysStalled(fresh, soulseek: row.soulseek, ignoringGrab: true)
        case (.stalled, .noProgress?):
            return isDownloading(fresh, soulseek: row.soulseek, ignoringGrab: true)
                && QueueSignature(fresh) == QueueSignature(row.item)
        default: return false
        }
    }

    /// Restart all (round 13, D63): the stalled, failed and couldn't-import rows Lidarr grabbed that may be restarted.
    public var restartable: [Row] { (stalled + failed + couldntImport).filter(\.canRestart) }

    /// Another app's stalled, failed and couldn't-import rows that may be restarted: in Restart all only when the owner
    /// turns that on in its confirmation.
    public var restartableForeign: [Row] {
        notStarted.filter { $0.canRestart && [.stalled, .failed, .couldntImport].contains($0.underlying) }
    }
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
        /// Z4 fix M1: removed, and Lidarr names no album it carried, so there is nothing to look for (another app's
        /// transfer Lidarr couldn't match).
        case removedNothingToLookFor
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

    let lidarr: LidarrClient
    let gate: LidarrWriteGate
    let runner: RequestRunner?
    /// Round 27 R (D292): Clear all's clock (its removals stop inside the search window).
    let now: @Sendable () -> Date
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(lidarr: LidarrClient, gate: LidarrWriteGate, runner: RequestRunner?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.lidarr = lidarr; self.gate = gate; self.runner = runner; self.now = now
    }

    /// Restarts one row, if it's still what the board showed. `allowForeign` (round 13, D63): only from the flagged
    /// confirmation; without it a download Lidarr never grabbed is left alone.
    public func restart(_ row: LidarrDownloads.Row, allowForeign: Bool = false) async -> Outcome {
        await takeTurn()
        defer { passTurn() }
        return await restartOne(row, allowForeign: allowForeign)
    }

    /// Restart all: the first `maxPerTap` rows, one after another (each re-checked, deleted and searched before the
    /// next). Stops when changes are switched off, or after two in a row couldn't reach Lidarr. Round 13 (D63): stalled,
    /// failed and couldn't-import rows; another app's only with `includeForeign` (the owner turned that on in the
    /// confirmation).
    public func restartAll(_ rows: [LidarrDownloads.Row], includeForeign: Bool = false) async -> [Outcome] {
        await takeTurn()
        defer { passTurn() }
        var outcomes: [Outcome] = []
        var unavailableInARow = 0
        for row in rows.prefix(Self.maxPerTap) {
            // A copy still going is only restarted on its own, after its confirmation.
            guard [.stalled, .failed, .couldntImport].contains(row.underlying) else { outcomes.append(.skipped); continue }
            guard !row.foreign || includeForeign else { outcomes.append(.notStartedByLidarr); continue }
            let outcome = await restartOne(row, allowForeign: includeForeign && row.foreign)
            outcomes.append(outcome)
            if outcome == .changesOff { break }
            unavailableInARow = outcome == .unavailable ? unavailableInARow + 1 : 0
            if unavailableInARow >= Self.maxUnavailableInARow { break }
        }
        return outcomes
    }

    func takeTurn() async {
        guard running else { running = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func passTurn() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }

    private func restartOne(_ row: LidarrDownloads.Row, allowForeign: Bool) async -> Outcome {
        guard row.canRestart else { return .skipped }
        guard await gate.enabled else { return .changesOff }
        let queueId = row.id
        let queue: [QueueItem]
        do { queue = try await lidarr.queueDetails(albumIds: []) } catch { return .unavailable }
        guard let item = queue.first(where: { $0.id == queueId }) else { return .gone }
        guard let downloadId = item.downloadId else { return .unnamed }
        let rows = queue.filter { $0.downloadId == downloadId }
        guard !rows.contains(where: \.isImportingOrDone) else { return .importingOrDone }
        // Fix round 2 N1: whose it is, read fresh (its message, then its grab history; the gate checks both again).
        // Round 13 (D63): another app's only with `allowForeign`, from the flagged confirmation.
        let foreign: Bool
        if rows.contains(where: \.saysNotGrabbedByLidarr) {
            foreign = true
        } else {
            do { foreign = try await !lidarr.grabbed(downloadId: downloadId) } catch { return .unavailable }
        }
        guard !foreign || allowForeign else { return .notStartedByLidarr }
        guard LidarrDownloads.stillRestartable(item, as: row) else { return .skipped }
        var albums: [Int] = []
        for album in rows.compactMap(\.albumId) where !albums.contains(album) { albums.append(album) }
        let searched: Int?
        do {
            let removal = try await removeOne(queueId, item, albums: albums, allowForeign: foreign, deferred: false)
            searched = removal.album
        } catch {
            return Self.outcome(error)
        }
        let rest = albums.filter { $0 != searched }
        guard !rest.isEmpty else { return albums.isEmpty ? .removedNothingToLookFor : .restarted }
        return await searchFor(rest) ? .restarted : .removedNotSearched
    }

    /// One download's removal, already re-checked by the caller on a fresh read (Restart and Clear all share it). Another
    /// app's (`allowForeign`, from the flagged confirmation, or Clear all's per Q2) is never a Magpie request's grab:
    /// removed directly, never counted. A live request's goes through its counted removal: with its search now
    /// (`restartFromDownloads`, Restart) or held back, the request kept busy (`clearAllRemove`, Clear all, round 27 R
    /// D292). Returns that request (held back only) and its album.
    func removeOne(_ queueId: Int, _ item: QueueItem, albums: [Int], allowForeign: Bool,
                   deferred: Bool) async throws -> (request: RequestID?, album: Int?) {
        // Fix round 1 L9: Clear all looks for a live request first, another app's download included: the request is
        // held (busy) while the download goes, so nothing else steps it, and its own search follows. Another app's
        // copy is still never counted toward its five (D63).
        var held: (RequestID, Int)?
        if let runner, deferred { held = try await runner.clearAllRemove(item, albums: Set(albums), counted: !allowForeign) }
        if allowForeign {
            do {
                _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: true, allowFinished: !deferred)
            } catch {
                if let held { await runner?.clearAllRelease(held.0) }
                throw error
            }
            return (held?.0, held?.1)
        }
        if let held { return (held.0, held.1) }
        if let runner, !deferred, let album = try await runner.restartFromDownloads(item, albums: Set(albums)) {
            return (nil, album)
        }
        _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny, allowForeign: false, allowFinished: !deferred)
        return (nil, nil)
    }

    /// The restart's AlbumSearch for the albums a removed download named (the gate's `restartSearch`: only within ten
    /// minutes of its removal). False when it didn't start (Lidarr will still look on its own schedule).
    func searchFor(_ rest: [Int]) async -> Bool {
        do {
            _ = try await gate.send("POST", "command", body: SearchBody(name: "AlbumSearch", albumIds: rest), confinedAs: .restartSearch)
            return true
        } catch {
            Log.logger("requests").error("restart: search not started: \(Log.category(of: error), privacy: .public)")
            return false
        }
    }

    static func outcome(_ error: Error) -> Outcome {
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

// MARK: - Round 27 R: Clear all downloads and search again

/// Round 27 R (owner, 2026-11-14, D292): what "Clear all downloads and search again" will act on, read fresh when the
/// owner taps it (the confirmation counts these): one row per download (removing one row removes the whole download),
/// every download Lidarr lists by name that has nothing importing, imported or complete, at most
/// `LidarrDownloadRestarter.maxClear`. Per the owner's Q2 answer, another app's downloads are in it too, counted.
/// Fix round 1 (security M2): a download that finished but couldn't be added (`importBlocked` / `importFailed`) is
/// never in it: its files are the owner's to check (Restart keeps its own confirmation for those); counted for the
/// confirmation's line.
public struct ClearAllPlan: Sendable, Equatable {
    public struct Target: Sendable, Equatable {
        /// Lidarr's queue id of the download's first row.
        public var queueId: Int
        public var downloadId: String
        /// Lidarr never grabbed it (its message, or no grab in its history, read when the plan was made).
        public var foreign: Bool
    }

    public private(set) var targets: [Target]
    /// Downloads past the cap, left for another tap.
    public private(set) var more: Int
    /// Downloads that finished but couldn't be added, left out.
    public private(set) var couldntImport = 0

    public var count: Int { targets.count }
    /// How many of them another app started (the confirmation's second line).
    public var foreign: Int { targets.filter(\.foreign).count }
}

/// How a Clear all went, for its one outcome line.
public struct ClearAllOutcome: Sendable, Equatable {
    /// Downloads removed.
    public var cleared = 0
    /// Albums a new search actually went out for (the runner's own for a Magpie request, `restartSearch` for the rest).
    public var searchedAlbums = 0
    /// Removed downloads that got no new search: Lidarr names no album for them (usually another app's), the window
    /// for it had passed, or the search didn't go.
    public var clearedWithoutSearch = 0
    /// `restartSearch`es the gate turned down (fix round 1 M1: kept at none by the window rule).
    public var searchesTurnedDown = 0
    /// Fix round 1 L5: removals Lidarr may have carried out but didn't answer in time.
    public var maybeCleared = 0
    /// Tried and left as they were: started importing meanwhile, another app's without the flag, refused by the gate,
    /// a request's five removals used up, or Lidarr couldn't be reached.
    public var notCleared = 0
    /// Not tried: past the cap, or after the run stopped.
    public var left = 0
    /// "Allow Magpie to change your library" was off (or turned off during the run).
    public var changesOff = false
    /// Two in a row couldn't reach Lidarr (D49's rule), so the run stopped.
    public var stoppedUnreachable = false

    public init() {}
}

extension LidarrDownloadRestarter {
    /// Clear all removes at most this many downloads a run (supersedes D49's 25 for this action only).
    public static let maxClear = 100
    /// Fix round 1 M1: no removal starts this long after the first; the rest are left for the next tap.
    static let clearRemovalWindow: TimeInterval = 300
    /// Fix round 1 M1: no `restartSearch` starts once its removal is this old (the gate allows 600 s); it is counted as
    /// cleared without a new search instead of being sent to be turned down.
    static let clearSearchWindow: TimeInterval = 570

    /// A download that finished but couldn't be added (security M2: never in Clear all).
    static func finishedButNotAdded(_ item: QueueItem) -> Bool { LidarrDownloads.couldntImport(item) }

    /// Reads the whole queue fresh (and the grab history of each download) for the confirmation. Throws when Lidarr
    /// can't be read.
    public func clearAllPlan() async throws -> ClearAllPlan {
        let queue = try await lidarr.queueDetails(albumIds: [])
        let done = Set(queue.filter(\.isImportingOrDone).compactMap(\.downloadId))
        let notAdded = Set(queue.filter(Self.finishedButNotAdded).compactMap(\.downloadId))
        var targets: [(id: Int, downloadId: String, says: Bool)] = []
        var seen = Set<String>()
        for item in queue {
            guard let id = item.id, let downloadId = item.downloadId, !done.contains(downloadId),
                  !notAdded.contains(downloadId), seen.insert(downloadId).inserted else { continue }
            let says = queue.contains { $0.downloadId == downloadId && $0.saysNotGrabbedByLidarr }
            targets.append((id, downloadId, says))
        }
        let taken = Array(targets.prefix(Self.maxClear))
        var grabbed: [String: Bool] = [:]
        let asked = taken.filter { !$0.says }.map(\.downloadId)
        for batch in stride(from: 0, to: asked.count, by: GrabCache.concurrency) {
            let ids = Array(asked[batch..<min(batch + GrabCache.concurrency, asked.count)])
            try await withThrowingTaskGroup(of: (String, Bool).self) { group in
                for id in ids { group.addTask { [lidarr] in (id, try await lidarr.grabbed(downloadId: id)) } }
                for try await (id, answer) in group { grabbed[id] = answer }
            }
        }
        return ClearAllPlan(targets: taken.map { t in
            ClearAllPlan.Target(queueId: t.id, downloadId: t.downloadId, foreign: t.says || grabbed[t.downloadId] != true)
        }, more: targets.count - taken.count, couldntImport: notAdded.subtracting(done).count)
    }

    /// Fix round 2 (stuck transport): no removal and no search starts this long after the run began (longer than the
    /// 570 s search rule, which it never undercuts; it bounds the held requests' searches and a run slowed by a stuck
    /// transport); a held request
    /// whose search would start later is let go to its own failed-download path.
    static let clearDeadline: TimeInterval = 900

    /// The removal may have gone but no answer came. Fix round 2 N3: only a timeout or a dropped connection, which can
    /// happen after the request left; anything else (the gate's refusal, Lidarr's own error, the runner's, a host that
    /// couldn't be reached, a cancellation) means nothing went.
    static func lostAnswer(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return url.code == .timedOut || url.code == .networkConnectionLost
    }

    /// Clear all, after its confirmation. At most `maxClear` downloads of `plan`, one at a time: read fresh (gone: not
    /// counted; its download changed, or something of it is importing, done or couldn't be added: left alone), whose it
    /// is read fresh (another app's only with `includeForeign`, set by the confirmation), then removed through the
    /// restarter's own removal (a live Magpie request held, its counted removal for its own copy, its search held back).
    /// Only once every removal has been tried do the searches go (fix round 1 M1): first the windowed `restartSearch`es,
    /// in removal order, none started once its removal is `clearSearchWindow` old; then the requests' own searches (the
    /// runner's, ledger-confined, not windowed). Stops when changes are off, after two in a row couldn't reach Lidarr,
    /// or `clearRemovalWindow` after the first removal.
    public func clearAll(_ plan: ClearAllPlan, includeForeign: Bool,
                         progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> ClearAllOutcome {
        await takeTurn()
        defer { passTurn() }
        let targets = Array(plan.targets.prefix(Self.maxClear))
        var outcome = ClearAllOutcome()
        outcome.left = plan.more + plan.targets.count - targets.count
        var removed: [(albums: [Int], request: RequestID?, requestAlbum: Int?, at: Date)] = []
        var unavailableInARow = 0
        var firstRemoval: Date?
        var tried = 0
        let runStart = now()
        for target in targets {
            // Read before the removal, so the windows count from no later than the gate's own time for it.
            let startedAt = now()
            if let firstRemoval, startedAt.timeIntervalSince(firstRemoval) >= Self.clearRemovalWindow { break }
            if startedAt.timeIntervalSince(runStart) >= Self.clearDeadline { break }
            guard await gate.enabled else { outcome.changesOff = true; break }
            if unavailableInARow >= Self.maxUnavailableInARow { outcome.stoppedUnreachable = true; break }
            tried += 1
            await progress(tried, targets.count)
            let queue: [QueueItem]
            do { queue = try await lidarr.queueDetails(albumIds: []) } catch {
                unavailableInARow += 1; outcome.notCleared += 1; continue
            }
            unavailableInARow = 0
            guard let item = queue.first(where: { $0.id == target.queueId }) else { continue }   // gone already
            let rows = queue.filter { $0.downloadId == target.downloadId }
            guard item.downloadId == target.downloadId, !rows.contains(where: \.isImportingOrDone),
                  !rows.contains(where: Self.finishedButNotAdded) else {
                outcome.notCleared += 1; continue
            }
            let foreign: Bool
            if rows.contains(where: \.saysNotGrabbedByLidarr) {
                foreign = true
            } else {
                do { foreign = try await !lidarr.grabbed(downloadId: target.downloadId) } catch {
                    unavailableInARow += 1; outcome.notCleared += 1; continue
                }
            }
            guard !foreign || includeForeign else { outcome.notCleared += 1; continue }
            var albums: [Int] = []
            for album in rows.compactMap(\.albumId) where !albums.contains(album) { albums.append(album) }
            do {
                let removal = try await removeOne(target.queueId, item, albums: albums, allowForeign: foreign, deferred: true)
                removed.append((albums, removal.request, removal.album, startedAt))
                if firstRemoval == nil { firstRemoval = startedAt }
                outcome.cleared += 1
            } catch {
                if Self.lostAnswer(error) {
                    outcome.maybeCleared += 1; unavailableInARow += 1; continue
                }
                outcome.notCleared += 1
                switch Self.outcome(error) {
                case .changesOff: outcome.changesOff = true
                case .unavailable: unavailableInARow += 1
                default: break
                }
                if outcome.changesOff { break }
            }
        }
        if unavailableInARow >= Self.maxUnavailableInARow { outcome.stoppedUnreachable = true }
        outcome.left += targets.count - tried
        // Every removal has been tried: now the searches. The windowed restart searches first, in removal order. Fix
        // round 2 N2: an album a held request searches itself, or one an earlier search here already asked for, isn't
        // asked for again (a removal sharing it counts as searched once that search went).
        let heldAlbums = Set(removed.compactMap { $0.request == nil ? nil : $0.requestAlbum })
        var askedFor = Set<Int>()
        for removal in removed {
            let rest = removal.albums.filter { !heldAlbums.contains($0) && !askedFor.contains($0) }
            guard !rest.isEmpty else { continue }
            guard now().timeIntervalSince(removal.at) < Self.clearSearchWindow else { continue }   // fix round 1 M1: the 570 s rule
            guard now().timeIntervalSince(runStart) < Self.clearDeadline else { continue }
            if await searchFor(rest) {
                outcome.searchedAlbums += rest.count
                askedFor.formUnion(rest)
            } else {
                outcome.searchesTurnedDown += 1
            }
        }
        // Then the held requests' own searches (ledger-confined, not windowed), each request freed after its own; past
        // the deadline, let go without one.
        for removal in removed {
            guard let request = removal.request, let runner else { continue }
            guard now().timeIntervalSince(runStart) < Self.clearDeadline else { await runner.clearAllRelease(request); continue }
            if await runner.clearAllSearch(request) {
                outcome.searchedAlbums += 1
                if let album = removal.requestAlbum { askedFor.insert(album) }
            }
        }
        outcome.clearedWithoutSearch = removed.filter { !$0.albums.contains(where: askedFor.contains) }.count
        return outcome
    }
}

extension RequestRunner {
    /// Round 27 R (D292): Clear all's hold on a live request waiting on one of `albums`: the request is kept busy, so
    /// nothing else steps it, until `clearAllSearch` sends its own search once every removal has been tried.
    /// `counted` (its own copy): the removal goes now through `removeCounting` (counted toward its five, saved before
    /// it's sent), as `restartFromDownloads` does but without its search; and, fix round 1 M1, `searchAgainAt` is saved
    /// at once, so a Magpie stopped before the searches leaves the request to its own failed-download path. Not
    /// counted (fix round 1 L9: another app's copy of its album): only held; the restarter removes it. Returns that
    /// request and its album, or nil when no request of Magpie's is waiting on any of `albums`.
    func clearAllRemove(_ item: QueueItem, albums: Set<Int>, counted: Bool) async throws -> (RequestID, Int)? {
        guard let r = list.first(where: { $0.isActive && $0.joinedTo == nil && $0.albumId.map(albums.contains) == true }),
              let albumId = r.albumId else { return nil }
        guard !stopped, r.canSearchAgain, !busy.contains(r.id) else { throw DownloadRestartError.notNow }
        guard !counted || !r.removalsUsedUp else { throw DownloadRestartError.limitReached }
        busy.insert(r.id)
        guard counted else { return (r.id, albumId) }
        do {
            guard try await removeCounting([item], for: r.id, manual: true, restartAny: true) > 0 else {
                throw DownloadRestartError.limitReached
            }
        } catch {
            busy.remove(r.id)
            throw error
        }
        let t = now()
        await mutate(r.id) { $0.searchAgainAt = t }
        try? await persist()
        return (r.id, albumId)
    }

    /// Fix round 1 L9: a hold whose removal didn't go.
    func clearAllRelease(_ id: RequestID) { busy.remove(id) }

    /// Round 27 R (D292): the held request's own search (as after Find another copy), then it is free again. True when
    /// a search actually went (task M2: Lidarr took a new AlbumSearch for it).
    func clearAllSearch(_ id: RequestID) async -> Bool {
        defer { busy.remove(id) }
        let before = request(id)?.searchCommandId
        let t = now()
        await mutate(id) {
            $0.searchAgainAt = t
            $0.sourceStalledAt = nil
        }
        await searchAgainNow(id)
        let after = request(id)?.searchCommandId
        return after != nil && after != before
    }
}
