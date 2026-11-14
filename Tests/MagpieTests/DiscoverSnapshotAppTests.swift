import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

/// Round 27 D1 (owner, 2026-11-14, item 2: "When you open discover, it should have all of the flows and aurral playlists
/// loaded then saved. So when you open it again, it can load quickly. In the background it checks for any changes and
/// then reloads it when it has updated. It then saves this for next time"; item 3; D283–D286): Discover saved, shown at
/// once, refreshed behind and swapped in place, against the stub Aurral and a small Navidrome (never the owner's).
@MainActor @Suite(.serialized) final class DiscoverSnapshotAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DiscoverSnapshotAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "DiscoverSnapshotAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = D1Routing()
    let aurralStore = MemoryAurralStore()
    let lidarrStore = MemoryLidarrStore()
    var aurral: StubAurral { transport.aurral }
    var nav: D1Navidrome { transport.navidrome }

    deinit {
        transport.releaseStatus()
        transport.navidrome.releasePlaylistReads()
        transport.navidrome.releaseLookups()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static let recording = "0383dadf-2a4e-4d10-a46a-e9e041da8eb3"
    static let server = URL(string: "http://192.168.1.2:4533")!

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                 aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                 notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    /// Discover Weekly (the user's flow): Lullaby (copy by recording id), Words (copy by title), Unknown Song (none),
    /// and two main-library songs it refers to. `sams`: Sam's flow "Sam Mix" with its own playlist. `extraFlows`: more
    /// flows of `extraSongs` Aurral songs each, none with a library copy.
    func signedIn(sams: Bool = false, extraFlows: Int = 0, extraSongs: Int = 2, aurralSetUp: Bool = true) async throws -> AppModel {
        nav.add(.init(id: "a-lullaby", title: "Lullaby", artist: "Low", duration: 251, mbid: Self.recording, library: 2))
        nav.add(.init(id: "a-words", title: "Words", artist: "Low", duration: 200, mbid: nil, library: 2))
        nav.add(.init(id: "a-unknown", title: "Unknown Song", artist: "Nobody", duration: 180, mbid: nil, library: 2))
        nav.add(.init(id: "m-lullaby", title: "Lullaby", artist: "Low", duration: 252, mbid: Self.recording, library: 1))
        nav.add(.init(id: "m-words", title: "Words", artist: "Low", duration: 201, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref1", title: "Ref One", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.add(.init(id: "m-ref2", title: "Ref Two", artist: "Q", duration: 100, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2"])
        nav.setList("pl-road", "Road trip", ["m-ref1"])
        var flows: [StubAurral.Flow] = [.init(id: "flow-dw", name: "Discover Weekly")]
        var jobs: [StubAurral.Job] = [
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: Self.recording, durationMs: 251_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Lullaby.flac"),
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Words", durationMs: 200_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Words.flac"),
            .init(flowId: "flow-dw", artistName: "Nobody", trackName: "Unknown Song", durationMs: 180_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Nobody/Single/Unknown Song.mp3"),
        ]
        if sams {
            aurral.addUser(id: 2, username: "sam", password: "sam-pw")
            nav.add(.init(id: "a-sam1", title: "Sam One", artist: "S", duration: 120, mbid: nil, library: 2))
            nav.add(.init(id: "a-sam2", title: "Sam Two", artist: "S", duration: 130, mbid: nil, library: 2))
            nav.setList("pl-sam", "Sam Mix", ["a-sam1", "a-sam2"])
            flows.append(.init(id: "flow-sam", name: "Sam Mix", ownerUserId: 2))
            jobs += [.init(flowId: "flow-sam", artistName: "S", trackName: "Sam One", durationMs: 120_000),
                     .init(flowId: "flow-sam", artistName: "S", trackName: "Sam Two", durationMs: 130_000)]
        }
        for i in 0..<extraFlows {
            for j in 0..<extraSongs {
                nav.add(.init(id: "a-x\(i)-\(j)", title: "Extra \(i) \(j)", artist: "X", duration: 150, mbid: nil, library: 2))
                jobs.append(.init(flowId: "flow-x\(i)", artistName: "X", trackName: "Extra \(i) \(j)", durationMs: 150_000))
            }
            nav.setList("pl-x\(i)", "Extra \(i)", (0..<extraSongs).map { "a-x\(i)-\($0)" })
            flows.append(.init(id: "flow-x\(i)", name: "Extra \(i)"))
        }
        aurral.setFlows(flows)
        aurral.setJobs(jobs)
        let model = makeModel()
        try await model.signIn(urls: [Self.server], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        await model.scopeIndexRefresh?.value
        return model
    }

    /// A cold start on the same Keychain, Aurral store, defaults and files.
    func relaunched() async -> AppModel {
        let model = makeModel()
        model.resumeSavedSession()
        await model.refreshMusicFolders()
        await model.matchIndexSettled()
        return model
    }

    func file(_ model: AppModel) throws -> URL {
        DiscoverSnapshotFile(root: tmp, scope: try #require(model.aurralFeedsScope)).url
    }

    /// Polls `condition` with a deadline (never a sleep).
    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { await Task.yield() }
        return condition()
    }

    // MARK: - Rows

    /// "Only mine" and everyone's, from the saved rows exactly as the last read decided (D189, D190, D205).
    @Test func savedRowsRespectEveryoneSwitch() async throws {
        let first = try await signedIn(sams: true)
        #expect(first.isOthersDiscoverPlaylist(Playlist(id: "pl-sam", name: "Sam Mix", songCount: 2, duration: 0)))
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        nav.reset()
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"])
        model.showEveryonesFlows = true
        #expect(try await model.discoverPlaylists().map(\.id).sorted() == ["pl-dw", "pl-sam"])
        #expect(model.discoverOwnerCaption(playlistId: "pl-sam") == "sam")
        #expect(model.discoverOwnerCaption(playlistId: "pl-dw") == nil)
        #expect(!model.isDiscoverPlaylist(id: "pl-road") && model.isDiscoverPlaylist(id: "pl-sam"), "D185 unchanged")
        #expect(nav.getPlaylists == 0)
    }

    /// Never without Aurral, never offline, never while Aurral refuses the user its flows.
    @Test func savedRowsNeverWithoutAurralOrOffline() async throws {
        let first = try await signedIn()
        _ = first
        aurral.setStatusFailure(500)
        let model = await relaunched()
        defer { model.signOut() }
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(model.discover.playlists.isEmpty, "offline: nothing restored")
        model.updatePreferences { $0.downloads.offlineMode = .off }
        model.discover.flowsNotPermitted = true
        #expect(try await model.discoverPlaylists().isEmpty)
        #expect(model.discover.playlists.isEmpty, "no flows allowed: nothing restored")
        model.discover.flowsNotPermitted = false
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"])
        let url = try file(model)
        model.disconnectAurral()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await model.discoverPlaylists().isEmpty)
    }

    /// The same rows after the read: nothing moves. A real change: swapped in place, once.
    @Test func refreshSwapsOnlyWhenDifferent() async throws {
        _ = try await signedIn()
        let model = await relaunched()
        defer { model.signOut() }
        let list = DiscoverListModel()
        await list.load(model)
        #expect(list.rows.value?.map(\.id) == ["playlist:pl-dw"])
        let revision = model.discover.rowsRevision
        await model.refreshDiscover(force: true)
        await list.load(model)
        #expect(list.visibleChanges == 0, "same rows: nothing changes")
        #expect(model.discover.rowsRevision == revision)
        nav.add(.init(id: "a-new", title: "New Song", artist: "Low", duration: 210, mbid: nil, library: 2))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2", "a-new"],
                    changed: "2026-11-02T10:00:00Z")
        await model.refreshDiscover(force: true)
        #expect(model.discover.rowsRevision == revision + 1)
        await list.load(model)
        #expect(list.visibleChanges == 1)
        guard case .playlist(let playlist)? = list.rows.value?.first?.link else { Issue.record("no row"); return }
        #expect(playlist.songCount == 6)
        let saved = DiscoverSnapshotFile(root: tmp, scope: try #require(model.aurralFeedsScope)).load()
        #expect(saved?.rows.first?.playlist.songCount == 6, "saved for next time")
    }

    // MARK: - A page

    /// The saved page shows while the playlist is still being read.
    @Test func pageShowsSavedAtOnce() async throws {
        let first = try await signedIn()
        _ = try await first.discoverPage(playlistId: "pl-dw")
        let model = await relaunched()
        defer { nav.releasePlaylistReads(); model.signOut() }
        nav.holdPlaylistReads()
        let page = DiscoverPageModel(playlistId: "pl-dw")
        let loading = Task { await page.load(model, fresh: false) }
        #expect(await eventually { page.page != nil })
        #expect(page.page?.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"])
        #expect(page.page?.entries.map(\.inYourLibrary) == [true, true, false, false, false])
        nav.releasePlaylistReads()
        await loading.value
        #expect(page.visibleChanges == 0, "the same songs: nothing moved")
    }

    /// Reopened with nothing changed: one read of the playlist and no lookups at all, also after a relaunch.
    @Test func unchangedPageSendsOneGetPlaylistAndNoLookups() async throws {
        let first = try await signedIn()
        _ = try await first.discoverPage(playlistId: "pl-dw")
        let model = await relaunched()
        defer { model.signOut() }
        nav.reset()
        let page = DiscoverPageModel(playlistId: "pl-dw")
        await page.load(model, fresh: false)
        #expect(nav.getPlaylist == ["pl-dw"])
        #expect(nav.lookupCount == 0, "\(nav.search3) \(nav.recordingLookups)")
        #expect(page.visibleChanges == 0)
    }

    /// A first-ever open shows the songs after one read, before any lookup lands; then the copies fill in, in place.
    @Test func firstOpenShowsSongsBeforeLookups() async throws {
        let model = try await signedIn()
        defer { nav.releaseLookups(); model.signOut() }
        model.discover.lookups = [:]   // nothing looked up yet
        model.discover.copies = [:]
        nav.holdLookups()
        let page = DiscoverPageModel(playlistId: "pl-dw")
        let loading = Task { await page.load(model, fresh: false) }
        #expect(await eventually { page.page != nil })
        #expect(page.page?.entries.map(\.song.id) == ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2"],
                "Aurral's copies until their lookups land")
        nav.releaseLookups()
        await loading.value
        #expect(page.page?.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"])
    }

    /// The copies fill their own rows: the order and the playlist's songs never change, only what plays in a row.
    @Test func copiesFillInPlace() async throws {
        let model = try await signedIn()
        defer { nav.releaseLookups(); model.signOut() }
        model.discover.lookups = [:]
        model.discover.copies = [:]
        nav.holdLookups()
        let page = DiscoverPageModel(playlistId: "pl-dw")
        let loading = Task { await page.load(model, fresh: false) }
        #expect(await eventually { page.page != nil })
        var seen: [[String]] = []
        nav.releaseLookups()
        while page.page?.entries.map(\.song.id) != ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"] {
            if let ids = page.page?.entries.map(\.original.id) { seen.append(ids) }
            await Task.yield()
            if seen.count > 100_000 { break }
        }
        await loading.value
        #expect(seen.allSatisfy { $0 == ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2"] })
        #expect(page.page?.entries.map(\.original.id) == ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2"])
        #expect(page.visibleChanges >= 2, "filled in, row by row")
    }

    /// Aurral never answering: the page still opens, within the three-second bound (no saved copy at all).
    @Test func pageNeverWaitsForWholeDiscoverRead() async throws {
        _ = try await signedIn()
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        model.forgetDiscoverSnapshots()   // a first open: nothing saved
        let clock = ContinuousClock(), start = clock.now
        let page = DiscoverPageModel(playlistId: "pl-dw")
        await page.load(model, fresh: false)
        // Fix round 1 (M5): the bound itself, and the one playlist read and its few lookups after it.
        #expect(clock.now - start < AppModel.discoverWait + .milliseconds(500), "took \(clock.now - start)")
        #expect(page.page?.entries.count == 5)
    }

    // MARK: - Lookups kept

    /// A saved copy stays while the match index still holds it; once it doesn't, it is looked up again.
    @Test func savedHitKeptWhileIndexHoldsIt() async throws {
        let first = try await signedIn()
        _ = try await first.discoverPage(playlistId: "pl-dw")
        let model = await relaunched()
        defer { model.signOut() }
        nav.reset()
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        #expect(nav.lookupCount == 0)
        nav.state.withLock { _ = $0.unindexed.insert("m-words") }
        try await model.refreshMatchIndex()
        nav.reset()
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        #expect(nav.search3 == ["words"], "only the copy the index lost: \(nav.search3) \(nav.recordingLookups)")
    }

    /// A song with no copy is asked again after a day, not before.
    @Test func savedMissAskedAgainAfterADay() async throws {
        let first = try await signedIn()
        _ = try await first.discoverPage(playlistId: "pl-dw")
        let model = await relaunched()
        defer { model.signOut() }
        await model.refreshDiscover(force: true)   // Aurral's library known: the library's own songs need nothing
        let now = Date()
        model.discover.now = { now.addingTimeInterval(23 * 3600) }
        nav.reset()
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        #expect(nav.lookupCount == 0)
        model.discover.now = { now.addingTimeInterval(25 * 3600) }
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        #expect(nav.search3 == ["unknown song"], "\(nav.search3) \(nav.recordingLookups)")
    }

    /// Pull to refresh looks every one of Aurral's songs up again (never the library's own).
    @Test func pullLooksEverythingUp() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        _ = try await model.discoverPage(playlistId: "pl-dw")
        nav.reset()
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        #expect(nav.lookupCount == 0)
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: true)
        #expect(Set(nav.search3) == ["words", "unknown song"] && nav.recordingLookups == [Self.recording],
                "\(nav.search3) \(nav.recordingLookups)")
    }

    /// Played before the lookups landed: a copy found later takes the song's place where it is still to come; the song
    /// playing now plays on.
    @Test func lateCopyReplacesQueuedSong() async throws {
        let model = try await signedIn()
        defer { nav.releaseLookups(); model.signOut() }
        model.discover.lookups = [:]
        model.discover.copies = [:]
        nav.holdLookups()
        let page = DiscoverPageModel(playlistId: "pl-dw")
        let loading = Task { await page.load(model, fresh: false) }
        #expect(await eventually { page.page != nil })
        model.play(try #require(page.page).songs, startAt: 0)
        #expect(model.player.queue.current?.song.id == "a-lullaby")
        nav.releaseLookups()
        await loading.value
        #expect(model.player.queue.current?.song.id == "a-lullaby", "the song playing plays on")
        #expect(model.player.queue.upcoming.map(\.song.id) == ["m-words", "a-unknown", "m-ref1", "m-ref2"])
    }

    /// Fix round 1 (I2): the flow rotated after Aurral's library was read: its new song (a job of the flow) is looked up
    /// when the page opens, and again after the next read; never taken for the library's own and kept so for a day.
    @Test func newAurralSongAfterLibraryReadIsLookedUp() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discover.discoverLibrarySongIds != nil, "Aurral's library read in full")
        nav.add(.init(id: "a-new", title: "New One", artist: "Fresh", duration: 200, mbid: nil, library: 2))
        nav.add(.init(id: "m-new", title: "New One", artist: "Fresh", duration: 201, mbid: nil, library: 1))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2", "a-new"],
                    changed: "2026-11-02T10:00:00Z")
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", trackMbid: Self.recording, durationMs: 251_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Lullaby.flac"),
            .init(flowId: "flow-dw", artistName: "Fresh", trackName: "New One", durationMs: 200_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Fresh/Single/New One.flac"),
        ])
        model.discover.statusReadAt = nil
        await model.refreshDiscover(force: true)   // the jobs name the new song; the library read is before it landed
        model.discover.discoverLibrarySongIds?.remove("a-new")
        nav.reset()
        let first = DiscoverPageModel(playlistId: "pl-dw")
        await first.load(model, fresh: false)
        #expect(nav.search3.contains("new one"), "looked up on the first open: \(nav.search3)")
        #expect(first.page?.entries.last?.song.id == "m-new")
        await model.refreshDiscover(force: true)
        let again = DiscoverPageModel(playlistId: "pl-dw")
        await again.load(model, fresh: false)
        #expect(again.page?.entries.last?.song.id == "m-new", "reopened: its library copy, never a day-long miss")
    }

    /// Fix round 1 (I2): a song skipped as the library's own leaves no lookup behind (asked anew on each open).
    @Test func ownLibrarySkipLeavesNoLookup() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        model.discover.lookups = [:]
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: true)
        #expect(model.discover.lookups["m-ref1"] == nil && model.discover.lookups["m-ref2"] == nil)
        let saved = DiscoverSnapshotFile(root: tmp, scope: try #require(model.aurralFeedsScope)).load()
        #expect(saved?.pages["pl-dw"]?.lookups["m-ref1"] == nil)
    }

    /// Fix round 1 (I3): the car and Play next take a saved page only while it is the playlist as Discover lists it
    /// now (same `changed` and song count); once a read lists it changed, the playlist is read.
    @Test func carReadsAPageThatChangedSinceItWasSaved() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        _ = try await model.discoverPage(playlistId: "pl-dw")
        nav.reset()
        _ = try await model.discoverPage(playlistId: "pl-dw")
        await model.discoverSnapshots.behind["pl-dw"]?.value
        #expect(nav.getPlaylist == ["pl-dw"], "the saved page, refreshed behind it: \(nav.getPlaylist)")
        nav.add(.init(id: "a-new", title: "New One", artist: "Fresh", duration: 200, mbid: nil, library: 2))
        nav.setList("pl-dw", "Discover Weekly", ["a-lullaby", "a-words", "a-unknown", "m-ref1", "m-ref2", "a-new"],
                    changed: "2026-11-02T10:00:00Z")
        await model.refreshDiscover(force: true)
        nav.state.withLock { $0.failPlaylistReads = true }
        await #expect(throws: (any Error).self, "changed since it was saved: read, never the old copy") {
            try await model.discoverPage(playlistId: "pl-dw")
        }
        nav.state.withLock { $0.failPlaylistReads = false }
        let car = try await CarPlayLibraryAdapter(model: model).playlist(id: "pl-dw")
        #expect(car.1.map(\.id).last == "a-new")
    }

    /// Fix round 1 (M2): a background pass's pages wait in memory, and go to the file with the next write that isn't
    /// held (here a page the owner opened), never all held until the pass ends.
    @Test func heldPassPagesWrittenWithTheNextWrite() async throws {
        let model = try await signedIn(extraFlows: 1)
        defer { model.signOut() }
        let url = try file(model)
        let scope = try #require(model.aurralFeedsScope)
        try await model.openDiscoverPage(playlistId: "pl-x0", fresh: false, waitForRead: false, background: true) { _ in }
        #expect(DiscoverSnapshotFile(root: tmp, scope: scope).load()?.pages["pl-x0"] == nil, "held")
        await DiscoverPageModel(playlistId: "pl-dw").load(model, fresh: false)
        let saved = try #require(DiscoverSnapshotFile(root: tmp, scope: scope).load())
        #expect(saved.pages["pl-x0"] != nil && saved.pages["pl-dw"] != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Fix round 1 (M3, D286): the first read after a launch starts from the restored playlists, as a later read starts
    /// from the last: a known playlist no flow is named as now (its flow renamed first) keeps the flow it had, even with
    /// Aurral's jobs unreadable (without the restore it would have had none: no Refresh Flow).
    @Test func restoredFlowsCarryIntoTheFirstRead() async throws {
        _ = try await signedIn()
        let model = await relaunched()
        defer { model.signOut() }
        aurral.setFlows([.init(id: "flow-dw", name: "Weekly Picks")])
        aurral.setJobsRoute(false)
        #expect(model.discoverRowsNow()?.map(\.id) == ["playlist:pl-dw"])
        await model.refreshDiscover(force: true)
        #expect(model.discover.statusReadAt != nil)
        #expect(model.discoverFlow(playlistId: "pl-dw")?.id == "flow-dw")
        #expect(model.discoverFlow(playlistId: "pl-dw")?.name == "Weekly Picks")
    }

    // MARK: - Every page, in the background

    /// At most 40 playlists and 400 lookups a pass, two pages at a time.
    @Test func backgroundPassBounded() async throws {
        _ = try await signedIn(extraFlows: 45, extraSongs: 12)
        transport.holdStatus()   // the pass alone reads playlists
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        nav.reset()
        let list = DiscoverListModel()
        await list.load(model)
        #expect(list.rows.value?.count == 46)
        await model.discoverPagePassSettled()
        #expect(nav.getPlaylist.count == AppModel.discoverPassPlaylists, "\(nav.getPlaylist.count)")
        #expect(model.discoverSnapshots.lastPassLookups == AppModel.discoverPassLookups)
        #expect(nav.lookupCount <= AppModel.discoverPassLookups)
        #expect(nav.peakInFlight <= 2, "peak \(nav.peakInFlight)")
        let saved = DiscoverSnapshotFile(root: tmp, scope: try #require(model.aurralFeedsScope)).load()
        #expect(saved?.pages.count == AppModel.discoverPassPlaylists)
        // Not again within ten minutes.
        nav.reset()
        await list.load(model)
        await model.discoverPagePassSettled()
        #expect(nav.getPlaylist.isEmpty)
    }

    /// A page saved with the same change and as many songs isn't read again; a changed one is.
    @Test func backgroundPassSkipsUnchanged() async throws {
        let first = try await signedIn(extraFlows: 2)
        await DiscoverListModel().load(first)
        await first.discoverPagePassSettled()
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        nav.reset()
        let list = DiscoverListModel()
        await list.load(model)
        await model.discoverPagePassSettled()
        #expect(nav.getPlaylist.isEmpty, "\(nav.getPlaylist)")
        nav.add(.init(id: "a-x0-9", title: "Extra 0 9", artist: "X", duration: 150, mbid: nil, library: 2))
        nav.setList("pl-x0", "Extra 0", ["a-x0-0", "a-x0-1", "a-x0-9"], changed: "2026-11-03T10:00:00Z")
        transport.releaseStatus()
        await model.refreshDiscover(force: true)
        transport.holdStatus()   // the pass alone reads playlists
        let now = Date()
        model.discover.now = { now.addingTimeInterval(11 * 60) }
        nav.reset()
        await list.load(model)
        await model.discoverPagePassSettled()
        #expect(nav.getPlaylist == ["pl-x0"], "\(nav.getPlaylist)")
    }

    // MARK: - The file

    @Test func fileHasNoURLsOrTokens() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        _ = try await model.discoverPage(playlistId: "pl-dw")
        let text = String(decoding: try Data(contentsOf: try file(model)), as: UTF8.self)
        #expect(text.contains("Discover Weekly") && text.contains("m-lullaby"))
        let token = try #require(aurralStore.load()?.login?.token)
        // Owners' usernames are what a caption shows (D205); never the address, the session or the password.
        for banned in ["http", "192.168", aurral.host, token, StubAurral.defaultPassword,
                       Self.recording, "_flows", "-pw"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        #expect(try file(model).lastPathComponent.hasSuffix("-lists.json"))
        #expect(!(try file(model).lastPathComponent.contains(StubAurral.defaultUsername)), "a hash, never a user name")
    }

    @Test func fileExcludedFromBackup() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        _ = try await model.discoverPage(playlistId: "pl-dw")
        let url = try file(model)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// Removed with D90's file: Aurral sign-out, another Aurral user, and the account's sign-out.
    @Test func fileRemovedAtAurralAndAccountSignOut() async throws {
        let model = try await signedIn()
        _ = try await model.discoverPage(playlistId: "pl-dw")
        let url = try file(model)
        #expect(FileManager.default.fileExists(atPath: url.path))
        model.disconnectAurral()
        #expect(!FileManager.default.fileExists(atPath: url.path), "Aurral sign-out")
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername, password: StubAurral.defaultPassword)
        _ = try await model.discoverPage(playlistId: "pl-dw")
        #expect(FileManager.default.fileExists(atPath: url.path))
        aurral.addUser(id: 4, username: "jordan", password: "jordan-pw", role: "admin")
        _ = try await model.connectAurral(base: aurral.base, username: "jordan", password: "jordan-pw")
        #expect(!FileManager.default.fileExists(atPath: url.path), "another Aurral user")
        _ = try await model.discoverPage(playlistId: "pl-dw")
        let jordans = try file(model)
        #expect(jordans != url)
        #expect(FileManager.default.fileExists(atPath: jordans.path))
        model.signOut()
        #expect(!FileManager.default.fileExists(atPath: jordans.path), "the account's sign-out")
    }

    // MARK: - Setups and identity

    /// Navidrome alone and + Lidarr: no file and no Discover. + Aurral and all: saved and refreshed.
    @Test(arguments: [false, true]) func fourSetups(_ lidarr: Bool) async throws {
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        let alone = try await signedIn(aurralSetUp: false)
        #expect(try await alone.discoverPlaylists().isEmpty)
        #expect(alone.aurralFeedsScope == nil)
        let directory = AurralFeeds.directory(root: tmp)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(!names.contains { $0.hasSuffix(DiscoverSnapshotFile.suffix) }, "no file without Aurral")
        _ = try await alone.connectAurral(base: aurral.base, username: StubAurral.defaultUsername, password: StubAurral.defaultPassword)
        #expect(try await alone.discoverPlaylists().map(\.id) == ["pl-dw"])
        #expect(FileManager.default.fileExists(atPath: try file(alone).path), "saved")
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"], "shown at once")
    }

    /// The saved rows are only what the last read decided: after a relaunch, the same playlists, flows, owners,
    /// captions and hidden set (D202–D205, D251, D271–D274 decide as before).
    @Test func identityDecisionsUnchanged() async throws {
        let first = try await signedIn(sams: true)
        first.showEveryonesFlows = true
        let before = (playlists: first.discover.playlists, others: first.othersDiscoverPlaylistIds,
                      owners: first.discover.playlistOwners, hidden: first.hiddenDiscoverPlaylistIds,
                      items: first.discover.itemRows)
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        _ = try await model.discoverPlaylists()
        func names(_ list: [DiscoverPlaylist]) -> [String] {
            list.map { "\($0.playlist.id)|\($0.flow.id)|\($0.flow.name)|\($0.flow.ownerUserId ?? -1)|\($0.flow.ownerUsername ?? "-")" }
        }
        #expect(names(model.discover.playlists) == names(before.playlists))
        #expect(model.discover.playlists.map(\.playlist) == before.playlists.map(\.playlist))
        #expect(model.othersDiscoverPlaylistIds == before.others)
        #expect(model.discover.playlistOwners == before.owners)
        #expect(model.hiddenDiscoverPlaylistIds == before.hidden)
        #expect(model.discover.itemRows == before.items.filter { !$0.mine })
        transport.releaseStatus()
        await model.refreshDiscover(force: true)
        #expect(model.discover.playlists.map(\.playlist.id) == before.playlists.map(\.playlist.id))
        #expect(model.othersDiscoverPlaylistIds == before.others)
    }
}
