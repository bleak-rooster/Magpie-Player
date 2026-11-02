import Foundation
import LidarrKit
import MagpieCore

// Round 12 item 6 (D49): Settings › Downloads in Lidarr. Every download in Lidarr's queue, whoever asked for it, sorted
// into Active, Stalled and Failed, with Restart on the stalled and failed ones. The owner decided this screen may
// restart ANY download (it supersedes R17's "never touches downloads of anything else" for this screen only).

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

/// R17's stall rule without a request: each queue row still coming before import, and since when it hasn't changed.
/// The clock starts when the row is first seen (R20) and starts over on any change; a row that leaves is forgotten.
public struct QueueStallWatch: Sendable, Equatable {
    private struct Seen: Sendable, Equatable {
        var signature: QueueSignature
        var since: Date
    }

    private var seen: [Int: Seen] = [:]

    public init() {}

    /// One read of the queue.
    public mutating func observe(_ items: [QueueItem], at now: Date) {
        var next: [Int: Seen] = [:]
        for item in items where item.isDownloadingBeforeImport {
            guard let id = item.id else { continue }
            let signature = QueueSignature(item)
            if let old = seen[id], old.signature == signature { next[id] = old } else { next[id] = Seen(signature: signature, since: now) }
        }
        seen = next
    }

    /// How long row `id` hasn't changed, or nil when it isn't followed.
    public func unchangedFor(_ id: Int, at now: Date) -> TimeInterval? {
        seen[id].map { max(0, now.timeIntervalSince($0.since)) }
    }
}

/// The queue as the screen shows it.
public struct LidarrDownloads: Sendable, Equatable {
    public enum Section: Sendable, Equatable { case active, stalled, failed }

    /// What a row is doing, for its status line (text plus a symbol in the app, D3).
    public enum Phase: Sendable, Equatable { case downloading, queued, waitingToImport, importing, stalled, failed }

    public struct Row: Sendable, Equatable, Identifiable {
        /// Lidarr's queue item id.
        public var id: Int
        public var item: QueueItem
        public var section: Section
        public var phase: Phase
        /// Stalled or failed, Lidarr names its download, and nothing of that download is importing or done (the
        /// gate checks the same again from its own read).
        public var canRestart: Bool
        public var artist: String
        public var album: String
        public var client: String?
        public var progress: Double?
        /// Lidarr's own words for a failed copy.
        public var message: String?

        public init(id: Int, item: QueueItem, section: Section, phase: Phase, canRestart: Bool, artist: String,
                    album: String, client: String?, progress: Double?, message: String?) {
            self.id = id; self.item = item; self.section = section; self.phase = phase; self.canRestart = canRestart
            self.artist = artist; self.album = album; self.client = client; self.progress = progress; self.message = message
        }
    }

    public var active: [Row] = []
    public var stalled: [Row] = []
    public var failed: [Row] = []

    public init() {}

    /// `soulseekClients`: the Soulseek download clients' names, lower-cased (`DownloadClientInfo.isSoulseek`): their
    /// "warning" while still downloading isn't a failure (R17). `watch` has seen this read already (`observe`).
    public init(_ items: [QueueItem], soulseekClients: Set<String>, watch: QueueStallWatch, stallLimit: TimeInterval,
                now: Date) {
        let done = Set(items.filter(\.isImportingOrDone).compactMap(\.downloadId))
        for item in items {
            guard let id = item.id else { continue }   // can't be named to Lidarr, so not shown
            let soulseek = item.downloadClient.map { soulseekClients.contains($0.lowercased()) } ?? false
            let section: Section, phase: Phase
            if item.isImportingOrDone {
                section = .active
                phase = item.trackedDownloadState.lowercased() == "importing" ? .importing : .waitingToImport
            } else if Self.isFailed(item, soulseek: soulseek) {
                (section, phase) = (.failed, .failed)
            } else if let still = watch.unchangedFor(id, at: now), still >= stallLimit {
                (section, phase) = (.stalled, .stalled)
            } else {
                section = .active
                phase = item.sizeleft >= item.size && item.status.lowercased() != "downloading" ? .queued : .downloading
            }
            let canRestart = section != .active && item.downloadId.map { !done.contains($0) } == true
            let message = (item.statusMessages.first ?? item.errorMessage).flatMap { $0.isEmpty ? nil : $0 }
            let row = Row(id: id, item: item, section: section, phase: phase, canRestart: canRestart,
                          artist: item.artistName ?? "", album: item.albumTitle ?? item.title ?? "",
                          client: item.downloadClient, progress: item.progress,
                          message: section == .failed ? message : nil)
            switch section {
            case .active: active.append(row)
            case .stalled: stalled.append(row)
            case .failed: failed.append(row)
            }
        }
    }

    /// Failed, an import blocked or failed, or Lidarr warns about it. A Soulseek copy still downloading shows "warning"
    /// all along (seen on a real Lidarr 3.2 with Tubifarry): that isn't a failure; the stall rule looks after it.
    static func isFailed(_ item: QueueItem, soulseek: Bool) -> Bool {
        let tracked = item.trackedDownloadState.lowercased(), status = item.status.lowercased()
        let trackedStatus = item.trackedDownloadStatus.lowercased()
        if ["downloadfailed", "downloadfailedpending", "failedpending", "importblocked", "importfailed"].contains(tracked) {
            return true
        }
        if status == "failed" || trackedStatus == "error" { return true }
        guard status == "warning" || trackedStatus == "warning" else { return false }
        return !(soulseek && tracked == "downloading")
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
    /// The only query the restart's delete carries (pinned by scripts/check-writes.sh; the gate refuses any other).
    static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"

    public enum Outcome: Sendable, Equatable {
        case restarted
        /// Removed, but the new search didn't start (Lidarr will still look on its own schedule).
        case removedNotSearched
        /// No longer in the queue.
        case gone
        /// The gate (or Magpie) wouldn't: importing or done, shared with such a copy, or the download unnamed.
        case refused(String)
        /// A Magpie request's download whose five removals are used up.
        case limitReached
        /// "Allow Magpie to change your library" is off (G1).
        case changesOff
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

    /// Restarts one queue row.
    public func restart(_ queueId: Int) async -> Outcome {
        await takeTurn()
        defer { passTurn() }
        return await restartOne(queueId)
    }

    /// Restart all: the first `maxPerTap` ids, one after another (each delete and its search before the next).
    public func restartAll(_ queueIds: [Int]) async -> [Outcome] {
        await takeTurn()
        defer { passTurn() }
        var outcomes: [Outcome] = []
        for id in queueIds.prefix(Self.maxPerTap) {
            let outcome = await restartOne(id)
            outcomes.append(outcome)
            if outcome == .changesOff { break }   // switched off meanwhile: nothing more goes
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

    private func restartOne(_ queueId: Int) async -> Outcome {
        guard await gate.enabled else { return .changesOff }
        let queue: [QueueItem]
        do { queue = try await lidarr.queueDetails(albumIds: []) } catch { return .unavailable }
        guard let item = queue.first(where: { $0.id == queueId }) else { return .gone }
        guard let downloadId = item.downloadId else { return .refused("the queue doesn't say which download it is") }
        let rows = queue.filter { $0.downloadId == downloadId }
        guard !rows.contains(where: \.isImportingOrDone) else { return .refused("importing or done") }
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
        case RequestRunner.DownloadRestartError.limitReached: .limitReached
        case RequestRunner.DownloadRestartError.notNow: .refused("Magpie is working on that request right now")
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
