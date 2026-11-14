import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Testing
@testable import Magpie

/// Round 27 D1: a gate requests wait at until the test lets them go (never a sleep).
final class D1Gate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>(initialState: (false, []))
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiting = [] }
            return s.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Round 27 D1: a small Navidrome for Discover's speed (never the owner's): libraries 1 (the main library) and 2
/// (Aurral's), playlists with `changed`, and counts of every read: playlists, each playlist, lookups by recording id
/// and by title, and how many playlist reads were in flight at once.
final class D1Navidrome: HTTPTransport, @unchecked Sendable {
    struct Entry: Sendable { var id, title, artist: String; var duration: Int; var mbid: String?; var library: Int }
    struct List: Sendable { var name: String; var songs: [String]; var changed: String? }
    struct State {
        var lists: [String: List] = [:]
        var songs: [String: Entry] = [:]
        /// Main-library songs the match index no longer lists (deleted from the library).
        var unindexed: Set<String> = []
        var failPlaylistReads = false
        var getPlaylists = 0
        var getPlaylist: [String] = []
        var search3: [String] = []
        var recordingLookups: [String] = []
        var inFlight = 0
        var peakInFlight = 0
        /// Playlist reads wait here until the test opens it (how many run at once is then plain to see).
        var playlistGate: D1Gate?
        /// Lookups (by recording id and by title) wait here until the test opens it.
        var lookupGate: D1Gate?
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func reset() {
        state.withLock { s in s.getPlaylists = 0; s.getPlaylist = []; s.search3 = []; s.recordingLookups = []; s.peakInFlight = 0 }
    }
    var getPlaylists: Int { state.withLock { $0.getPlaylists } }
    var getPlaylist: [String] { state.withLock { $0.getPlaylist } }
    var search3: [String] { state.withLock { $0.search3 } }
    var recordingLookups: [String] { state.withLock { $0.recordingLookups } }
    var lookupCount: Int { state.withLock { $0.search3.count + $0.recordingLookups.count } }
    var peakInFlight: Int { state.withLock { $0.peakInFlight } }
    var inFlight: Int { state.withLock { $0.inFlight } }
    func holdPlaylistReads() { state.withLock { $0.playlistGate = D1Gate() } }
    func releasePlaylistReads() { state.withLock { s in s.playlistGate?.open(); s.playlistGate = nil } }
    func holdLookups() { state.withLock { $0.lookupGate = D1Gate() } }
    func releaseLookups() { state.withLock { s in s.lookupGate?.open(); s.lookupGate = nil } }

    func add(_ e: Entry) { state.withLock { $0.songs[e.id] = e } }
    func setList(_ id: String, _ name: String, _ songs: [String], changed: String? = "2026-11-01T10:00:00Z") {
        state.withLock { $0.lists[id] = List(name: name, songs: songs, changed: changed) }
    }

