import Foundation
import MagpieCore
import Observation

/// Library search as you type: waits for a pause, cancels whatever was in flight, and ignores
/// stale answers. The search call and the sleep are injected so tests run without real time.
@MainActor @Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle          // no query
        case searching
        case done
        case failed(String)
    }

    static let debounce: Duration = .milliseconds(250)

    private(set) var query = ""
    private(set) var results = SearchSections.empty
    private(set) var phase = Phase.idle

    @ObservationIgnored private let search: @Sendable (String) async throws -> LibrarySearchResult
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let errorMessage: (Error) -> String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(search: @escaping @Sendable (String) async throws -> LibrarySearchResult,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         debounce: Duration = SearchModel.debounce,
         errorMessage: @escaping (Error) -> String = { _ in "Search didn't work. Try again in a moment." }) {
        self.search = search
        self.sleep = sleep
        self.debounce = debounce
        self.errorMessage = errorMessage
    }

    /// The query changed. An empty (or blank) query clears the results at once.
    func update(query newQuery: String) {
        query = newQuery
        task?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            task = nil
            results = .empty
            phase = .idle
            return
        }
        phase = .searching
        let search = self.search, sleep = self.sleep, debounce = self.debounce
        task = Task { [weak self] in
            do {
                try await sleep(debounce)
                try Task.checkCancellation()
                let found = try await search(trimmed)
                try Task.checkCancellation()
                self?.finish(.library(found, query: trimmed), for: newQuery)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.fail(self.errorMessage(error), for: newQuery)
            }
        }
    }

    /// Waits for the current query's search to finish (tests).
    func settle() async {
        await task?.value
    }

    private func finish(_ sections: SearchSections, for q: String) {
        guard q == query else { return }
        results = sections
        phase = .done
    }

    private func fail(_ message: String, for q: String) {
        guard q == query else { return }
        results = .empty
        phase = .failed(message)
    }
}

/// Recent searches, newest first, kept on the device.
struct RecentSearches {
    static let limit = 8
    private let defaults: UserDefaults
    private let key = "magpie.recentSearches"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var items: [String] { defaults.stringArray(forKey: key) ?? [] }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = items.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
