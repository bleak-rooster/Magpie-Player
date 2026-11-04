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
    /// The one read in flight and the one retry waiting (fix I1): a new read replaces both.
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Bumped by every read; only the newest read records and settles.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastAnswered: Date?
    @ObservationIgnored private var lastSaved: [HomeShelf]?
    /// Signed out or another account (fix M1): nothing is read, retried or saved again.
    @ObservationIgnored private(set) var isStopped = false
    /// In the background (fix I2): no retry waits; returning to the foreground reads what is still missing.
    @ObservationIgnored private(set) var isPaused = false
    /// A trigger (reconnect, a stale foreground) that arrived while a read was under way (fix N2): one read follows
    /// it, everything again when `true`. At most one is queued.
    @ObservationIgnored private var followUp: Bool?
    /// Round 13 Z2: sections that changed while a read was under way (`sectionsChanged`): not read once it settles.
    @ObservationIgnored private var staleSections: Set<HomeSection> = []
    /// Retry tasks alive now (tests: never more than one).
    @ObservationIgnored private(set) var liveRetries = 0

    /// Round 14 A6: albums, playlists and flows played on this phone, newest first (Home's quick grid).
    private(set) var recentPlays: [RecentPlay] = []
    @ObservationIgnored private let recentStore: QuickAccessStore?

    init(scope: String? = nil, cache: HomeShelfCache?, recentStore: QuickAccessStore? = nil, read: @escaping Reader,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping () -> Date = Date.init) {
        self.scope = scope
        self.cache = cache
        self.recentStore = recentStore
        self.read = read
        self.sleep = sleep
        self.now = now
        recentPlays = recentStore?.load() ?? []
        if let saved = cache?.load(), !saved.isEmpty {
            load = HomeLoad(cached: saved)
            lastSaved = saved
        }
    }

    /// Home's state for `LoadableView`: the shelves as soon as there are any; a failure only once it is shown. While
    /// nothing is on screen yet and a retry is coming, the spinner stays (not an empty Home).
    var state: Loadable<HomeLoad> {
        if let load {
            if load.found.isEmpty, !failuresShown, let key = lastKey, load.needsRead(key) { return .loading }
            return .loaded(load)
        }
        if let pageError, failuresShown { return .failed(pageError) }
        return .loading
    }

    /// Whether `section` says "Couldn't load": it failed, nothing of it is on screen, and failures are shown.
    func showsFailure(_ section: HomeSection) -> Bool { failuresShown && load?.showsFailure(section) == true }

    /// A read is in flight.
    var isReading: Bool { readTask != nil }

    /// Reads what a change to `key` needs (Home appearing, a section turned on, offline or back, a download). Replaces
    /// any read in flight. The read is the feed's own: the view going away (a tab switch) stops the wait, not the
    /// read, which still records and settles (fix N1).
    func show(_ key: HomeLoad.Key) async {
        await run(startRead(key, fresh: false, asked: false))
    }

    /// Pull to refresh (and Try again): everything again, failures shown at once.
    func refresh(_ key: HomeLoad.Key) async {
        attempt = 0
        await run(startRead(key, fresh: true, asked: true))
    }

    /// The server answers again, or the network came back: what failed is read at once (or by the read under way).
    func reconnected() {
        guard let key = lastKey, needsRead(key) else { return }
        restart(key, fresh: false)
    }

    /// Back in the foreground: retries resume; what failed is read at once; after `staleAfter`, everything is read
    /// again silently.
    func foregrounded() {
        isPaused = false
        guard let key = lastKey else { return }
        if needsRead(key) {
            restart(key, fresh: false)
        } else if let last = lastAnswered, now().timeIntervalSince(last) > Self.staleAfter {
            restart(key, fresh: true)
        }
    }

    /// Round 12 Y3: the library Home reads changed (the main library was picked or chosen): everything again,
    /// silently, so no other library's albums stay on screen.
    func libraryChanged() {
        guard let key = lastKey else { return }
        restart(key, fresh: true)
    }

    /// Round 13 Z2: what `sections` show changed elsewhere (Discover's playlists, and so Playlists): they are read
    /// again, silently, their shelves staying on screen meanwhile. A read under way may have read them before the
    /// change, so one more read follows it.
    func sectionsChanged(_ sections: Set<HomeSection>) {
        guard !isStopped else { return }
        if var state = load {
            state.forget(sections)
            load = state
        }
        guard let key = lastKey else { return }
        if readTask != nil { staleSections.formUnion(sections) }
        restart(key, fresh: false)
    }

    /// Round 13 Z2 (review M5): `sections`' shelves belong to something no longer there (another Aurral, or another
    /// of its users): they leave the screen and the saved shelves now, and are read again.
    func discard(_ sections: Set<HomeSection>) {
        guard !isStopped, var state = load else { return }
        state.drop(sections)
        load = state
        if lastKey?.offline != true, let cache {   // the saved file loads by section, so any order will do
            let shelves = (lastKey?.sections ?? HomeSection.allCases).compactMap { state.found[$0] }
            lastSaved = shelves
            cache.save(shelves)
        }
        guard let key = lastKey else { return }
        if readTask != nil { staleSections.formUnion(sections) }
        restart(key, fresh: false)
    }

    /// Round 14 A6: `play` heads the quick grid now, and is saved (never once stopped: signed out, another account).
    func notePlayed(_ play: RecentPlay) {
        guard !isStopped else { return }
        var play = play
        play.playedAt = play.playedAt ?? now()
        recentPlays = QuickAccess.noting(play, in: recentPlays)
        recentStore?.save(recentPlays)
    }

    /// To the background: no retry waits meanwhile (the read under way, if any, finishes).
    func backgrounded() {
        isPaused = true
        cancelRetry()
    }

    /// Stops for good (sign-out, another account): the read in flight and any retry are cancelled, and nothing is
    /// read, retried or saved again.
    func stop() {
        isStopped = true
        readTask?.cancel()
        readTask = nil
        cancelRetry()
    }

    private func needsRead(_ key: HomeLoad.Key) -> Bool { load?.needsRead(key) ?? true }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// A read now; the backoff starts over. With a read under way, one read follows it instead (fix N2): that read
    /// began before this trigger, so its outcome may be stale.
    private func restart(_ key: HomeLoad.Key, fresh: Bool) {
        guard !isStopped else { return }
        guard readTask == nil else {
            followUp = (followUp ?? false) || fresh
            return
        }
        attempt = 0
        startRead(key, fresh: fresh, asked: false)
    }

    /// The one read: replaces the read in flight and any retry waiting.
    @discardableResult
    private func startRead(_ key: HomeLoad.Key, fresh: Bool, asked: Bool) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        readTask?.cancel()
        cancelRetry()
        followUp = nil   // this read covers it
        staleSections = []   // and reads them: `load` already counts them as not read
        generation += 1
        let mine = generation
        let task = Task { [weak self] () -> Void in await self?.perform(key, fresh: fresh, asked: asked, generation: mine) }
        readTask = task
        return task
    }

    /// Waits for `task` (pull to refresh's spinner, the view's task). A newer read, or `stop()`, cancels it; the
    /// caller going away doesn't (fix N1).
    private func run(_ task: Task<Void, Never>?) async {
        await task?.value
    }

    private func isCurrent(_ mine: Int) -> Bool { !Task.isCancelled && !isStopped && mine == generation }

    private func perform(_ want: HomeLoad.Key, fresh: Bool, asked: Bool, generation mine: Int) async {
        defer { if mine == generation { readTask = nil } }
        lastKey = want
        var state = load ?? HomeLoad()
        let request = state.read(for: want, fresh: fresh)
        do {
            let result = request.sections.isEmpty ? AppModel.HomeRead(shelves: [], failed: [])
                                                  : try await read(request.sections)
            guard isCurrent(mine) else { return }   // a newer read took over, or the feed stopped: nothing recorded
            state = load ?? state
            state.record(request, for: want, shelves: result.shelves, failed: result.failed, unread: result.cancelled)
            load = state
            pageError = nil
            if result.failed.union(result.cancelled).count < request.sections.count { lastAnswered = now() }
        } catch {
            guard isCurrent(mine) else { return }
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
        guard !isStopped else { return }
        if !staleSections.isEmpty, var state = load {   // read before they changed: the follow-up reads them again
            state.forget(staleSections)
            load = state
        }
        staleSections = []
        save(want)
        if let fresh = followUp {   // a trigger arrived during this read: read once more, now (fix N2)
            attempt = 0
            startRead(lastKey ?? want, fresh: fresh, asked: false)
            return
        }
        guard needsRead(want) else {
            attempt = 0
            failuresShown = false
            return
        }
        if asked { failuresShown = true }
        guard attempt < Self.retryDelays.count else { return giveUp() }
        guard !isPaused else { return }   // foregrounding reads it
        let delay = Self.retryDelays[attempt]
        attempt += 1
        cancelRetry()
        liveRetries += 1
        retryTask = Task { [weak self, sleep] in
            defer { self?.liveRetries -= 1 }
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.retryTask = nil   // so starting the read doesn't cancel this task under it
            self.startRead(self.lastKey ?? want, fresh: false, asked: false)
        }
    }

    /// The retries ran out: say so. A launch whose every read was cut short has no message yet (fix M2): it gets the
    /// plain one, with Try again, instead of a spinner that never ends.
    private func giveUp() {
        failuresShown = true
        if load == nil, pageError == nil { pageError = BrowseErrorCopy.message(for: CancellationError()) }
    }

    /// Saves the shelves on screen, in Home's order, when they changed. Not offline (fix M3): the offline shelves
    /// (Downloaded only) never replace the saved online ones.
    private func save(_ want: HomeLoad.Key) {
        guard !isStopped, !want.offline, let cache, let load else { return }
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
                            recentStore: scope.map { QuickAccessStore(root: dataDirectory, scope: $0) },
                            read: { [weak self] sections in
                                guard let self else { throw CancellationError() }
                                return try await self.homeRead(for: sections)
                            })
        homeFeedSlot = feed
        return feed
    }

    /// The session changed (fix I2): another account's feed stops at once, not on Home's next draw.
    func homeFeedSessionChanged() {
        guard let feed = homeFeedSlot, feed.scope != navidromeScope else { return }
        feed.stop()
        homeFeedSlot = nil
    }

    /// The app went to the background or came back (fix I2): retries pause, and resume on return.
    func homeFeedForegroundChanged(_ foreground: Bool) {
        guard let feed = homeFeedSlot else { return }
        if foreground { feed.foregrounded() } else { feed.backgrounded() }
    }

    /// Sign-out: the feed stops and every saved shelf is removed.
    func forgetHomeShelves() {
        homeFeedSlot?.stop()
        homeFeedSlot = nil
        HomeShelfCache.removeAll(root: dataDirectory)
    }
}
