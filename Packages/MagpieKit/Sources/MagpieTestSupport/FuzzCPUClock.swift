import Foundation

/// Round 28 crash hunt (R28X): the clock `FuzzClock` measures with. Wall-clock bounds failed whenever the machine was
/// busy (six fuzz checks with an app build alongside: a sweep's seconds are the machine's, not the algorithm's), so
/// fuzz work is timed in **CPU time of the thread that does it**, which waiting for a core doesn't add to:
/// - synchronous work: the calling thread's CPU clock;
/// - asynchronous work: it runs on a task executor of its own, one thread, whose CPU clock is read on that thread
///   before and after. Nested measurements share the outer one's executor.
/// A quadratic blow-up still burns the CPU time it always did; an infinite loop still never returns.
public enum FuzzCPUClock {
    /// Seconds of CPU time the current thread has used.
    public static func threadSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    @TaskLocal static var executor: CPUTimedExecutor?

    /// CPU seconds `body` takes on one executor thread.
    public static func seconds(_ body: () async throws -> Void) async rethrows -> Double {
        if let executor { return try await measure(on: executor, body) }
        let executor = CPUTimedExecutor()
        defer { executor.shutdown() }
        return try await $executor.withValue(executor) { try await measure(on: executor, body) }
    }

    private static func measure(on executor: CPUTimedExecutor, _ body: () async throws -> Void) async rethrows -> Double {
        try await withTaskExecutorPreference(executor) {
            try await onExecutorThread(executor, body)
        }
    }

    /// `@concurrent`, so it runs on the preferred task executor whatever isolation the caller has; the reads happen
    /// there, on its one thread.
    @concurrent private static func onExecutorThread(_ executor: CPUTimedExecutor,
                                                     _ body: () async throws -> Void) async rethrows -> Double {
        executor.checkOnThread()
        let start = threadSeconds()
        try await body()
        executor.checkOnThread()
        return threadSeconds() - start
    }
}

/// A task executor with one thread of its own (`FuzzCPUClock`): every job of a task that prefers it runs there, so that
/// thread's CPU clock is the work's.
final class CPUTimedExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var head = 0
    private var stopping = false
    private var threadId: pthread_t?

    init() {
        let thread = Thread { [self] in run() }
        thread.name = "FuzzCPUClock"
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// No more jobs: the thread ends once the queue is empty.
    func shutdown() {
        condition.lock()
        stopping = true
        condition.signal()
        condition.unlock()
    }

    /// A measurement read off this executor's thread would be another thread's clock.
    func checkOnThread() {
        condition.lock()
        let mine = threadId.map { pthread_equal($0, pthread_self()) != 0 } ?? false
        condition.unlock()
        precondition(mine, "FuzzCPUClock read off its executor's thread")
    }

    private func run() {
        condition.lock()
        threadId = pthread_self()
        condition.unlock()
        while true {
            condition.lock()
            while head == jobs.count, !stopping { condition.wait() }
            guard head < jobs.count else {
                condition.unlock()
                return
            }
            let job = jobs[head]
            head += 1
            if head == jobs.count { jobs.removeAll(keepingCapacity: true); head = 0 }
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
