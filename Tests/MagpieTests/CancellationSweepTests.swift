import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Search
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let failedJSON = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"no"}}}"#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

private func queryValue(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

/// SplitMix64: a small seeded generator, so a failing sweep replays exactly from its seed.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Answers every request after a seeded, cancellation-aware delay (0–`maxMicros` µs), the way a real network answers
/// in no particular order. A cancelled request throws `CancellationError`, as URLSession's tasks stop when cancelled.
final class JitterTransport: HTTPTransport, @unchecked Sendable {
    let base = HostSwitchTransport()
    var inner: MockTransport { base.inner }
    private let rng = OSAllocatedUnfairLock(initialState: SeededGenerator(seed: 1))
    private let maxMicros = OSAllocatedUnfairLock(initialState: 0)

    func jitter(seed: UInt64, maxMicros: Int) {
        rng.withLock { $0 = SeededGenerator(seed: seed) }
        self.maxMicros.withLock { $0 = maxMicros }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let most = maxMicros.withLock { $0 }
        if most > 0 {
            let wait = rng.withLock { Int.random(in: 0...most, using: &$0) }
            try await Task.sleep(for: .microseconds(wait))
        }
        try Task.checkCancellation()
        return try await base.send(request)
    }
}

/// Crash hunt 3, item 1: every concurrent loader, cancelled at seeded random points (before it starts, between child
/// reads, while results are being joined, just after it finished). The build 8 launch crash was this class: a cancelled
/// Home read left a gap in positional results and trapped with "Index out of range". For each loader: no trap, a
/// result is either the full uncancelled answer or a cancellation (never a shorter or shifted one, never an error that
/// would say "couldn't load"), and nothing is written to the model once the cancel has landed.
@MainActor @Suite(.serialized) final class CancellationSweepTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CancellationSweepTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CancellationSweepTests.\(UUID().uuidString)")!
    let transport = JitterTransport()
    /// `getAlbumList2` types that answer with a Subsonic error.
    let failing = OSAllocatedUnfairLock(initialState: Set<String>())
    static let genreCount = 11   // over `fetchWidth` (4) twice, so `inOrder` takes the "wait for one, add one" path

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Albums per type for Home; `genreCount` genres "G0"…"G10" whose albums overlap their neighbour's (so the merge's
    /// de-duplication depends on order) and whose songs run to several pages.
    func signedInModel() async throws -> AppModel {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let failing = failing
        t.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = queryValue(request, "type") ?? ""
            if failing.withLock({ $0.contains(type) }) { return MockTransport.Response(status: 200, body: failedJSON) }
            let ids: [String]
            if type == "byGenre", let genre = queryValue(request, "genre"), let g = Int(genre.dropFirst()) {
                ids = (0..<(3 + g % 4)).map { "g\(g + $0 % 2)-a\($0)" }   // shares ids with the next genre
            } else {
                ids = (0..<(1 + type.count % 5)).map { "\(type)-\($0)" }
            }
            let albums = ids.map { #"{"id":"\#($0)","name":"\#($0)","artist":"A","songCount":1}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums)]}"#))
        }
        t.stub(pathSuffix: "/rest/getPlaylists",
               body: subsonic(#""playlists":{"playlist":[{"id":"p1","name":"Road","songCount":3,"duration":600}]}"#))
        let genres = (0..<Self.genreCount).map { #"{"value":"G\#($0)","songCount":\#(40 + $0 * 7),"albumCount":\#(3 + $0 % 4)}"# }
        t.stub(pathSuffix: "/rest/getGenres", body: subsonic(#""genres":{"genre":[\#(genres.joined(separator: ","))]}"#))
        t.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let genre = queryValue(request, "genre") ?? "G0"
            let g = Int(genre.dropFirst()) ?? 0
            let offset = Int(queryValue(request, "offset") ?? "0") ?? 0, count = Int(queryValue(request, "count") ?? "0") ?? 0
            let page = (0..<(40 + g * 7)).map { "\(genre)-s\($0)" }.dropFirst(offset).prefix(count)
            let songs = page.map { #"{"id":"\#($0)","title":"\#($0)","genre":"\#(genre)"}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":{"song":[\#(songs)]}"#))
        }
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    /// Where `cancelled` cancels when not at random: the two ends every sweep must reach, whatever the machine's speed.
    enum CancelPoint { case beforeStart, afterFinish }

    /// Runs `op`, cancelling it at a seeded random point: before it starts, after some yields, or after a short sleep.
    /// The seed fixes the choices, not the outcomes: where a cancel lands against the jittered answers depends on the
    /// machine, so a replay repeats the same rounds but may not land them the same way. Which outcome a random round
    /// gets is never asserted; `at` forces one end (merged crash-hunt review, I3).
    func cancelled<T: Sendable>(_ rng: inout SeededGenerator, at point: CancelPoint? = nil,
                                _ op: @escaping @MainActor () async throws -> T) async -> Result<T, any Error> {
        let task = Task { @MainActor in try await op() }
        if let point {
            if point == .afterFinish { _ = await task.result }
            task.cancel()
            return await task.result
        }
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: break                                                         // before the first await
        case 1: for _ in 0..<Int.random(in: 1...40, using: &rng) { await Task.yield() }
        case 2: try? await Task.sleep(for: .microseconds(Int.random(in: 0...3000, using: &rng)))
        default: try? await Task.sleep(for: .microseconds(Int.random(in: 2000...12000, using: &rng)))   // often after
        }
        task.cancel()
        return await task.result
    }

    func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Home (build 8)

    /// `homeRead` over random sections (some failing), cancelled at random points: either the uncancelled read
    /// exactly (every shelf under its own section) or a cancellation, never a trap or "every section failed".
    @Test func homeReadCancelledAnywhere() async throws {
        let model = try await signedInModel()
        let all = HomeSection.allCases.filter { $0 != .madeForYou }
        var rng = SeededGenerator(seed: 0xB8)
        for round in 0..<150 {
            let wanted = Array(all.shuffled(using: &rng).prefix(Int.random(in: 1...all.count, using: &rng)))
            let types = ["recent", "newest", "frequent", "starred", "random"]
            let failSet = Set(types.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 })
            failing.withLock { $0 = failSet }
            transport.jitter(seed: UInt64(round), maxMicros: 0)
            let expected = await capture { try await model.homeRead(for: wanted) }
            transport.jitter(seed: UInt64(round), maxMicros: 1500)
            switch await cancelled(&rng, { try await model.homeRead(for: wanted) }) {
            case .success(let read):
                let base = try #require(try? expected.get(), "round \(round): a read that failed uncancelled succeeded")
                #expect(read.shelves == base.shelves, "round \(round) \(wanted): shelves differ from the uncancelled read")
                #expect(read.failed == base.failed, "round \(round) \(wanted)")
            case .failure(let error):
                if case .success = expected {
                    #expect(isCancellation(error), "round \(round) \(wanted): a cancelled read reported \(error)")
                }
            }
        }
        // Both outcomes, whatever the machine's speed: a cancel after the read finished keeps it whole, one before it
        // starts is a cancellation.
        failing.withLock { $0 = [] }
        transport.jitter(seed: 0, maxMicros: 0)
        let whole = try await model.homeRead(for: all)
        transport.jitter(seed: 0, maxMicros: 1500)
        let late = await cancelled(&rng, at: .afterFinish) { try await model.homeRead(for: all) }
        #expect((try? late.get())?.shelves == whole.shelves, "a cancel after the read finished changed it")
        let early = await cancelled(&rng, at: .beforeStart) { try await model.homeRead(for: all) }
        #expect(early.error.map(isCancellation) == true, "a cancel before the read started: \(early)")
    }

    /// The car's Home reads the same shelves (with Made for you's own read alongside, `async let`).
    @Test func carPlayHomeShelvesCancelledAnywhere() async throws {
        let model = try await signedInModel()
        let adapter = CarPlayLibraryAdapter(model: model)
        let all = HomeSection.allCases
        var rng = SeededGenerator(seed: 0xCA)
        for round in 0..<80 {
            let wanted = Array(all.shuffled(using: &rng).prefix(Int.random(in: 1...all.count, using: &rng)))
            let size = Int.random(in: -1...14, using: &rng)
            transport.jitter(seed: UInt64(round), maxMicros: 0)
            let expected = try await adapter.homeShelves(wanted, size: size)
            transport.jitter(seed: UInt64(round), maxMicros: 1500)
            switch await cancelled(&rng, { try await adapter.homeShelves(wanted, size: size) }) {
            case .success(let shelves):
                #expect(shelves == expected, "round \(round): shelves differ from the uncancelled read")
                #expect(shelves.allSatisfy { $0.items.count <= max(0, size) }, "round \(round)")
            case .failure(let error):
                #expect(isCancellation(error), "round \(round): \(error)")
            }
        }
    }

    // MARK: - Genres (`inOrder`)

    /// A group's albums merged over 11 genres, 4 at a time: the whole merge in the genres' order, or a cancellation.
    @Test func groupAlbumsCancelledAnywhere() async throws {
        let model = try await signedInModel()
        let genres = try await model.allGenres()
        #expect(genres.count == Self.genreCount)
        var rng = SeededGenerator(seed: 0x6E)
        for round in 0..<150 {
            let some = Array(genres.shuffled(using: &rng).prefix(Int.random(in: 1...genres.count, using: &rng)))
            transport.jitter(seed: UInt64(round), maxMicros: 0)
            let expected = try await model.groupAlbums(in: some)
            transport.jitter(seed: UInt64(round), maxMicros: 1500)
            switch await cancelled(&rng, { try await model.groupAlbums(in: some) }) {
            case .success(let albums):
                #expect(albums.map(\.id) == expected.map(\.id), "round \(round): merge differs from the uncancelled one")
            case .failure(let error):
                #expect(isCancellation(error), "round \(round): \(error)")
            }
        }
        // Both outcomes, whatever the machine's speed.
        transport.jitter(seed: 0, maxMicros: 0)
        let whole = try await model.groupAlbums(in: genres)
        transport.jitter(seed: 0, maxMicros: 1500)
        let late = await cancelled(&rng, at: .afterFinish) { try await model.groupAlbums(in: genres) }
        #expect((try? late.get())?.map(\.id) == whole.map(\.id), "a cancel after the merge finished changed it")
        let early = await cancelled(&rng, at: .beforeStart) { try await model.groupAlbums(in: genres) }
        #expect(early.error.map(isCancellation) == true, "a cancel before the merge started: \(early)")
    }

    /// A group's Shuffle reads every genre round by round (`inOrder` per round): the whole list or a cancellation;
    /// never songs credited to the wrong genre's offsets (a shifted page would repeat or skip songs).
    @Test func groupSongsCancelledAnywhere() async throws {
        let model = try await signedInModel()
        let genres = try await model.allGenres()
        var rng = SeededGenerator(seed: 0x5A)
        for round in 0..<60 {
            let some = Array(genres.shuffled(using: &rng).prefix(Int.random(in: 1...genres.count, using: &rng)))
            transport.jitter(seed: UInt64(round), maxMicros: 0)
            let expected = try await model.groupSongsInFetchOrder(some)
            #expect(Set(expected.map(\.id)).count == expected.count, "round \(round): duplicates uncancelled")
            transport.jitter(seed: UInt64(round), maxMicros: 800)
            switch await cancelled(&rng, { try await model.groupSongsInFetchOrder(some) }) {
            case .success(let songs):
                #expect(songs.map(\.id) == expected.map(\.id), "round \(round)")
            case .failure(let error):
                #expect(isCancellation(error), "round \(round): \(error)")
            }
        }
    }

    /// The Genres screen's groups (counts summed per group) and Home's Genres shelf, cancelled anywhere.
    @Test func genreSectionsCancelledAnywhere() async throws {
        let model = try await signedInModel()
        let expected = try await model.genreSections()
        var rng = SeededGenerator(seed: 0x6F)
        for round in 0..<100 {
            transport.jitter(seed: UInt64(round), maxMicros: 1500)
            switch await cancelled(&rng, { try await model.genreSections() }) {
            case .success(let sections):
                #expect(sections.map(\.group.id) == expected.map(\.group.id), "round \(round)")
                #expect(sections.map(\.albumCount) == expected.map(\.albumCount), "round \(round)")
            case .failure(let error):
                #expect(isCancellation(error), "round \(round): \(error)")
            }
        }
    }
}

// MARK: - Helpers

@MainActor func capture<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

// MARK: - Made for you and search

private let lbPlaylistId = MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11")!
private let lbCreatedFor = Data(#"""
{"playlists":[{"playlist":{"identifier":"https://listenbrainz.org/playlist/5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11","title":"Weekly Exploration for rob",
 "extension":{"https://musicbrainz.org/doc/jspf#playlist":{"additional_metadata":{"algorithm_metadata":{"source_patch":"weekly-exploration"}}}}}}]}
"""#.utf8)
/// 24 library songs; the playlist lists 16 of them (in a shuffled order) and 8 that aren't in the library.
private let lbLibraryCount = 24

/// Made for you's playlist read (library songs looked up 6 at a time, `withTaskGroup`) and its shelf read, and search
/// as you type, each cancelled at seeded random points. ListenBrainz requests are spaced 2 a second by the app's
/// limiter, so these sweeps take fewer rounds.
@MainActor @Suite(.serialized) final class MadeForYouAndSearchSweepTests {
    let transport = JitterTransport()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let tokens = MemoryTokenStore()

    deinit { store.clear() }

    func signedInModel() async throws -> AppModel {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        let songs = (0..<lbLibraryCount).map {
            #"{"id":"s\#($0)","title":"Song \#($0)","artist":"Artist \#($0)","album":"Album \#($0)","duration":200,"missing":false}"#
        }
        t.stub(pathSuffix: "/api/song", body: Data("[\(songs.joined(separator: ","))]".utf8),
               headers: ["X-Total-Count": "\(lbLibraryCount)"])
        t.stub(pathSuffix: "/rest/getSong") { request in
            let id = queryValue(request, "id") ?? "s0"
            let n = id.dropFirst()
            return MockTransport.Response(status: 200, body: subsonic(
                #""song":{"id":"\#(id)","title":"Song \#(n)","artist":"Artist \#(n)","album":"Album \#(n)","duration":200}"#))
        }
        t.stub(pathSuffix: "/1/validate-token", body: Data(#"{"valid":true,"user_name":"rob"}"#.utf8))
        t.stub(pathSuffix: "/1/user/rob/playlists/createdfor", body: lbCreatedFor)
        var order = SeededGenerator(seed: 7)
        let inLibrary = (0..<16).map { #"{"title":"Song \#($0)","creator":"Artist \#($0)","duration":200000}"# }
        let outside = (0..<8).map { #"{"title":"Elsewhere \#($0)","creator":"Nobody \#($0)"}"# }
        let tracks = (inLibrary + outside).shuffled(using: &order).joined(separator: ",")
        t.stub(pathSuffix: "/1/playlist/\(lbPlaylistId.rawValue)", body: Data(#"{"playlist":{"track":[\#(tracks)]}}"#.utf8))
        try tokens.save("secret-token-123")
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: tokens, matchIndexDirectory: nil,
                             dataDirectory: nil, gateDefaultsSuite: "magpie-tests-gate-\(UUID().uuidString)",
                             transport: transport, probeTransport: transport, engine: FakeEngine(),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!, systemNowPlaying: false,
                             notifications: false)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.matchIndexSettled()
        return model
    }

    /// A cancelled playlist read is nil (never a list with library songs missing or out of order); one that finished is
    /// the uncancelled list exactly.
    @Test func madeForYouTracksCancelledAnywhere() async throws {
        let expected = try #require(await signedInModel().madeForYouTracks(lbPlaylistId))
        #expect(expected.count == 24)
        #expect(expected.filter { if case .library = $0 { true } else { false } }.count == 16)
        var rng = SeededGenerator(seed: 0x3F)
        for round in 0..<40 {
            // A model per round: its ListenBrainz limiter starts with a free slot, so the playlist read answers at once
            // and the cancel lands anywhere in the library song reads (6 at a time). A cancelled read keeps its
            // limiter slot, so on one model the reads would only queue up behind the limiter (see the report).
            let model = try await signedInModel()
            transport.jitter(seed: UInt64(round), maxMicros: 1500)
            let task = Task { @MainActor in await model.madeForYouTracks(lbPlaylistId) }
            for _ in 0..<Int.random(in: 0...60, using: &rng) { await Task.yield() }
            if Bool.random(using: &rng) { try? await Task.sleep(for: .microseconds(Int.random(in: 0...12000, using: &rng))) }
            task.cancel()
            if let rows = await task.value {
                #expect(rows == expected, "round \(round): a finished read differs from the uncancelled one")
            }
        }
        // Both outcomes, whatever the machine's speed (16 lookups behind a limiter can outlast every random cancel
        // point on a slow simulator): cancelled after it finished it is whole, before it starts it is nil.
        let lateModel = try await signedInModel()
        transport.jitter(seed: 0, maxMicros: 1500)
        let late = Task { @MainActor in await lateModel.madeForYouTracks(lbPlaylistId) }
        let finished = await late.value
        late.cancel()
        #expect(finished == expected, "a read left to finish differs from the uncancelled one")
        let earlyModel = try await signedInModel()
        let early = Task { @MainActor in await earlyModel.madeForYouTracks(lbPlaylistId) }
        early.cancel()
        #expect(await early.value == nil, "a read cancelled before it started gave rows")
    }

    /// The shelf read writes the shelf only if it wasn't cancelled: what the shelf is when the cancel lands is what it
    /// stays.
    @Test func madeForYouShelfNotWrittenAfterCancel() async throws {
        let model = try await signedInModel()
        var rng = SeededGenerator(seed: 0x5E)
        for round in 0..<8 {
            model.listenBrainzTokenChanged()   // empties the shelf (what a token change does)
            transport.jitter(seed: UInt64(round), maxMicros: 3000)
            let task = Task { @MainActor in await model.refreshMadeForYou() }
            for _ in 0..<Int.random(in: 0...40, using: &rng) { await Task.yield() }
            if Bool.random(using: &rng) { try? await Task.sleep(for: .milliseconds(Int.random(in: 0...700, using: &rng))) }
            task.cancel()
            let atCancel = model.madeForYouShelf
            await task.value
            #expect(model.madeForYouShelf == atCancel, "round \(round): the shelf changed after the cancel")
        }
        await model.refreshMadeForYou()
        #expect(model.madeForYouShelf.map(\.id) == [lbPlaylistId], "an uncancelled read still fills the shelf")
    }

    /// Typing: random edits (appends, deletes, blanks, clears) with random pauses, each search answering after a random
    /// delay and handing over early library rows first. At every point the rows shown belong to the query shown (or
    /// there are none), and once typing stops the last query's rows show and search is done.
    @Test(arguments: 0..<6) func searchTypingNeverShowsAnotherQuerysRows(_ seed: Int) async throws {
        let latency = OSAllocatedUnfairLock(initialState: SeededGenerator(seed: UInt64(seed) &* 31))
        let model = SearchModel(search: { q, early in
            let (a, b) = latency.withLock { (Int.random(in: 0...3000, using: &$0), Int.random(in: 0...3000, using: &$0)) }
            try await Task.sleep(for: .microseconds(a))
            await early(SearchSections(songs: [sweepSong("early|" + q)]))
            try await Task.sleep(for: .microseconds(b))
            return SearchSections(songs: [sweepSong("done|" + q)])
        }, debounce: .microseconds(500))
        var rng = SeededGenerator(seed: UInt64(seed))
        var text = ""
        for step in 0..<120 {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: text = ""
            case 1: text += " "
            case 2, 3: if !text.isEmpty { text.removeLast() }
            default: text += String("harbour".randomElement(using: &rng)!)
            }
            model.update(query: text)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: break
            case 1: for _ in 0..<Int.random(in: 1...20, using: &rng) { await Task.yield() }
            default: try await Task.sleep(for: .microseconds(Int.random(in: 0...5000, using: &rng)))
            }
            let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            for shown in model.results.songs {
                #expect(shown.id == "early|" + trimmed || shown.id == "done|" + trimmed,
                        "seed \(seed) step \(step): \(shown.id) shown for \(model.query.debugDescription)")
            }
            if trimmed.isEmpty { #expect(model.phase == .idle && model.results.songs.isEmpty) }
        }
        await model.settle()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            #expect(model.phase == .idle && model.results.songs.isEmpty)
        } else {
            #expect(model.phase == .done, "seed \(seed): \(model.phase)")
            #expect(model.results.songs.map(\.id) == ["done|" + trimmed], "seed \(seed)")
        }
    }
}

private func sweepSong(_ id: String) -> Song { Song(id: id, title: id, artist: "A", album: "B", duration: 1) }

private extension Result {
    var error: Failure? { if case .failure(let error) = self { error } else { nil } }
}
