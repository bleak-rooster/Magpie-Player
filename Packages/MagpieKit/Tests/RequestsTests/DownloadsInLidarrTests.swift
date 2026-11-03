import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 12 item 6 (D49): Settings › Downloads in Lidarr. The whole queue sorted into Active, Stalled and Failed, and
/// Restart: `DELETE /queue/{id}` in the one shape (the gate's `queueRestartAny`) then an AlbumSearch, one at a time, at
/// most 25 per tap, each row re-checked on a fresh read first; a Magpie request's download goes through the runner, so
/// its five-removal count stays true.
///
/// Fix round 1: Stalled is only a copy that's actually downloading and not moving (Lidarr says so, or no change past
/// the limit); queued, paused, delayed and unreachable copies never are (C1). Failed is failed or import blocked (I2).
/// A row that recovered since the board was read is skipped (I1).
@Suite struct DownloadsInLidarrTests {
    static let deleteQuery = "removeFromClient=true&blocklist=true&skipRedownload=true"
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let soulseek: Set<String> = ["slskd"]

    private func item(_ id: Int, album: Int = 41, client: String = "SABnzbd", sizeleft: Double = 50,
                      status: String = "downloading", tracked: String = "downloading", trackedStatus: String = "ok",
                      download: String? = nil, messages: [String] = []) -> QueueItem {
        QueueItem(id: id, albumId: album, artistId: 9, downloadClient: client, downloadId: download ?? "dl-\(id)",
                  size: 100, sizeleft: sizeleft, status: status, trackedDownloadState: tracked, statusMessages: messages,
                  trackedDownloadStatus: trackedStatus, title: "Release \(id)", artistName: "Owner Artist",
                  albumTitle: "Album \(album)")
    }

    /// Fix round 3 N2: a grab cache that knows Lidarr grabbed every download in `items` (unless listed in `not`).
    private func grabs(_ items: [QueueItem], not ungrabbed: Set<String> = []) -> GrabCache {
        var cache = GrabCache()
        for id in Set(items.compactMap(\.downloadId)) { cache.record(id, grabbed: !ungrabbed.contains(id), at: t0) }
        return cache
    }

    private func board(_ items: [QueueItem], watch: QueueStallWatch = QueueStallWatch(), at now: Date? = nil,
                       limit: TimeInterval = 60, grabs given: GrabCache? = nil) -> LidarrDownloads {
        LidarrDownloads(items, soulseekClients: Self.soulseek, watch: watch, grabs: given ?? grabs(items),
                        stallLimit: limit, now: now ?? t0)
    }

    /// Observes `items` every 5 s for `seconds`, then classifies.
    private func watched(_ items: [QueueItem], for seconds: Int, limit: TimeInterval = 60) -> LidarrDownloads {
        var watch = QueueStallWatch()
        for s in stride(from: 0, through: seconds, by: 5) {
            watch.observe(items, soulseekClients: Self.soulseek, at: t0.addingTimeInterval(Double(s)))
        }
        return board(items, watch: watch, at: t0.addingTimeInterval(Double(seconds)), limit: limit)
    }

    // MARK: - Classification

