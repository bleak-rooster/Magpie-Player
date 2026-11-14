import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Search
import Testing
@testable import Magpie

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

private func json(_ object: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}

/// The library Automix and Play top songs are tried against (round 27 A): the seed artist Aurora Field (`ar1`, two
/// albums of four songs), thirty songs Navidrome calls similar (ten other artists), and forty songs of the genre (eight
/// more artists). Every answer can change during a test.
final class AutomixLibrary: @unchecked Sendable {
    struct Row: Sendable {
        var id: String
        var title: String
        var artist: String
        var artistId: String
        var album = "Album"
        var albumId = "al-x"
        var genre = "Ambient"

        var subsonic: [String: Any] {
            ["id": id, "title": title, "artist": artist, "artistId": artistId, "album": album, "albumId": albumId,
             "duration": 200, "genre": genre, "coverArt": albumId]
        }
    }

    struct State: Sendable {
        var own: [Row] = (1...8).map {
            Row(id: "own\($0)", title: "Own \($0)", artist: "Aurora Field", artistId: "ar1",
                album: $0 <= 4 ? "First Light" : "Second Sight", albumId: $0 <= 4 ? "al-1" : "al-2")
        }
        var similar: [Row] = (0..<30).map { Row(id: "sim\($0)", title: "Similar \($0)", artist: "Band \($0 % 10)", artistId: "b\($0 % 10)") }
        var genre: [Row] = (0..<40).map { Row(id: "gen\($0)", title: "Genre \($0)", artist: "Genre Band \($0 % 8)", artistId: "g\($0 % 8)") }
        var topSongs: [String] = ["own3", "own1", "own5", "own2", "own8", "own4", "own6", "own7"]
        var similarStatus = 200
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    func update(_ change: (inout State) -> Void) { lock.withLockUnchecked { change(&$0) } }
    var now: State { lock.withLock { $0 } }

    func song(_ id: String) -> Song? {
        let s = now
        guard let row = (s.own + s.similar + s.genre).first(where: { $0.id == id }) else { return nil }
        return Song(id: row.id, title: row.title, artist: row.artist, artistId: row.artistId, album: row.album,
                    albumId: row.albumId, duration: 200, coverArtId: row.albumId, genre: row.genre)
    }

