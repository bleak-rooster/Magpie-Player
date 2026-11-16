import Foundation
import Testing
@testable import MagpieCore

/// Round 28 crash hunt (R28X): the reachability machine never gets stuck down. Whatever happens, a machine that is
/// suspect or offline by itself, signed in, keeps a way back: a probe running, or a wake it asked for (D326). Stuck, it
/// would stay offline until the owner opened Magpie or tapped Try again. Seeded, deterministic, as the app drives it:
/// every `probeNow` starts a probe that ends (`probeFinished`) later, sometimes with a verdict.
@Suite struct ReachabilityLivenessFuzzTests {
    typealias Rng = ReachabilityFuzzTests.Rng

    @Test func machine_downAlwaysHasAWayBack() {
        var failures: [String] = []
        for seed in 1...2000 {
            if let failure = run(seed: UInt64(seed)) { failures.append(failure) }
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    func run(seed: UInt64) -> String? {
        var rng = Rng(state: seed &* 0x2545_F491_4F6C_DD1D)
        var m = ReachabilityMachine(automaticEnabled: rng.chance(80), manual: rng.chance(10))
        var now = 0.0
        /// When the probe the machine started ends, as the app's probe task always does.
        var probeEndsAt: Double?
        var log: [String] = []
        func apply(_ event: ReachabilityMachine.Event) {
            log.append("\(event)")
            let effects = m.handle(event, now: now)
            if effects.contains(.probeNow) { probeEndsAt = now + Double(rng.below(1600)) / 100 }
        }
        for step in 0..<300 {
            if let end = probeEndsAt, rng.chance(40) {
                now = max(now, end)
            } else if let wake = m.nextWake, rng.chance(50) {
                now = max(now, wake)
            } else {
                now += Double(rng.below(3000)) / 100
            }
            if let end = probeEndsAt, now >= end {
                probeEndsAt = nil
                switch rng.below(3) {
                case 0: apply(.answered)
                case 1: apply(.failure)
                default: break
                }
                apply(.probeFinished)
            } else if let wake = m.nextWake, now >= wake {
                apply(.tick)   // the app's timer fires at every wake it was given
            } else {
                switch rng.below(13) {
                case 0, 1, 2: apply(.failure)
                case 3: apply(.answered)
                case 4: apply(.authRejected)
                case 5: apply(.pathChanged(connected: rng.chance(60)))
                case 6: apply(.becameActive(lastAnswer: rng.chance(50) ? now - 100 : nil))
                case 7: apply(.manual(on: rng.chance(30)))
                case 8: apply(.automatic(enabled: rng.chance(70)))
                case 9: apply(.lowPower(rng.chance(30)))
                case 10: apply(rng.chance(85) ? .signedIn : .signedOut)
                case 11: apply(.probeRequested)
                default: apply(.tick)
                }
            }
            if m.probing != (probeEndsAt != nil) {
                return "seed \(seed) step \(step): the machine thinks a probe is \(m.probing ? "running" : "over") (\(log.suffix(8)))"
            }
            if m.hasSession, m.isDown, !m.probing, m.nextWake == nil {
                return "seed \(seed) step \(step) t=\(now): stuck \(m.state) with no probe and no wake (\(log.suffix(8)))"
            }
        }
        return nil
    }
}
