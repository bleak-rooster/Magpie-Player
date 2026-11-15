import Foundation
import Testing
@testable import MagpieCore

/// Round 28 O1 (owner, 2026-11-15): seeded random events through the reachability machine (plan §7.3). Deterministic;
/// each failure names its seed and step.
@Suite struct ReachabilityFuzzTests {
    /// SplitMix64: the same seed gives the same run on every machine.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    @Test func machine_randomEventsKeepInvariants() {
        var failures: [String] = []
        for seed in 1...1000 {
            if let failure = run(seed: UInt64(seed)) { failures.append(failure) }
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// One run of 200 events; nil when every invariant held.
    func run(seed: UInt64) -> String? {
        var rng = Rng(state: seed)
        var m = ReachabilityMachine(automaticEnabled: rng.chance(80))
        var now = 0.0
        var inFlight = 0
        var probeEndsAt: Double?
        var lastAnswer: Double?
        /// The first failure since the last answer, sign-in or manual change: the window may not start before it.
        var firstFailure: Double?
        var pathDownSince: Double?
        for step in 0..<200 {
            func fail(_ why: String) -> String { "seed \(seed) step \(step) t=\(now): \(why) (state \(m.state))" }
            func apply(_ event: ReachabilityMachine.Event) -> String? {
                let previous = m.state
                let wasManual = previous == .manualOffline
                let effects = m.handle(event, now: now)
                // The test's own record of what happened.
                switch event {
                case .answered, .authRejected:
                    if !wasManual { lastAnswer = now; firstFailure = nil }
                case .failure where m.hasSession && !wasManual:
                    if firstFailure == nil { firstFailure = now }
                case .signedOut, .signedIn, .manual:
                    if m.state == .online || m.state == .manualOffline { firstFailure = nil }
                case .pathChanged(let connected):
                    pathDownSince = connected ? nil : (pathDownSince ?? now)
                case .probeFinished:
                    if !m.probing { inFlight = 0; probeEndsAt = nil }
                default: break
                }
                // Invariants.
                if m.state == .manualOffline || wasManual {
                    if effects.contains(.probeNow) { return "manual offline asked for a probe after \(event)" }
                    if effects.contains(where: { if case .scheduleProbe = $0 { true } else { false } }) {
                        return "manual offline scheduled a probe after \(event)"
                    }
                }
                if case .automaticOffline = m.state, !m.automaticEnabled { return "offline with Go offline automatically off" }
                if case .automaticOffline = m.state, !m.hasSession { return "offline with no session" }
                if effects.contains(.goOffline) {
                    defer { if firstFailure == nil { firstFailure = now } }   // unanswered from here on
                    guard m.automaticEnabled else { return "went offline in Off" }
                    let byPath = pathDownSince.map { now - $0 >= ReachabilityMachine.pathGrace - 1e-9 } ?? false
                    var byWindow = false
                    if case .suspect(let since) = previous {
                        byWindow = now - since >= ReachabilityMachine.window - 1e-9 && (firstFailure.map { since >= $0 - 1e-9 } ?? false)
                    }
                    if !byPath, !byWindow { return "went offline without 30 s unanswered or 2 s with no path (after \(event))" }
                }
                if case .answered = event, !wasManual, m.state != .online { return "an answer didn't bring it online" }
                if effects.contains(.probeNow) {
                    inFlight += 1
                    if inFlight > 1 { return "two probes in flight" }
                    probeEndsAt = now + Double(rng.below(1300)) / 100
                }
                for case .scheduleProbe(let at) in effects {
                    let gap = at - now
                    if !(gap > 0 && gap <= 240) { return "a probe scheduled \(gap) s ahead" }
                }
                if let wake = m.nextWake, wake.isNaN { return "a wake that isn't a time" }
                return nil
            }
            // Time moves on: to the machine's next wake, to a running probe's end, or by a random amount.
            if let end = probeEndsAt, rng.chance(40) {
                now = max(now, end)
            } else if let wake = m.nextWake, rng.chance(50) {
                now = max(now, wake)
            } else {
                now += Double(rng.below(4000)) / 100
            }
            let event: ReachabilityMachine.Event
            if let end = probeEndsAt, now >= end {
                probeEndsAt = nil
                inFlight = 0
                // The probe's verdict first (sometimes), then its end.
                switch rng.below(3) {
                case 0: if let message = apply(.answered) { return fail(message) }
                case 1: if let message = apply(.failure) { return fail(message) }
                default: break
                }
                event = .probeFinished
            } else {
                switch rng.below(16) {
                case 0, 1, 2: event = .failure
                case 3: event = .answered
                case 4: event = .authRejected
                case 5: event = .pathChanged(connected: rng.chance(50))
                case 6: event = .becameActive(lastAnswer: lastAnswer)
                case 7, 8, 9: event = .tick
                case 10: event = .manual(on: rng.chance(30))
                case 11: event = .automatic(enabled: rng.chance(70))
                case 12: event = .lowPower(rng.chance(30))
                case 13: event = rng.chance(85) ? .signedIn : .signedOut
                case 14: event = .probeRequested
                default: event = .probeFinished
                }
            }
            if let message = apply(event) { return fail(message) }

        }
        return nil
    }
}
