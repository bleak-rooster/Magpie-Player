import AurralKit
import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import SwiftUI
import Testing
@testable import Magpie

/// Aurral (stub) and Navidrome (mock); a chart flow's song writes can be made to fail, and each one notes what the
/// phone had saved at that moment (the feeds file under `dataDirectory`).
final class ChartWriteRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = MockTransport()
    let dataDirectory: URL
    private let lock = NSLock()
    private var failing = false
    private var savedAtWrite: [Data] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    /// Fix round 1: chart-flow song writes wait (until released) once they arrive.
    func holdWrites(_ on: Bool) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = on
            guard !on else { return [] }
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    /// How many writes are waiting.
    var heldCount: Int { lock.withLock { held.count } }

    init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    func failWrites(_ on: Bool) { lock.withLock { failing = on } }
    /// The feeds file as it was on disk when each chart-flow song write arrived.
    var savedWhenSent: [Data] { lock.withLock { savedAtWrite } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.host == aurral.host else { return try await navidrome.send(request) }
        let path = request.url?.path ?? ""
        if request.httpMethod == "POST", path.hasSuffix("/track-removals") || path.hasSuffix("/tracks") {
            let saved = Self.feedsFiles(in: dataDirectory).compactMap { try? Data(contentsOf: $0) }
                .first { String(decoding: $0, as: UTF8.self).contains("chartFlows") }
            let fail = lock.withLock { () -> Bool in
                if let saved { savedAtWrite.append(saved) }
                return failing
            }
            if lock.withLock({ holding }) {
                await withCheckedContinuation { continuation in
                    let wait = lock.withLock { () -> Bool in
                        guard holding else { return false }
                        held.append(continuation)
                        return true
                    }
                    if !wait { continuation.resume() }
                }
            }
            if fail, let url = request.url {
                return (Data(#"{"error":"boom"}"#.utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
        }
        return try await aurral.send(request)
    }

    static func feedsFiles(in directory: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
    }
}

/// Round 27 D2 (owner item 16, 2026-11-14, D317–D320): Trending's rows play the chart flow's songs in full, a song on
/// its way says so, the flow keeps up with its chart once a day, and a new flow starts at the whole chart.
@MainActor @Suite(.serialized) final class TrendingFlowCopiesAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "TrendingFlowCopiesAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "TrendingFlowCopiesAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var transport = ChartWriteRouting(dataDirectory: tmp)
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    var aurral: StubAurral { transport.aurral }
    private var chartWrites: [String] { aurral.asked.filter { $0.contains("/api/playlists/shared-playlists") } }

    func model(aurralSetUp: Bool = true, lidarr: Bool = false) async throws -> AppModel {
        aurral.useAurral213()
        aurral.setSyncedCreationDelay(reads: 0)
        nav.install(on: transport.navidrome)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    /// The stub's worldwide chart song N's length (`StubAurralDiscover.song`).
    static func seconds(_ n: Int) -> Int { 180 + (3_140_000 + n - 1) % 60 }

    /// Makes and confirms the worldwide flow of `count`, then publishes its Navidrome playlist ("Top Worldwide") with
    /// the songs `published` (by chart number) as Aurral's copies, and reads Discover so it knows the playlist.
    private func flowOnServer(_ model: AppModel, count: Int, published: [Int]) async throws -> (ChartPage, ChartFlow) {
        let page = try await model.chartPage(.worldwide)
        _ = try await model.createChartFlow(page, count: count)
        #expect(await model.checkChartFlow(page) == .live(.inYourFlows))
        for n in published {
            nav.songs["w-\(n)"] = .init(id: "w-\(n)", title: "World Song \(n)", artist: "World Artist \((n - 1) % 7 + 1)",
                                        duration: Self.seconds(n) + 1, mbid: nil, library: 2)
        }
        nav.lists["pl-top"] = ("Top Worldwide", published.map { "w-\($0)" })
        await model.refreshDiscover(force: true)
        let flow = try #require(model.chartFlow(for: .worldwide))
        #expect(model.chartFlowPlaylist(for: .worldwide)?.playlistId == "pl-top", "Discover knows the flow's playlist")
        return (page, flow)
    }

    // MARK: - Rows (D317, D318)

    @Test func trending_matchedRowPlaysInFullNoPreview() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, _) = try await flowOnServer(model, count: 10, published: Array(1...10))
        let reads = transport.navidrome.requests.filter { $0.url?.path.hasSuffix("/rest/getPlaylist") == true }.count
        let rows = await model.chartRows(chart: .worldwide, songs: page.songs)
        #expect(transport.navidrome.requests.filter { $0.url?.path.hasSuffix("/rest/getPlaylist") == true }.count == reads + 1,
                "the flow's playlist is read once")
        #expect((0..<10).allSatisfy { rows.copies[$0]?.id == "w-\($0 + 1)" }, "\(rows.copies.mapValues(\.id))")
        #expect(rows.copies[10] == nil && rows.onItsWay.isEmpty)
        #expect(ChartSongRow.kind(copy: rows.copies[2], onItsWay: false) == .library, "played as a library row, no preview")
        // The list plays the shown playable rows from the tapped one.
        let queue = ChartSongList.playOrder(copies: rows.copies, from: 2)
        #expect(queue?.songs.map(\.id) == (1...10).map { "w-\($0)" } && queue?.start == 2)
        model.play(queue?.songs ?? [], startAt: queue?.start ?? 0)
        #expect(model.player.queue.current?.song.id == "w-3", "the whole song from the flow's playlist")
        // Without the chart (or for another chart) nothing is matched.
        #expect(await model.chartRows(chart: nil, songs: page.songs).copies.isEmpty)
        #expect(await model.chartRows(chart: .genre(132), songs: page.songs).copies.isEmpty)
    }

    @Test func trending_onItsWayRow() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, flow) = try await flowOnServer(model, count: 6, published: [1, 2, 3, 4])
        let waiting = model.discover.jobs.filter { $0.flowId == flow.playlistId && ["World Song 5", "World Song 6"].contains($0.trackName) }
        #expect(waiting.count == 2)
        aurral.setJobStatus(waiting[0].id, "pending")
        aurral.setJobStatus(waiting[1].id, "failed")
        await model.refreshDiscover(force: true)
        let rows = await model.chartRows(chart: .worldwide, songs: page.songs)
        let five = try #require(page.songs.firstIndex { $0.title == "World Song 5" })
        let six = try #require(page.songs.firstIndex { $0.title == "World Song 6" })
        #expect(rows.onItsWay == [five], "pending says On its way; failed doesn't")
        #expect(ChartSongRow.kind(copy: nil, onItsWay: true) == .onItsWay)
        #expect(ChartSongRow.kind(copy: rows.copies[six], onItsWay: rows.onItsWay.contains(six)) == .preview)
        #expect(ChartFlowRowCopy.onItsWay == "On its way" && ChartFlowRowCopy.onItsWaySymbol == "arrow.down.circle.dotted")
    }

    @Test func trending_unmatchedKeepsPreview() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, _) = try await flowOnServer(model, count: 3, published: [1, 2, 3])
        let rows = await model.chartRows(chart: .worldwide, songs: page.songs)
        #expect(rows.copies.count == 3)
        for index in 3..<page.songs.count {
            #expect(ChartSongRow.kind(copy: rows.copies[index], onItsWay: rows.onItsWay.contains(index)) == .preview)
        }
    }

    /// No words about where the songs live.
    @Test func trending_noWordsAboutAurral() {
        let words = [ChartFlowRowCopy.onItsWay, ChartFlowRowCopy.keepsUp,
                     PreviewRow<EmptyView>.accessibilityLabel(title: "World Song 1", artist: "World Artist 1", inLibrary: true)]
        for text in words {
            for banned in ["Aurral", "Lidarr", "Navidrome", "Discover", "flow\u{2019}s library", "playlist"] {
                #expect(!text.localizedCaseInsensitiveContains(banned), "\(text)")
            }
        }
        #expect(ChartFlowRowCopy.keepsUp == "Keeps up with the chart once a day.")
    }

    // MARK: - Keeping up (D319)

    @Test func keepUp_sendsOnceADayWhenChanged() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (page, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        let before = chartWrites
        // Within the day: nothing, changed or not.
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        #expect(await !model.keepChartFlowUp(moved))
        #expect(await !model.keepChartFlowUp(page))
        #expect(chartWrites == before)
        // A day on, the chart's top 10 changed: the existing removal and append, once.
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        #expect(await model.keepChartFlowUp(moved))
        let base = "/api/playlists/shared-playlists/\(flow.playlistId)"
        #expect(Array(chartWrites.dropFirst(before.count)) == ["POST \(base)/track-removals", "POST \(base)/tracks"])
        #expect(Set(aurral.sharedPlaylistSongs(flow.playlistId)?.map(\.title) ?? []) == Set((4...13).map { "World Song \($0)" }))
        #expect(model.chartFlow(for: .worldwide)?.count == 10, "the same N")
        let sent = chartWrites
        #expect(await !model.keepChartFlowUp(moved), "at most once a day")
        // Another day on with the chart unchanged: nothing.
        model.aurralFeeds.now = { start.addingTimeInterval(2 * AppModel.chartFlowKeepUpInterval + 120) }
        await model.refreshDiscover(force: true)
        #expect(await !model.keepChartFlowUp(moved))
        #expect(chartWrites == sent && !chartWrites.contains { $0.hasPrefix("PUT") })
    }

    @Test func keepUp_notWhileRunning() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (_, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        model.discover.refreshing[flow.playlistId] = RefreshLatch(startedAt: model.discover.now(), lastRunAt: nil)
        #expect(model.isFlowRunActive(flow.playlistId))
        let before = chartWrites
        #expect(await !model.keepChartFlowUp(moved))
        #expect(chartWrites == before)
        #expect(model.chartFlow(for: .worldwide)?.refreshedAt == flow.refreshedAt, "nothing marked")
    }

    @Test func keepUp_savedBeforeSend() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.aurralFeeds.now = { start }
        let (_, _) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        let later = start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60)
        model.aurralFeeds.now = { later }
        transport.failWrites(true)
        #expect(await !model.keepChartFlowUp(moved), "the send failed")
        let saved = try #require(transport.savedWhenSent.first, "the phone's copy at the moment of sending")
        let book = try #require(Self.book(in: saved))
        #expect(book.flow(for: TrendingChart.worldwide.key)?.refreshedAt == later, "marked as sent before it went")
        // A failed send waits for the next day.
        transport.failWrites(false)
        let before = chartWrites
        #expect(await !model.keepChartFlowUp(moved))
        #expect(chartWrites == before)
    }

    @Test func keepUp_404Forgets() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (_, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        aurral.setDeleteDelay(reads: 0)
        try await model.aurralClient?.deleteChartFlow(playlistId: flow.playlistId)   // gone on the server
        _ = try await model.aurralClient?.status()   // its queued delete runs (the phone's copy of the status still lists it)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        #expect(await !model.keepChartFlowUp(moved))
        #expect(model.chartFlow(for: .worldwide) == nil, "forgotten: Create flow… shows again")
        #expect(model.aurralFeeds.chartFlows.wasRemoved(flow.playlistId))
    }

    @Test func keepUp_neverOthersOrOffline() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (_, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        let before = chartWrites
        // Offline: nothing.
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await !model.keepChartFlowUp(moved))
        model.updatePreferences { $0.downloads.offlineMode = .off }
        // A flow the user's own list doesn't hold (another user's playlist): nothing.
        model.aurralFeeds.noteChartFlow(ChartFlow(chartKey: TrendingChart.worldwide.key, playlistId: "sams-playlist",
                                                  name: "Top Worldwide", count: 10, createdAt: start, refreshedAt: start,
                                                  confirmed: true))
        #expect(await !model.keepChartFlowUp(moved))
        #expect(chartWrites == before)
        // A flow not yet confirmed: nothing.
        model.aurralFeeds.noteChartFlow(ChartFlow(chartKey: TrendingChart.worldwide.key, playlistId: flow.playlistId,
                                                  name: flow.name, count: 10, createdAt: start, refreshedAt: start))
        #expect(await !model.keepChartFlowUp(moved))
        #expect(chartWrites == before)
    }

    /// Reading Trending's default chart (as Home's shelf does) keeps its flow up too.
    @Test func keepUp_fromTheTrendingRead() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        _ = await model.makeDefaultChart(.worldwide)
        let (_, flow) = try await flowOnServer(model, count: 5, published: Array(1...5))
        aurral.setWorldwideChartOffset(2)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        await model.aurralFeeds.refresh(.trending, force: true)
        let base = "/api/playlists/shared-playlists/\(flow.playlistId)"
        #expect(await eventually { self.chartWrites.contains("POST \(base)/tracks") }, "\(chartWrites)")
        #expect(Set(aurral.sharedPlaylistSongs(flow.playlistId)?.map(\.title) ?? []) == Set((3...7).map { "World Song \($0)" }))
    }

    // MARK: - Fix round 1

    /// I1: the No. 1 and Play play in full what the list has; Play previews leaves those rows out (and hides when every
    /// row plays in full).
    @Test func trending_spotlightAndPlayButtonsPlayInFull() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, _) = try await flowOnServer(model, count: 10, published: Array(1...10))
        let rows = await model.chartRows(chart: .worldwide, songs: page.songs)
        #expect(rows.playOrder(from: 0)?.songs.first?.id == "w-1", "the No. 1 plays the flow's song")
        let play = try #require(ChartPlayButtons.playOrder(rows))
        #expect(play.songs.map(\.id) == (1...10).map { "w-\($0)" } && play.start == 0)
        let previews = ChartPlayButtons.previewSongs(page.songs, rows)
        #expect(previews.count == page.songs.count - 10)
        #expect(!previews.contains { song in (1...10).contains { song.title == "World Song \($0)" } }, "no preview of a song it holds")
        let all = ChartRows(copies: Dictionary(uniqueKeysWithValues: page.songs.indices.map {
            ($0, Song(id: "x\($0)", title: "", artist: "", album: "", duration: 1))
        }))
        #expect(ChartPlayButtons.previewSongs(page.songs, all).isEmpty, "Play previews hides")
        #expect(ChartPlayButtons.playOrder(ChartRows()) == nil, "no Play without a row to play")
        #expect(ChartFlowRowCopy.play == "Play")
    }

    /// Design H1: the flow's copies are never said to be "in your library".
    @Test func trending_flowCopyNotInLibrary() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (page, _) = try await flowOnServer(model, count: 4, published: [1, 2, 3, 4])
        let rows = await model.chartRows(chart: .worldwide, songs: page.songs)
        #expect(rows.flowRows == Set(0..<4))
        #expect(!ChartSongRow.showsInLibrary(flowCopy: true) && ChartSongRow.showsInLibrary(flowCopy: false))
        #expect(PreviewRow<EmptyView>.accessibilityLabel(title: "World Song 1", artist: "World Artist 1",
                                                         inLibrary: ChartSongRow.showsInLibrary(flowCopy: true))
                == "World Song 1, World Artist 1")
    }

    /// Design H2, M1: a row on its way offers no second Try or Add, and says "on its way" in its own label.
    @Test func trending_onItsWayNoSecondTry() {
        #expect(OutsideSongMenu.items(onItsWay: true) == [.onItsWay, .save])
        #expect(OutsideSongMenu.items(onItsWay: false) == [.tryIt, .addToLibrary, .addArtist, .save])
        #expect(PreviewRow<EmptyView>.accessibilityLabel(title: "World Song 5", artist: "World Artist 5", inLibrary: false,
                                                         note: ChartFlowRowCopy.onItsWayNote)
                == "World Song 5, World Artist 5, on its way")
    }

    /// M4: the list's key follows the flow's playlist and its songs' states.
    @Test func trending_rowsFollowDownloads() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.chartFlowSignature(.worldwide).isEmpty)
        let (_, flow) = try await flowOnServer(model, count: 3, published: [1, 2, 3])
        let before = model.chartFlowSignature(.worldwide)
        #expect(before.hasPrefix("pl-top|"))
        let job = try #require(model.discover.jobs.first { $0.flowId == flow.playlistId })
        aurral.setJobStatus(job.id, "pending")
        await model.refreshDiscover(force: true)
        #expect(model.chartFlowSignature(.worldwide) != before)
    }

    /// I2: a keep-up started from a page that goes away (its task cancelled) still finishes.
    @Test func keepUp_backgroundSurvivesCancel() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (_, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        let page = Task { @MainActor () -> Task<Bool, Never> in
            withUnsafeCurrentTask { $0?.cancel() }   // the page went away (switching charts)
            return model.keepChartFlowUpInBackground(moved)
        }
        let inner = await page.value
        #expect(await inner.value, "the send finished")
        let base = "/api/playlists/shared-playlists/\(flow.playlistId)"
        #expect(chartWrites.suffix(2) == ["POST \(base)/track-removals", "POST \(base)/tracks"])
    }

    /// I3: a Refresh now or Songs: N during a keep-up is refused (and the other way round): never a second append.
    /// Fix round 2 (m2): the hand sends run in their own tasks and must be refused while the keep-up's write is still
    /// held, so an unlocked build fails here instead of hanging.
    @Test(.timeLimit(.minutes(1))) func keepUp_lockedAgainstHandSends() async throws {
        let model = try await model()
        defer { model.signOut(); transport.holdWrites(false) }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (page, flow) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        transport.holdWrites(true)
        let keepUp = model.keepChartFlowUpInBackground(moved)
        #expect(await eventually { self.transport.heldCount == 1 }, "the keep-up's first write is on its way")
        let answers = HandSendAnswers()
        Task {
            do { _ = try await model.refreshChartFlow(.worldwide); answers.refresh = .some(nil) } catch { answers.refresh = .some(error) }
        }
        Task {
            do { _ = try await model.resizeChartFlow(page, count: 5); answers.resize = .some(nil) } catch { answers.resize = .some(error) }
        }
        let refused = await eventually { answers.refresh != nil && answers.resize != nil }
        #expect(refused && transport.heldCount == 1, "both answered while the keep-up's write is still held")
        #expect((answers.refresh ?? nil) as? AurralError == .runActive)
        #expect((answers.resize ?? nil) as? AurralError == .runActive)
        transport.holdWrites(false)
        #expect(await keepUp.value)
        let base = "/api/playlists/shared-playlists/\(flow.playlistId)"
        #expect(chartWrites.filter { $0 == "POST \(base)/tracks" }.count == 1, "one append")
        // The other way round: a Songs: N under way, then a chart read a day later sends nothing.
        model.aurralFeeds.now = { start.addingTimeInterval(3 * AppModel.chartFlowKeepUpInterval) }
        aurral.setWorldwideChartOffset(6)
        let movedAgain = try await model.chartPage(.worldwide, fresh: true)
        await model.refreshDiscover(force: true)
        transport.holdWrites(true)
        let resize = Task { try await model.resizeChartFlow(movedAgain, count: 10) }
        #expect(await eventually { self.transport.heldCount == 1 })
        #expect(await !model.keepChartFlowUp(movedAgain))
        transport.holdWrites(false)
        _ = try await resize.value
    }

    /// M2: nothing is sent while the flow's songs aren't known, or without accessFlow; M3: nor from a short read.
    @Test func keepUp_noWriteWhenUnsure() async throws {
        let model = try await model()
        defer { model.signOut() }
        let start = Date()
        model.aurralFeeds.now = { start }
        let (_, _) = try await flowOnServer(model, count: 10, published: Array(1...10))
        aurral.setWorldwideChartOffset(3)
        let moved = try await model.chartPage(.worldwide, fresh: true)
        model.aurralFeeds.now = { start.addingTimeInterval(AppModel.chartFlowKeepUpInterval + 60) }
        let before = chartWrites
        // A chart read that lists fewer songs than the flow holds.
        var short = moved
        short.songs = Array(moved.songs.prefix(6))
        #expect(await !model.keepChartFlowUp(short))
        // The flow's songs unknown (Discover hasn't read them).
        let jobs = model.discover.jobs
        model.discover.jobs = []
        #expect(await !model.keepChartFlowUp(moved))
        model.discover.jobs = jobs
        // accessFlow gone.
        let bootstrap = model.discover.bootstrap
        model.discover.bootstrap = nil
        #expect(!model.aurralCanAddFlow)
        #expect(await !model.keepChartFlowUp(moved))
        model.discover.bootstrap = bootstrap
        #expect(chartWrites == before)
        #expect(await model.keepChartFlowUp(moved), "and with all of it known, it does")
    }

    // MARK: - A new flow's length (D320)

    @Test func defaultLengthWholeChart() async throws {
        #expect(AppModel.newChartFlowCount(chartLength: 30) == 30)
        #expect(AppModel.newChartFlowCount(chartLength: 150) == 100)
        #expect(AppModel.newChartFlowCount(chartLength: 0) == 1)
        let model = try await model()
        defer { model.signOut() }
        let page = try await model.chartPage(.worldwide)
        #expect(ChartFlowSheet.initialCount(page: page, flow: nil) == page.songs.count, "the whole chart")
        let existing = ChartFlow(chartKey: page.chart.key, playlistId: "p", name: "Top Worldwide", count: 12,
                                 createdAt: Date(), refreshedAt: Date(), confirmed: true)
        #expect(ChartFlowSheet.initialCount(page: page, flow: existing) == 12, "an existing flow keeps its N")
    }

    // MARK: - Setups (D321)

    @Test func fourSetups() async throws {
        // Navidrome alone, and with Lidarr: no charts, nothing matched, nothing kept up.
        for lidarr in [false, true] {
            let model = try await model(aurralSetUp: false, lidarr: lidarr)
            let song = ChartSong(AurralSong(key: "1", trackName: "World Song 1", artistName: "World Artist 1", albumName: nil,
                                            deezerAlbumId: nil, durationMs: 181_000, artwork: nil, preview: nil, position: 1))
            #expect(await model.chartRows(chart: .worldwide, songs: [song]).copies.isEmpty)
            #expect(model.chartFlowPlaylist(for: .worldwide) == nil)
            #expect(await !model.keepChartFlowUp(ChartPage(chart: .worldwide, name: "Top Worldwide", songs: [song], playlistId: nil,
                                                           libraryPlaylistId: nil)))
            model.signOut()
        }
        #expect(aurral.asked.isEmpty)
        // With Aurral (and with everything): matched rows.
        for lidarr in [false, true] {
            let model = try await model(lidarr: lidarr)
            let (page, _) = try await flowOnServer(model, count: 2, published: [1, 2])
            #expect(await model.chartRows(chart: .worldwide, songs: page.songs).copies.count == 2)
            try await model.removeChartFlow(.worldwide)
            nav.lists["pl-top"] = nil
            model.signOut()
        }
    }

    /// The chart flows' book in a saved feeds file.
    static func book(in data: Data) -> ChartFlowBook? {
        struct File: Decodable { var chartFlows: ChartFlowBook? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return (try? decoder.decode(File.self, from: data))?.chartFlows
    }
}

/// Fix round 2 (m2): what each hand send answered (nil: not yet; .some(nil): it went through).
@MainActor final class HandSendAnswers {
    var refresh: Error??
    var resize: Error??
}
