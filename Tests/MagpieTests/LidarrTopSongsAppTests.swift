import AurralKit
import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Requests
import Search
import Testing
@testable import Magpie

private let lidarrBase = URL(string: "http://192.168.1.2:8686")!
private let artistMBID = MBID("4d8175ea-cc33-4565-8a8e-6b0f6c7a3f11")!
private let recWide = "11111111-1111-4111-8111-111111111101"
private let recNorth = "11111111-1111-4111-8111-111111111102"
private let recHarbourAlbum = "11111111-1111-4111-8111-111111111103"
private let recSongAlbum = "11111111-1111-4111-8111-111111111104"
private let recSongSingle = "11111111-1111-4111-8111-111111111105"
private let recGlassLive = "11111111-1111-4111-8111-111111111106"

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// One library song of the fixture (all by Aurora Field, artist id `ar1`).
private struct LibrarySong: Sendable {
    var id: String
    var title: String
    var album: String
    var duration: Int
    var recording: String? = nil
    var library = 1

    var native: [String: Any] {
        var row: [String: Any] = ["id": id, "title": title, "artist": "Aurora Field", "artistId": "ar1", "album": album,
                                  "albumId": "al-\(album.prefix(5))", "duration": duration, "missing": false,
                                  "mbzArtistId": artistMBID.rawValue, "libraryId": library]
        if let recording { row["mbzRecordingID"] = recording }
        return row
    }

    var subsonic: [String: Any] {
        var row: [String: Any] = ["id": id, "title": title, "artist": "Aurora Field", "artistId": "ar1", "album": album,
                                  "albumId": "al-\(album.prefix(5))", "duration": duration, "coverArt": "al-\(album.prefix(5))"]
        if let recording { row["musicBrainzId"] = recording }
        return row
    }
}

/// The library: "Harbour" is the album copy of the single "Harbour (Radio Edit)"; "Glass" is only on a live album; the
/// only "Song" on First Light is "Song (Reprise)" (the K1 I2 case: the index folds "(Reprise)").
private let libraryFixture: [LibrarySong] = [
    LibrarySong(id: "s-wide", title: "Wide Open", album: "First Light", duration: 240, recording: recWide),
    LibrarySong(id: "s-harbour", title: "Harbour", album: "First Light", duration: 246),
    LibrarySong(id: "s-north", title: "Northern Line", album: "First Light", duration: 200, recording: recNorth),
    LibrarySong(id: "s-glass", title: "Glass", album: "Alive", duration: 262),
    LibrarySong(id: "s-reprise", title: "Song (Reprise)", album: "First Light", duration: 245),
    LibrarySong(id: "s-tide", title: "Low Tide", album: "Second Sight", duration: 190),
    LibrarySong(id: "s-ember", title: "Ember", album: "Second Sight", duration: 205),
    LibrarySong(id: "s-quiet", title: "Quiet Hours", album: "Second Sight", duration: 230),
]

private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

