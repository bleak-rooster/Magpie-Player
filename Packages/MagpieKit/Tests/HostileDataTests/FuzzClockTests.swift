import Foundation
import MagpieTestSupport
import Testing

/// Round 28 crash hunt (R28X): the fuzz sweeps' clock counts the work's CPU time, not the time spent waiting for a core.
/// Six timing-bound checks failed with an app build alongside and passed on a quiet machine: the wall clock measured
/// the machine. Here the wait is made by another thread burning CPU while the measured body waits on it.
@Suite struct FuzzClockTests {
    /// Burns `seconds` of this thread's CPU time.
    static func burn(_ seconds: Double) -> Int {
        func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        let end = now() + seconds
        var sink = 0
        while now() < end { sink &+= 1 }
        return sink
    }

    /// Asynchronous work that only waits (as a sweep's case does while the machine is busy) measures as nothing.
    @Test func fuzzClock_waitingIsNotTheWork() async {
        let seconds = await FuzzClock.seconds {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    _ = Self.burn(0.4)   // someone else's work, on another thread
                    done.resume()
                }
            }
        }
        #expect(seconds < 0.2, "a wait counted as \(seconds) s of work")
    }

    /// Work still counts, synchronous or asynchronous, nested or not.
    @Test func fuzzClock_workCounts() async {
        let sync = FuzzClock.seconds { _ = Self.burn(0.2) }
        #expect(sync >= 0.19)
        var inner = 0.0
        let outer = await FuzzClock.seconds {
            inner = await FuzzClock.seconds {
                await Task.yield()
                _ = Self.burn(0.2)
            }
            _ = Self.burn(0.1)
        }
        #expect(inner >= 0.19 && inner < outer, "inner \(inner) s, outer \(outer) s")
        #expect(outer >= 0.29)
    }
}
