import Foundation
import LidarrKit
import MagpieCore

/// Settings › New music "Give up on a stuck copy after" (R17; R20's words). Soulseek downloads only. The clock
/// starts when the item appears in the queue (R20: the owner's "no change for 1 minute", not the first progress).
public enum StallLimit: Int, CaseIterable, Sendable, Identifiable {
    case oneMinute = 60, twoMinutes = 120, threeMinutes = 180, fiveMinutes = 300, tenMinutes = 600

    /// Y5 (item 9.6): 3 minutes; a minute gave up on slow transfers that were still alive. A saved choice is kept (I11).
    public static let standard = StallLimit.threeMinutes

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
    /// Read naturally in the setting's picker: "1 minute", "2 minutes"… (fix round 1 M7).
    public var title: String { rawValue == 60 ? "1 minute" : "\(rawValue / 60) minutes" }

    /// A saved value; anything that isn't one of the choices reads as the default.
    public init(seconds: TimeInterval) {
        self = Self.allCases.first { $0.seconds == seconds } ?? .standard
    }
}

/// How one Soulseek download looked when it last changed (R17). The signature is shared with the request-independent
/// `QueueStallWatch` (round 12 item 6).
struct StallWatch: Sendable, Equatable {
    struct Signature: Sendable, Equatable {
        var sizeleft: Double
        var status: String
        var tracked: String
        var client: String?

        /// Y5 (item 9.6): only what shows progress. A status flipping between ok and warning (slskd does) isn't
        /// progress, so it no longer restarts the clock.
        init(_ item: QueueItem) {
            sizeleft = item.sizeleft; status = ""
            tracked = ""; client = item.downloadClient?.lowercased()
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
    /// Fix round 1 I3: the five removals (automatic and Find another copy together) are used up for good.
    public var removalsUsedUp: Bool { stallsUsedUp }
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
        /// Five copies have been dropped for this request already (automatically and by hand together).
        case limitReached
    }

    /// The requests on their way now, as `RequestID` text (the write gate's check for queue deletes).
    public var liveRequestIds: Set<String> { Set(list.filter(\.isActive).map(\.id.description)) }

    /// Settings › New music "Give up on a stuck copy after".
    public func setStallLimit(_ seconds: TimeInterval) { stallLimit = StallLimit(seconds: seconds).seconds }

    // MARK: - Soulseek

    /// The Soulseek clients' names (lower-cased), read again every poll pass (item 9.6: the owner may rename or add
    /// a client), reused within the pass. Nil while Lidarr can't be read.
    func soulseekNames() async -> Set<String>? {
        if let soulseekClients, clientsReadInPass == passCount { return soulseekClients }
        clientsReadInPass = passCount
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
        // Fix round 1 I1: only copies still coming before import; one that's complete, waiting to import or importing is
        // never stalled (its watch is dropped). Round 19: a copy Lidarr couldn't import (blocked or failed, from any
        // client: Lidarr never retries it) is given up on the same way, so the request doesn't wait a day on it.
        let followed = items.filter { $0.albumId == albumId && $0.id != nil && ($0.isDownloadingBeforeImport || $0.isBlockedImport) }
        let present = Set(followed.compactMap(\.id))
        stallWatch = stallWatch.filter { $0.value.albumId != albumId || present.contains($0.key) }
        guard !followed.isEmpty, r.isActive, r.joinedTo == nil, let names = await soulseekNames() else { return false }
        var stalled: [QueueItem] = []
        for item in followed {
            guard let queueId = item.id, item.isBlockedImport || item.downloadClient.map({ names.contains($0.lowercased()) }) == true
            else { continue }
            let signature = StallWatch.Signature(item)
            if let watch = stallWatch[queueId], watch.signature == signature {
                if t.timeIntervalSince(watch.since) >= stallLimit { stalled.append(item) }
            } else {
                stallWatch[queueId] = StallWatch(albumId: albumId, signature: signature, since: t)
            }
        }
        guard !stalled.isEmpty, (try? await mayRemoveDownloads(r)) == true else { return false }
        if r.stallsUsedUp {
            // M3 ruling: nothing more is removed and nothing searched; the stuck copy is left to Lidarr, and the poll
            // carries on as usual. A download that moves again starts over (above).
            return false
        }
        return await giveUp(on: stalled, for: id)
    }

