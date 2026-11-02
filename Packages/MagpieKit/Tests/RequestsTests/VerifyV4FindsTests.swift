import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Verify V4 (docs/FLOWS.md §3g, §3j): Finds behaviours the earlier suites didn't pin down.
@Suite struct VerifyV4FindsTests {
    /// §3g Keep "Failed move: ... 5 restore writes ends in Needs attention, and nothing more is written."
    /// The move fails and every put-back write goes unanswered (a timeout, so it is retried on later ticks): at
    /// most `keepRestoreLimit` (5) put-back writes are ever sent, then needs attention, and later ticks send none.
    @Test func restoreWritesStopAtFive() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)
        h.server.with { $0.move = .hangs }
        #expect(try await h.runner.keep(id) == .stillMoving)
        // Lidarr's move failed and reverted the path; every put-back from now on times out.
        h.server.with { s in
            for i in s.commands.indices where s.commands[i].name == "BulkMoveArtist" { s.commands[i].status = "failed" }
            s.artists[0].root = "/music/samples"
            s.artists[0].path = nil
            s.editorTimesOut = 1_000
        }
        let editorLog = { await h.gate.changeLog().filter { $0.path == "/api/v1/artist/editor" } }
        for _ in 0..<12 {
            h.clock.advance(RequestRunner.keepCheckInterval)
            await h.runner.tick()
        }
        let log = await editorLog()
        #expect(log.count == 1 + RequestRunner.keepRestoreLimit, "the move, then exactly 5 put-backs")
        #expect(RequestRunner.keepRestoreLimit == 5)
        #expect(log.dropFirst().allSatisfy { $0.bodySummary.contains(#""applyTags":"add""#) })
        let r = try #require(await h.request(id))
        #expect(r.keepNeedsAttention && r.keep == nil)
        // The ledger keeps saying keeping (C5: treated as kept): Not for me will never delete it.
        #expect(try await h.ledger.entries.filter { $0.lidarrArtistId == 42 }.allSatisfy(\.isKeptOrKeeping))
    }

    /// §3g Bring in more "offered ids only": ids the sheet never offered, or that aren't eligible now (already
    /// monitored, the owner's own, not this artist's), never come in, even when passed as `offered`.
    @Test func bringInSendsOnlyEligibleOfferedIds() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await BringInMoreTests.keptFind(h)
        let before = h.server.writes.count
        let result = try await h.runner.bringIn(id, choice: .everything, offered: [999, 50, 55, 52], follow: false)
        #expect(result.albums == 1)
        let writes = Array(h.server.writeBodies().dropFirst(before))
        #expect(writes.map(\.0) == ["PUT album/monitor", "POST command"])
        #expect(writes.first?.1["albumIds"] as? [Int] == [52])
        #expect(writes.last?.1["albumIds"] as? [Int] == [52])
    }

    /// §3g Bring in more room = min(20, 5 − active): with 4 places taken, one release comes in; it then takes a
    /// place itself (FL4), so a further Bring in more has no room and a Try is refused.
    @Test func bringInRoomIsFiveMinusActiveAndCounts() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await BringInMoreTests.keptFind(h)
        let mine = try await h.store.load()
        let active = (0..<4).map { i in
            var r = MagpieRequest(recording: h.recording(mbid(300 + i)), tier: .standard, createdAt: h.clock.now)
            r.state = .searching
            return r
        }
        try await h.store.save(mine + active)
        await h.runner.stop()
        let busy = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        let result = try await busy.runner.bringIn(id, choice: .everything, follow: false)
        #expect(result.albums == 1)
        #expect(h.server.writeBodies().last { $0.0 == "PUT album/monitor" }?.1["albumIds"] as? [Int] == [54], "the newest")
        #expect(await busy.runner.activeCount == 5)
        await #expect(throws: RequestRunner.BringInError.tooMany) {
            _ = try await busy.runner.bringIn(id, choice: .everything, follow: false)
        }
        await #expect(throws: RequestRunner.TryError.tooMany) {
            _ = try await busy.runner.tryRecording(busy.recording(recAlbumOnly), tier: .standard)
        }
    }

    // MARK: - Requests file (§3j)

    /// A requests file that can't be decoded is moved aside, never overwritten; one that can't be read right now
    /// throws and is left exactly as it was.
    @Test func damagedRequestsFileIsMovedAsideAndUnreadableIsLeftAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-v4-req-\(UUID().uuidString)")
        let url = RequestStore.defaultURL(in: dir, instance: "abc")
        #expect(url.path.hasSuffix("Magpie/requests-abc.json"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = RequestStore(fileURL: url)
        #expect(try await store.load().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let aside = try #require(names.first { $0.hasPrefix("requests-abc.json.unreadable-") })
        #expect(try String(contentsOf: url.deletingLastPathComponent().appending(path: aside), encoding: .utf8) == "not json")

        // Unreadable (a folder where the file should be): throws, and nothing is moved or replaced.
        let blocked = RequestStore.defaultURL(in: dir, instance: "def")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        await #expect(throws: RequestStoreError.unavailable) { _ = try await RequestStore(fileURL: blocked).load() }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blocked.path, isDirectory: &isDir) && isDir.boolValue)
    }
}