    @Test func sortsIntoActiveStalledFailed() {
        let items = [
            item(1),                                                                          // downloading
            item(2, status: "completed", tracked: "importBlocked", trackedStatus: "warning",
                 messages: ["No files found are eligible for import"]),                       // failed
            item(3, status: "failed", tracked: "downloadFailed", trackedStatus: "error"),     // failed
            item(4, sizeleft: 0, status: "completed", tracked: "importing"),                  // active, not restartable
            item(5, status: "warning", trackedStatus: "warning",
                 messages: ["The download is stalled with no connections"]),                  // I2: Lidarr says stalled
            item(6, client: "Slskd", status: "warning", trackedStatus: "warning"),            // Soulseek warning: active
            item(7, trackedStatus: "error"),                                                  // I2: still downloading
        ]
        let b = board(items)
        #expect(b.active.map(\.id) == [1, 4, 6, 7])
        #expect(b.stalled.map(\.id) == [5])
        #expect(b.stalled.first?.stall == .lidarr)
        #expect(b.stalled.first?.message == "The download is stalled with no connections")
        #expect(b.failed.map(\.id) == [3])
        // Fix round 2: a finished copy that couldn't be imported has its own section, out of Restart all.
        #expect(b.couldntImport.map(\.id) == [2])
        #expect(b.couldntImport.first?.message == "No files found are eligible for import")
        #expect(b.couldntImport.first?.canRestart == true)
        #expect(b.active.first { $0.id == 4 }?.canRestart == false)
        #expect(b.active.first { $0.id == 4 }?.phase == .importing)
        #expect(b.failed.filter { !$0.canRestart }.isEmpty)
        // Round 13 item 6 (D63): Restart all takes couldn't-import copies too; every row but the importing one offers
        // Restart, a stalled or failed one directly, one still going after a confirmation.
        #expect(b.restartable.map(\.id) == [5, 3, 2])
        #expect(b.active.filter(\.canRestart).map(\.id) == [1, 6, 7])
        #expect(b.active.filter(\.canRestart).allSatisfy { $0.ask == .stillGoing && !$0.foreign })
        #expect(b.stalled.first?.ask == LidarrDownloads.Ask.none)
        #expect(b.failed.first?.ask == LidarrDownloads.Ask.none)
        #expect(b.couldntImport.first?.ask == .couldntImport)
        #expect(b.active.first?.artist == "Owner Artist")
        #expect(b.active.first?.album == "Album 41")
        #expect(b.active.first?.client == "SABnzbd")
        #expect(b.active.first?.progress == 0.5)
    }

    /// Fix round 2, the owner's real queue (read-only re-review, anonymised): every row a Soulseek copy.
    /// - complete, import blocked ("Artist name mismatch") or failed ("Has missing tracks", "Album match is not close
    ///   enough") → Couldn't import: restartable one at a time, never by Restart all;
    /// - status failed while Lidarr still tracks it as downloading, "Download wasn't grabbed by Lidarr, skipping" →
    ///   Not started by your library: read-only, never restartable;
    /// - import pending with a warning → Couldn't import, but Lidarr may still import it: not restartable.
    @Test func ownersRealShapes() {
        func soulseekRow(_ id: Int, status: String, tracked: String, sizeleft: Double, message: String,
                         errorMessage: String? = nil) -> QueueItem {
            QueueItem(id: id, albumId: 40 + id, artistId: 9, downloadClient: "Slskd",
                      protocolName: "SoulseekDownloadProtocol", downloadId: "dl-\(id)", size: 100, sizeleft: sizeleft,
                      status: status, trackedDownloadState: tracked, statusMessages: [message],
                      trackedDownloadStatus: "warning", errorMessage: errorMessage)
        }
        let items = [
            soulseekRow(1, status: "completed", tracked: "importBlocked", sizeleft: 0,
                        message: "Artist name mismatch, automatic import is not possible. Check the release and import manually."),
            soulseekRow(2, status: "completed", tracked: "importFailed", sizeleft: 0, message: "Has missing tracks"),
            soulseekRow(3, status: "completed", tracked: "importFailed", sizeleft: 0,
                        message: "Album match is not close enough: 72.4 % vs 80 % [Artist]"),
            soulseekRow(4, status: "failed", tracked: "downloading", sizeleft: 40,
                        message: "Download wasn't grabbed by Lidarr, skipping",
                        errorMessage: "Download wasn't grabbed by Lidarr, skipping"),
            soulseekRow(5, status: "completed", tracked: "importPending", sizeleft: 0, message: "Waiting for manual import"),
            soulseekRow(6, status: "completed", tracked: "importFailed", sizeleft: 0, message: "Has missing tracks"),
        ]
        // Fix round 3 N2, as measured on the owner's Lidarr: the "Artist name mismatch" copies (1) have no grab in the
        // history either, so they're another tool's; the import failures (2, 3) were grabbed. 6's history isn't read yet.
        var cache = grabs(Array(items.prefix(5)), not: ["dl-1", "dl-4"])
        cache.record("dl-5", grabbed: true, at: t0)
        let b = board(items, grabs: cache)
        #expect(b.couldntImport.map(\.id) == [2, 3, 5, 6])
        #expect(b.couldntImport.map(\.canRestart) == [true, true, false, false])
        #expect(b.couldntImport.first?.message == "Has missing tracks")
        #expect(b.notStarted.map(\.id) == [1, 4])
        // Round 13 item 6 (D63): another app's copy offers Restart behind the flagged confirmation.
        #expect(b.notStarted.allSatisfy { $0.canRestart && $0.foreign && $0.ask == .foreign && $0.phase == .notStarted })
        #expect(b.notStarted.map(\.underlying) == [.couldntImport, .failed])
        #expect(b.notStarted.first?.message?.hasPrefix("Artist name mismatch") == true)
        #expect(b.failed.isEmpty && b.stalled.isEmpty)
        #expect(b.restartable.map(\.id) == [2, 3], "Restart all takes grabbed couldn't-import copies, never another app's")
        #expect(b.restartableForeign.map(\.id) == [1, 4], "only when the owner turns that on in its confirmation")
        #expect(b.attention == 2, "only grabbed copies that can be restarted need attention")
    }