    /// Fix round 1 I2: `item` is a download of `albumId` alone: Lidarr names its download, and no other queue row
    /// (another album) shares it. Removing it can then take nothing else with it. The gate checks the same from its own
    /// read of the whole queue, against the live requests.
    static func isOwnDownload(_ item: QueueItem, of albumId: Int, in queue: [QueueItem]) -> Bool {
        guard item.albumId == albumId, let downloadId = item.downloadId else { return false }
        return queue.allSatisfy { $0.downloadId != downloadId || $0.albumId == albumId }
    }

    /// The stalled downloads, re-read fresh: removed (blocklisted) and searched again. True when it did.
    private func giveUp(on stalled: [QueueItem], for id: RequestID) async -> Bool {
        guard !requestBusy(id), let r = request(id), let albumId = r.albumId else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let fresh = try await lidarr.queueDetails(albumIds: [])   // the whole queue (I2: every album of the download)
            lastLidarrContact = now()
            let still = stalled.filter { old in
                fresh.contains { item in
                    item.id == old.id && item.albumId == albumId && item.downloadClient == old.downloadClient
                        && ((isSoulseek(item) && item.isDownloadingBeforeImport) || item.isBlockedImport)
                        && StallWatch.Signature(item) == StallWatch.Signature(old)
                        && Self.isOwnDownload(item, of: albumId, in: fresh)
                }
            }
            guard !still.isEmpty, try await mayRemoveDownloads(r), let current = request(id), current.isActive,
                  current.state == r.state, !current.stallsUsedUp else { return false }
            let removed = try await removeCounting(still, for: id)
            guard removed > 0 else { return false }
            Log.logger("requests").info("stalled download removed; searching again")
            await searchAgainNow(id)
            return true
        } catch {
            Log.logger("requests").error("stalled download not removed: \(Log.category(of: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Search again

    /// The owner's Search again on the request page: removes the request's download from Lidarr's queue (the same
    /// blocklisting delete) and searches again. Throws `needsConfirmation` (nothing sent) when there is a download
    /// and `removingDownload` is false. Once per `searchAgainInterval`. A removal by hand counts toward the same
    /// `maxStallRetries` as the automatic ones, and never starts the count over (fix round 1 I3): once they're used up
    /// it throws `limitReached`.
    public func searchAgain(_ id: RequestID, removingDownload confirmed: Bool) async throws {
        guard !stopped, let r = request(id), r.canSearchAgain, let albumId = r.albumId, !requestBusy(id) else {
            throw SearchAgainError.notNow
        }
        guard !r.removalsUsedUp else { throw SearchAgainError.limitReached }
        let t = now()
        if let last = r.searchAgainAt, t >= last, t.timeIntervalSince(last) < Self.searchAgainInterval {
            throw SearchAgainError.tooSoon
        }
        busy.insert(id)
        defer { busy.remove(id) }
        guard await gate.enabled else { throw SearchAgainError.unavailable }
        let queue: [QueueItem]
        do { queue = try await lidarr.queueDetails(albumIds: []) } catch { throw SearchAgainError.unavailable }
        lastLidarrContact = now()
        // I1, I2: only a copy still coming before import, and a download of this album alone.
        let downloads = queue.filter {
            $0.id != nil && $0.isDownloadingBeforeImport && Self.isOwnDownload($0, of: albumId, in: queue)
        }
        // Only Magpie's to remove (the ledger); an owner's download stays and the search goes ahead without it.
        let removable = (try? await mayRemoveDownloads(r)) == true ? downloads : []
        if !removable.isEmpty, !confirmed { throw SearchAgainError.needsConfirmation }
        guard let current = request(id), current.canSearchAgain else { throw SearchAgainError.notNow }
        guard removable.isEmpty || !current.removalsUsedUp else { throw SearchAgainError.limitReached }
        await mutate(id) {
            $0.searchAgainAt = t
            $0.sourceStalledAt = nil
        }
        if !removable.isEmpty {
            // M4: once anything was removed, the search goes ahead even if a later removal was refused.
            do {
                guard try await removeCounting(removable, for: id, manual: true) > 0 else {
                    throw SearchAgainError.unavailable
                }
            } catch let error as SearchAgainError {
                throw error
            } catch {
                throw SearchAgainError.unavailable
            }
        }
        await searchAgainNow(id)
    }

    // MARK: - Shared

    /// The request's downloads are Magpie's to remove: the ledger's open, applied entry for its album belongs to a
    /// live request (this one, or the one that monitored it), isn't kept, and says Magpie monitored the album or added
    /// its artist. The gate checks the same again from a fresh queue read (`WriteConfinement.queueDelete`).
    func mayRemoveDownloads(_ r: MagpieRequest) async throws -> Bool {
        guard let albumId = r.albumId, let entry = try await ledger.entry(albumId: albumId) else { return false }
        let live = liveRequestIds
        return entry.isOpen && entry.isApplied && !entry.isKeptOrKeeping && (entry.createdArtist || !entry.wasMonitoredBefore)
            && entry.requestId.map(live.contains) == true && entry.lidarrArtistId == r.lidarrArtistId
    }

    /// Each copy removed counts toward the request's `maxStallRetries` (automatic and by hand alike; N2), counted and saved before
    /// anything is sent (M6: a crash never refunds one), then `DELETE /queue/{id}` with exactly `queueRemoval` for
    /// each item, through the gate. Returns how many were removed. When none was (the gate refused or couldn't
    /// confirm), the count is rolled back (fix round 1 M2) and the error passed on; after one or more, a later
    /// refusal is logged and the count stands. `restartAny` (round 12 item 6, D49): Settings › Downloads in Lidarr's
    /// restart, sent as the gate's `queueRestartAny` shape (same request, confined by a fresh queue read).
    func removeCounting(_ items: [QueueItem], for id: RequestID, manual: Bool = false,
                        restartAny: Bool = false) async throws -> Int {
        let before = request(id)
        // N2: one count per copy removed, and never past the cap: only as many copies as are left to it.
        let items = Array(items.prefix(max(0, Self.maxStallRetries - (before?.stalls ?? 0))))
        guard !items.isEmpty else { return 0 }
        await mutate(id) {
            $0.stallRetries = $0.stalls + items.count
            if !manual { $0.sourceStalledAt = self.now() }
        }
        var removed = 0
        do {
            try await persist()
            for item in items {
                guard let queueId = item.id else { continue }
                if restartAny {
                    _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil, confinedAs: .queueRestartAny)
                } else {
                    _ = try await gate.send("DELETE", "queue/\(queueId)?\(Self.queueRemoval)", body: nil)
                }
                stallWatch[queueId] = nil
                removed += 1
            }
        } catch {
            if removed == 0 {
                await mutate(id) {
                    $0.stallRetries = before?.stallRetries
                    $0.sourceStalledAt = before?.sourceStalledAt
                }
                try? await persist()
                throw error
            }
            Log.logger("requests").error("a copy wasn't removed: \(Log.category(of: error), privacy: .public)")
            let unsent = items.count - removed
            await mutate(id) { $0.stallRetries = max(0, $0.stalls - unsent) }   // only the ones sent count
            try? await persist()
        }
        return removed
    }

    /// Back to searching: the runner's own AlbumSearch (`startSearch`). The blocklisting delete makes Lidarr record the
    /// download as failed; that failure is this search's start, not a new one to wait on.
    func searchAgainNow(_ id: RequestID) async {
        searchAfterRemoval.insert(id)   // N1: this search goes out, even right after the fifth removal
        await mutate(id) {
            $0.skipNextSearch = false
            $0.grabbed = false
            $0.failureSeenAt = self.now().addingTimeInterval(60)
        }
        await apply(id, .searchAgain)
    }
}