    private static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Stubs the reads (before the shared Navidrome's, so these answer first).
    func install(on t: MockTransport) {
        t.stub(pathSuffix: "/rest/getSimilarSongs2") { _ in
            let s = self.now
            guard s.similarStatus == 200 else { return MockTransport.Response(status: s.similarStatus) }
            return MockTransport.Response(status: 200, body: subsonic(#""similarSongs2":"# + json(["song": s.similar.map(\.subsonic)])))
        }
        t.stub(pathSuffix: "/rest/getTopSongs") { _ in
            let s = self.now
            let byId = Dictionary(uniqueKeysWithValues: s.own.map { ($0.id, $0) })
            return MockTransport.Response(status: 200, body: subsonic(#""topSongs":"# + json(["song": s.topSongs.compactMap { byId[$0]?.subsonic }])))
        }
        t.stub(pathSuffix: "/rest/getArtist") { _ in
            let albums: [[String: Any]] = [
                ["id": "al-1", "name": "First Light", "artist": "Aurora Field", "artistId": "ar1", "songCount": 4],
                ["id": "al-2", "name": "Second Sight", "artist": "Aurora Field", "artistId": "ar1", "songCount": 4],
            ]
            return MockTransport.Response(status: 200, body: subsonic(#""artist":"# + json(["id": "ar1", "name": "Aurora Field", "album": albums])))
        }
        t.stub(pathSuffix: "/rest/getAlbum") { request in
            let id = Self.query(request, "id") ?? ""
            let songs = self.now.own.filter { $0.albumId == id }.map(\.subsonic)
            return MockTransport.Response(status: 200, body: subsonic(#""album":"# + json(["id": id, "name": "Album", "song": songs])))
        }
        t.stub(pathSuffix: "/rest/getGenres") { _ in
            MockTransport.Response(status: 200, body: subsonic(#""genres":{"genre":[{"value":"Ambient","songCount":40,"albumCount":5}]}"#))
        }
        t.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let offset = Int(Self.query(request, "offset") ?? "0") ?? 0
            let count = Int(Self.query(request, "count") ?? "100") ?? 100
            let rows = self.now.genre.dropFirst(offset).prefix(count).map(\.subsonic)
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":"# + json(["song": Array(rows)])))
        }
    }
}

/// Round 27 A (owner item 17, 2026-11-14: "There should be an automix option whenever you're playing a song, or on an
/// artist page … It should then build the queue in the background while playing the first song."; owner Q5: it replaces
/// what's coming up, Play next songs stay; D305–D308): the sheet's choices, where it shows, and the builder, end to end
/// against a mock Navidrome (Lidarr, Aurral and ListenBrainz play no part: `fourSetups` checks it behaves the same).
@MainActor @Suite(.serialized) final class AutomixAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "AutomixAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "AutomixAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = TopSongsRouting()
    let nav = DiscoverNavidrome()
    let library = AutomixLibrary()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    init() {
        library.install(on: transport.mock)
    }

    func model(lidarr: Bool = false, aurral: Bool = false) async throws -> AppModel {
        transport.aurral.useAurral213()
        nav.install(on: transport.mock)
        transport.mock.stub(pathSuffix: "/api/v1/artist", body: Data("[]".utf8))
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(nil),
                             aurralStore: MemoryAurralStore(), matchIndexDirectory: nil, dataDirectory: tmp,
                             transport: transport, probeTransport: transport, engine: FakeEngine(),
                             previewTransport: transport, defaults: defaults, systemNowPlaying: false,
                             notifications: false, network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "jordan", password: "pw")
        await model.refreshMusicFolders()
        if aurral {
            _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        model.queueBuilder.seed = 27
        return model
    }

    private func song(_ id: String) throws -> Song { try #require(library.song(id)) }
    private func upcoming(_ model: AppModel) -> [String] { model.player.queue.upcoming.map(\.song.id) }
    private func mainIds(_ model: AppModel) -> [String] { model.player.queue.main.map(\.song.id) }

    private func artistSeed(top: [Song]) -> AutomixSeed {
        AutomixSeed(.artist(id: "ar1", name: "Aurora Field", top: top,
                            albums: [Album(id: "al-1", name: "First Light", artist: "Aurora Field", artistId: "ar1", songCount: 4, duration: 800),
                                     Album(id: "al-2", name: "Second Sight", artist: "Aurora Field", artistId: "ar1", songCount: 4, duration: 800)]))
    }

    // MARK: - The sheet (D305)

    @Test func automix_sheetDefaultsAndRemembers() async throws {
        let model = try await model()
        defer { model.signOut() }
        #expect(model.automixLength == .fifty && model.automixVariety == .balanced, "50 songs, Balanced")
        model.automixLength = .hundred
        model.automixVariety = .adventurous
        #expect(defaults.integer(forKey: "magpie.automix.length") == 100)
        #expect(defaults.string(forKey: "magpie.automix.variety") == "adventurous")
        #expect(model.automixLength == .hundred && model.automixVariety == .adventurous, "remembered on the phone")
        defaults.set(37, forKey: "magpie.automix.length")
        defaults.set("wild", forKey: "magpie.automix.variety")
        #expect(model.automixLength == .fifty && model.automixVariety == .balanced, "an unknown value reads as the default")
        // The copy, exactly as plan §8.
        let s = try song("sim1")
        #expect(AutomixCopy.intro(AutomixSeed(.song(s))) == "Songs like \u{201C}Similar 1\u{201D} from your library, added after it.")
        // Fix round 1 (design L1, H2, M3, L2): the artist's intro, each seed's own note, a short mix's wording, the hint.
        #expect(AutomixCopy.intro(artistSeed(top: [])) == "Songs like Aurora Field from your library, starting with one of theirs.")
        #expect(AutomixCopy.note(artistSeed(top: [])) == "Starts now, in place of what\u{2019}s playing. Songs you chose with Play next stay.")
        #expect(AutomixCopy.note(AutomixSeed(.song(s))) == "Replaces what\u{2019}s coming up. Songs you chose with Play next stay.")
        #expect(AutomixCopy.found(1) == "Automix found 1 song like this in your library.")
        #expect(AutomixCopy.found(7) == "Automix found 7 songs like this in your library.")
        #expect(AutomixCopy.none(queueKept: true) == "Couldn\u{2019}t find songs like this in your library. What\u{2019}s coming up hasn\u{2019}t changed.")
        #expect(AutomixCopy.none(queueKept: false) == "Couldn\u{2019}t find songs like this in your library.")
        #expect(AutomixCopy.artistHint == "Choose how long and how varied, then play songs like theirs.")
        #expect(Automix.Length.allCases.map(AutomixCopy.length) == ["20 songs", "50 songs", "100 songs"])
        #expect(Automix.Variety.allCases.map(AutomixCopy.variety) == ["Close", "Balanced", "Adventurous"])
        #expect(Automix.Variety.allCases.map(AutomixCopy.footer) == ["Mostly this artist and the ones nearest them.",
                                                                      "Close matches with a few further out.",
                                                                      "Further afield, with fewer repeats of any one artist."])
        #expect(AutomixCopy.start == "Start Automix" && AutomixCopy.menuItem == "Automix\u{2026}" && AutomixCopy.title == "Automix")
        #expect(AutomixCopy.added(1) == "Automix added 1 song." && AutomixCopy.added(12) == "Automix added 12 songs.")
    }

    @Test func automix_hiddenOfflineAndForFinds() async throws {
        let model = try await model()
        let s = try song("sim1")
        #expect(model.automixAvailable(for: s))
        #expect(model.automixAvailable(artistId: "ar1", albums: []))
        model.findsIdentity.markLanded("sim1")
        #expect(!model.automixAvailable(for: s), "a find is never mixed from")
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(!model.automixAvailable(for: try song("sim2")) && !model.automixAvailable(artistId: "ar1", albums: []))
        model.updatePreferences { $0.downloads.offlineMode = .off }
        #expect(!model.automixAvailable(artistId: "magpie.local:artist:aurora field", albums: []),
                "an artist grouped from the phone")
        let links = NowPlayingLinks(album: nil, artist: nil)
        #expect(model.nowPlayingMoreItems(try song("sim2"), lyricsMode: false, links: links).automix)
        #expect(!model.nowPlayingMoreItems(s, lyricsMode: false, links: links).automix)
        model.signOut()
        #expect(!model.automixAvailable(for: try song("sim2")), "without a session")
    }

    /// The outside artist page has no library songs to seed from: no Automix there (source check, as K2's sections).
    @Test func automix_notOnOutsidePage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let outside = try String(contentsOf: root.appending(path: "App/Screens/Outside/OutsideArtistView.swift"), encoding: .utf8)
        let artist = try String(contentsOf: root.appending(path: "App/Screens/Artist/ArtistView.swift"), encoding: .utf8)
        #expect(!outside.contains("Automix") && !outside.contains("AutomixSheet"))
        #expect(artist.contains("AutomixSheet") && artist.contains("AutomixCopy.actionBar"))
    }

    // MARK: - The builder (D306, D307)

    /// Q5: the current song plays on, what was coming is replaced, Play next songs stay; the mix follows them.
    @Test func build_fromNowPlayingKeepsCurrentAndPlayNext() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed, try song("gen1"), try song("gen2")], startAt: 0)
        model.player.playNext([try song("own7")])
        let current = model.player.queue.current?.id
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.id == current, "the song playing goes on")
        #expect(model.player.queue.upNext.map(\.song.id) == ["own7"], "Play next stays")
        let mix = Array(upcoming(model).dropFirst())
        #expect(mix.count == 20 && !mix.contains("gen1") && !mix.contains("gen2") && !mix.contains("sim1"))
        #expect(mix.allSatisfy { $0.hasPrefix("sim") || $0.hasPrefix("own") || $0.hasPrefix("gen") })
        #expect(model.libraryEdits.notice?.text == "Automix added 20 songs.")
        #expect(model.libraryEdits.notice?.symbol == "checkmark.circle")
    }

    @Test func build_fromArtistPlaysAtOnce() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.player.play([try song("gen5"), try song("gen6")], startAt: 0)
        model.player.playNext([try song("gen9")])
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        let top = ["own3", "own1", "own5"]
        model.startAutomix(artistSeed(top: try (top + ["own2", "own8"]).map(song)), length: .twenty, variety: .balanced)
        #expect(await eventually { top.contains(model.player.queue.current?.song.id ?? "") },
                "one of their top three plays before any read (fix round 1, design L4)")
        #expect(model.player.queue.upNext.map(\.song.id) == ["gen9"], "Play next songs stay, after it")
        #expect(model.libraryEdits.notice?.text == "Adding songs to your Automix\u{2026}")
        #expect(model.libraryEdits.notice?.symbol == "wand.and.stars")
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(top.contains(mainIds(model).first ?? "") && !mainIds(model).contains("gen6"), "what was coming is replaced")
        #expect(upcoming(model).count == 21, "Play next, then twenty")
        #expect(transport.count("/rest/getSimilarSongs2") == 1)
        #expect(transport.sent.contains { $0.url?.path.hasSuffix("/rest/getSimilarSongs2") == true && $0.url?.query?.contains("id=ar1") == true },
                "seeded by the artist")
    }