    /// N2: a stalled or failed row whose grab history isn't known yet isn't restartable and doesn't count; one with no
    /// grab is another app's.
    @Test func ungrabbedOrUnknownIsNeverRestartable() {
        let items = [item(1, status: "failed", tracked: "downloadFailed"), item(2, status: "warning", trackedStatus: "warning"),
                     item(3, status: "failed", tracked: "downloadFailed")]
        var cache = GrabCache()
        cache.record("dl-1", grabbed: false, at: t0)
        cache.record("dl-3", grabbed: true, at: t0)
        let b = board(items, grabs: cache)
        #expect(b.notStarted.map(\.id) == [1])
        #expect(b.notStarted.first?.canRestart == true && b.notStarted.first?.foreign == true)
        #expect(b.stalled.map(\.id) == [2])
        #expect(b.stalled.first?.canRestart == false, "not known yet: can't tell whose it is")
        #expect(b.restartable.map(\.id) == [3])
        #expect(b.attention == 1)
    }

    /// C1: queued, paused, delayed and unreachable copies are never Stalled or restartable, however long they sit
    /// unchanged; each says what it's doing.
    @Test func waitingCopiesAreNeverStalled() {
        let items = [item(1, status: "queued"), item(2, status: "paused"), item(3, status: "delay"),
                     item(4, status: "downloadClientUnavailable"), item(5, client: "Slskd", status: "queued"),
                     item(6, sizeleft: 100, status: "queued", trackedStatus: "warning")]
        let b = watched(items, for: 3_600)
        #expect(b.active.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(b.stalled.isEmpty && b.failed.isEmpty && b.restartable.isEmpty)
        #expect(b.active.map(\.phase) == [.queued, .paused, .queued, .clientUnavailable, .queued, .queued])
        // Round 13 item 6 (D63): each may still be restarted, after the "still going" confirmation; never by Restart all.
        #expect(b.active.allSatisfy { $0.canRestart && $0.ask == .stillGoing })
    }

