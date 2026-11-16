import Foundation
import MagpieCore
import Testing
@testable import Playback

/// Round 28 crash hunt (R28X): the offline stall grace (D349) against the order things happen in a tunnel. The stream's
/// buffer often runs dry while Magpie is still online (or only suspect), and the switch to offline comes after: the
/// stall then never got its grace and the song sat silent, its stream never failing, with nothing on the phone playing.
@MainActor
@Suite struct OfflineStallHuntTests {
    typealias Rig = OfflineTransitionTests.Rig
    typealias Sleeper = OfflineTransitionTests.Sleeper

    func rig(local: Set<String>, sleeper: Sleeper) -> Rig { OfflineTransitionTests().rig(local: local, sleeper: sleeper) }
    func songs(_ ids: [String]) -> [Song] { OfflineTransitionTests().songs(ids) }

    /// Polls until `condition`, yielding to the player's tasks; gives up only after 10 s on the continuous clock (a
    /// loaded machine may take many yields before another task runs, so no yield count bounds it).
    func poll(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    /// Stalled online, then the switch to automatic offline (the tunnel): the stall gets its grace from the switch, and
    /// past it the next song on the phone plays.
    @Test func stall_beforeGoingOfflineGetsItsGrace() async {
        let sleeper = Sleeper()
        let r = rig(local: ["s3"], sleeper: sleeper)
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        r.player.handle(.time(r.player.queue.current!.id, 10, duration: 200))
        r.player.handle(.stalled)   // online: waited out (D282)
        #expect(!r.player.isStalled)
        r.goOffline(manual: false)
        #expect(r.player.isStalled, "offline, the silent stream shows stopped")
        #expect(await poll { sleeper.count == 1 }, "the grace starts at the switch")
        sleeper.releaseAll()
        #expect(await poll { r.currentId == "s3" }, "past the grace the next song on the phone plays")
        #expect(r.player.isPlaying && r.currentURL?.isFileURL == true)
    }

    /// Sound came back before the switch: nothing is stalled, no grace starts.
    @Test func stall_thatClearedOnlineStartsNoGrace() async {
        let sleeper = Sleeper()
        let r = rig(local: ["s3"], sleeper: sleeper)
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        let id = r.player.queue.current!.id
        r.player.handle(.time(id, 10, duration: 200))
        r.player.handle(.stalled)
        r.player.handle(.time(id, 11, duration: 200))   // sound again
        r.goOffline(manual: false)
        for _ in 0..<50 { await Task.yield() }
        #expect(!r.player.isStalled && sleeper.count == 0 && r.currentId == "s1" && r.player.isPlaying)
    }

    /// Offline stall, back online before the grace runs out (it is left to pick up), still no sound, offline again: the
    /// stall gets its grace again rather than staying silent for good (found by `OfflineStallFuzzTests`).
    @Test func stall_graceEndingOnlineIsKeptForTheNextSwitch() async {
        let sleeper = Sleeper()
        let r = rig(local: ["s3"], sleeper: sleeper)
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        r.goOffline(manual: false)
        r.player.handle(.stalled)
        #expect(await poll { sleeper.count == 1 })
        r.goOnline()
        sleeper.releaseAll()   // the grace runs out online: left to pick up
        #expect(await poll { !r.player.isStalled })
        #expect(r.currentId == "s1" && r.player.isPlaying)
        r.goOffline(manual: false)   // still no sound
        #expect(r.player.isStalled, "the silent stream is waited out again")
        #expect(await poll { sleeper.count == 1 })
        sleeper.releaseAll()
        #expect(await poll { r.currentId == "s3" }, "past the grace the next song on the phone plays")
    }

    /// Paused after the online stall: the switch starts no grace (nothing is meant to be heard).
    @Test func stall_pausedBeforeGoingOfflineStartsNoGrace() async {
        let sleeper = Sleeper()
        let r = rig(local: ["s3"], sleeper: sleeper)
        r.player.play(songs(["s1", "s2", "s3"]), startAt: 0)
        r.player.handle(.stalled)
        r.player.toggle()   // pause
        r.goOffline(manual: false)
        for _ in 0..<50 { await Task.yield() }
        #expect(!r.player.isStalled && sleeper.count == 0 && r.currentId == "s1" && !r.player.isPlaying)
    }
}
