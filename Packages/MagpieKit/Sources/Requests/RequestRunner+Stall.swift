import Foundation
import LidarrKit
import MagpieCore

/// Settings › New music "Give up on a stuck copy after" (R17; R20's words). Soulseek downloads only. The clock
/// starts when the item appears in the queue (R20: the owner's "no change for 1 minute", not the first progress).
public enum StallLimit: Int, CaseIterable, Sendable, Identifiable {
    case oneMinute = 60, twoMinutes = 120, fiveMinutes = 300, tenMinutes = 600

    public static let standard = StallLimit.oneMinute

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var title: String { "\(rawValue / 60) min" }

    /// A saved value; anything that isn't one of the choices reads as the default.
    public init(seconds: TimeInterval) {
        self = Self.allCases.first { $0.seconds == seconds } ?? .standard
    }
}

/// How one Soulseek download looked when it last changed (R17).
struct StallWatch: Sendable, Equatable {
    struct Signature: Sendable, Equatable {
        var sizeleft: Double
        var status: String
        var tracked: String
        var client: String?

        init(_ item: QueueItem) {
            sizeleft = item.sizeleft; status = item.status.lowercased()
            tracked = item.trackedDownloadState.lowercased(); client = item.downloadClient?.lowercased()
        }
    }

    var albumId: Int
    var signature: Signature
    var since: Date
}

extension MagpieRequest {
    /// Stalled downloads given up on automatically so far.
    public var stalls: Int { stallRetries ?? 0 }
    /// The automatic stall retries are used up: it waits as Still looking, with Find another copy (Search again in R17).
    public var stallsUsedUp: Bool { stalls >= RequestRunner.maxStallRetries }
    /// Searching again after a stalled download ("That copy stopped coming. Looking for another…").
    public var isSourceStalled: Bool { sourceStalledAt != nil && state == .searching }

    /// Search again is offered: on its way and not yet imported, with its album known, and not following another
    /// request (that one searches; G7).
    public var canSearchAgain: Bool {
        guard isActive, albumId != nil, joinedTo == nil else { return false }
        switch state {
        case .searching, .downloading, .waiting: return true
        default: return false
        }
    }
}

/// R17: stalled Soulseek downloads and Search again.
///
/// Magpie sees slskd through Lidarr: a queue item whose `downloadClient` names a download client Lidarr lists as
/// Soulseek (`GET /downloadclient`, read once per runner). When one of a Magpie request's Soulseek downloads hasn't
/// changed (`sizeleft`, status, trackedDownloadState) for `stallLimit`, the runner reads the queue again, and if it is
/// still the same item, album and client, unchanged:
/// 1. `DELETE /queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=true` (through the gate, which checks it
///    again on its own: `WriteConfinement.queueDelete`);
/// 2. then its own AlbumSearch for the album (so the search is Magpie's and counted).
/// At most `maxStallRetries` times per request; then it waits as still looking. Search again does the same by hand,
/// once per `searchAgainInterval`, and asks first when there's a download to remove.
///
/// Owner data: only for a live request that isn't following another, and only when the ledger says Magpie monitored
/// the album or added its artist (never an album the owner had monitored, never a kept one). The queue only, before
/// import: no library file is ever touched.
extension RequestRunner {
    public static let maxStallRetries = 5
    public static let searchAgainInterval: TimeInterval = 30
    /// The only query a queue delete carries (`ForbiddenWrites.queueDeleteQuery`).
    static let queueRemoval = "removeFromClient=true&blocklist=true&skipRedownload=true"

    public enum SearchAgainError: Error, Equatable {
        /// Not for this request now (home, importing, stopped, following another, or a step is running).
        case notNow
        /// Searched again less than `searchAgainInterval` ago.
        case tooSoon
        /// A download would be removed: ask the owner first, then call again with `removingDownload: true`.
        case needsConfirmation
        /// Lidarr couldn't be read or written right now (or changes are switched off).
        case unavailable
    }

    /// The requests on their way now, as `RequestID` text (the write gate's check for queue deletes).
    public var liveRequestIds: Set<String> { Set(list.filter(\.isActive).map(\.id.description)) }

    /// Settings › New music "Give up on a stuck copy after".
    public func setStallLimit(_ seconds: TimeInterval) { stallLimit = StallLimit(seconds: seconds).seconds }

    // MARK: - Soulseek

    /// The Soulseek clients' names (lower-cased), read once per runner. Nil while Lidarr can't be read.
    func soulseekNames() async -> Set<String>? {
        if let soulseekClients { return soulseekClients }
        guard let clients = try? await lidarr.downloadClients() else { return nil }
        lastLidarrContact = now()
        let names = Set(clients.filter(\.isSoulseek).map { $0.name.lowercased() })
        soulseekClients = names
        return names
    }

    func isSoulseek(_ item: QueueItem) -> Bool {
        guard let name = item.downloadClient?.lowercased(), let soulseekClients else { return false }
        return soulseekClients.contains(name)
    }

    /// slskd downloads show status "warning" while still downloading (seen on a real Lidarr 3.2 with Tubifarry): that
    /// isn't stuck. The stall rule looks after them instead.
    func isSoulseekDownloading(_ item: QueueItem) -> Bool {
        isSoulseek(item) && item.trackedDownloadState.lowercased() == "downloading" && item.status.lowercased() == "warning"
    }

    // MARK: - Stalls

