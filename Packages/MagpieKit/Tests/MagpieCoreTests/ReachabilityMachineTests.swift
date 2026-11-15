import Foundation
import Testing
@testable import MagpieCore

/// Round 28 O1 (owner, 2026-11-15): the reachability machine, every row of plan §7.1 (D324, D326, D327, D330).
/// Time is seconds on the machine's own clock; nothing sleeps.
@Suite struct ReachabilityMachineTests {
    typealias M = ReachabilityMachine

    /// Signed in and online at t = 0.
    func online(automatic: Bool = true) -> M {
        var m = M(automaticEnabled: automatic)
        _ = m.handle(.signedIn, now: 0)
        return m
    }

    /// Ticks at every wake the machine asks for up to `until`, finishing each probe it starts at once (a probe that
    /// failed). Returns the times each probe started.
    @discardableResult
    func run(_ m: inout M, until: Double, probesFail: Bool = true) -> [Double] {
        var probes: [Double] = []
        var guardCount = 0
        while let wake = m.nextWake, wake <= until, guardCount < 10_000 {
            guardCount += 1
            let effects = m.handle(.tick, now: wake)
            if effects.contains(.probeNow) {
                probes.append(wake)
                if probesFail { _ = m.handle(.failure, now: wake) }
                _ = m.handle(.probeFinished, now: wake)
            }
        }
        return probes
    }

    // MARK: - 30 seconds (D324)

    @Test func machine_goesOfflineAt30sNotBefore() {
        var m = online()
        let fx = m.handle(.failure, now: 0)
        #expect(m.state == .suspect(since: 0))
        #expect(fx.contains(.scheduleProbe(at: 5)) && fx.contains(.scheduleTick(at: 30)))
        #expect(!m.handle(.tick, now: 29.9).contains(.goOffline))
        #expect(m.state == .suspect(since: 0))
        let at30 = m.handle(.tick, now: 30)
        #expect(at30.contains(.goOffline))
        #expect(m.state == .automaticOffline(since: 30))
    }

