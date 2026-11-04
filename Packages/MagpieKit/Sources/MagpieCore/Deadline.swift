import Foundation

/// B1 fix round (review 6): the one "answer within a time limit" helper (Home's provided sections, outside pictures, the
/// outside artist page, search's sources).
public enum Deadline {
    /// The limit passed before the work answered.
    public struct Exceeded: Error, Equatable, Sendable {
        public init() {}
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// `op`'s answer, or `.failure(Exceeded())` once `limit` passes on `sleep`'s clock. The work is cancelled and never
    /// waited for, so a source that ignores cancellation can't hold its caller up. Cancelling the caller answers
    /// `.failure(CancellationError())` at once.
    public static func run<T: Sendable>(_ limit: Duration, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                                        _ op: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
        let first = FirstAnswer<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, any Error>, Never>) in
                let work = Task {
                    let result: Result<T, any Error>
                    do { result = .success(try await op()) } catch { result = .failure(error) }
                    first.finish(result)
                }
                let timer = Task {
                    do { try await sleep(limit) } catch { return }   // cancelled: the work answered
                    first.finish(.failure(Exceeded()))
                }
                first.start(continuation, cancelling: [work, timer])
            }
        } onCancel: {
            first.finish(.failure(CancellationError()))
        }
    }

    /// The first answer wins; both tasks are then cancelled. An answer that comes before `start` is kept for it.
    private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, any Error>, Never>?
        private var early: Result<T, any Error>?
        private var tasks: [Task<Void, Never>] = []
        private var done = false

        func start(_ continuation: CheckedContinuation<Result<T, any Error>, Never>, cancelling tasks: [Task<Void, Never>]) {
            lock.lock()
            if let early {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                continuation.resume(returning: early)
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            guard let continuation else { early = result; lock.unlock(); return }
            self.continuation = nil
            let tasks = self.tasks
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation.resume(returning: result)
        }
    }
}

/// B1 fix round (review 4, D120): runs `op` for each key concurrently and answers by key, never by position. The
/// answer is awaited into a constant before it is paired with its key: build 14's Release build lost a position that
/// was paired with an inline `try await` (every answer landed on the first one). Duplicate keys are asked once.
public enum KeyedGather {
    private struct Answer<Key: Sendable, Value: Sendable>: Sendable {
        let key: Key
        let value: Value
    }

    /// Every key's value, at most `width` running at once (nil: all at once). The first error is thrown (the rest are
    /// cancelled).
    public static func values<Key: Hashable & Sendable, Value: Sendable>(
        _ keys: [Key], width: Int? = nil, _ op: @escaping @Sendable (Key) async throws -> Value
    ) async throws -> [Key: Value] {
        var seen = Set<Key>()
        let unique = keys.filter { seen.insert($0).inserted }
        return try await withThrowingTaskGroup(of: Answer<Key, Value>.self) { group in
            var answers: [Key: Value] = [:]
            var next = unique.makeIterator()
            func add() -> Bool {
                guard let key = next.next() else { return false }
                group.addTask {
                    let value = try await op(key)
                    return Answer(key: key, value: value)
                }
                return true
            }
            for _ in 0..<max(1, width ?? unique.count) { if !add() { break } }
            while let answer = try await group.next() {
                answers[answer.key] = answer.value
                _ = add()
            }
            return answers
        }
    }

    /// `values`, in the keys' order (a key that's missing means the read was cut short: `CancellationError`).
    public static func inOrder<Key: Hashable & Sendable, Value: Sendable>(
        _ keys: [Key], width: Int? = nil, _ op: @escaping @Sendable (Key) async throws -> Value
    ) async throws -> [Value] {
        let answers = try await values(keys, width: width, op)
        return try keys.map { key in
            guard let value = answers[key] else { throw CancellationError() }
            return value
        }
    }
}