    /// The no-progress timer: a copy downloading with `sizeleft` unchanged. Soulseek copies after the owner's limit
    /// (R17's setting); other clients after at least 10 minutes.
    @Test func noProgressTimer() {
        let usenet = item(1), slsk = item(2, client: "Slskd", status: "warning", trackedStatus: "warning")
        let early = watched([usenet, slsk], for: 60)
        #expect(early.stalled.map(\.id) == [2])
        #expect(early.stalled.first?.stall == .noProgress)
        #expect(early.stalled.first?.canRestart == true)
        #expect(watched([usenet, slsk], for: 595).stalled.map(\.id) == [2])
        #expect(watched([usenet, slsk], for: 600).stalled.map(\.id) == [1, 2])
        #expect(watched([usenet, slsk], for: 55).stalled.isEmpty)
    }

    /// Any change starts the clock over; a row that leaves is forgotten.
    @Test func stallWatchRestartsOnChange() {
        var watch = QueueStallWatch()
        let a = item(1, client: "Slskd"), b = item(2, client: "Slskd")
        watch.observe([a, b], soulseekClients: Self.soulseek, at: t0)
        var moved = b
        moved.sizeleft = 40
        watch.observe([a, moved], soulseekClients: Self.soulseek, at: t0.addingTimeInterval(30))
        let later = board([a, moved], watch: watch, at: t0.addingTimeInterval(60))
        #expect(later.stalled.map(\.id) == [1])
        #expect(later.active.map(\.id) == [2])
        watch.observe([moved], soulseekClients: Self.soulseek, at: t0.addingTimeInterval(61))
        watch.observe([a, moved], soulseekClients: Self.soulseek, at: t0.addingTimeInterval(62))
        #expect(board([a, moved], watch: watch, at: t0.addingTimeInterval(100)).stalled.map(\.id) == [2])
        #expect(watch.unchangedFor(1, at: t0.addingTimeInterval(100)) == 38)
    }

    /// Minor: Active rows show a speed, from the change in `sizeleft` between reads.
    @Test func speedFromSuccessiveReads() {
        var watch = QueueStallWatch()
        let a = item(1, sizeleft: 50)
        watch.observe([a], soulseekClients: [], at: t0)
        #expect(watch.speed(1) == nil)
        var b = a
        b.sizeleft = 40
        watch.observe([b], soulseekClients: [], at: t0.addingTimeInterval(5))
        #expect(watch.speed(1) == 2)
        #expect(board([b], watch: watch, at: t0.addingTimeInterval(5)).active.first?.speed == 2)
    }

    @Test func sharedWithAnImportIsNotRestartable() {
        let b = board([item(1, status: "failed", tracked: "downloadFailed", download: "x"),
                       item(2, album: 42, sizeleft: 0, status: "completed", tracked: "importing", download: "x"),
                       item(3, status: "failed", tracked: "downloadFailed", download: nil)])
        #expect(b.failed.first { $0.id == 1 }?.canRestart == false)
        #expect(b.active.first { $0.id == 2 }?.canRestart == false)
        #expect(b.restartable.map(\.id) == [3])
    }

    /// The page's signature counts a status change; the runner's R17 stall clock (Y5 item 9.6, D53) doesn't: a status
    /// flip (ok ↔ warning, as slskd does) isn't progress there.
    @Test func signatureIsShared() {
        let a = item(1)
        var b = a
        b.status = "Queued"
        #expect(QueueSignature(b) != QueueSignature(a))
        #expect(StallWatch.Signature(b) == StallWatch.Signature(a))
        var c = a
        c.sizeleft -= 1
        #expect(StallWatch.Signature(c) != StallWatch.Signature(a) && QueueSignature(c) != QueueSignature(a))
    }