    @Test func machine_offlineByTimerWithoutAnotherFailure() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        // Only the machine's own wakes, and probes that end without a verdict (no failure, no answer).
        var wentOffline: Double?
        while let wake = m.nextWake, wake <= 40, wentOffline == nil {
            let fx = m.handle(.tick, now: wake)
            if fx.contains(.probeNow) { _ = m.handle(.probeFinished, now: wake) }
            if fx.contains(.goOffline) { wentOffline = wake }
        }
        #expect(wentOffline == 30, "decided by the timer at the mark, not by a later failure")
    }

    @Test func machine_answerResetsTheWindow() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        let fx = m.handle(.answered, now: 20)
        #expect(m.state == .online && fx.contains(.cancelProbes) && !fx.contains(.goOnline))
        #expect(m.nextWake == nil)
        _ = m.handle(.failure, now: 25)
        #expect(!m.handle(.tick, now: 30).contains(.goOffline))
        #expect(!m.handle(.tick, now: 54.9).contains(.goOffline))
        #expect(m.handle(.tick, now: 55).contains(.goOffline))
    }

    @Test func machine_twoQuickFailuresStaySuspect() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.failure, now: 1)
        #expect(m.state == .suspect(since: 0), "a second failure keeps the first one's time")
        #expect(m.handle(.tick, now: 5) == [.probeNow])
        #expect(m.handle(.failure, now: 6).isEmpty)
        _ = m.handle(.probeFinished, now: 6)
        _ = m.handle(.failure, now: 7)
        #expect(m.state == .suspect(since: 0), "no reconnect-count shortcut (supersedes D46's 2 reconnects)")
    }

    // MARK: - Manual and Off (D323, D327)

    @Test func machine_manualNeverProbes() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        let on = m.handle(.manual(on: true), now: 1)
        #expect(m.state == .manualOffline && on.contains(.cancelProbes))
        let events: [M.Event] = [.failure, .tick, .probeRequested, .pathChanged(connected: false), .pathChanged(connected: true),
                                 .becameActive(lastAnswer: nil), .answered, .authRejected, .probeFinished, .automatic(enabled: false),
                                 .automatic(enabled: true), .lowPower(true), .tick]
        for (i, event) in events.enumerated() {
            let fx = m.handle(event, now: Double(10 + i * 40))
            #expect(!fx.contains(.probeNow) && !fx.contains { if case .scheduleProbe = $0 { true } else { false } },
                    "\(event) in manual offline")
            #expect(m.state == .manualOffline)
        }
        #expect(m.nextWake == nil)
        _ = m.handle(.signedOut, now: 1000)
        #expect(m.state == .manualOffline, "Offline mode is the owner's preference: signing out keeps it")
    }

    @Test func machine_manualOffBackToOnline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        #expect(m.state == .automaticOffline(since: 30))
        #expect(m.handle(.manual(on: true), now: 31).contains(.goOnline), "manual takes over from automatic")
        // Fix round 1 (design H1): leaving manual stays offline (automatically) until a check answers, so the screens
        // say "Trying…" and never "Back online." before the login has worked.
        #expect(m.handle(.manual(on: false), now: 40) == [.goOffline, .probeNow])
        #expect(m.state == .automaticOffline(since: 40))
        _ = m.handle(.failure, now: 41)
        _ = m.handle(.probeFinished, now: 41)
        #expect(m.state == .automaticOffline(since: 40), "a failed check: straight on offline, nothing in between")
        #expect(m.handle(.answered, now: 50).contains(.goOnline) && m.state == .online)
        // With Go offline automatically off it goes online at once (Off never offline); the app logs in.
        var off = online(automatic: false)
        _ = off.handle(.manual(on: true), now: 0)
        #expect(off.handle(.manual(on: false), now: 1).isEmpty && off.state == .online)
        // With no session (signed out in Offline mode) it just leaves manual.
        var none = M(manual: true)
        #expect(none.handle(.manual(on: false), now: 0).isEmpty && none.state == .online)
    }

    @Test func machine_offModeNeverOffline() {
        var m = online(automatic: false)
        let fx = m.handle(.failure, now: 0)
        #expect(!fx.contains { if case .scheduleTick = $0 { true } else { false } })
        _ = m.handle(.pathChanged(connected: false), now: 1)
        let probes = run(&m, until: 2000)
        #expect(m.state == .suspect(since: 0), "Off: never offline, suspect holds")
        #expect(probes.count > 10, "probes still run to clear suspect")
        #expect(m.handle(.answered, now: 2001).contains(.cancelProbes) && m.state == .online)
    }

    @Test func machine_automaticDisabledWhileOfflineGoesOnline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        let fx = m.handle(.automatic(enabled: false), now: 40)
        #expect(fx.contains(.goOnline))
        #expect(m.state == .suspect(since: 40), "Off restarts suspect from now")
        // Turned back on: the window runs from when Off began.
        #expect(m.handle(.automatic(enabled: true), now: 50) == [.scheduleTick(at: 70)])
        #expect(m.handle(.tick, now: 70).contains(.goOffline))
    }

    // MARK: - Schedule (D326)

    @Test func machine_scheduleSuspectThenOffline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        let probes = run(&m, until: 1300)
        #expect(Array(probes.prefix(3)) == [5, 15, 25], "while suspect: 5 s, then every 10 s")
        #expect(m.state != .online)
        let offline = Array(probes.dropFirst(3))
        // Offline at 30: every 30 s for the first 5 minutes (ten probes), every 60 s to 15 minutes, then every 2 minutes.
        #expect(Array(offline.prefix(10)) == stride(from: 60.0, through: 330, by: 30).map { $0 })
        let gaps = zip(offline.dropFirst(), offline).map { $0 - $1 }
        #expect(gaps.prefix(9).allSatisfy { $0 == 30 })
        #expect(gaps.dropFirst(9).prefix(10).allSatisfy { $0 == 60 })
        #expect(offline.contains(930) && offline.contains(1050), "after 15 minutes offline, every 2 minutes: \(offline)")
        #expect(gaps.last == 120)
    }

    @Test func machine_lowPowerDoublesIntervals() {
        var m = online()
        _ = m.handle(.lowPower(true), now: 0)
        #expect(m.handle(.failure, now: 0).contains(.scheduleProbe(at: 10)))
        let probes = run(&m, until: 200)
        #expect(probes == [10, 90, 150], "10 s; offline at 30 (the window doesn't double), then every 60 s: \(probes)")
        // Suspect's 10 s becomes 20 s (seen with Off, where suspect lasts past the window).
        var off = online(automatic: false)
        _ = off.handle(.lowPower(true), now: 0)
        _ = off.handle(.failure, now: 0)
        #expect(run(&off, until: 25) == [10])
        #expect(run(&off, until: 95) == [30, 90], "20 s while suspect; past 30 s Off follows the slow schedule, doubled")
        _ = m.handle(.lowPower(false), now: 200)
        #expect(run(&m, until: 300).first == 210.0, "the next probe was already set; later ones are 30 s again")
    }

    @Test func machine_pathReturnProbesNow() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        _ = m.handle(.pathChanged(connected: false), now: 40)
        let back = m.handle(.pathChanged(connected: true), now: 41)
        #expect(back == [.scheduleProbe(at: 43)], "debounced 2 s")
        // A change of interface (Wi-Fi to mobile data) moves the probe again.
        #expect(m.handle(.pathChanged(connected: true), now: 42) == [.scheduleProbe(at: 44)])
        #expect(m.nextWake == 44)
        #expect(m.handle(.tick, now: 44) == [.probeNow])
        #expect(m.handle(.pathChanged(connected: true), now: 45) == [.scheduleProbe(at: 47)])
        #expect(m.handle(.tick, now: 47).isEmpty, "never two probes at once")
    }

    @Test func machine_tryAgainProbesNowOnlyWhenDown() {
        var m = online()
        #expect(m.handle(.probeRequested, now: 0).isEmpty, "online: pull to refresh just reloads")
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        #expect(m.handle(.probeRequested, now: 31) == [.probeNow])
        #expect(m.handle(.probeRequested, now: 32).isEmpty, "one at a time")
    }

    // MARK: - Coming to the front (D326)

    @Test func machine_becameActiveRestartsWindow() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        let active = m.handle(.becameActive(lastAnswer: nil), now: 25)
        #expect(m.state == .suspect(since: 25) && active.contains(.probeNow) && active.contains(.scheduleTick(at: 55)))
        _ = m.handle(.probeFinished, now: 25)
        #expect(!m.handle(.tick, now: 30).contains(.goOffline))
        #expect(m.handle(.tick, now: 55).contains(.goOffline))
        // Offline: coming to the front probes now and stays offline.
        #expect(m.handle(.becameActive(lastAnswer: nil), now: 70) == [.probeNow])
        #expect(m.state == .automaticOffline(since: 55))
    }

    @Test func machine_becameActiveOnlinePingsWhenStale() {
        var m = online()
        #expect(m.handle(.becameActive(lastAnswer: 100), now: 140).isEmpty, "answered 40 s ago")
        #expect(m.handle(.becameActive(lastAnswer: 100), now: 161) == [.probeNow], "no answer for over 60 s: one ping")
        #expect(m.state == .online)
        _ = m.handle(.probeFinished, now: 162)
        var none = M()
        #expect(none.handle(.becameActive(lastAnswer: nil), now: 0).isEmpty, "no session: nothing")
    }

    /// The window counts only while Magpie runs: a tick that comes long after its mark (iOS suspended the app) restarts
    /// the window and probes instead of going offline.
    @Test func machine_lateTickRestartsWindow() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        let fx = m.handle(.tick, now: 600)
        #expect(!fx.contains(.goOffline) && fx.contains(.probeNow))
        #expect(m.state == .suspect(since: 600))
    }

    // MARK: - Answers (D325)

    @Test func machine_authRejectedIsOnline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        #expect(m.handle(.authRejected, now: 3).contains(.cancelProbes))
        #expect(m.state == .online)
        _ = m.handle(.failure, now: 10)
        _ = m.handle(.tick, now: 40)
        let fx = m.handle(.authRejected, now: 41)
        #expect(fx.contains(.goOnline) && m.state == .online, "the server answered: the sign-in error, never offline")
    }

    @Test func machine_answeredFromOfflineGoesOnline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        let fx = m.handle(.answered, now: 61)
        #expect(fx.contains(.goOnline) && fx.contains(.cancelProbes) && m.state == .online && m.nextWake == nil)
    }

    // MARK: - No connection at all (Q1)

    @Test func machine_noConnectionGoesOfflineAtOnce() {
        var m = online()
        #expect(m.handle(.pathChanged(connected: false), now: 0) == [.scheduleTick(at: 2)])
        #expect(m.handle(.tick, now: 1.9).isEmpty)
        let fx = m.handle(.tick, now: 2)
        #expect(fx.contains(.goOffline) && m.state == .automaticOffline(since: 2))
        // Probes on the path's return (and the slow schedule).
        #expect(m.handle(.pathChanged(connected: true), now: 10) == [.scheduleProbe(at: 12)])
        // A blip shorter than 2 s changes nothing.
        var blip = online()
        _ = blip.handle(.pathChanged(connected: false), now: 0)
        _ = blip.handle(.pathChanged(connected: true), now: 1)
        #expect(blip.handle(.tick, now: 2).isEmpty && blip.state == .online)
        // A failure with no path for 2 s already: offline at once, not 30 s later.
        var launch = M()
        _ = launch.handle(.pathChanged(connected: false), now: 0)
        _ = launch.handle(.signedIn, now: 5)
        #expect(launch.state == .automaticOffline(since: 5), "a launch with no network: the phone's music at once")
        // Off: never.
        var off = online(automatic: false)
        _ = off.handle(.pathChanged(connected: false), now: 0)
        #expect(off.handle(.tick, now: 5).isEmpty && off.state == .online)
    }

    // MARK: - Sign-out

    @Test func machine_signedOutCancelsAndStartsOnline() {
        var m = online()
        _ = m.handle(.failure, now: 0)
        _ = m.handle(.tick, now: 30)
        let fx = m.handle(.signedOut, now: 31)
        #expect(fx.contains(.cancelProbes) && fx.contains(.goOnline) && m.state == .online && m.nextWake == nil)
        #expect(m.handle(.failure, now: 32).isEmpty, "no session: nothing to reach")
    }

    @Test func machine_offlineIntervalCurve() {
        #expect(M.offlineInterval(afterOfflineFor: 0) == 30)
        #expect(M.offlineInterval(afterOfflineFor: 299) == 30)
        #expect(M.offlineInterval(afterOfflineFor: 300) == 60)
        #expect(M.offlineInterval(afterOfflineFor: 899) == 60)
        #expect(M.offlineInterval(afterOfflineFor: 900) == 120)
        #expect(M.offlineInterval(afterOfflineFor: 1e9) == 120)
    }
}
