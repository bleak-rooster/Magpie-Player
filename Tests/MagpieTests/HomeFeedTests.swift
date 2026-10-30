import Foundation
import MagpieCore
import Testing
@testable import Magpie

/// P5 (priority round): Home feels seamless. Saved shelves show at once, a read replaces them silently, a cancelled
/// read is never a failure, failed sections retry by themselves (5 s, 30 s, 2 min), on reconnect and on returning to
/// the foreground, and "Couldn't load" shows only once the retries have failed. Time is injected: `ManualSleep` holds
/// each backoff wait until the test lets it go, and `now` is a variable.
@MainActor @Suite(.serialized) final class HomeFeedTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "HomeFeedTests-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Holds each sleep until `release()`; a cancelled sleep ends at once with `CancellationError`.
    @MainActor final class ManualSleep {
        private(set) var requested: [Duration] = []
        private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        var pending: Int { waiting.count }

        func sleep(_ duration: Duration) async throws {
            requested.append(duration)
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
            try Task.checkCancellation()
        }

        private func cancel(_ id: UUID) {
            guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: i).continuation.resume(throwing: CancellationError())
        }

        /// Lets the oldest sleep go, once one is waiting (the retry task starts it a moment after the read).
        func release() async {
            guard await eventually(5, { () -> Bool in !self.waiting.isEmpty }) else { Issue.record("no retry was waiting"); return }
            waiting.removeFirst().continuation.resume()
        }
    }

    /// Answers each read from `answer`, counting the sections asked for.
    @MainActor final class FakeServer {
        var reads: [[HomeSection]] = []
        var answer: ([HomeSection]) throws -> AppModel.HomeRead = { sections in
            AppModel.HomeRead(shelves: sections.map { HomeShelf(section: $0, items: [.album(HomeFeedTests.album("\($0.rawValue)-live"))]) },
                              failed: [])
        }
        /// Set: reads wait here until resumed.
        var gate: CheckedContinuation<Void, Never>?
        var holds = false

        func read(_ sections: [HomeSection]) async throws -> AppModel.HomeRead {
            reads.append(sections)
            if holds { await withCheckedContinuation { gate = $0 } }
            return try answer(sections)
        }
    }

    static func album(_ id: String) -> Album { Album(id: id, name: id, artist: "A", songCount: 1, duration: 0) }
    let key = HomeLoad.Key.make(sections: [.jumpBackIn, .recentlyAdded], offline: false, onPhone: nil, genres: .defaultValue)

    func makeFeed(_ server: FakeServer, _ sleeper: ManualSleep, now: @escaping () -> Date = Date.init,
                  cache: HomeShelfCache? = nil) -> HomeFeed {
        HomeFeed(cache: cache, read: { try await server.read($0) }, sleep: { try await sleeper.sleep($0) }, now: now)
    }

    private func failing(_ failed: Set<HomeSection>) -> ([HomeSection]) throws -> AppModel.HomeRead {
        { sections in
            AppModel.HomeRead(shelves: sections.filter { !failed.contains($0) }
                                .map { HomeShelf(section: $0, items: [.album(Self.album("\($0.rawValue)-live"))]) },
                              failed: failed.intersection(sections))
        }
    }

    // MARK: - CancellationError is never a failure

    @Test func cancelledReadIsNeverShownAsFailed() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        // The whole read cut short, though Home's own task wasn't cancelled.
        server.answer = { _ in throw CancellationError() }
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        if case .failed = feed.state { Issue.record("a cancelled read showed as failed") }
        #expect(await eventually { sleeper.requested == [.seconds(5)] }, "it is read again soon")

        // URLError.cancelled, and sections a read never reported (gaps), count as not read, never as failed.
        server.answer = { _ in
            AppModel.HomeRead(shelves: [HomeShelf(section: .jumpBackIn, items: [.album(Self.album("j"))])],
                              failed: [], cancelled: [.recentlyAdded])
        }
        await feed.refresh(key)
        #expect(feed.state.value?.found[.jumpBackIn] != nil)
        #expect(!feed.showsFailure(.recentlyAdded))
        server.answer = { _ in throw URLError(.cancelled) }
        await feed.refresh(key)
        #expect(!feed.showsFailure(.jumpBackIn) && !feed.showsFailure(.recentlyAdded))
        #expect(feed.state.value?.found[.jumpBackIn] != nil, "the shelf on screen stays")
    }

    @Test func assembleCountsCancelledSectionsAsNotRead() throws {
        let items: [HomeShelf.Item] = [.album(Self.album("x"))]
        let read = try AppModel.assemble(wanted: [.jumpBackIn, .recentlyAdded, .mostPlayed],
                                         results: [.failure(URLError(.cancelled)), .success(items),
                                                   .failure(URLError(.timedOut))])
        #expect(read.cancelled == [.jumpBackIn])
        #expect(read.failed == [.mostPlayed])
    }

    // MARK: - Cached shelves first

    @Test func cachedShelvesShowBeforeTheNetworkAnswers() async throws {
        let cache = HomeShelfCache(root: root, scope: "abc123")
        cache.save([HomeShelf(section: .jumpBackIn, items: [.album(Self.album("cached"))])])
        let server = FakeServer(), sleeper = ManualSleep()
        server.holds = true
        let feed = makeFeed(server, sleeper, cache: cache)
        // Before any read: the saved shelf, no spinner.
        #expect(feed.state.value?.found[.jumpBackIn]?.items == [.album(Self.album("cached"))])

        let showing = Task { await feed.show(key) }
        #expect(await eventually { server.gate != nil })
        #expect(feed.state.value?.found[.jumpBackIn]?.items == [.album(Self.album("cached"))], "spinner while reading")
        server.gate?.resume()
        await showing.value
        // Replaced silently, and saved for the next launch.
        #expect(feed.state.value?.found[.jumpBackIn]?.items == [.album(Self.album("jumpBackIn-live"))])
        #expect(cache.load().map(\.section) == [.jumpBackIn, .recentlyAdded])
    }

    @Test func cacheFileIsSmallPrivateAndHostileSafe() throws {
        let cache = HomeShelfCache(root: root, scope: "abc123")
        cache.save([HomeShelf(section: .playlists, items: [.playlist(Playlist(id: "p1", name: "Road", songCount: 3, duration: 0,
                                                                                      coverArtId: "pl-1"))])])
        #expect(cache.url.path.contains("Magpie/Home/abc123.json"))
        let values = try cache.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let text = try String(contentsOf: cache.url, encoding: .utf8)
        #expect(!text.contains("http") && !text.contains("token") && !text.contains("password"))
        #expect(cache.load().first?.items == [.playlist(Playlist(id: "p1", name: "Road", songCount: 3, duration: 0, coverArtId: "pl-1"))])

        try Data("{\"version\":1,\"shelves\":[[[[[[".utf8).write(to: cache.url)
        #expect(cache.load().isEmpty)
        HomeShelfCache.removeAll(root: root)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
    }

    // MARK: - Backoff

    @Test func failedSectionsRetryOnTheBackoffSchedule() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = failing([.recentlyAdded])
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        #expect(feed.state.value?.found[.jumpBackIn] != nil)
        #expect(!feed.showsFailure(.recentlyAdded), "Couldn't load shows before the retries")
        #expect(await eventually { sleeper.requested == [.seconds(5)] })

        await sleeper.release()
        #expect(await eventually { server.reads.count == 2 && sleeper.requested.count == 2 })
        #expect(server.reads.last == [.recentlyAdded], "only the failed section is read again")
        #expect(sleeper.requested == [.seconds(5), .seconds(30)])
        #expect(!feed.showsFailure(.recentlyAdded))

        await sleeper.release()
        #expect(await eventually { sleeper.requested.count == 3 })
        #expect(sleeper.requested == [.seconds(5), .seconds(30), .seconds(120)])

        await sleeper.release()
        #expect(await eventually { server.reads.count == 4 })
        #expect(await eventually { feed.showsFailure(.recentlyAdded) }, "after the retries fail, it says so")
        #expect(sleeper.pending == 0 && sleeper.requested.count == 3, "no more retries")
    }

    @Test func aRetryThatWorksStopsRetrying() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = failing([.recentlyAdded])
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        server.answer = failing([])
        await sleeper.release()
        #expect(await eventually { feed.state.value?.found[.recentlyAdded] != nil })
        #expect(sleeper.requested == [.seconds(5)] && sleeper.pending == 0)
    }

    @Test func firstReadFailingWholeRetriesBeforeSayingSo() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = { _ in throw URLError(.timedOut) }
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        if case .failed = feed.state { Issue.record("failed before any retry") }
        for _ in 0..<3 {
            let before = server.reads.count
            await sleeper.release()
            #expect(await eventually { server.reads.count == before + 1 })
        }
        #expect(await eventually { if case .failed = feed.state { true } else { false } })
    }

    @Test func pullToRefreshReadsEverythingAndSaysSoAtOnce() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        #expect(server.reads == [[.jumpBackIn, .recentlyAdded]])
        server.answer = failing([.recentlyAdded])
        await feed.refresh(key)
        #expect(server.reads.last == [.jumpBackIn, .recentlyAdded])
        // The old shelf stays on screen; a failed pull never blanks a shelf.
        #expect(feed.state.value?.found[.recentlyAdded] != nil)
    }

    // MARK: - Reconnect and foreground

    @Test func reconnectRetriesFailedSectionsAtOnce() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = failing([.recentlyAdded])
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        server.answer = failing([])
        feed.reconnected()
        #expect(await eventually { feed.state.value?.found[.recentlyAdded] != nil })
        #expect(server.reads.count == 2)
    }

    @Test func foregroundRetriesFailuresAndRefreshesAfterTenMinutes() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let feed = makeFeed(server, sleeper, now: { clock })
        await feed.show(key)
        #expect(server.reads.count == 1)

        clock += 5 * 60
        feed.foregrounded()
        #expect(!feed.isReading && server.reads.count == 1, "back within 10 minutes and nothing failed: no read")

        clock += 6 * 60
        server.answer = { sections in
            AppModel.HomeRead(shelves: sections.map { HomeShelf(section: $0, items: [.album(Self.album("\($0.rawValue)-new"))]) },
                              failed: [])
        }
        feed.foregrounded()
        #expect(await eventually { server.reads.count == 2 })
        #expect(server.reads.last == [.jumpBackIn, .recentlyAdded], "a silent refresh of everything")
        #expect(await eventually { feed.state.value?.found[.jumpBackIn]?.items == [.album(Self.album("jumpBackIn-new"))] })

        // A section that failed is read again on foregrounding, whenever.
        server.answer = failing([.recentlyAdded])
        await feed.refresh(key)
        server.answer = failing([])
        feed.foregrounded()
        #expect(await eventually { server.reads.count == 4 })
        #expect(server.reads.last == [.recentlyAdded])
    }

    // MARK: - Fix round 1

    /// I1: launch overlaps a reconnect and a foreground read. One read runs (the others join it), one retry task lives,
    /// and the schedule stays 5 s, 30 s, 2 min; after `stop()` nothing more is read.
    @Test func overlappingTriggersShareOneReadAndOneRetry() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.holds = true
        server.answer = failing([.recentlyAdded])
        let feed = makeFeed(server, sleeper)
        let showing = Task { await feed.show(key) }
        #expect(await eventually { server.gate != nil })
        feed.reconnected()
        feed.foregrounded()
        feed.reconnected()
        #expect(server.reads.count == 1, "a second read started beside the first")
        server.holds = false
        server.gate?.resume()
        await showing.value

        #expect(await eventually { sleeper.pending == 1 && feed.liveRetries == 1 })
        feed.reconnected()   // a retry read now, replacing the waiting one
        #expect(await eventually { server.reads.count == 2 && sleeper.requested.count == 2 && sleeper.pending == 1
                                   && feed.liveRetries == 1 }, "an orphaned retry task")
        await sleeper.release()
        #expect(await eventually { server.reads.count == 3 && sleeper.requested.count == 3 && sleeper.pending == 1 })
        await sleeper.release()
        #expect(await eventually { server.reads.count == 4 && sleeper.requested.count == 4 && sleeper.pending == 1 })
        #expect(sleeper.requested == [.seconds(5), .seconds(5), .seconds(30), .seconds(120)],
                "reconnect starts the backoff over; otherwise it is 5 s, 30 s, 2 min")
        #expect(feed.liveRetries == 1)

        feed.stop()
        #expect(await eventually { sleeper.pending == 0 && feed.liveRetries == 0 })
        feed.reconnected(); feed.foregrounded()
        await feed.show(key)
        #expect(server.reads.count == 4, "a stopped feed read again")
    }

    /// M5: a stopped feed's waiting retry never reads, and a read in flight at the stop records and saves nothing.
    @Test func stopCancelsTheRetryAndTheReadInFlight() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = failing([.recentlyAdded])
        let cache = HomeShelfCache(root: root, scope: "stop1")
        let feed = makeFeed(server, sleeper, cache: cache)
        await feed.show(key)
        #expect(await eventually { sleeper.pending == 1 })
        feed.stop()
        #expect(await eventually { sleeper.pending == 0 && feed.liveRetries == 0 })
        #expect(server.reads.count == 1)

        // A read in flight when the feed stops: nothing recorded, nothing saved.
        let other = FakeServer(), otherSleep = ManualSleep()
        other.holds = true
        let second = makeFeed(other, otherSleep, cache: HomeShelfCache(root: root, scope: "stop2"))
        let showing = Task { await second.show(key) }
        #expect(await eventually { other.gate != nil })
        second.stop()
        other.gate?.resume()
        await showing.value
        #expect(second.state.value == nil)
        #expect(!FileManager.default.fileExists(atPath: HomeShelfCache(root: root, scope: "stop2").url.path))
        #expect(otherSleep.requested.isEmpty)
    }

    /// I2: in the background no retry waits; back in the foreground, what failed is read at once.
    @Test func backgroundPausesRetriesAndForegroundResumes() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = failing([.recentlyAdded])
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        #expect(await eventually { sleeper.pending == 1 })
        feed.backgrounded()
        #expect(await eventually { sleeper.pending == 0 && feed.liveRetries == 0 })
        #expect(feed.isPaused)
        // A read that fails while backgrounded schedules nothing.
        await feed.show(key)
        #expect(server.reads.count == 2 && feed.liveRetries == 0 && sleeper.requested.count == 1)

        server.answer = failing([])
        feed.foregrounded()
        #expect(await eventually { feed.state.value?.found[.recentlyAdded] != nil })
        #expect(server.reads.count == 3 && !feed.isPaused)
    }

    /// I2: the model stops the feed eagerly on sign-out and on another account, and pauses it in the background.
    @Test func modelStopsAndPausesTheFeedEagerly() async throws {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: root, engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: "HomeFeedTests.\(UUID().uuidString)")!,
                             systemNowPlaying: false, notifications: false)
        let server = FakeServer(), sleeper = ManualSleep()
        let feed = makeFeed(server, sleeper)
        model.homeFeedSlot = feed   // scope nil: the signed-out model's own feed
        model.isForeground = false
        #expect(feed.isPaused)
        model.isForeground = true
        #expect(!feed.isPaused)

        let other = HomeFeed(scope: "another-account", cache: nil, read: { try await server.read($0) },
                             sleep: { try await sleeper.sleep($0) })
        model.homeFeedSlot = other
        model.homeFeedSessionChanged()   // what `session`'s didSet runs
        #expect(other.isStopped && model.homeFeedSlot == nil)

        model.homeFeedSlot = feed
        model.signOut()
        #expect(feed.isStopped && model.homeFeedSlot == nil)
    }

    /// M2: a launch whose every read is cut short stops spinning once the retries run out.
    @Test func endlessCancellationEndsInTryAgain() async throws {
        let server = FakeServer(), sleeper = ManualSleep()
        server.answer = { _ in throw CancellationError() }
        let feed = makeFeed(server, sleeper)
        await feed.show(key)
        for _ in 0..<3 { await sleeper.release() }
        #expect(await eventually { if case .failed = feed.state { true } else { false } })
    }

    /// M3: offline, the saved online shelves are left alone.
    @Test func offlineNeverOverwritesTheSavedShelves() async throws {
        let cache = HomeShelfCache(root: root, scope: "offline1")
        cache.save([HomeShelf(section: .jumpBackIn, items: [.album(Self.album("online"))])])
        let server = FakeServer(), sleeper = ManualSleep()
        let feed = makeFeed(server, sleeper, cache: cache)
        await feed.show(.make(sections: [.downloaded], offline: true, onPhone: 1, genres: .defaultValue))
        #expect(feed.state.value?.found[.downloaded] != nil)
        #expect(cache.load().map(\.section) == [.jumpBackIn])
    }

    /// M4: every server section failed, some cut short: no throw; the real failures fail, the rest stay unread.
    @Test func mixedFailuresKeepCancelledSectionsUnread() throws {
        let read = try AppModel.assemble(wanted: [.jumpBackIn, .recentlyAdded],
                                         results: [.failure(URLError(.cancelled)), .failure(URLError(.timedOut))])
        #expect(read.cancelled == [.jumpBackIn] && read.failed == [.recentlyAdded])
        #expect(throws: URLError.self) {
            try AppModel.assemble(wanted: [.jumpBackIn, .recentlyAdded],
                                  results: [.failure(URLError(.timedOut)), .failure(URLError(.badServerResponse))])
        }
        #expect(throws: CancellationError.self) {
            try AppModel.assemble(wanted: [.jumpBackIn], results: [.failure(CancellationError())])
        }
    }

    // MARK: - Sign-out

    @Test func signOutRemovesTheSavedShelves() async throws {
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: root, engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: "HomeFeedTests.\(UUID().uuidString)")!,
                             systemNowPlaying: false, notifications: false)
        let cache = HomeShelfCache(root: root, scope: "abc123")
        cache.save([HomeShelf(section: .jumpBackIn, items: [.album(Self.album("cached"))])])
        #expect(FileManager.default.fileExists(atPath: cache.url.path))
        model.signOut()
        #expect(!FileManager.default.fileExists(atPath: HomeShelfCache.directory(root: root).path))
    }
}