    /// I1: the same rule on a fresh read decides whether a row is still restartable.
    @Test func stillRestartableUsesTheSameRule() {
        let slsk = item(2, client: "Slskd", status: "warning", trackedStatus: "warning")
        let row = try! #require(watched([slsk], for: 60).stalled.first)
        #expect(LidarrDownloads.stillRestartable(slsk, as: row))
        var moved = slsk
        moved.sizeleft = 49
        #expect(!LidarrDownloads.stillRestartable(moved, as: row))
        var paused = slsk
        paused.status = "paused"
        #expect(!LidarrDownloads.stillRestartable(paused, as: row))
        let warned = item(5, status: "warning", trackedStatus: "warning")
        let lidarrRow = try! #require(board([warned]).stalled.first)
        var cleared = warned
        cleared.status = "downloading"; cleared.trackedDownloadStatus = "ok"
        #expect(!LidarrDownloads.stillRestartable(cleared, as: lidarrRow))
        let failed = item(3, status: "failed", tracked: "downloadFailed")
        let failedRow = try! #require(board([failed]).failed.first)
        #expect(LidarrDownloads.stillRestartable(failed, as: failedRow))
        #expect(!LidarrDownloads.stillRestartable(item(3), as: failedRow))
        // Round 13 item 6 (D63): a row still going stays restartable until it's importing or done.
        let pausedItem = item(8, status: "paused")
        let pausedRow = try! #require(board([pausedItem]).active.first)
        #expect(LidarrDownloads.stillRestartable(pausedItem, as: pausedRow))
        #expect(LidarrDownloads.stillRestartable(item(8), as: pausedRow))
        #expect(!LidarrDownloads.stillRestartable(item(8, sizeleft: 0, status: "completed", tracked: "importing"), as: pausedRow))
    }

    // MARK: - Restart (owner's downloads)

    private func ownerQueue(_ h: Harness, ids: [Int]) {
        h.server.with { s in
            s.queue = ids.map { FakeLidarr.Queued(albumId: 41 + $0 - 901, size: 100, sizeleft: 50, status: "failed",
                                                  tracked: "downloadFailed", id: $0, artistId: 9, client: "SABnzbd") }
        }
    }

    /// The board as the screen would build it from the fake Lidarr now, its grab history looked up (N2).
    private func rows(_ h: Harness) async throws -> LidarrDownloads {
        let items = try await h.lidarrClient.queueDetails(albumIds: [])
        var cache = GrabCache()
        while await cache.lookUp(items, soulseekClients: Self.soulseek, lidarr: h.lidarrClient, now: t0) > 0 {}
        return LidarrDownloads(items, soulseekClients: Self.soulseek, watch: QueueStallWatch(), grabs: cache,
                               stallLimit: 60, now: t0)
    }

