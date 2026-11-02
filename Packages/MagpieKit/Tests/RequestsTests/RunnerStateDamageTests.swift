import Foundation
import Testing
import MagpieCore
import LidarrKit
@testable import Requests

/// Round 12 security M5: a damaged runner-state file fails closed, like the ledger and the change log.
@Suite struct RunnerStateDamageTests {
    typealias F = FindFlowTests

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "magpie-state-\(UUID().uuidString)/runner-state-x.json")
    }

    static func plant(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func asides(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt") }
    }

    /// A damaged file is renamed `.corrupt` (its bytes kept), never overwritten, and the fresh state says so.
    @Test func aDamagedFileIsKeptAsideAndMarked() throws {
        let url = Self.tempURL()
        try Self.plant(#"{"leases":[{"key":"artist:42""#, at: url)
        let state = try RunnerState.read(url)
        #expect(state.damagedAt != nil)
        #expect(state.leases.isEmpty)
        let aside = try #require(try Self.asides(url).first)
        #expect(aside.lastPathComponent == "runner-state-x.json.corrupt")
        #expect(String(decoding: try Data(contentsOf: aside), as: UTF8.self) == #"{"leases":[{"key":"artist:42""#)
        // The marker is on disk, so a later read (another runner) still sees it.
        #expect(try RunnerState.read(url).damagedAt != nil)
    }

    /// A second damaged file never replaces the first one kept aside.
    @Test func aSecondDamageKeepsTheFirstAside() throws {
        let url = Self.tempURL()
        try Self.plant("first", at: url)
        _ = try RunnerState.read(url)
        try Self.plant("second", at: url)
        _ = try RunnerState.read(url)
        let contents = try Self.asides(url).map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.sorted()
        #expect(contents == ["first", "second"])
    }

    /// A file that exists but can't be read is left alone and nothing is saved over it.
    @Test func anUnreadableFileRefusesAndIsNotOverwritten() throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)   // unreadable as a file
        #expect(throws: (any Error).self) { try RunnerState.read(url) }
        #expect(RunnerState.modify(url) { $0.migrated["y5"] = Date() } == nil)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// A missing file is a fresh start, not damage.
    @Test func aMissingFileIsFresh() throws {
        let state = try RunnerState.read(Self.tempURL())
        #expect(state == RunnerState())
    }

    /// After damage the Y5 migration's destructive step (clearing a legacy Keep lock) doesn't run again: the kept
    /// artist stays locked, and the runner says it needs a look.
    @Test func aDamagedStateNeverClearsALegacyLock() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await F.readyFind(h)
        try await h.ledger.update(artistId: 42) { $0.keptAt = h.clock.now }
        await h.runner.stop()
        let url = RunnerState.url(forRequests: RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!))
        try Self.plant("not json", at: url)
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        await again.runner.tick()
        #expect(try await F.entries(again).allSatisfy { $0.keptAt != nil }, "the lock stays")
        #expect(await again.runner.stateNeedsAttention)
        #expect(try Self.asides(url).count == 1)
    }

    /// An unreadable state file skips the pass: nothing is saved over it and nothing is sent.
    @Test func anUnreadableStateSkipsThePass() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        _ = try await F.readyFind(h)
        await h.runner.stop()
        let url = RunnerState.url(forRequests: RequestStore.defaultURL(in: h.dir, instance: h.ledger.instance!))
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let writesBefore = h.server.writes.count
        let again = await Harness(directory: h.dir, lidarr: h.server, setup: Harness.findsSetup)
        #expect(await !again.runner.load())
        await again.runner.tick()
        #expect(h.server.writes.count == writesBefore)
    }
}
