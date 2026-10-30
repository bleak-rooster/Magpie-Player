import Foundation
import MagpieCore
import Observation

/// What Home shows and when it reads again (P5, priority round): Home should feel seamless, never needing a pull.
///
/// - The last shelves are saved per account (`HomeShelfCache`) and show at once at launch: no spinner when there are
///   some. A read replaces them in the background without a flash.
/// - A read cut short (`CancellationError`, URLSession's `.cancelled`, a section that never reported) is never a
///   failure: it is simply not read yet, and is read again.
/// - What failed is read again by itself after 5 s, 30 s and 2 min, at once on reconnect and on returning to the
///   foreground. "Couldn't load" shows only once those retries have failed, or straight after a pull to refresh.
/// - Back in the foreground after more than 10 minutes, everything is read again silently.
///
/// One per account (`AppModel.homeFeed`), so it outlives the Home view; the view hands it the current `HomeLoad.Key`.
@MainActor @Observable final class HomeFeed {
    typealias Reader = @MainActor ([HomeSection]) async throws -> AppModel.HomeRead
    typealias Sleep = @MainActor (Duration) async throws -> Void

    /// The waits before each automatic retry; after the last one fails, Home says so.
    static let retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    /// Back in the foreground after this long, Home reads everything again.
    static let staleAfter: TimeInterval = 10 * 60

    /// The shelves on screen (saved or read); nil until there are some.
    private(set) var load: HomeLoad?
    /// Why the first read failed, while nothing is on screen.
    private(set) var pageError: String?
    /// Failures are shown: the retries ran out, or the owner pulled to refresh.
    private(set) var failuresShown = false

    /// The account this feed belongs to (`AppModel.navidromeScope`).
    let scope: String?
    @ObservationIgnored private let cache: HomeShelfCache?
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastKey: HomeLoad.Key?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var lastAnswered: Date?
    @ObservationIgnored private var lastSaved: [HomeShelf]?

    init(scope: String? = nil, cache: HomeShelfCache?, read: @escaping Reader,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        self.cache = cache
        self.read = read
        self.sleep = sleep
        self.now = now
        if let saved = cache?.load(), !saved.isEmpty {
            load = HomeLoad(cached: saved)
            lastSaved = saved
        }
    }

    /// Home's state for `LoadableView`: the shelves as soon as there are any; a failure only once it is shown.
    var state: Loadable<HomeLoad> {
        if let load { return .loaded(load) }
        if let pageError, failuresShown { return .failed(pageError) }
        return .loading
    }

    /// Whether `section` says "Couldn't load": it failed, nothing of it is on screen, and failures are shown.
    func showsFailure(_ section: HomeSection) -> Bool { failuresShown && load?.showsFailure(section) == true }

    /// Reads what a change to `key` needs (Home appearing, a section turned on, offline or back, a download).
    func show(_ key: HomeLoad.Key) async {
        retryTask?.cancel()
        await perform(key, fresh: false, asked: false)
    }

    /// Pull to refresh (and Try again): everything again, failures shown at once.
    func refresh(_ key: HomeLoad.Key) async {
        retryTask?.cancel()
        attempt = 0
        await perform(key, fresh: true, asked: true)
    }

    /// The server answers again, or the network came back: what failed is read at once.
    func reconnected() {
        guard let key = lastKey, needsRead(key) else { return }
        restart(key, fresh: false)
    }

    /// Back in the foreground: what failed is read at once; after `staleAfter`, everything is read again silently.
    func foregrounded() {
        guard let key = lastKey else { return }
        if needsRead(key) {
            restart(key, fresh: false)
        } else if let last = lastAnswered, now().timeIntervalSince(last) > Self.staleAfter {
            restart(key, fresh: true)
        }
    }

    /// Stops any retry (sign-out, another account).
    func stop() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func needsRead(_ key: HomeLoad.Key) -> Bool { load?.needsRead(key) ?? true }

    /// A read now, in place of any retry waiting; the backoff starts over.
    private func restart(_ key: HomeLoad.Key, fresh: Bool) {
        retryTask?.cancel()
        attempt = 0
        retryTask = Task { [weak self] in await self?.perform(key, fresh: fresh, asked: false) }
    }

    private func perform(_ want: HomeLoad.Key, fresh: Bool, asked: Bool) async {
        lastKey = want
        var state = load ?? HomeLoad()
        let request = state.read(for: want, fresh: fresh)
        do {
            let result = request.sections.isEmpty ? AppModel.HomeRead(shelves: [], failed: [])
                                                  : try await read(request.sections)
            guard !Task.isCancelled else { return }   // a newer read (or the view going) took over: nothing recorded
            state = load ?? state
            state.record(request, for: want, shelves: result.shelves, failed: result.failed, unread: result.cancelled)
            load = state
            pageError = nil
            if result.failed.union(result.cancelled).count < request.sections.count { lastAnswered = now() }
        } catch {
            guard !Task.isCancelled else { return }
            if AppModel.isCancellation(error) {
                // Cut short, not failed: nothing recorded, read again soon.
            } else if var state = load {
                state.record(request, for: want, shelves: [], failed: Set(request.sections))
                load = state
            } else {
                pageError = BrowseErrorCopy.message(for: error)
            }
        }
        settle(want, asked: asked)
    }

    /// After a read: done (save what is on screen), or retry on the backoff, or say what failed.
    private func settle(_ want: HomeLoad.Key, asked: Bool) {
        guard needsRead(want) else {
            attempt = 0
            failuresShown = false
            save(want)
            return
        }
        if asked { failuresShown = true }
        save(want)
        guard attempt < Self.retryDelays.count else {
            failuresShown = true
            return
        }
        let delay = Self.retryDelays[attempt]
        attempt += 1
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.perform(self.lastKey ?? want, fresh: false, asked: false)
        }
    }

    /// Saves the shelves on screen, in Home's order, when they changed.
    private func save(_ want: HomeLoad.Key) {
        guard let cache, let load else { return }
        let shelves = want.sections.compactMap { load.found[$0] }
        guard !shelves.isEmpty, shelves != lastSaved else { return }
        lastSaved = shelves
        cache.save(shelves)
    }
}

extension AppModel {
    /// Home's feed for the signed-in account (P5): made on first use, replaced when the account changes.
    var homeFeed: HomeFeed {
        let scope = navidromeScope
        if let feed = homeFeedSlot, feed.scope == scope { return feed }
        homeFeedSlot?.stop()
        let feed = HomeFeed(scope: scope, cache: scope.map { HomeShelfCache(root: dataDirectory, scope: $0) },
                            read: { [weak self] sections in
                                guard let self else { throw CancellationError() }
                                return try await self.homeRead(for: sections)
                            })
        homeFeedSlot = feed
        return feed
    }

    /// Sign-out: the feed stops and every saved shelf is removed.
    func forgetHomeShelves() {
        homeFeedSlot?.stop()
        homeFeedSlot = nil
        HomeShelfCache.removeAll(root: dataDirectory)
    }
}
