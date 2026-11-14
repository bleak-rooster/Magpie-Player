import Foundation
import Testing
import LidarrKit
@testable import Requests

/// Round 27 R (owner, 2026-11-14): "automatically trigger this search every day or week when you open the app (ie it
/// should save when it last triggered it and if opened again after the set wait period, it should send the trigger
/// again)" (D291). Pure: whether it's due, and what the saved time becomes after each kind of answer.
@Suite struct MissingAlbumScheduleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3_600

    private var ready: MissingAlbumSchedule.Situation {
        MissingAlbumSchedule.Situation(trigger: .becameActive, online: true, lidarrConnected: true, changesAllowed: true)
    }

    private func due(_ every: MissingAlbumSchedule.Every, last: Date?, after seconds: TimeInterval,
                     _ situation: MissingAlbumSchedule.Situation? = nil) -> Bool {
        MissingAlbumSchedule.isDue(every: every, lastAsked: last, now: t0.addingTimeInterval(seconds),
                                   situation: situation ?? ready)
    }

    @Test func due_dailyAfter24h() {
        #expect(!due(.day, last: t0, after: 24 * hour - 1))
        #expect(due(.day, last: t0, after: 24 * hour))
        #expect(due(.day, last: t0, after: 30 * 24 * hour))
        #expect(due(.day, last: nil, after: 0), "never asked: due the first time Magpie opens")
    }

    @Test func due_weeklyAfter7d() {
        #expect(!due(.week, last: t0, after: 24 * hour))
        #expect(!due(.week, last: t0, after: 7 * 24 * hour - 1))
        #expect(due(.week, last: t0, after: 7 * 24 * hour))
        #expect(due(.week, last: nil, after: 0))
    }

    @Test func notDueOff() {
        #expect(!due(.off, last: nil, after: 0))
        #expect(!due(.off, last: t0, after: 365 * 24 * hour))
        #expect(MissingAlbumSchedule.Every.off.interval == nil)
        #expect(MissingAlbumSchedule.Every.allCases == [.off, .day, .week], "Off first: the default")
    }

    /// The phone's clock: a saved time ahead of it (the clock went back) isn't due; it waits from now.
    @Test func futureTimeIsNotDue() {
        #expect(!due(.day, last: t0.addingTimeInterval(48 * hour), after: 0))
        #expect(MissingAlbumSchedule.lastAskedClamped(t0.addingTimeInterval(48 * hour), now: t0) == t0)
        #expect(MissingAlbumSchedule.lastAskedClamped(t0, now: t0.addingTimeInterval(hour)) == t0)
        #expect(MissingAlbumSchedule.lastAskedClamped(nil, now: t0) == nil)
    }

    @Test func refusalRestoresPreviousTime() {
        let previous = t0.addingTimeInterval(-30 * hour)
        let asked = t0
        let refusals: [Error] = [WriteGateError.disabled, WriteGateError.unconfirmed, WriteGateError.logUnavailable,
                                 WriteGateError.forbidden("command not allowed"), WriteGateError.invalidRequest("path"),
                                 LidarrError.unauthorized, LidarrError.http(status: 400)]
        for error in refusals {
            let answer = MissingAlbumSchedule.answer(for: error)
            #expect(answer == .refused, "\(error)")
            #expect(MissingAlbumSchedule.lastAsked(after: answer, previous: previous, askedAt: asked) == previous)
            #expect(MissingAlbumSchedule.lastAsked(after: answer, previous: nil, askedAt: asked) == nil)
        }
    }

    @Test func alreadyRunningCountsAsSent() {
        let running = MissingAlbumSchedule.answer(for: WriteGateError.forbidden(MissingAlbumSearch.alreadyRunning))
        #expect(running == .alreadyRunning)
        #expect(MissingAlbumSchedule.lastAsked(after: running, previous: nil, askedAt: t0) == t0)
        // Fix round 1 L6: the gate's ten minutes has its own answer (its own words), and counts as asked too.
        let soon = MissingAlbumSchedule.answer(for: WriteGateError.forbidden(MissingAlbumSearch.tooSoon))
        #expect(soon == .tooSoon)
        #expect(MissingAlbumSchedule.lastAsked(after: soon, previous: nil, askedAt: t0) == t0)
        #expect(MissingAlbumSchedule.answer(for: nil) == .sent)
        #expect(MissingAlbumSchedule.lastAsked(after: .sent, previous: t0.addingTimeInterval(-hour), askedAt: t0) == t0)
    }

    /// Sent, but no answer came: Lidarr may be looking already, so it counts (the gate's record and its command read
    /// prove the next one again).
    @Test func lostAnswerCountsAsSent() {
        for error in [URLError(.timedOut), URLError(.networkConnectionLost), LidarrError.http(status: 504),
                      LidarrError.http(status: 500)] as [Error] {
            let answer = MissingAlbumSchedule.answer(for: error)
            #expect(answer == .lostAnswer, "\(error)")
            #expect(MissingAlbumSchedule.lastAsked(after: answer, previous: nil, askedAt: t0) == t0)
        }
    }

    @Test func onlyWhenActiveOnlineAndAllowed() {
        func with(online: Bool = true, connected: Bool = true, allowed: Bool = true) -> MissingAlbumSchedule.Situation {
            MissingAlbumSchedule.Situation(trigger: .becameActive, online: online, lidarrConnected: connected,
                                           changesAllowed: allowed)
        }
        #expect(due(.day, last: nil, after: 0, with()))
        #expect(!due(.day, last: nil, after: 0, with(online: false)))
        #expect(!due(.day, last: nil, after: 0, with(connected: false)))
        #expect(!due(.day, last: nil, after: 0, with(allowed: false)))
    }

    @Test func neverInBackgroundPass() {
        let background = MissingAlbumSchedule.Situation(trigger: .backgroundPass, online: true, lidarrConnected: true,
                                                        changesAllowed: true)
        #expect(!due(.day, last: nil, after: 0, background))
        #expect(!due(.week, last: t0, after: 30 * 24 * hour, background))
    }

    /// Per Lidarr: its own keys, forgotten with the others.
    @Test func keysArePerLidarrAndForgotten() throws {
        let suite = "magpie-missing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = MissingAlbumSchedule.Store(defaults: defaults, scope: "aaa")
        let b = MissingAlbumSchedule.Store(defaults: defaults, scope: "bbb")
        #expect(a.every == .off && a.lastAsked == nil, "Off by default")
        a.every = .week
        a.lastAsked = t0
        #expect(b.every == .off && b.lastAsked == nil)
        #expect(MissingAlbumSchedule.everyKey(scope: "aaa") == "magpie.lidarr.missingSearchEvery.aaa")
        #expect(defaults.string(forKey: "magpie.lidarr.missingSearchEvery.aaa") == "week")
        a.forget()
        #expect(a.every == .off && a.lastAsked == nil)
    }
}