    private static func ok(_ body: String = "") -> Data {
        Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
    }
    private static func value(_ r: URLRequest, _ name: String) -> String? {
        r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }
    private func child(_ e: Entry) -> String {
        #"{"id":"\#(e.id)","title":"\#(e.title)","artist":"\#(e.artist)","album":"A","albumId":"al-\#(e.id)","duration":\#(e.duration),"coverArt":"co-\#(e.id)"\#(e.mbid.map { #","musicBrainzId":"\#($0)""# } ?? "")}"#
    }
    private func native(_ e: Entry) -> String {
        #"{"id":"\#(e.id)","title":"\#(e.title)","artist":"\#(e.artist)","album":"A","duration":\#(e.duration),"libraryId":\#(e.library)\#(e.mbid.map { #","mbzRecordingID":"\#($0)""# } ?? "")}"#
    }
    private func respond(_ body: Data, status: Int = 200, headers: [String: String] = [:], _ r: URLRequest) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: r.url ?? URL(string: "about:blank")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = r.url?.path ?? ""
        if path.hasSuffix("/rest/ping") { return respond(Self.ok(), r) }
        if path.hasSuffix("/auth/login") {
            return respond(Data(#"{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}"#.utf8), r)
        }
        if path.hasSuffix("/rest/getMusicFolders") {
            return respond(Self.ok(#""musicFolders":{"musicFolder":[{"id":1,"name":"Music Library"},{"id":2,"name":"Aurral Playlists"}]}"#), r)
        }
        if path.hasSuffix("/rest/getPlaylists") {
            let rows = state.withLock { s in
                s.getPlaylists += 1
                return s.lists.sorted { $0.key < $1.key }.map { id, l in
                    #"{"id":"\#(id)","name":"\#(l.name)","owner":"admin","readonly":false,"public":true,"songCount":\#(l.songs.count),"duration":\#(l.songs.count * 100)\#(l.changed.map { #","changed":"\#($0)""# } ?? "")}"#
                }
            }
            return respond(Self.ok(#""playlists":{"playlist":[\#(rows.joined(separator: ","))]}"#), r)
        }
        if path.hasSuffix("/rest/getPlaylist") {
            let id = Self.value(r, "id") ?? ""
            let gate = state.withLock { s in
                s.getPlaylist.append(id)
                s.inFlight += 1
                s.peakInFlight = max(s.peakInFlight, s.inFlight)
                return s.playlistGate
            }
            await gate?.wait()
            let (list, songs, fail) = state.withLock { s in
                s.inFlight -= 1
                return (s.lists[id], s.songs, s.failPlaylistReads)
            }
            if fail { return respond(Data(), status: 500, r) }
            guard let list else {
                return respond(Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8), r)
            }
            let entries = list.songs.compactMap { songs[$0] }.map(child).joined(separator: ",")
            return respond(Self.ok(#""playlist":{"id":"\#(id)","name":"\#(list.name)","owner":"admin","readonly":false,"songCount":\#(list.songs.count)\#(list.changed.map { #","changed":"\#($0)""# } ?? ""),"entry":[\#(entries)]}"#), r)
        }
        if path.hasSuffix("/rest/search3") || Self.value(r, "mbz_recording_id") != nil {
            await state.withLock { $0.lookupGate }?.wait()
        }
        if path.hasSuffix("/rest/search3") {
            let q = (Self.value(r, "query") ?? "").lowercased()
            let hits = state.withLock { s in
                s.search3.append(q)
                return s.songs.values.filter { $0.title.lowercased() == q }.sorted { $0.id < $1.id }
            }.map(child)
            return respond(Self.ok(#""searchResult3":{"song":[\#(hits.joined(separator: ","))]}"#), r)
        }
        if path.hasSuffix("/api/song") {
            let rows: [Entry] = state.withLock { s in
                if let mbid = Self.value(r, "mbz_recording_id") {
                    s.recordingLookups.append(mbid)
                    return s.songs.values.filter { $0.mbid == mbid }.sorted { $0.id < $1.id }
                }
                if let library = Self.value(r, "library_id").flatMap(Int.init) {
                    return s.songs.values.filter { $0.library == library && !s.unindexed.contains($0.id) }.sorted { $0.id < $1.id }
                }
                return []
            }
            let start = Self.value(r, "_start").flatMap(Int.init) ?? 0
            let end = Self.value(r, "_end").flatMap(Int.init) ?? rows.count
            let page = rows.count > start ? Array(rows[start..<min(end, rows.count)]) : []
            return respond(Data("[\(page.map(native).joined(separator: ","))]".utf8), headers: ["X-Total-Count": "\(rows.count)"], r)
        }
        if path.hasSuffix("/rest/getAlbumList2") { return respond(Self.ok(#""albumList2":{"album":[]}"#), r) }
        return respond(Self.ok(), r)
    }
}

/// Round 27 D1: the stub Aurral on its host (its status can be held, never answering until the test ends); everything
/// else to `D1Navidrome`.
final class D1Routing: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = D1Navidrome()
    private let held = OSAllocatedUnfairLock<D1Gate?>(initialState: nil)
    /// Aurral's status never answers until `releaseStatus()`.
    func holdStatus() { held.withLock { $0 = D1Gate() } }
    func releaseStatus() { held.withLock { gate in gate?.open(); gate = nil } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host {
            if request.url?.path == "/api/playlists/status", let gate = held.withLock({ $0 }) { await gate.wait() }
            return try await aurral.send(request)
        }
        return try await navidrome.send(request)
    }
}

/// Round 27 D1 (owner, 2026-11-14, item 3: "the time it takes to load one of the aurral playlist/flow especially when
/// filled with more songs takes too long. Find a much more efficient way of doing this"; D284, D285): a flow's page
/// opens at once, with fewer reads, against the stub Aurral and a small Navidrome (never the owner's).
@MainActor @Suite(.serialized) final class DiscoverPageSpeedTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DiscoverPageSpeedTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "DiscoverPageSpeedTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = D1Routing()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }
    var nav: D1Navidrome { transport.navidrome }

    deinit {
        transport.releaseStatus()
        transport.navidrome.releasePlaylistReads()
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    static let recording = "0383dadf-2a4e-4d10-a46a-e9e041da8eb3"

    func makeModel() -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                 probeTransport: transport, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                 notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
    }

    /// Discover Weekly: Aurral's Lullaby (its library copy found by recording id), Words (by title), Unknown Song (no
    /// copy), and two songs of the main library Aurral's playlist refers to (Ref One, Ref Two). `extraFlows`: more flows,
    /// each with its own Navidrome playlist of two Aurral songs.
    func signedIn(extraFlows: Int = 0) async throws -> AppModel {
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
        for i in 0..<extraFlows {
            for j in 0..<2 {
                nav.add(.init(id: "a-x\(i)-\(j)", title: "Extra \(i) \(j)", artist: "X", duration: 150, mbid: nil, library: 2))
                jobs.append(.init(flowId: "flow-x\(i)", artistName: "X", trackName: "Extra \(i) \(j)", durationMs: 150_000))
            }
            nav.setList("pl-x\(i)", "Extra \(i)", ["a-x\(i)-0", "a-x\(i)-1"])
            flows.append(.init(id: "flow-x\(i)", name: "Extra \(i)"))
        }
        aurral.setFlows(flows)
        aurral.setJobs(jobs)
        let model = makeModel()
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername, password: StubAurral.defaultPassword)
        await model.scopeIndexRefresh?.value
        return model
    }

    /// A cold start on the same Keychain, Aurral store, defaults and files.
    func relaunched() async -> AppModel {
        let model = makeModel()
        model.resumeSavedSession()
        await model.refreshMusicFolders()
        return model
    }

    // MARK: - The Discover read

    /// §2.2 (1): each Discover read read its candidate playlists one after another; now four at a time.
    @Test func candidatePlaylistsReadFourAtATime() async throws {
        let model = try await signedIn(extraFlows: 7)
        defer { model.signOut() }
        nav.reset()
        nav.holdPlaylistReads()
        let read = Task { await model.refreshDiscover(force: true) }
        // Polled with a deadline (never a sleep): the reads in flight while none may finish.
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while nav.inFlight < 4, clock.now < deadline { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }   // room for a fifth, if anything would start one
        let peak = nav.peakInFlight
        nav.releasePlaylistReads()
        await read.value
        #expect(nav.getPlaylist.count >= 8)
        #expect(peak == 4, "peak \(peak)")
    }

    // MARK: - Fewer lookups

    /// §2.2 (5): the main library's own songs in Aurral's playlist need no lookup (Aurral's library is read in full).
    @Test func mainLibrarySongNeedsNoLookup() async throws {
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.savedDiscoverLibraryIds == [2])
        nav.reset()
        let page = try await model.discoverPage(playlistId: "pl-dw", fresh: true)   // every song asked again
        #expect(page.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"])
        #expect(page.entries.map(\.inYourLibrary) == [true, true, false, false, false])
        #expect(!nav.search3.contains("ref one") && !nav.search3.contains("ref two"), "\(nav.search3)")
        #expect(nav.lookupCount <= 3, "only Aurral's three songs are looked up: \(nav.search3) \(nav.recordingLookups)")
    }

    // MARK: - The car

    /// The car opens a saved page at once, even when the playlist can't be read just now (D283, D285).
    @Test func carOpensSavedPage() async throws {
        let first = try await signedIn()
        _ = try await first.discoverPage(playlistId: "pl-dw")
        let model = await relaunched()
        defer { model.signOut() }
        nav.reset()
        nav.state.withLock { $0.failPlaylistReads = true }
        let page = try await model.discoverPage(playlistId: "pl-dw")
        #expect(page.entries.map(\.song.id) == ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"])
        #expect(page.playlist.name == "Discover Weekly")
        let car = try await CarPlayLibraryAdapter(model: model).playlist(id: "pl-dw")
        #expect(car.1.map(\.id) == ["m-lullaby", "m-words", "a-unknown", "m-ref1", "m-ref2"])
    }

    // MARK: - Saved rows

    /// At launch with Aurral not answering, Discover's rows come from the file: no wait and no read of every playlist.
    @Test func savedRowsShowAtLaunchWithoutAnyRead() async throws {
        let first = try await signedIn()
        _ = first
        transport.holdStatus()
        let model = await relaunched()
        defer { transport.releaseStatus(); model.signOut() }
        nav.reset()
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await model.discoverPlaylists()
        #expect(clock.now - start < .seconds(1), "waited \(clock.now - start)")
        #expect(rows.map(\.id) == ["pl-dw"])
        #expect(rows.first?.name == "Discover Weekly")
        #expect(nav.getPlaylists == 0, "no read of every playlist")
        #expect(model.discoverFlow(playlistId: "pl-dw")?.id == "flow-dw", "the flow as last read")
    }

    /// A read that fails keeps the saved rows (no note), and reads no playlists instead.
    @Test func failedReadKeepsSavedRows() async throws {
        _ = try await signedIn()
        aurral.setStatusFailure(500)
        let model = await relaunched()
        defer { model.signOut() }
        nav.reset()
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"])
        await model.refreshDiscover(force: true)
        #expect(try await model.discoverPlaylists().map(\.id) == ["pl-dw"])
        #expect(nav.getPlaylists == 0)
    }
}
