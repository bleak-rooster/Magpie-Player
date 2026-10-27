import Foundation
import Testing
import LidarrKit
import MagpieCore
@testable import Requests

/// Task H1: the device clock goes back while a Keep or Not for me is still going (a manual change, or a large
/// network time correction). Following it must not wait until the clock passes the last check again.
@Suite struct ClockChangeTests {
    /// The device clock is set back after a Not for me started going (a manual change, or a large network time
    /// correction): it is still followed on the next tick, not only once the clock passes the last check again.
    @Test func notForMeStillGoingIsFollowedAfterTheClockGoesBack() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await NotForMeTests.readyFind(h)
        h.server.with {
            $0.deleteFails503 = 1
            $0.rootsDownAfterDelete = true
        }
        #expect(try await h.runner.notForMe(id, permanentConfirmed: true) == .stillGoing)
        h.server.with {
            $0.rootsDown = false
            $0.rootsDownAfterDelete = false
        }
        h.clock.advance(-6 * 3600)
        await h.runner.tick()
        #expect(await h.state(id) == .dismissed)
    }

    /// The same for a Keep still moving.
    @Test func keepStillMovingIsFollowedAfterTheClockGoesBack() async throws {
        let h = await Harness(setup: Harness.findsSetup)
        let id = try await KeepTests.readyFind(h)
        h.library.state.withLock { $0.mainSongs[recSingleAndAlbum] = KeepTests.mainSong }
        h.server.with { $0.move = .hangs }
        #expect(try await h.runner.keep(id) == .stillMoving)
        h.server.with { $0.move = .completes }   // the move finishes on Lidarr's next read
        h.clock.advance(-6 * 3600)
        await h.runner.tick()
        let r = try #require(await h.request(id))
        #expect(r.state == .kept && r.keep == nil, "state \(r.state)")
    }
}
