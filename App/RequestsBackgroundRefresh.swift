import BackgroundTasks
import Foundation
import os
import Requests
import SwiftUI

/// R16: requests keep going in the background. While audio plays, the process stays alive and the runner keeps polling
/// every 30 s (`pollRequests`). Otherwise, when iOS grants time, a `BGAppRefreshTask` runs one bounded runner pass: the
/// same `tick()` the foreground runs (Lidarr queue and history reads, the Navidrome match check, and only the retry
/// searches the runner already had scheduled), which posts the ready notification through `requestBecameReady`.
/// Best-effort: iOS decides if and when it runs; at most every 15 minutes is asked for.
enum RequestsBackgroundRefresh {
    static let identifier = "com.bleak-rooster.magpie.requests"
    /// The iOS minimum hint for app refresh.
    static let interval: TimeInterval = 15 * 60
    /// The pass ends by then, well inside the ~30 s iOS allows.
    static let passLimit: Duration = .seconds(25)

    /// At launch, before the app finishes launching (`MagpieApp.init`).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let completion = Completion(task)
            let stop = PassStop()
            // iOS takes the time back: the pass stops between steps (never mid-write) and the task completes.
            task.expirationHandler = {
                stop.stop()
                completion.finish(false)
            }
            Task { @MainActor in completion.finish(await AppModel.shared.backgroundRequestPass(stop: stop)) }
        }
    }

    /// Hands a request to iOS: iOS 27's async submit, or iOS 26's synchronous one (R21, D166).
    static func submit(_ request: BGTaskRequest) async throws {
        if #available(iOS 27, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    static func request(now: Date = Date()) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        return request
    }

    /// Tells a pass to stop at its next step (expiration or the time limit).
    final class PassStop: Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        func stop() { flag.withLock { $0 = true } }
        var isStopped: Bool { flag.withLock { $0 } }
    }

    /// Completes the task once, whichever comes first: the pass or iOS taking the time back.
    private final class Completion: @unchecked Sendable {
        private let task: BGTask
        private let done = OSAllocatedUnfairLock(initialState: false)
        init(_ task: BGTask) { self.task = task }
        func finish(_ success: Bool) {
            guard done.withLock({ d in defer { d = true }; return !d }) else { return }
            task.setTaskCompleted(success: success)
        }
    }
}

extension AppModel {
    /// Asks iOS for a background pass while any request is still on its way (on going to the background, and after
    /// each pass). Nothing is asked for otherwise.
    func scheduleRequestRefresh(submit: @escaping (BGTaskRequest) async throws -> Void = RequestsBackgroundRefresh.submit) {
        guard let runner else { return }
        Task {
            guard await runner.needsPolling else { return }
            try? await submit(RequestsBackgroundRefresh.request())
        }
    }

    /// The scene phase: going to the background asks iOS for a pass while a request is on its way (RootView).
    func requestsScenePhaseChanged(_ phase: ScenePhase, submit: @escaping (BGTaskRequest) async throws -> Void = RequestsBackgroundRefresh.submit) {
        guard phase == .background else { return }
        scheduleRequestRefresh(submit: submit)
    }

    /// One bounded runner pass (the BGAppRefreshTask's work). At a cold background launch whose Keychain read came
    /// up empty, the Lidarr connection is read again and the runner built first. Signed out or without Lidarr: nothing
    /// to do (false). Offline: nothing is sent, and the next pass is asked for. Past `limit`, or once `stop` is
    /// told, the runner stops between steps.
    /// - Returns: whether the pass finished within `limit`.
    func backgroundRequestPass(limit: Duration = RequestsBackgroundRefresh.passLimit,
                               stop: RequestsBackgroundRefresh.PassStop = .init(),
                               submit: @escaping (BGTaskRequest) async throws -> Void = RequestsBackgroundRefresh.submit)
        async -> Bool {
        if runner == nil, session != nil, reloadKeychainItems() { rebuildRunner() }
        guard let runner else { return false }
        guard !isOffline else {
            scheduleRequestRefresh(submit: submit)
            return false
        }
        let finished = await Self.within(limit) { await runner.tick(shouldStop: { stop.isStopped }) }
        if !finished { stop.stop() }
        scheduleRequestRefresh(submit: submit)   // the next one, while something is still on its way
        return finished
    }

    /// Runs `work`, returning true when it ends within `limit`, false when the time ran out first (the caller then
    /// tells it to stop at its next step).
    static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            func finish(_ value: Bool) {
                guard once.withLock({ d in defer { d = true }; return !d }) else { return }
                c.resume(returning: value)
            }
            Task { await work(); finish(true) }
            Task { try? await Task.sleep(for: limit); finish(false) }
        }
    }
}
