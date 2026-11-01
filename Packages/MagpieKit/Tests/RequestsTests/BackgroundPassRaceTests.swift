import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// X5 fix round 1 (I1): at a cold background launch the app's initial load-then-poll and the BGAppRefreshTask's
/// pass call the runner together. One load from the store, one pass at a time; a stale list never overwrites one
/// already changed in memory (e.g. `addSent`), so no gated write is sent twice.
@Suite struct BackgroundPassRaceTests {
    @Test func concurrentLoadsAndTicksShareOneLoadAndOnePass() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask { if i.isMultiple(of: 2) { await h.runner.tick() } else { _ = await h.runner.load() } }
            }
        }
        #expect(await h.runner.storeLoads == 1, "the saved list is read once")
        #expect(await h.runner.passCount == 1, "ticks that overlap the first one (and its load) don't run a second pass")
    }

    @Test func aLoadFinishingLateNeverOverwritesProgressMadeMeanwhile() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-race-\(UUID().uuidString)")
        let h = await Harness(directory: dir)
        h.server.ownerHasArtist(albumMonitored: false)
        // Two callers race into load(); the first through goes on to start a request (a gated write).
        async let first: Bool = h.runner.load()
        async let second: Bool = h.runner.load()
        let id = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        _ = await (first, second)
        await h.runner.settle()
        #expect(await h.request(id) != nil, "the request made meanwhile is still there")
        let saved = try await h.store.load()
        #expect(saved.contains { $0.id == id })
        #expect(await h.runner.storeLoads == 1)
    }
}

/// X5 fix round 1: when iOS takes the background time back, the pass stops between steps, never mid-write.
@Suite struct BackgroundPassStopTests {
    @Test func aStoppedPassSendsNothingMoreAfterTheCurrentStep() async throws {
        let h = await Harness()
        h.server.ownerHasArtist(albumMonitored: false)
        _ = try await h.runner.tryRecording(h.recording(recAlbumOnly), tier: .standard)
        await h.runner.settle()   // on its way: a pass reads Lidarr's queue
        let before = h.server.transport.requests.count
        let passes = await h.runner.passCount
        await h.runner.tick(shouldStop: { true })
        #expect(h.server.transport.requests.count == before, "stopped before the first step: nothing sent")
        #expect(await h.runner.passCount == passes + 1)
        await h.runner.tick(shouldStop: { false })
        #expect(h.server.transport.requests.count > before, "a pass that isn't stopped polls as usual")
    }
}