    private func historyReads(_ h: Harness) -> [String] {
        h.server.transport.requests.filter { $0.url?.path.hasSuffix("/api/v1/history") == true }.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "downloadId" }?.value
        }
    }

    /// N2: the grab history is read on each refresh for the rows that could be restarted, at most `GrabCache.perRefresh`
    /// at a time; a grab is kept, "no grab" is asked again after a minute; Active rows are never asked about.
    @Test func grabCacheIsBatchedAndCached() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = (901...930).map { FakeLidarr.Queued(albumId: 41 + $0 - 901, size: 100, sizeleft: 50, status: "failed",
                                                         tracked: "downloadFailed", id: $0, artistId: 9, client: "SABnzbd") }
                + [FakeLidarr.Queued(albumId: 99, size: 100, sizeleft: 50, id: 931, artistId: 9, client: "SABnzbd")]
            s.ungrabbed = ["dl-901"]
        }
        let items = try await h.lidarrClient.queueDetails(albumIds: [])
        var cache = GrabCache()
        #expect(await cache.lookUp(items, soulseekClients: Self.soulseek, lidarr: h.lidarrClient, now: t0) == GrabCache.perRefresh)
        #expect(historyReads(h).count == GrabCache.perRefresh)
        while await cache.lookUp(items, soulseekClients: Self.soulseek, lidarr: h.lidarrClient, now: t0) > 0 {}
        // Round 13 item 6 (D63): an active row may be restarted too, so it's asked about, after the stuck ones.
        #expect(historyReads(h).count == 31)
        #expect(historyReads(h).last == "dl-931", "an active row is asked about after the stuck ones")
        #expect(cache.status("dl-901") == false && cache.status("dl-902") == true)
        // Nothing more within the minute; then only the "no grab" one again.
        #expect(await cache.lookUp(items, soulseekClients: Self.soulseek, lidarr: h.lidarrClient, now: t0.addingTimeInterval(59)) == 0)
        #expect(await cache.lookUp(items, soulseekClients: Self.soulseek, lidarr: h.lidarrClient, now: t0.addingTimeInterval(60)) == 1)
        #expect(historyReads(h).last == "dl-901")
    }

    private func writes(_ h: Harness) -> [String] {
        h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
    }

    @Test func restartsAnOwnersDownload() async throws {
        let h = await Harness()
        ownerQueue(h, ids: [901])
        let row = try #require(try await rows(h).failed.first)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row) == .restarted)
        #expect(writes(h) == ["DELETE queue/901", "POST command"])
        #expect(h.server.writes.first?.url?.query == Self.deleteQuery)
        let search = try #require(h.server.writeBodies().last)
        #expect(search.1["name"] as? String == "AlbumSearch")
        #expect(search.1["albumIds"] as? [Int] == [41])
        #expect(await h.gate.changeLog().map(\.method) == ["DELETE", "POST"])
    }

    @Test func refusalsSendNothing() async throws {
        let h = await Harness()
        ownerQueue(h, ids: [901, 902, 903])
        let board = try await rows(h)
        let (r1, r2, r3) = (board.failed[0], board.failed[1], board.failed[2])
        h.server.with { s in
            s.queue.removeAll { $0.id == 901 }                                              // gone
            if let i = s.queue.firstIndex(where: { $0.id == 902 }) {                        // importing now
                s.queue[i].status = "completed"; s.queue[i].tracked = "importing"; s.queue[i].sizeleft = 0
            }
        }
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(r1) == .gone)
        #expect(await restarter.restart(r2) == .importingOrDone)
        await h.gate.setEnabled(false)
        #expect(await restarter.restart(r3) == .changesOff)
        #expect(h.server.writes.isEmpty)
    }

    /// Round 13 item 6 (D63, replaces fix round 2's "one at a time"): Restart all takes a finished copy that couldn't
    /// be imported when Lidarr grabbed it; another app's only when the owner turned that on in its confirmation.
    @Test func couldntImportJoinsRestartAllButForeignOnlyWhenTurnedOn() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [901, 902].map { FakeLidarr.Queued(albumId: 41 + $0 - 901, size: 100, sizeleft: 0, status: "completed",
                                                         tracked: "importBlocked", messages: ["Artist name mismatch"],
                                                         id: $0, artistId: 9, client: "Slskd") }
            s.ungrabbed = ["dl-902"]
        }
        let board = try await rows(h)
        #expect(board.couldntImport.map(\.id) == [901])
        #expect(board.notStarted.map(\.id) == [902])
        #expect(board.restartable.map(\.id) == [901])
        #expect(board.restartableForeign.map(\.id) == [902])
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restartAll(board.restartable + board.restartableForeign) == [.restarted, .notStartedByLidarr])
        #expect(writes(h) == ["DELETE queue/901", "POST command"])
        var forced = try #require(board.notStarted.first)   // a foreign row passed off as Lidarr's: still needs the flag
        forced.foreign = false; forced.section = .couldntImport
        #expect(await restarter.restart(forced) == .notStartedByLidarr)
        #expect(writes(h).count == 2)
        #expect(await restarter.restartAll(board.restartableForeign, includeForeign: true) == [.restarted])
        #expect(writes(h) == ["DELETE queue/901", "POST command", "DELETE queue/902", "POST command"])
        #expect(h.server.writes.last { $0.httpMethod == "DELETE" }?.url?.query == Self.deleteQuery)
    }

    /// Round 13 item 6 (D63): a download Lidarr never grabbed is restarted only with `allowForeign` (set only by the
    /// flagged confirmation); without it nothing is sent.
    @Test func foreignNeedsTheFlag() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 41, size: 100, sizeleft: 40, status: "failed",
                                         messages: ["Download wasn't grabbed by Lidarr, skipping"], id: 901, artistId: 9,
                                         client: "Slskd")]
            s.ungrabbed = ["dl-901"]
        }
        let board = try await rows(h)
        let row = try #require(board.notStarted.first)
        #expect(row.canRestart && row.foreign && row.ask == .foreign)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row) == .notStartedByLidarr)
        #expect(h.server.writes.isEmpty)
        #expect(await restarter.restart(row, allowForeign: true) == .restarted)
        #expect(writes(h) == ["DELETE queue/901", "POST command"])
        #expect(h.server.writes.first?.url?.query == Self.deleteQuery)
        #expect(h.server.writeBodies().last?.1["albumIds"] as? [Int] == [41])
    }

    /// Z4 fix M1: another app's transfer Lidarr names no album for is only removed: nothing is searched, and the
    /// outcome says so (not "Restarted").
    @Test func foreignWithNoAlbumIsOnlyRemoved() async throws {
        let h = await Harness()
        h.server.with { s in
            var q = FakeLidarr.Queued(albumId: 0, size: 100, sizeleft: 40, status: "failed", tracked: "downloadFailed",
                                      id: 901, artistId: 9, client: "Slskd")
            q.noAlbum = true
            s.queue = [q]
            s.ungrabbed = ["dl-901"]
        }
        let row = try #require(try await rows(h).notStarted.first)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row, allowForeign: true) == .removedNothingToLookFor)
        #expect(writes(h) == ["DELETE queue/901"])
    }

    /// Round 13 item 6 (D63): a copy still going (here paused) may be restarted (the screen asks first).
    @Test func pausedRowIsRestarted() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 41, size: 100, sizeleft: 50, status: "paused", id: 901, artistId: 9,
                                         client: "SABnzbd")]
        }
        let row = try #require(try await rows(h).active.first)
        #expect(row.canRestart && row.ask == .stillGoing)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restartAll([row]) == [.skipped], "never by Restart all")
        #expect(await restarter.restart(row) == .restarted)
        #expect(writes(h) == ["DELETE queue/901", "POST command"])
    }

    /// I1: a row that started moving again between the board and the tap (here: mid-batch) is skipped, not removed.
    @Test func recoveredRowIsSkippedMidBatch() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = (901...903).map { FakeLidarr.Queued(albumId: 41 + $0 - 901, size: 100, sizeleft: 50, status: "warning",
                                                         id: $0, artistId: 9, client: "Slskd") }
        }
        var watch = QueueStallWatch()
        let first = try await h.lidarrClient.queueDetails(albumIds: [])
        watch.observe(first, soulseekClients: Self.soulseek, at: t0)
        watch.observe(first, soulseekClients: Self.soulseek, at: t0.addingTimeInterval(60))
        let board = LidarrDownloads(first, soulseekClients: Self.soulseek, watch: watch, grabs: grabs(first),
                                    stallLimit: 60, now: t0.addingTimeInterval(60))
        #expect(board.stalled.map(\.id) == [901, 902, 903])
        // 902 picks up again while 901 is being restarted.
        h.server.with { s in
            if let i = s.queue.firstIndex(where: { $0.id == 902 }) { s.queue[i].sizeleft = 30 }
        }
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restartAll(board.restartable) == [.restarted, .skipped, .restarted])
        #expect(h.server.with { $0.removedFromQueue } == [901, 903])
    }

    @Test func bulkIsCappedAndSequential() async throws {
        let h = await Harness()
        let ids = Array(901...930)
        ownerQueue(h, ids: ids)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        let outcomes = await restarter.restartAll(try await rows(h).restartable)
        #expect(outcomes.count == 25)
        #expect(outcomes.allSatisfy { $0 == .restarted })
        #expect(writes(h) == ids.prefix(25).flatMap { ["DELETE queue/\($0)", "POST command"] })
        #expect(h.server.with { $0.removedFromQueue } == Array(ids.prefix(25)))
    }

    /// Minor M3: Lidarr gone away: Restart all stops after two unanswered in a row.
    @Test func bulkStopsWhenLidarrIsGone() async throws {
        let h = await Harness()
        ownerQueue(h, ids: Array(901...905))
        let board = try await rows(h)
        h.server.with { $0.down = true }
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restartAll(board.restartable) == [.unavailable, .unavailable])
        #expect(h.server.writes.isEmpty)
    }

    // MARK: - Restart (a Magpie request's download)

    private func searching() async throws -> (Harness, RequestID) {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()
        #expect(await h.state(id) == .searching)
        return (h, id)
    }

    private func failedRow(_ h: Harness, _ queueId: Int) async throws -> LidarrDownloads.Row {
        h.server.with { $0.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed",
                                                      tracked: "downloadFailed", id: queueId, artistId: 7, client: "SABnzbd")] }
        return try #require(try await rows(h).failed.first)
    }

    @Test func magpieRequestIsCounted() async throws {
        let (h, id) = try await searching()
        let row = try await failedRow(h, 901)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row) == .restarted)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "DELETE queue/901", "POST command"])
        #expect(h.server.writes.last { $0.httpMethod == "DELETE" }?.url?.query == Self.deleteQuery)
        let r = try #require(await h.request(id))
        #expect(r.stallRetries == 1)
        #expect(r.state == .searching)
        #expect(r.sourceStalledAt == nil)
    }

    @Test func magpieRequestLimitHolds() async throws {
        let (h, id) = try await searching()
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        for queueId in 901...905 {
            #expect(await restarter.restart(try await failedRow(h, queueId)) == .restarted)
            await h.runner.settle()
        }
        #expect(await h.request(id)?.stallRetries == 5)
        let sixth = try await failedRow(h, 906)
        let deletesBefore = h.server.writes.filter { $0.httpMethod == "DELETE" }.count
        #expect(await restarter.restart(sixth) == .limitReached)
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == deletesBefore)
        #expect(await h.request(id)?.stallRetries == 5)
    }

    /// Minor M7: one download carrying a Magpie request's album and an owner's album: the runner removes it (counted)
    /// and searches its album; the owner's album gets its own AlbumSearch.
    @Test func sharedDownloadThroughTheRunner() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [
            FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed", id: 901,
                              artistId: 7, client: "SABnzbd", downloadId: "multi"),
            FakeLidarr.Queued(albumId: 35, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed", id: 902,
                              artistId: 9, client: "SABnzbd", downloadId: "multi"),
        ] }
        let row = try #require(try await rows(h).failed.first { $0.id == 902 })
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row) == .restarted)
        await h.runner.settle()
        #expect(await h.request(id)?.stallRetries == 1)
        let searches = h.server.writeBodies().filter { $0.0 == "POST command" }.dropFirst().compactMap { $0.1["albumIds"] as? [Int] }
        #expect(Set(searches) == [[31], [35]])
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    /// Round 13 item 6 (D63): another app's download of an album a Magpie request is waiting on isn't the request's copy:
    /// it's removed directly (flagged), never counted toward the request's five removals.
    @Test func foreignNeverGoesThroughTheRunner() async throws {
        let (h, id) = try await searching()
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, status: "failed", tracked: "downloadFailed",
                                         id: 901, artistId: 7, client: "Slskd")]
            s.ungrabbed = ["dl-901"]
        }
        let row = try #require(try await rows(h).notStarted.first)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(row, allowForeign: true) == .restarted)
        await h.runner.settle()
        #expect((await h.request(id)?.stallRetries ?? 0) == 0)
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == 1)
    }
}