    /// No top song known: a song of theirs from one of their albums starts it.
    @Test func build_fromArtistWithoutTopSongStartsWithOneOfTheirs() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.startAutomix(artistSeed(top: []), length: .twenty, variety: .close)
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.song.artistId == "ar1")
        #expect(upcoming(model).count == 20)
    }

    @Test func build_appendsInBatches() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed], startAt: 0)
        var sizes: [Int] = []
        model.queueBuilder.onAppend = { sizes.append($0.count) }
        model.startAutomix(AutomixSeed(.song(seed)), length: .fifty, variety: .adventurous)
        await model.queueBuilder.task?.value
        #expect(sizes.allSatisfy { $0 <= 10 } && sizes.count >= 5, "batches of ten")
        #expect(sizes.reduce(0, +) == upcoming(model).count && upcoming(model).count <= 50)
    }

    @Test func build_cancelledByNewPlay() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        #expect(await eventually { self.transport.count("/rest/getSimilarSongs2") == 1 })
        model.play([try song("gen1"), try song("gen2")], startAt: 0)   // something else, from anywhere
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(mainIds(model) == ["gen1", "gen2"], "nothing lands in the new queue")
    }

    /// Navidrome doesn't answer in time: the artist's and the genre's songs fill it.
    @Test func build_similarDeadlineThenFallbacks() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("own1")
        model.player.play([seed], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        let waits = OSAllocatedUnfairLock(initialState: [Duration]())
        // The first deadline (the similar read, the only read Balanced starts with) passes at once; the others wait.
        model.queueBuilder.sleep = { limit in
            let first = waits.withLock { $0.append(limit); return $0.count == 1 }
            if !first { try await Task.sleep(for: .seconds(60)) }
        }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        await model.queueBuilder.task?.value
        #expect(waits.withLock { $0.contains(.seconds(20)) }, "the similar read's 20 s")
        let mix = upcoming(model)
        #expect(!mix.isEmpty && mix.allSatisfy { $0.hasPrefix("own") || $0.hasPrefix("gen") })
        #expect(!mix.contains("own1"))
    }

    /// Fix round 1 (design H1): nothing found leaves what was coming up as it was, and says so.
    @Test func build_noSongsSaysSo() async throws {
        let model = try await model()
        defer { model.signOut() }
        let (gen1, gen2) = (try song("gen1"), try song("gen2"))
        library.update { $0.similar = []; $0.genre = []; $0.own = [$0.own[0]] }
        let seed = try song("own1")
        model.player.play([seed, gen1, gen2], startAt: 0)
        model.player.playNext([gen2])
        let before = model.player.queue.upcoming.map(\.id)
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        await model.queueBuilder.task?.value
        #expect(model.player.queue.upcoming.map(\.id) == before, "the queue is untouched")
        #expect(model.libraryEdits.notice?.text == "Couldn\u{2019}t find songs like this in your library. What\u{2019}s coming up hasn\u{2019}t changed.")
        #expect(model.libraryEdits.notice?.symbol == "exclamationmark.triangle")
    }

    /// Fix round 1 (design H1): the song playing ends while the mix is read: the mix starts playing when it lands.
    @Test func build_songEndsMidReadStartsMix() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        #expect(await eventually { self.transport.count("/rest/getSimilarSongs2") == 1 })
        let entry = try #require(model.player.queue.current?.id)
        model.player.handle(.ended(entry))
        #expect(model.player.hasEnded)
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.song.id != "sim1" && !model.player.hasEnded, "the first new song plays")
        #expect(model.player.queue.current?.song.id.hasPrefix("sim") == true || model.player.queue.current?.song.id.hasPrefix("own") == true)
        #expect(upcoming(model).count == 19)
    }

    /// Fix round 1 (design H1): a skip into the old queue before the mix is ready keeps the old queue and stops the mix.
    @Test func build_skipIntoOldQueueCancels() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed, try song("gen1"), try song("gen2")], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        #expect(await eventually { self.transport.count("/rest/getSimilarSongs2") == 1 })
        model.player.next()
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.song.id == "gen1" && upcoming(model) == ["gen2"])
        #expect(model.libraryEdits.notice?.text == "What\u{2019}s coming up hasn\u{2019}t changed.",
                "fix round 2 (N1): a skip stops the mix and says so, never silently")
    }

    /// Fix round 2 (N1): the seed song ends by itself while the mix is read, and so does the next: the queue moves on
    /// (the engine goes to the next item by itself, gapless) and the mix follows the song playing then, in place of what
    /// was after it, with no gap or restart. (The engine always holds the song after the current one, so a song with
    /// others after it ends as `.itemChanged`; `.ended` comes only at the end of the list, `build_songEndsMidReadStartsMix`.)
    @Test func build_seedEndsNaturallyMixFollowsTheNextSong() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed, try song("gen1"), try song("gen2"), try song("gen3")], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        #expect(await eventually { self.transport.count("/rest/getSimilarSongs2") == 1 })
        model.player.handle(.itemChanged(try #require(model.player.queue.upcoming.first?.id)))
        model.player.handle(.itemChanged(try #require(model.player.queue.upcoming.first?.id)))
        let moved = try #require(model.player.queue.current)
        #expect(moved.song.id == "gen2")
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.id == moved.id, "gen2 plays on, not restarted")
        let mix = upcoming(model)
        #expect(mix.count == 20 && !mix.contains("gen3") && !mix.contains("sim1"), "the mix follows gen2: \(mix)")
        #expect(model.libraryEdits.notice?.text == "Automix added 20 songs.")
    }

    /// Fix round 2 (N1): the same when the engine moves on by itself without a gap (`.itemChanged`).
    @Test func build_seedMovesOnGaplessMixFollows() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed, try song("gen1"), try song("gen2")], startAt: 0)
        transport.hold("/rest/getSimilarSongs2")
        defer { transport.release("/rest/getSimilarSongs2") }
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        #expect(await eventually { self.transport.count("/rest/getSimilarSongs2") == 1 })
        let next = try #require(model.player.queue.upcoming.first)
        model.player.handle(.itemChanged(next.id))
        #expect(model.player.queue.current?.id == next.id)
        transport.release("/rest/getSimilarSongs2")
        await model.queueBuilder.task?.value
        #expect(model.player.queue.current?.id == next.id)
        #expect(upcoming(model).count == 20 && !upcoming(model).contains("gen2"))
    }

    /// Fix round 1 (design M3): a mix shorter than asked says how many it found.
    @Test func build_shortMixSaysWhatItFound() async throws {
        let model = try await model()
        defer { model.signOut() }
        library.update { $0.similar = Array($0.similar.prefix(4)); $0.genre = []; $0.own = [$0.own[0]] }
        let seed = try song("own1")
        model.player.play([seed], startAt: 0)
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
        await model.queueBuilder.task?.value
        #expect(upcoming(model).count == 4)
        #expect(model.libraryEdits.notice?.text == "Automix found 4 songs like this in your library.")
    }

    /// Never a Discover copy or a find.
    @Test func build_neverDiscoverCopyOrFind() async throws {
        let model = try await model()
        defer { model.signOut() }
        model.discover.flowSongIds = ["sim2", "sim4"]
        model.findsIdentity.markLanded("sim6")
        let seed = try song("sim1")
        model.player.play([seed], startAt: 0)
        model.startAutomix(AutomixSeed(.song(seed)), length: .hundred, variety: .adventurous)
        await model.queueBuilder.task?.value
        let mix = upcoming(model)
        #expect(!mix.isEmpty && !mix.contains("sim2") && !mix.contains("sim4") && !mix.contains("sim6"))
        #expect(Set(mix).count == mix.count)
    }

    @Test func nothingSavedAsPlaylist() async throws {
        let model = try await model()
        defer { model.signOut() }
        let seed = try song("sim1")
        model.player.play([seed], startAt: 0)
        model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .close)
        await model.queueBuilder.task?.value
        let paths = transport.sent.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.hasSuffix("/createPlaylist") || $0.hasSuffix("/updatePlaylist") || $0.hasSuffix("/api/playlist") },
                "no playlist created or changed")
    }

    /// Navidrome alone, + Lidarr, + Aurral, all: the same mix from the same library (library only; nothing else is asked).
    @Test func fourSetups() async throws {
        var mixes: [[String]] = []
        for (lidarr, aurral) in [(false, false), (true, false), (false, true), (true, true)] {
            let model = try await model(lidarr: lidarr, aurral: aurral)
            let seed = try song("sim1")
            model.player.play([seed], startAt: 0)
            #expect(model.automixAvailable(for: seed))
            model.startAutomix(AutomixSeed(.song(seed)), length: .twenty, variety: .balanced)
            await model.queueBuilder.task?.value
            mixes.append(upcoming(model))
            model.signOut()
        }
        #expect(mixes.allSatisfy { $0.count == 20 } && Set(mixes.map { $0 }).count == 1)
    }
}
