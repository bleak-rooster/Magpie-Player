import BackgroundTasks
import Foundation
import os
import Requests

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
            task.expirationHandler = { completion.finish(false) }
            Task { @MainActor in completion.finish(await AppModel.shared.backgroundRequestPass()) }
        }
    }

    static func request(now: Date = Date()) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        return request
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
    func scheduleRequestRefresh(submit: @escaping (BGTaskRequest) async throws -> Void = {
        try await BGTaskScheduler.shared.submitTaskRequest($0)
    }) {
        guard let runner else { return }
        Task {
            guard await runner.needsPolling else { return }
            try? await submit(RequestsBackgroundRefresh.request())
        }
    }

    /// One bounded runner pass (the BGAppRefreshTask's work). Offline, signed out or without Lidarr: nothing is sent.
    /// - Returns: whether the pass finished within `limit`.
    func backgroundRequestPass(limit: Duration = RequestsBackgroundRefresh.passLimit) async -> Bool {
        guard let runner, !isOffline else { return false }
        let finished = await Self.within(limit) { await runner.tick() }
        scheduleRequestRefresh()   // the next one, while something is still on its way
        return finished
    }

    /// Runs `work`, returning true when it ends within `limit`, false when the time ran out first (it keeps going;
    /// iOS suspends the app when the task completes).
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
