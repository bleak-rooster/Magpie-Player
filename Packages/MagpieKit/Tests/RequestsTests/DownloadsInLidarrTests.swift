import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Round 12 item 6 (D49): Settings › Downloads in Lidarr. The whole queue sorted into Active, Stalled and Failed (with a
/// request-independent stall watch), and Restart: `DELETE /queue/{id}` in the one shape (the gate's `queueRestartAny`)
/// then an AlbumSearch, one at a time, at most 25 per tap; a Magpie request's download goes through the runner, so its
/// five-removal count stays true.
@Suite struct DownloadsInLidarrTests {
    static let deleteQuery = "removeFromClient=true&blocklist=true&skipRedownload=true"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func item(_ id: Int, album: Int = 41, client: String = "SABnzbd", sizeleft: Double = 50,
                      status: String = "downloading", tracked: String = "downloading", trackedStatus: String = "ok",
                      download: String? = nil, messages: [String] = []) -> QueueItem {
        QueueItem(id: id, albumId: album, artistId: 9, downloadClient: client, downloadId: download ?? "dl-\(id)",
                  size: 100, sizeleft: sizeleft, status: status, trackedDownloadState: tracked, statusMessages: messages,
                  trackedDownloadStatus: trackedStatus, title: "Release \(id)", artistName: "Owner Artist",
                  albumTitle: "Album \(album)")
    }

    private func board(_ items: [QueueItem], watch: QueueStallWatch = QueueStallWatch(), at now: Date? = nil,
                       limit: TimeInterval = 60) -> LidarrDownloads {
        LidarrDownloads(items, soulseekClients: ["slskd"], watch: watch, stallLimit: limit, now: now ?? t0)
    }

    // MARK: - Classification

    @Test func sortsIntoActiveStalledFailed() {
        let items = [
            item(1),                                                                          // downloading
            item(2, status: "completed", tracked: "importBlocked", trackedStatus: "warning",
                 messages: ["No files found are eligible for import"]),                       // failed
            item(3, status: "failed", tracked: "downloadFailed", trackedStatus: "error"),     // failed
            item(4, sizeleft: 0, status: "completed", tracked: "importing"),                  // active, not restartable
            item(5, status: "warning", trackedStatus: "warning"),                             // failed (not Soulseek)
            item(6, client: "Slskd", status: "warning", trackedStatus: "warning"),            // Soulseek warning: active
            item(7, status: "queued"),                                                        // active
        ]
        let b = board(items)
        #expect(b.active.map(\.id) == [1, 4, 6, 7])
        #expect(b.stalled.isEmpty)
        #expect(b.failed.map(\.id) == [2, 3, 5])
        #expect(b.failed.first?.message == "No files found are eligible for import")
        #expect(b.active.first { $0.id == 4 }?.canRestart == false)
        #expect(b.active.first { $0.id == 4 }?.phase == .importing)
        #expect(b.failed.filter { !$0.canRestart }.isEmpty)
        #expect(b.restartable.map(\.id) == [2, 3, 5])
        #expect(b.active.first?.artist == "Owner Artist")
        #expect(b.active.first?.album == "Album 41")
        #expect(b.active.first?.client == "SABnzbd")
        #expect(b.active.first?.progress == 0.5)
    }

    /// A failed row whose download is shared with a copy that's importing can't be restarted (it would take that along).
    @Test func sharedWithAnImportIsNotRestartable() {
        let b = board([item(1, status: "failed", tracked: "downloadFailed", download: "x"),
                       item(2, album: 42, sizeleft: 0, status: "completed", tracked: "importing", download: "x"),
                       item(3, status: "failed", tracked: "downloadFailed", download: nil)])
        #expect(b.failed.first { $0.id == 1 }?.canRestart == false)
        #expect(b.restartable.map(\.id) == [3])
    }

    /// Stalled: no change past the stall limit, whoever asked for it; the clock starts when the screen first sees it,
    /// and any change starts it over.
    @Test func stallWatchIsRequestIndependent() {
        var watch = QueueStallWatch()
        let a = item(1), b = item(2, client: "Slskd")
        watch.observe([a, b], at: t0)
        #expect(board([a, b], watch: watch, at: t0.addingTimeInterval(59)).stalled.isEmpty)
        var moved = b
        moved.sizeleft = 40
        watch.observe([a, moved], at: t0.addingTimeInterval(30))
        let later = board([a, moved], watch: watch, at: t0.addingTimeInterval(60))
        #expect(later.stalled.map(\.id) == [1])
        #expect(later.stalled.first?.canRestart == true)
        #expect(later.active.map(\.id) == [2])
        // Gone from the queue: forgotten, so it starts over if it comes back.
        watch.observe([moved], at: t0.addingTimeInterval(61))
        watch.observe([a, moved], at: t0.addingTimeInterval(62))
        #expect(board([a, moved], watch: watch, at: t0.addingTimeInterval(100)).stalled.map(\.id) == [2])
        #expect(watch.unchangedFor(1, at: t0.addingTimeInterval(100)) == 38)
    }

    /// The signature is X6's (`StallWatch.Signature`): same fields, so both watches agree on what "changed" means.
    @Test func signatureIsShared() {
        let a = item(1)
        #expect(StallWatch.Signature(a) == QueueSignature(a))
        var b = a
        b.status = "Queued"
        #expect(QueueSignature(b) != QueueSignature(a))
    }

    // MARK: - Restart (owner's downloads)

    private func ownerQueue(_ h: Harness, ids: [Int]) {
        h.server.with { s in
            s.queue = ids.map { FakeLidarr.Queued(albumId: 41 + $0 - 901, size: 100, sizeleft: 50, status: "failed",
                                                  tracked: "downloadFailed", id: $0, artistId: 9, client: "SABnzbd") }
        }
    }

    private func writes(_ h: Harness) -> [String] {
        h.server.writes.map { "\($0.httpMethod!) \($0.url!.path.replacingOccurrences(of: "/lidarr/api/v1/", with: ""))" }
    }

    /// The owner's own failed download: the exact delete, then an AlbumSearch for its album.
    @Test func restartsAnOwnersDownload() async throws {
        let h = await Harness()
        ownerQueue(h, ids: [901])
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(901) == .restarted)
        #expect(writes(h) == ["DELETE queue/901", "POST command"])
        let delete = try #require(h.server.writes.first)
        #expect(delete.url?.query == Self.deleteQuery)
        let search = try #require(h.server.writeBodies().last)
        #expect(search.1["name"] as? String == "AlbumSearch")
        #expect(search.1["albumIds"] as? [Int] == [41])
        let log = await h.gate.changeLog()
        #expect(log.map(\.method) == ["DELETE", "POST"])
    }

    /// Refusals: gone, importing, and "Allow changes" off. Nothing is written.
    @Test func refusalsSendNothing() async throws {
        let h = await Harness()
        h.server.with { s in
            s.queue = [FakeLidarr.Queued(albumId: 41, size: 100, sizeleft: 0, status: "completed", tracked: "importing",
                                         id: 902, artistId: 9, client: "SABnzbd")]
        }
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(901) == .gone)
        guard case .refused = await restarter.restart(902) else { Issue.record("importing restarted"); return }
        await h.gate.setEnabled(false)
        ownerQueue(h, ids: [903])
        #expect(await restarter.restart(903) == .changesOff)
        #expect(h.server.writes.isEmpty)
    }

    /// Restart all: at most 25 per tap, one at a time (each delete and its search before the next delete).
    @Test func bulkIsCappedAndSequential() async throws {
        let h = await Harness()
        let ids = Array(901...930)
        ownerQueue(h, ids: ids)
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        let outcomes = await restarter.restartAll(ids)
        #expect(outcomes.count == 25)
        #expect(outcomes.allSatisfy { $0 == .restarted })
        let expected = ids.prefix(25).flatMap { ["DELETE queue/\($0)", "POST command"] }
        #expect(writes(h) == expected)
        #expect(h.server.with { $0.removedFromQueue } == Array(ids.prefix(25)))
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

    /// A Magpie request's download goes through the runner: counted like Find another copy, and the search is the
    /// runner's own (one AlbumSearch, not two).
    @Test func magpieRequestIsCounted() async throws {
        let (h, id) = try await searching()
        h.server.with { $0.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, id: 901, artistId: 7,
                                                      client: "SABnzbd")] }
        await h.runner.tick()
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        #expect(await restarter.restart(901) == .restarted)
        await h.runner.settle()
        #expect(h.server.writeBodies().map(\.0) == ["PUT album/monitor", "POST command", "DELETE queue/901", "POST command"])
        #expect(h.server.writes.last { $0.httpMethod == "DELETE" }?.url?.query == Self.deleteQuery)
        let r = try #require(await h.request(id))
        #expect(r.stallRetries == 1)
        #expect(r.state == .searching)
        #expect(r.sourceStalledAt == nil)
    }

    /// The request's five removals are used up: the screen doesn't remove a sixth (the count stays true).
    @Test func magpieRequestLimitHolds() async throws {
        let (h, id) = try await searching()
        let restarter = LidarrDownloadRestarter(lidarr: h.lidarrClient, gate: h.gate, runner: h.runner)
        for queueId in 901...905 {
            h.server.with { $0.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, id: queueId, artistId: 7,
                                                          client: "SABnzbd")] }
            #expect(await restarter.restart(queueId) == .restarted)
            await h.runner.settle()
        }
        #expect(await h.request(id)?.stallRetries == 5)
        h.server.with { $0.queue = [FakeLidarr.Queued(albumId: 31, size: 100, sizeleft: 60, id: 906, artistId: 7,
                                                      client: "SABnzbd")] }
        let deletesBefore = h.server.writes.filter { $0.httpMethod == "DELETE" }.count
        #expect(await restarter.restart(906) == .limitReached)
        #expect(h.server.writes.filter { $0.httpMethod == "DELETE" }.count == deletesBefore)
        #expect(await h.request(id)?.stallRetries == 5)
    }
}