/// Aurral on its host (its artist preview answered here, so each test says what Aurral's top songs are), everything else
/// (Navidrome, Lidarr, ListenBrainz) to the mock. A path can be held (a slow source) until released or cancelled.
final class TopSongsRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let mock = MockTransport()
    private struct State {
        var preview: Data?
        var previewStatus = 200
        var previewReads = 0
        var held: Set<String> = []
        var sent: [URLRequest] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPreview(_ tracks: [[String: Any]], status: Int = 200) {
        let body = json(["tracks": tracks])
        state.withLock { $0.preview = body; $0.previewStatus = status }
    }

    func hold(_ pathSuffix: String) { state.withLock { _ = $0.held.insert(pathSuffix) } }
    func release(_ pathSuffix: String) { state.withLock { _ = $0.held.remove(pathSuffix) } }
    var previewReads: Int { state.withLock { $0.previewReads } }
    /// Every request any server was sent, in order.
    var sent: [URLRequest] { state.withLock { $0.sent } }
    func count(_ pathSuffix: String) -> Int { sent.filter { $0.url?.path.hasSuffix(pathSuffix) == true }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        state.withLock { $0.sent.append(request) }
        // A held source answers only once released (at most 30 s: a test that forgets to release it fails, never hangs);
        // a deadline that cuts it cancels this wait.
        let until = Date().addingTimeInterval(30)
        while state.withLock({ s in s.held.contains { path.hasSuffix($0) } }) {
            guard Date() < until else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        if request.url?.host == aurral.host, path.hasPrefix("/api/artists/"), path.hasSuffix("/preview") {
            let (body, status) = state.withLock { s -> (Data, Int) in
                s.previewReads += 1
                return (s.preview ?? json(["tracks": []]), s.previewStatus)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (status == 200 ? body : Data(), http)
        }
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        return try await mock.send(request)
    }
}

private let listenBrainzFixture = json([
    ["artist_mbids": [artistMBID.rawValue], "artist_name": "Aurora Field", "recording_mbid": recNorth,
     "recording_name": "Northern Line", "length": 200_000],
    ["artist_mbids": [artistMBID.rawValue], "artist_name": "Aurora Field", "recording_mbid": recSongSingle,
     "recording_name": "Song (Radio Edit)", "length": 211_000],
])
/// Lidarr's releases of the artist: the studio album, a live album and the single.
private let albumsFixture = json([
    ["id": 1, "title": "First Light", "artistId": 20, "albumType": "Album", "secondaryTypes": [], "monitored": true],
    ["id": 2, "title": "Alive", "artistId": 20, "albumType": "Album", "secondaryTypes": ["Live"], "monitored": true],
    ["id": 3, "title": "Harbour", "artistId": 20, "albumType": "Single", "secondaryTypes": [], "monitored": true],
])
/// Lidarr's tracks: the album's "Harbour", "Song" and "Wide Open" have files; the live "Glass" too; the single doesn't.
private let tracksFixture = json([
    ["id": 101, "albumId": 1, "title": "Harbour", "duration": 246_000, "trackFileId": 5001, "foreignRecordingId": recHarbourAlbum],
    ["id": 102, "albumId": 1, "title": "Song", "duration": 246_000, "trackFileId": 5002, "foreignRecordingId": recSongAlbum],
    ["id": 103, "albumId": 2, "title": "Glass", "duration": 262_000, "trackFileId": 5003, "foreignRecordingId": recGlassLive],
    ["id": 104, "albumId": 3, "title": "Harbour (Radio Edit)", "duration": 211_000, "trackFileId": 0],
    ["id": 105, "albumId": 1, "title": "Wide Open", "duration": 240_000, "trackFileId": 5004, "foreignRecordingId": recWide],
])
private let lidarrArtistsFixture = json([["id": 20, "artistName": "Aurora Field", "foreignArtistId": artistMBID.rawValue,
                                          "monitored": true, "tags": []]])

/// Answers that can change during a test.
private final class Answers: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    struct State: Sendable {
        var library: [LibrarySong] = libraryFixture
        var topSongs: [String] = ["s-wide", "s-tide", "s-ember", "s-quiet"]
        var listenBrainz = listenBrainzFixture
        var listenBrainzStatus = 200
        var lidarrArtists = lidarrArtistsFixture
        var albums = albumsFixture
        var tracks = tracksFixture
    }
    func update(_ change: (inout State) -> Void) { lock.withLockUnchecked { change(&$0) } }
    var now: State { lock.withLock { $0 } }
}

/// Round 26 K2 (owner, 2026-11-10; D263–D268): an artist page's Top songs for an artist Lidarr has, end to end in the app
/// against StubAurral 2.13 (its artist preview answered by the routing), a mock Navidrome, Lidarr and ListenBrainz: the
/// saved list at once, the background refresh and the swap, the album step, the setups, Settings' footer and sign-out.
@MainActor @Suite(.serialized) final class LidarrTopSongsAppTests {
    /// Aurral's top songs: the single's radio edit (its album copy is in the library), a song only on a live album, one
    /// the library hasn't got, and one it has.
    static let aurralFixture: [[String: Any]] = [
        ["id": "9001", "title": "Harbour (Radio Edit)", "album": "Harbour", "preview_url": "/api/deezer/preview/9001.mp3", "duration_ms": 211_000],
        ["id": "9002", "title": "Glass", "album": "Glass", "preview_url": "/api/deezer/preview/9002.mp3", "duration_ms": 180_000],
        ["id": "9003", "title": "Unknown Song", "album": "Elsewhere", "preview_url": "/api/deezer/preview/9003.mp3", "duration_ms": 200_000],
        ["id": "9004", "title": "Wide Open", "album": "First Light", "preview_url": "/api/deezer/preview/9004.mp3", "duration_ms": 240_000],
    ]
    /// What the full process gives for the fixture (D258).
    static let expected = ["s-harbour", "s-wide", "s-north", "s-tide", "s-ember"]

    let tmp = FileManager.default.temporaryDirectory.appending(path: "LidarrTopSongsAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "LidarrTopSongsAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = TopSongsRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    private let answers = Answers()

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    init() {
        let t = transport.mock
        let answers = answers
        t.stub(pathSuffix: "/api/song") { _ in
            let rows = answers.now.library.map(\.native)
            return MockTransport.Response(status: 200, body: json(rows), headers: ["X-Total-Count": String(rows.count)])
        }
        t.stub(pathSuffix: "/rest/getTopSongs") { _ in
            let byId = Dictionary(uniqueKeysWithValues: answers.now.library.map { ($0.id, $0) })
            let songs = answers.now.topSongs.compactMap { byId[$0]?.subsonic }
            return MockTransport.Response(status: 200, body: subsonic(#""topSongs":"# + String(decoding: json(["song": songs]), as: UTF8.self)))
        }
        t.stub(pathSuffix: "/rest/getSong") { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            guard let song = answers.now.library.first(where: { $0.id == id }) else {
                return MockTransport.Response(status: 200, body: Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":70,"message":"not found"}}}"#.utf8))
            }
            return MockTransport.Response(status: 200, body: subsonic(#""song":"# + String(decoding: json(song.subsonic), as: UTF8.self)))
        }
        t.stub(pathSuffix: "/rest/search3") { _ in
            MockTransport.Response(status: 200, body: subsonic(#""searchResult3":{}"#))
        }
        t.stub(pathSuffix: "/1/popularity/top-recordings-for-artist/\(artistMBID.rawValue)") { _ in
            let now = answers.now
            return MockTransport.Response(status: now.listenBrainzStatus, body: now.listenBrainzStatus == 200 ? now.listenBrainz : Data())
        }
        t.stub(pathSuffix: "/api/v1/artist") { _ in MockTransport.Response(status: 200, body: answers.now.lidarrArtists) }
        t.stub(pathSuffix: "/api/v1/command", body: Data("[]".utf8))
        t.stub(pathSuffix: "/api/v1/album") { _ in MockTransport.Response(status: 200, body: answers.now.albums) }
        t.stub(pathSuffix: "/api/v1/track") { _ in MockTransport.Response(status: 200, body: answers.now.tracks) }
        transport.setPreview(Self.aurralFixture)
    }

    func model(aurral: Bool = true, lidarr: Bool = true, listenBrainzToken: String? = "tok") async throws -> AppModel {
        transport.aurral.useAurral213()
        nav.install(on: transport.mock)
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: lidarrBase, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(listenBrainzToken),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), previewTransport: transport, defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        model.aurralFeeds.phoneRegion = { nil }
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "jordan", password: "pw")
        await model.refreshMusicFolders()
        if aurral {
            _ = try await model.connectAurral(base: transport.aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        await model.matchIndexSettled()
        return model
    }

    private func cache(_ model: AppModel) throws -> LidarrTopSongsCache {
        LidarrTopSongsCache(root: tmp, scope: try #require(model.navidromeScope))
    }

    private var key: String { "mbid:\(artistMBID.rawValue)" }

    private func page(_ model: AppModel, mbid: MBID? = artistMBID, artistId: String? = "ar1") async throws -> LidarrTopSongsModel {
        try #require(await model.lidarrTopSongs(name: "Aurora Field", mbid: mbid, artistId: artistId))
    }

    private func saved(_ ids: [String], in model: AppModel) throws {
        let byId = Dictionary(uniqueKeysWithValues: libraryFixture.map { ($0.id, $0) })
        let rows = ids.map { id in
            let s = byId[id] ?? LibrarySong(id: id, title: "Gone \(id)", album: "Lost", duration: 100)
            return LidarrTopSongs.Row(song: Song(id: s.id, title: s.title, artist: "Aurora Field", artistId: "ar1",
                                                 album: s.album, duration: TimeInterval(s.duration)), source: .library)
        }
        try cache(model).save(rows, key: key)
    }

    private let monitored = LidarrTopSongsModel.LidarrAnswer.answered(.monitored(lidarrId: 20, searching: false))

    private func ids(_ songs: [Song]) -> [String] { songs.map(\.id) }

    // MARK: - The process, end to end (D258–D262)

    /// The single's radio edit is found on the album through Lidarr; the live-only song and the library's "Song
    /// (Reprise)" never show; Navidrome's list fills the rest; each source in order, no song twice.
    @Test func singleOnlyMatchedThroughAlbum() async throws {
        let model = try await model()
        defer { model.signOut() }
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(result.complete)
        #expect(ids(result.rows.map(\.song)) == Self.expected)
        #expect(result.rows.map(\.source) == [.aurral, .aurral, .listenBrainz, .library, .library])
        #expect(result.rows.first?.song.title == "Harbour", "the album copy of \u{201C}Harbour (Radio Edit)\u{201D}")
    }

    @Test func liveAlbumCopyNeverShown() async throws {
        let model = try await model()
        defer { model.signOut() }
        answers.update { $0.topSongs = [] }
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(!ids(result.rows.map(\.song)).contains("s-glass"), "only on a live album: never")
        #expect(ids(result.rows.map(\.song)) == ["s-harbour", "s-wide", "s-north"])
    }

    /// K1 I2 (controller ruling): the index links Lidarr's "Song" to the library's "Song (Reprise)" (it folds the note);
    /// the fetched song fails `confirms` on its full title and is skipped like any unmatched song.
    @Test func repriseFromTheAlbumStepFailsTheRecheck() async throws {
        let model = try await model()
        defer { model.signOut() }
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(!ids(result.rows.map(\.song)).contains("s-reprise"))
        #expect(transport.sent.contains { $0.url?.path.hasSuffix("/rest/getSong") == true && $0.url?.query?.contains("id=s-reprise") == true },
                "it was linked and fetched, then refused")
    }

    @Test func navidromeFillsWhenOthersMiss() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.setPreview([["id": "1", "title": "Nobody Has This", "duration_ms": 200_000]])
        answers.update { $0.listenBrainz = json([]) }
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(result.complete && ids(result.rows.map(\.song)) == ["s-wide", "s-tide", "s-ember", "s-quiet"])
        #expect(result.rows.allSatisfy { $0.source == .library })
    }

    /// K1 M5 + re-review m1: a Discover copy of a song (the app knows its id) never stands in for the main library's.
    @Test func discoverCopyIsNotPreferred() async throws {
        answers.update {
            $0.library.insert(LibrarySong(id: "s-wide-flow", title: "Wide Open", album: "Discover Weekly", duration: 240,
                                          recording: recWide, library: 9), at: 0)
            $0.topSongs = []
        }
        let model = try await model()
        defer { model.signOut() }
        model.discover.flowSongIds = ["s-wide-flow"]
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(ids(result.rows.map(\.song)).contains("s-wide") && !ids(result.rows.map(\.song)).contains("s-wide-flow"))
    }

    @Test func fewerThanFiveShowsThose() async throws {
        let model = try await model()
        defer { model.signOut() }
        answers.update { $0.topSongs = [] }
        let page = try await page(model)
        await page.run(fresh: false) { self.monitored }
        #expect(ids(page.songs) == ["s-harbour", "s-wide", "s-north"] && page.phase == .shown && !page.wantsOrdinary)
        #expect(try cache(model).load(key)?.map(\.id) == ["s-harbour", "s-wide", "s-north"], "no filler")
    }

    /// Q2 (owner): none of the top songs are in the library: the ordinary Top songs (with previews) instead, and the saved
    /// list goes.
    @Test func zeroMatchesShowsOrdinaryList() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide"], in: model)
        transport.setPreview([["id": "1", "title": "Nobody Has This", "preview_url": "/api/deezer/preview/1.mp3", "duration_ms": 200_000]])
        answers.update { $0.listenBrainz = json([]); $0.topSongs = [] }
        let page = try await page(model)
        #expect(ids(page.songs) == ["s-tide"])
        await page.run(fresh: false) { self.monitored }
        #expect(page.wantsOrdinary && ids(page.songs) == ["s-tide"], "kept until the ordinary list is in (design M3)")
        #expect(try cache(model).load(key) == nil)
        page.retire()
        #expect(page.songs.isEmpty && !page.showsList)
        let ordinary = try #require(await model.artistTopSongs(name: "Aurora Field", mbid: artistMBID))
        #expect(ordinary.provider == .aurral && ordinary.rows.first?.preview != nil, "with its preview")
    }

    // MARK: - The saved list and the swap (D263, D264)

    @Test func savedListShowsAtOnceThenSwaps() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide", "s-ember"], in: model)
        let page = try await page(model)
        #expect(ids(page.songs) == ["s-tide", "s-ember"] && page.showsList && page.phase == .waiting, "before any read")
        await page.run(fresh: false) { self.monitored }
        #expect(ids(page.songs) == Self.expected && page.visibleChanges == 1)
        #expect(try cache(model).load(key)?.map(\.id) == Self.expected, "saved for next time")
        #expect(try cache(model).load(key)?.map(\.source) == ["aurral", "aurral", "listenBrainz", "library", "library"])
    }

    @Test func sameIdsDoNotSwap() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(Self.expected, in: model)
        let page = try await page(model)
        let before = page.songs
        await page.run(fresh: false) { self.monitored }
        #expect(ids(page.songs) == Self.expected && page.visibleChanges == 0)
        #expect(page.songs != before, "the same rows take the fresh songs' details (cover, format) silently")
    }

    /// Rows are identified by song id (the section's `ForEach`), so a row that stays keeps its identity across a swap; the
    /// swap itself is a single replacement with no animation (`.transaction`, checked in the section's source).
    @Test func swapHasNoAnimationAndKeepsRowIdentity() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-north", "s-tide"], in: model)
        let page = try await page(model)
        await page.run(fresh: false) { self.monitored }
        #expect(page.visibleChanges == 1, "one replacement, not one per row")
        #expect(Set(ids(page.songs)).isSuperset(of: ["s-north", "s-tide"]), "the rows that stay are the same songs")
        let section = LidarrTopSongsSection(songs: page.songs)
        #expect(section.songs.map(\.id) == ids(page.songs))
    }

    @Test func incompleteRefreshKeepsSavedList() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide", "s-ember"], in: model)
        answers.update { $0.listenBrainzStatus = 500 }
        let page = try await page(model)
        await page.run(fresh: false) { self.monitored }
        #expect(ids(page.songs) == ["s-tide", "s-ember"] && page.visibleChanges == 0 && page.phase == .shown)
        #expect(try cache(model).load(key)?.map(\.id) == ["s-tide", "s-ember"], "nothing saved")
    }

    @Test func incompleteRefreshWithNothingSavedShowsAndSaves() async throws {
        let model = try await model()
        defer { model.signOut() }
        answers.update { $0.listenBrainzStatus = 500 }
        let page = try await page(model)
        await page.run(fresh: false) { self.monitored }
        #expect(ids(page.songs) == ["s-harbour", "s-wide", "s-tide", "s-ember", "s-quiet"])
        #expect(try cache(model).load(key)?.map(\.id) == ["s-harbour", "s-wide", "s-tide", "s-ember", "s-quiet"])
    }

    /// D264: Aurral's failure is never kept as "no songs" (unlike `artistPreviewSongs`); its answer is kept for the session.
    @Test func failedAurralNotCachedAsEmpty() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.setPreview(Self.aurralFixture, status: 500)
        let failed = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(!failed.complete && !ids(failed.rows.map(\.song)).contains("s-harbour"))
        #expect(model.lidarrTopSongsSession.aurral[artistMBID] == nil && model.songActions.artistPreviews[artistMBID] == nil)
        transport.setPreview(Self.aurralFixture)
        let answered = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(answered.complete && ids(answered.rows.map(\.song)) == Self.expected)
        #expect(transport.previewReads == 2, "asked again after the failure")
        _ = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(transport.previewReads == 2, "the answer is kept for the session")
        _ = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: true)
        #expect(transport.previewReads == 3, "a pull asks again")
    }

    /// D262: a source that doesn't answer is cut by its deadline (the test clock fires only ListenBrainz's), and the list
    /// is incomplete; the others' songs still come.
    @Test(.timeLimit(.minutes(1))) func deadlineCutsASlowSource() async throws {
        let model = try await model()
        defer { model.signOut() }
        transport.hold("/1/popularity/top-recordings-for-artist/\(artistMBID.rawValue)")
        model.lidarrTopSongsSession.sleep = { wait, _ in
            if wait == .listenBrainz { return }
            try await Task.sleep(for: .seconds(3600))   // never: cancelled when its source answers
        }
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(!result.complete)
        #expect(ids(result.rows.map(\.song)) == ["s-harbour", "s-wide", "s-tide", "s-ember", "s-quiet"])
        #expect(result.rows.allSatisfy { $0.source != .listenBrainz })
        transport.release("/1/popularity/top-recordings-for-artist/\(artistMBID.rawValue)")
    }

    @Test func refreshAtMostEveryTwoMinutesUnlessPulled() async throws {
        let model = try await model()
        defer { model.signOut() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        model.lidarrTopSongsSession.now = { now }
        let first = try await page(model)
        await first.run(fresh: false) { self.monitored }
        #expect(transport.count("/rest/getTopSongs") == 1)

        let again = try await page(model)   // back to the page a minute later
        now += 60
        await again.run(fresh: false) { self.monitored }
        #expect(transport.count("/rest/getTopSongs") == 1, "not read again within two minutes")
        #expect(ids(again.songs) == Self.expected && again.phase == .shown, "the saved list shows")

        await again.run(fresh: true) { self.monitored }
        #expect(transport.count("/rest/getTopSongs") == 2, "a pull always refreshes")

        now += 121
        let later = try await page(model)
        await later.run(fresh: false) { self.monitored }
        #expect(transport.count("/rest/getTopSongs") == 3)
    }

    @Test func pullToRefreshKeepsSavedUntilSwap() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide"], in: model)
        let page = try await page(model)
        transport.hold("/rest/getTopSongs")
        let pull = Task { await page.run(fresh: true) { self.monitored } }
        #expect(await eventually { self.transport.count("/rest/getTopSongs") == 1 })
        #expect(ids(page.songs) == ["s-tide"] && page.visibleChanges == 0, "still showing while the refresh runs")
        #expect(try cache(model).load(key)?.map(\.id) == ["s-tide"], "a pull doesn't clear the saved list first")
        transport.release("/rest/getTopSongs")
        await pull.value
        #expect(ids(page.songs) == Self.expected && page.visibleChanges == 1)
    }

    // MARK: - Lidarr's answer (D257, D264)

    @Test func leftLidarrDropsSavedAndShowsOrdinary() async throws {
        let model = try await model()
        defer { model.signOut() }
        for state in [ArtistLidarrState.notInLidarr(mbid: artistMBID), .unmatched] {
            try saved(["s-tide"], in: model)
            let page = try await page(model)
            #expect(page.showsList)
            await page.run(fresh: false) { .answered(state) }
            #expect(page.wantsOrdinary && ids(page.songs) == ["s-tide"], "\(state): shown until the ordinary list is in")
            #expect(try cache(model).load(key) == nil)
            page.retire()
            #expect(page.songs.isEmpty && page.display(fallback: []) == .ordinary)
        }
        #expect(transport.count("/rest/getTopSongs") == 0, "nothing read for an artist Lidarr doesn't have")
    }

    /// Q1 (owner): a find still on trial keeps the ordinary Top songs (previews and Try); a kept find qualifies.
    @Test func findOnTrialUnchanged() async throws {
        let model = try await model()
        defer { model.signOut() }
        let trial = try await page(model)
        await trial.run(fresh: false) { .answered(.find(lidarrId: 20, state: .find)) }
        #expect(trial.wantsOrdinary && transport.count("/rest/getTopSongs") == 0)
        let kept = try await page(model)
        await kept.run(fresh: true) { .answered(.find(lidarrId: 20, state: .keptInFinds)) }
        #expect(ids(kept.songs) == Self.expected)
    }

    @Test func lidarrUnreadKeepsSavedAndSkipsRefresh() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide"], in: model)
        let unread = try await page(model)
        await unread.run(fresh: true) { .unread }
        #expect(ids(unread.songs) == ["s-tide"] && unread.phase == .shown && transport.count("/rest/getTopSongs") == 0)

        // Lidarr's answer bounded by its deadline (fired at once here): the same.
        model.lidarrTopSongsSession.sleep = { wait, _ in
            if wait == .lidarrAnswer { return }
            try await Task.sleep(for: .seconds(3600))
        }
        let slow = try await page(model)
        let answered = OSAllocatedUnfairLock(initialState: false)
        await slow.run(fresh: true) {
            // A Lidarr that answers only after the deadline (released at the end of the test).
            _ = await eventually(30) { answered.withLock { $0 } }
            return .answered(.monitored(lidarrId: 20, searching: false))
        }
        answered.withLock { $0 = true }
        #expect(ids(slow.songs) == ["s-tide"] && transport.count("/rest/getTopSongs") == 0)

        try cache(model).remove(key)
        let none = try await page(model)
        await none.run(fresh: true) { .unread }
        #expect(none.wantsOrdinary, "nothing saved: the ordinary list")
    }

    /// Through the page's own Lidarr line, as the artist page uses it.
    @Test func throughTheArtistPagesLidarrLine() async throws {
        let model = try await model()
        defer { model.signOut() }
        let line = ArtistLidarrModel(model: model, name: "Aurora Field", mbid: artistMBID)
        let first = try await page(model)
        await first.run(fresh: false) {
            await line.refresh()
            return line.state.map(LidarrTopSongsModel.LidarrAnswer.answered) ?? .unread
        }
        #expect(ids(first.songs) == Self.expected && line.presentation?.text == "In Lidarr \u{00B7} Monitored")

        answers.update { $0.lidarrArtists = json([]) }
        let line2 = ArtistLidarrModel(model: model, name: "Aurora Field", mbid: artistMBID)
        let page2 = try await page(model)
        await page2.run(fresh: false) {
            await line2.refresh()
            return line2.state.map(LidarrTopSongsModel.LidarrAnswer.answered) ?? .unread
        }
        let left = try cache(model).load(key)
        #expect(page2.wantsOrdinary && left == nil, "removed from Lidarr: the saved list goes")
    }

    // MARK: - Setups, offline, the outside page (D263, D267, D268)

    @Test func noLidarrNeverShowsSaved() async throws {
        let model = try await model(lidarr: false)
        defer { model.signOut() }
        try saved(["s-tide"], in: model)
        #expect(await model.lidarrTopSongs(name: "Aurora Field", mbid: artistMBID, artistId: "ar1") == nil)
    }

    @Test func deletedSongDroppedFromSavedList() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-gone", "s-tide"], in: model)
        let page = try await page(model)
        #expect(ids(page.songs) == ["s-tide"], "the library no longer has s-gone")
    }

    @Test func offlineShowsOnlySongsOnThePhone() async throws {
        let model = try await model()
        defer { model.signOut() }
        await model.downloads?.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        try saved(["s-tide", "s-ember"], in: model)
        model.download([Song(id: "s-tide", title: "Low Tide", artist: "Aurora Field", artistId: "ar1", album: "Second Sight",
                             albumId: "al-Secon", duration: 190, suffix: "mp3")], reason: .song)
        await model.downloads?.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = transport.sent.count
        // The offline artist page knows only the library's artist id; the list was saved under the MBID.
        let page = try await page(model, mbid: nil, artistId: "ar1")
        #expect(ids(page.songs) == ["s-tide"] && page.offline)
        #expect(transport.sent.count == before, "nothing is read")
        model.updatePreferences { $0.downloads.offlineMode = .off }
    }

    @Test func outsidePageSharesSavedListByMBID() async throws {
        let model = try await model()
        defer { model.signOut() }
        let library = try await page(model)
        await library.run(fresh: false) { self.monitored }
        let outside = try await page(model, mbid: artistMBID, artistId: nil)
        #expect(outside.key == library.key && ids(outside.songs) == Self.expected, "the same list, at once")
    }

    /// Q3 (owner): an artist Lidarr doesn't have keeps D104's Top songs (the chosen source, previews and the ⋯ menu); no
    /// saved list is made for them.
    @Test func notInLidarrUnchanged() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await page(model)
        await page.run(fresh: false) { .answered(.notInLidarr(mbid: artistMBID)) }
        let none = try cache(model).load(key)
        #expect(page.wantsOrdinary && none == nil)
        let ordinary = try #require(await model.artistTopSongs(name: "Aurora Field", mbid: artistMBID))
        #expect(ordinary.provider == .aurral)
        #expect(ordinary.rows.contains { $0.library == nil && $0.preview != nil }, "a song you haven't got, with its preview")
    }

    @Test func fourSetups() async throws {
        // Navidrome alone: no list, nothing read from Lidarr.
        let alone = try await model(aurral: false, lidarr: false, listenBrainzToken: nil)
        #expect(await alone.lidarrTopSongs(name: "Aurora Field", mbid: artistMBID, artistId: "ar1") == nil)
        #expect(alone.topSongsProviders(mbid: artistMBID) == [.library])
        alone.signOut()
        // + Aurral: no list.
        let withAurral = try await model(lidarr: false, listenBrainzToken: nil)
        #expect(await withAurral.lidarrTopSongs(name: "Aurora Field", mbid: artistMBID, artistId: "ar1") == nil)
        withAurral.signOut()
        #expect(!transport.sent.contains { $0.url?.port == 8686 }, "no Lidarr: nothing read from it")
        // + Lidarr (ListenBrainz with a token, no Aurral): ListenBrainz then the library.
        let withLidarr = try await model(aurral: false)
        let partial = await withLidarr.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(partial.complete && ids(partial.rows.map(\.song)) == ["s-north", "s-wide", "s-tide", "s-ember", "s-quiet"])
        #expect(transport.previewReads == 0)
        withLidarr.signOut()
        // All of them: the full process.
        let all = try await model()
        defer { all.signOut() }
        let full = await all.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(ids(full.rows.map(\.song)) == Self.expected)
    }

    /// D262: reads only. Every request is a GET; Lidarr is asked only for its artists, commands, albums and tracks; no
    /// MusicBrainz, Deezer or Apple host.
    @Test func noWritesAndNoMusicBrainz() async throws {
        let model = try await model()
        defer { model.signOut() }
        let before = transport.sent.count
        let line = ArtistLidarrModel(model: model, name: "Aurora Field", mbid: artistMBID)
        let page = try await page(model)
        await page.run(fresh: true) {
            await line.refresh()
            return line.state.map(LidarrTopSongsModel.LidarrAnswer.answered) ?? .unread
        }
        let sent = transport.sent.dropFirst(before)
        #expect(!sent.isEmpty && sent.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        let lidarr = Set(sent.filter { $0.url?.port == 8686 }.compactMap { $0.url?.path })
        #expect(lidarr == ["/api/v1/artist", "/api/v1/command", "/api/v1/album", "/api/v1/track"])
        for host in ["musicbrainz.org", "deezer", "apple"] {
            #expect(!sent.contains { $0.url?.host?.contains(host) == true }, "\(host)")
        }
        #expect(sent.filter { $0.url?.path.hasSuffix("/rest/getSong") == true }.count <= AppModel.lidarrTopSongsFetches)
    }

    // MARK: - Settings (D266) and sign-out (D263)

    @Test func settingsFooterNamesOnlySetUpSources() async throws {
        let all = try await model()
        #expect(ArtistTopSongsView.footer(all) == "Used for the Top songs of artists Lidarr doesn\u{2019}t look after. For artists Lidarr looks after, Top songs are up to five songs you already have, picked from Aurral, then ListenBrainz, then your library. If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note.")
        all.signOut()
        let noAurral = try await model(aurral: false)
        #expect(ArtistTopSongsView.footer(noAurral).contains("picked from ListenBrainz, then your library. If the choice"))
        noAurral.signOut()
        let libraryOnly = try await model(aurral: false, listenBrainzToken: nil)
        defer { libraryOnly.signOut() }
        #expect(ArtistTopSongsView.footer(libraryOnly) == "Used for the Top songs of artists Lidarr doesn\u{2019}t look after. For artists Lidarr looks after, Top songs are up to five songs you already have, picked from your library. If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note. ListenBrainz needs your token in Settings \u{203A} Scrobbling.")
    }

    @Test func settingsFooterUnchangedWithoutLidarr() async throws {
        let withToken = try await model(lidarr: false)
        #expect(ArtistTopSongsView.footer(withToken) == "Used for the Top songs on every artist page. If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note.")
        withToken.signOut()
        let noToken = try await model(lidarr: false, listenBrainzToken: nil)
        defer { noToken.signOut() }
        #expect(ArtistTopSongsView.footer(noToken) == "Used for the Top songs on every artist page. If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note. ListenBrainz needs your token in Settings \u{203A} Scrobbling.")
    }

    @Test func signOutRemovesTopSongsFiles() async throws {
        let model = try await model()
        let page = try await page(model)
        await page.run(fresh: false) { self.monitored }
        let file = try cache(model).url
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(!model.lidarrTopSongsSession.refreshedAt.isEmpty && !model.lidarrTopSongsSession.aurral.isEmpty)
        model.signOut()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(model.lidarrTopSongsSession.refreshedAt.isEmpty && model.lidarrTopSongsSession.aurral.isEmpty)
    }

    // MARK: - Fix round 1

    /// I1 (controller ruling C1): a direct-ladder link must also have the same strict title. ListenBrainz's "Song" (245 s)
    /// finds only the library's "Song (Reprise)" (the index folds the note): not shown. The ladder itself is unchanged
    /// for every other caller.
    @Test func fix1_I1_directMatchToARepriseIsNotShown() async throws {
        answers.update {
            $0.listenBrainz = json([["artist_mbids": [artistMBID.rawValue], "artist_name": "Aurora Field",
                                     "recording_mbid": "11111111-1111-4111-8111-111111111199", "recording_name": "Song",
                                     "length": 245_000]])
            $0.topSongs = []
        }
        let model = try await model()
        defer { model.signOut() }
        transport.setPreview([])
        let recording = ExternalRecording(artistMBID: artistMBID, title: "Song", artist: "Aurora Field", duration: 245,
                                          source: .listenBrainz)
        #expect(await model.matchIndex?.index.librarySong(for: recording) == "s-reprise", "Try and search: unchanged")
        let result = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: false)
        #expect(!ids(result.rows.map(\.song)).contains("s-reprise"))
    }

    /// I2: a refresh that finishes after sign-out writes nothing (no file comes back, nothing lands in the session).
    @Test func fix1_I2_aRefreshFinishingAfterSignOutWritesNothing() async throws {
        let model = try await model()
        let file = try cache(model).url
        let page = try await page(model)
        transport.hold("/rest/getTopSongs")
        let refresh = Task { await page.run(fresh: true) { self.monitored } }
        #expect(await eventually { self.transport.count("/rest/getTopSongs") == 1 })
        model.signOut()
        transport.release("/rest/getTopSongs")
        await refresh.value
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(model.lidarrTopSongsSession.aurral.isEmpty && model.lidarrTopSongsSession.refreshedAt.isEmpty)
    }

    /// M1: a run that isn't the page's latest never changes it (the outside page's task and a pull can overlap).
    @Test func fix1_M1_aSupersededRunIsDropped() async throws {
        let model = try await model()
        defer { model.signOut() }
        let page = try await page(model)
        let answer = OSAllocatedUnfairLock(initialState: false)
        let asked = OSAllocatedUnfairLock(initialState: false)
        let older = Task {
            await page.run(fresh: true) {
                asked.withLock { $0 = true }
                _ = await eventually(30) { answer.withLock { $0 } }
                return .answered(.notInLidarr(mbid: artistMBID))
            }
        }
        #expect(await eventually { asked.withLock { $0 } }, "the older run is waiting for Lidarr")
        await page.run(fresh: true) { self.monitored }
        #expect(ids(page.songs) == Self.expected)
        answer.withLock { $0 = true }
        await older.value
        #expect(ids(page.songs) == Self.expected && !page.wantsOrdinary, "the older run's answer is dropped")
        #expect(try cache(model).load(key)?.map(\.id) == Self.expected)
    }

    /// M1: the refresh is noted when it starts, so two pages of one artist opened together refresh once.
    @Test func fix1_M1_twoPagesOfOneArtistRefreshOnce() async throws {
        let model = try await model()
        defer { model.signOut() }
        let library = try await page(model)
        let outside = try await page(model, mbid: artistMBID, artistId: nil)
        transport.hold("/rest/getTopSongs")
        let first = Task { await library.run(fresh: false) { self.monitored } }
        #expect(await eventually { self.transport.count("/rest/getTopSongs") == 1 })
        await outside.run(fresh: false) { self.monitored }
        transport.release("/rest/getTopSongs")
        await first.value
        #expect(transport.count("/rest/getTopSongs") == 1)
    }

    /// M4 (and design M5): one predicate says whether Aurral is used, for the footer and the read alike.
    @Test func fix1_M4_footerAndReadAgreeOnAurral() async throws {
        for aurral in [true, false] {
            let model = try await model(aurral: aurral)
            let before = transport.previewReads
            _ = await model.readLidarrTopSongs(name: "Aurora Field", mbid: artistMBID, lidarrArtistId: 20, fresh: true)
            let read = transport.previewReads > before
            #expect(model.lidarrTopSongsUsesAurral == aurral && read == aurral)
            #expect(ArtistTopSongsView.footer(model).contains("picked from Aurral") == aurral)
            model.signOut()
        }
    }

    /// Design H2: what the page shows as it learns. Lidarr's answer pending: only a saved list (nothing else, no space
    /// held). Qualifying with nothing saved while the refresh runs: the library's own top songs (Popular's rows) under
    /// "Top songs". Not qualifying: the ordinary list.
    @Test func fix1_H2_theSectionNeverFlipsBetweenPopularAndTopSongs() async throws {
        let model = try await model()
        defer { model.signOut() }
        let fallback = [Song(id: "s-tide", title: "Low Tide", artist: "Aurora Field", album: "Second Sight", duration: 190)]
        let fresh = try await page(model)
        #expect(fresh.display(fallback: fallback) == .nothing, "Lidarr hasn't answered: nothing, not Popular")

        transport.hold("/rest/getTopSongs")
        let refresh = Task { await fresh.run(fresh: true) { self.monitored } }
        #expect(await eventually { self.transport.count("/rest/getTopSongs") == 1 })
        #expect(fresh.display(fallback: fallback) == .lidarr(fallback), "qualifying: the library's songs, as Top songs")
        #expect(fresh.display(fallback: Array(repeating: fallback[0], count: 8)) == .lidarr(Array(repeating: fallback[0], count: 5)),
                "at most five")
        transport.release("/rest/getTopSongs")
        await refresh.value
        #expect(fresh.display(fallback: fallback) == .lidarr(fresh.songs) && ids(fresh.songs) == Self.expected)

        try saved(["s-north"], in: model)
        let savedPage = try await page(model)
        #expect(savedPage.display(fallback: fallback) == .lidarr(savedPage.songs), "a saved list shows while pending")

        let other = try await page(model, mbid: MBID("22222222-2222-4222-8222-222222222222"), artistId: "ar9")
        await other.run(fresh: false) { .answered(.notInLidarr(mbid: nil)) }
        other.retire()
        #expect(other.display(fallback: fallback) == .ordinary)
    }

    /// Design H3: the ordinary list is read at once, in parallel with Lidarr's answer, and shown only once that answer
    /// says so; a list that was showing stays until the ordinary one is in, then goes in one step (design M3).
    @Test func fix1_H3_theOrdinaryListIsReadWithoutWaitingForLidarr() async throws {
        let model = try await model()
        defer { model.signOut() }
        try saved(["s-tide"], in: model)
        let page = try await page(model)
        let lidarrAnswered = OSAllocatedUnfairLock(initialState: false)
        let ordinaryStarted = OSAllocatedUnfairLock(initialState: false)
        let ordinaryDone = OSAllocatedUnfairLock(initialState: false)
        let load = Task {
            await page.load(fresh: false, lidarr: {
                _ = await eventually(30) { lidarrAnswered.withLock { $0 } }
                return .answered(.notInLidarr(mbid: artistMBID))
            }, ordinary: {
                ordinaryStarted.withLock { $0 = true }
                _ = await eventually(30) { ordinaryDone.withLock { $0 } }
            })
        }
        #expect(await eventually { ordinaryStarted.withLock { $0 } }, "the ordinary read doesn't wait for Lidarr")
        #expect(page.display(fallback: []) == .lidarr(page.songs) && ids(page.songs) == ["s-tide"])
        lidarrAnswered.withLock { $0 = true }
        #expect(await eventually { page.wantsOrdinary })
        #expect(ids(page.songs) == ["s-tide"], "kept until the ordinary list is in")
        ordinaryDone.withLock { $0 = true }
        await load.value
        #expect(page.songs.isEmpty && page.display(fallback: []) == .ordinary)
    }
}