    /// From `pollLidarr`, for each polled request with the queue items Lidarr listed: follows the request's Soulseek
    /// downloads and gives up on the ones that haven't changed for `stallLimit`. True when it handled the request
    /// this poll (the poll moves on).
    func handledStall(_ id: RequestID, _ items: [QueueItem]) async -> Bool {
        guard let r = request(id), let albumId = r.albumId else { return false }
        let t = now()
        let followed = items.filter { $0.albumId == albumId && $0.id != nil }
        let present = Set(followed.compactMap(\.id))
        stallWatch = stallWatch.filter { $0.value.albumId != albumId || present.contains($0.key) }
        guard !followed.isEmpty, r.isActive, r.joinedTo == nil, let names = await soulseekNames() else { return false }
        var stalled: [QueueItem] = []
        for item in followed {
            guard let queueId = item.id, let client = item.downloadClient?.lowercased(), names.contains(client) else {
                continue
            }
            let signature = StallWatch.Signature(item)
            if let watch = stallWatch[queueId], watch.signature == signature {
                if t.timeIntervalSince(watch.since) >= stallLimit { stalled.append(item) }
            } else {
                stallWatch[queueId] = StallWatch(albumId: albumId, signature: signature, since: t)
            }
        }
        guard !stalled.isEmpty, (try? await mayRemoveDownloads(r)) == true else { return false }
        if r.stallsUsedUp {
            // Waits as still looking; nothing more is removed. A download that moves again starts over (above).
            if case .waiting = r.state { return true }
            await apply(id, .stalled)
            return true
        }
        await giveUp(on: stalled, for: id)
        return true
    }

    /// The stalled downloads, re-read fresh: removed (blocklisted) and searched again.
    private func giveUp(on stalled: [QueueItem], for id: RequestID) async {
        guard !busy.contains(id), let r = request(id), let albumId = r.albumId else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let fresh = try await lidarr.queueDetails(albumIds: [albumId])
            lastLidarrContact = now()
            let still = stalled.filter { old in
                fresh.contains { item in
                    item.id == old.id && item.albumId == albumId && item.downloadClient == old.downloadClient
                        && isSoulseek(item) && StallWatch.Signature(item) == StallWatch.Signature(old)
                }
            }
            guard !still.isEmpty, try await mayRemoveDownloads(r),
                  let current = request(id), current.isActive, current.state == r.state else { return }
            await mutate(id) {
                $0.stallRetries = $0.stalls + 1
                $0.sourceStalledAt = self.now()
            }
            try await removeFromQueue(still, for: id)
            Log.logger("requests").info("stalled download removed; searching again")
            await searchAgainNow(id)
        } catch {
            Log.logger("requests").error("stalled download not removed: \(Log.category(of: error), privacy: .public)")
        }
    }

    // MARK: - Search again

    /// The owner's Search again on the request page: removes the request's download from Lidarr's queue (the same
    /// blocklisting delete) and searches again. Throws `needsConfirmation` (nothing sent) when there is a download
    /// and `removingDownload` is false. Once per `searchAgainInterval`; it starts the stall count over.
    public func searchAgain(_ id: RequestID, removingDownload confirmed: Bool) async throws {
        guard !stopped, let r = request(id), r.canSearchAgain, let albumId = r.albumId, !busy.contains(id) else {
            throw SearchAgainError.notNow
        }
        let t = now()
        if let last = r.searchAgainAt, t >= last, t.timeIntervalSince(last) < Self.searchAgainInterval {
            throw SearchAgainError.tooSoon
        }
        busy.insert(id)
        defer { busy.remove(id) }
        guard await gate.enabled else { throw SearchAgainError.unavailable }
        let queue: [QueueItem]
        do { queue = try await lidarr.queueDetails(albumIds: [albumId]) } catch { throw SearchAgainError.unavailable }
        lastLidarrContact = now()
        let downloads = queue.filter { $0.albumId == albumId && $0.id != nil }
        // Only Magpie's to remove (the ledger); an owner's download stays and the search goes ahead without it.
        let removable = (try? await mayRemoveDownloads(r)) == true ? downloads : []
        if !removable.isEmpty, !confirmed { throw SearchAgainError.needsConfirmation }
        guard request(id)?.canSearchAgain == true else { throw SearchAgainError.notNow }
        await mutate(id) {
            $0.searchAgainAt = t
            $0.stallRetries = 0
            $0.sourceStalledAt = nil
        }
        do { try await removeFromQueue(removable, for: id) } catch { throw SearchAgainError.unavailable }
        await searchAgainNow(id)
    }

    // MARK: - Shared

    /// The request's downloads are Magpie's to remove: the ledger's open, applied entry for its album belongs to a
    /// live request (this one, or the one that monitored it), isn't kept, and says Magpie monitored the album or added
    /// its artist. The gate checks the same again from a fresh queue read (`WriteConfinement.queueDelete`).
    func mayRemoveDownloads(_ r: MagpieRequest) async throws -> Bool {
        guard let albumId = r.albumId, let entry = try await ledger.entry(albumId: albumId) else { return false }
        let live = liveRequestIds
        return entry.isOpen && entry.isApplied && entry.keptAt == nil && (entry.createdArtist || !entry.wasMonitoredBefore)
            && entry.requestId.map(live.contains) == true && entry.lidarrArtistId == r.lidarrArtistId
    }

    /// Saves the request (M6), then `DELETE /queue/{id}` with exactly `queueRemoval` for each item, through the gate.
    private func removeFromQueue(_ items: [QueueItem], for id: RequestID) async throws {
        try await persist()
        for item in items {
            guard let queueId = item.id else { continue }
            _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil)
            stallWatch[queueId] = nil
        }
    }

    /// Back to searching: the runner's own AlbumSearch (`startSearch`). The blocklisting delete makes Lidarr record the
    /// download as failed; that failure is this search's start, not a new one to wait on.
    private func searchAgainNow(_ id: RequestID) async {
        await mutate(id) {
            $0.skipNextSearch = false
            $0.grabbed = false
            $0.failureSeenAt = self.now().addingTimeInterval(60)
        }
        await apply(id, .searchAgain)
    }
}
