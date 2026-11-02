import CarPlayUI
import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import os
import Testing
import UIKit
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!
private let notAllowed = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"not admin"}}}"#.utf8)

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

private func queryValue(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

/// Round 12 Y3: Home and the main library (plan item 5), pull to refresh on the pages (item 4) and Now Playing's
/// "what you hear" line (item 11). The fake server keeps three libraries, as the owner's does: Music Library (1),
/// Aurral Playlists (2) and Finds (3); its lists answer for the library asked, or for all of them when none is named.
@MainActor @Suite(.serialized) final class Round12HomePagesTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round12HomePagesTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "Round12HomePagesTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    /// The music folders the server lists.
    let folders = OSAllocatedUnfairLock(initialState: [1, 2, 3])
    /// What `getScanStatus` answers, one per ask (the last one repeats); `startScan` refused when false.
    let scanAnswers = OSAllocatedUnfairLock(initialState: [false])
    let scanAllowed = OSAllocatedUnfairLock(initialState: true)
    /// What `getPlaylists` lists.
    let playlistsJSON = OSAllocatedUnfairLock(initialState: "")

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Each library's albums: main-1 in 1, aurral-1 in 2, find-1 in 3.
    nonisolated private static func albums(_ folder: String?) -> [String] {
        switch folder {
        case "1": ["main-1"]
        case "2": ["aurral-1"]
        case "3": ["find-1"]
        default: ["main-1", "aurral-1", "find-1"]
        }
    }

    func signedInModel() async throws -> AppModel {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        let folders = folders
        t.stub(pathSuffix: "/rest/getMusicFolders") { _ in
            let list = folders.withLock { $0 }.map { #"{"id":\#($0),"name":"L\#($0)"}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""musicFolders":{"musicFolder":[\#(list)]}"#))
        }
        t.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let rows = Self.albums(queryValue(request, "musicFolderId"))
                .map { #"{"id":"\#($0)","name":"\#($0)","artist":"A","songCount":1}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(rows)]}"#))
        }
        t.stub(pathSuffix: "/rest/search3") { request in
            let rows = Self.albums(queryValue(request, "musicFolderId"))
                .map { #"{"id":"\#($0)","name":"\#($0)","artist":"A","songCount":1}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""searchResult3":{"album":[\#(rows)]}"#))
        }
        let playlists = playlistsJSON
        t.stub(pathSuffix: "/rest/getPlaylists") { _ in
            MockTransport.Response(status: 200, body: subsonic(#""playlists":{"playlist":[\#(playlists.withLock { $0 })]}"#))
        }
        t.stub(pathSuffix: "/rest/getGenres", body: subsonic(#""genres":{"genre":[]}"#))
        t.stub(pathSuffix: "/rest/getStarred2", body: subsonic(#""starred2":{}"#))
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let allowed = scanAllowed, answers = scanAnswers
        t.stub(pathSuffix: "/rest/startScan") { _ in
            MockTransport.Response(status: 200, body: allowed.withLock { $0 } ? ok : notAllowed)
        }
        t.stub(pathSuffix: "/rest/getScanStatus") { _ in
            let scanning = answers.withLock { list in list.count > 1 ? list.removeFirst() : list[0] }
            return MockTransport.Response(status: 200, body: subsonic(#""scanStatus":{"scanning":\#(scanning)}"#))
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

    /// The owner's choice in Settings (R18): Music Library is the main library, Finds is library 3.
    func chooseMainLibrary(_ model: AppModel) throws {
        let scope = try #require(model.navidromeScope)
        var setup = FindsSetup(lidarrScope: "lidarr", navidromeScope: scope)
        setup.library = NavidromeLibrary(id: 3, name: "Finds", path: "/finds")
        setup.mainLibrary = NavidromeLibrary(id: 1, name: "Music Library", path: "/music")
        model.findsSetup = setup
    }

    private func albumIds(_ shelves: [HomeShelf]) -> Set<String> {
        Set(shelves.flatMap(\.items).compactMap { if case .album(let a) = $0 { a.id } else { nil } })
    }

    // MARK: - Item 5: the main library everywhere

    @Test func mainLibraryIsPickedAsInR18() {
        // Chosen: used, unless it's kept apart or gone.
        #expect(AppModel.mainLibraryId(chosen: 1, folders: [1, 2, 3], separate: [3]) == 1)
        #expect(AppModel.mainLibraryId(chosen: 3, folders: [1, 2, 3], separate: [3]) == nil)
        #expect(AppModel.mainLibraryId(chosen: 9, folders: [1, 2, 3], separate: [3]) == nil)
        // Obvious: one library left once Finds is set aside.
        #expect(AppModel.mainLibraryId(chosen: nil, folders: [1, 3], separate: [3]) == 1)
        // Not obvious: the owner chooses; until then nothing is named.
        #expect(AppModel.mainLibraryId(chosen: nil, folders: [1, 2, 3], separate: [3]) == nil)
        // A single library: nothing is sent, chosen or not.
        #expect(AppModel.mainLibraryId(chosen: nil, folders: [1], separate: []) == nil)
        #expect(AppModel.mainLibraryId(chosen: 1, folders: [1], separate: []) == nil)
        #expect(AppModel.mainLibraryId(chosen: nil, folders: nil, separate: []) == nil)
    }

    /// Aurral's and the Finds library's albums never reach Home, the Library's album list, Search or the car's Home,
    /// and every list call names the main library.
    @Test func aurralAndFindsNeverReachHomeLibraryOrSearch() async throws {
        let model = try await signedInModel()
        try chooseMainLibrary(model)
        #expect(model.libraryScope == 1)
        let before = transport.inner.requests.count

        let shelves = try await model.homeShelves(for: [.jumpBackIn, .recentlyAdded, .mostPlayed, .randomAlbums])
        #expect(albumIds(shelves) == ["main-1"])
        let library = try await model.albumsWindow(from: 0)
        #expect(library.items.map(\.id) == ["main-1"])
        let search = try await model.request { try await $0.search("a") }   // what Search's library source runs
        #expect(search.albums.map(\.id) == ["main-1"])

        let lists = transport.inner.requests.dropFirst(before)
            .filter { ["getAlbumList2", "search3"].contains($0.url!.lastPathComponent) }
        #expect(!lists.isEmpty)
        for r in lists { #expect(queryValue(r, "musicFolderId") == "1", "\(r.url!.lastPathComponent) names the main library") }
    }

    /// Without a main library chosen, one library left besides Finds is picked by itself once the libraries are read.
    @Test func obviousMainLibraryIsPickedAutomatically() async throws {
        folders.withLock { $0 = [1, 3] }
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        defaults.set(3, forKey: AppModel.findsLibraryKey(scope))   // the Finds library, known per account (FM2)
        await model.refreshMusicFolders()
        #expect(model.libraryScope == 1)
        #expect(albumIds(try await model.homeShelves(for: [.recentlyAdded])) == ["main-1"])
    }

    // MARK: - Fix round 1: the main library picked without the owner

    /// The owner's three libraries, with their paths (`/api/library`) and album counts (`/api/album`).
    func stubLibraries(names: [Int: String] = [1: "Music Library", 2: "Aurral Playlists", 3: "Finds"],
                       paths: [Int: String] = [1: "/music", 2: "/aurral", 3: "/finds"],
                       albums: [Int: Int] = [1: 312, 2: 40, 3: 900]) {
        let rows = [1, 2, 3].map { #"{"id":\#($0),"name":"\#(names[$0]!)","path":"\#(paths[$0]!)"}"# }.joined(separator: ",")
        transport.inner.stub(pathSuffix: "/api/library", body: Data("[\(rows)]".utf8))
        transport.inner.stub(pathSuffix: "/api/album") { request in
            let id = Int(queryValue(request, "library_id") ?? "") ?? 0
            return MockTransport.Response(status: 200, body: Data("[]".utf8), headers: ["X-Total-Count": "\(albums[id] ?? 0)"])
        }
    }

    /// I1: Lidarr's main root folder (`/music`) is in library 1, so library 1 is the main library, picked and saved
    /// where Settings shows it, with no choice made and nothing named "Aurral" looked for.
    @Test func mainLibraryIsTheOneHoldingLidarrsRootFolder() async throws {
        stubLibraries()
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        var setup = FindsSetup(lidarrScope: "lidarr", navidromeScope: scope)
        setup.library = NavidromeLibrary(id: 3, name: "Finds", path: "/finds")
        model.findsSetup = setup
        model.lidarrSetup = LidarrSetup(base: URL(string: "http://127.0.0.1:8686")!, scope: "lidarr", rootFolderPath: "/music")
        #expect(model.libraryScope == nil, "two libraries left besides Finds: not obvious from the folders alone")
        await model.refreshMusicFolders()
        #expect(model.findsSetup?.mainLibrary?.id == 1)
        #expect(model.libraryScope == 1)
        #expect(albumIds(try await model.homeShelves(for: [.recentlyAdded])) == ["main-1"])
    }

    /// Names are the owner's to change: the pick follows the folder, whatever the libraries are called.
    @Test func mainLibraryPickNeverGoesByName() async throws {
        stubLibraries(names: [1: "Aurral Playlists", 2: "Music Library", 3: "Finds"])
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        var setup = FindsSetup(lidarrScope: "lidarr", navidromeScope: scope)
        setup.library = NavidromeLibrary(id: 3, name: "Finds", path: "/finds")
        model.findsSetup = setup
        model.lidarrSetup = LidarrSetup(base: URL(string: "http://127.0.0.1:8686")!, scope: "lidarr", rootFolderPath: "/music/")
        await model.refreshMusicFolders()
        #expect(model.libraryScope == 1)
    }

    /// Without Lidarr: the library with the most albums, Finds left out (it has more here).
    @Test func withoutLidarrTheLibraryWithMostAlbums() async throws {
        stubLibraries()
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        defaults.set(3, forKey: AppModel.findsLibraryKey(scope))
        await model.refreshMusicFolders()
        #expect(model.libraryScope == 1)
        #expect(model.mainLibraryPick == .mostAlbums && model.mainLibraryPickedAutomatically)
        // N1: a fallback pick is never saved.
        #expect(defaults.object(forKey: AppModel.autoMainLibraryKey(scope)) == nil)
    }

    // MARK: - Fix round 2 (N1): the pick follows Lidarr and Finds as they arrive

    /// A fresh install: sign in (no Lidarr, Finds unknown), then Lidarr, then Finds. The fallback's first guess
    /// (library 3, the most albums) is only a guess: Lidarr's root replaces it, and it's saved only then.
    @Test func freshInstallSignInThenLidarrThenFinds() async throws {
        stubLibraries()
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        #expect(model.libraryScope == 3 && model.mainLibraryPick == .mostAlbums)
        #expect(defaults.object(forKey: AppModel.autoMainLibraryKey(scope)) == nil, "a guess is kept in memory only")

        model.lidarrSetup = LidarrSetup(base: URL(string: "http://127.0.0.1:8686")!, scope: "lidarr", rootFolderPath: "/music")
        #expect(await eventually { model.libraryScope == 1 }, "Lidarr's root decides as soon as it's there")
        #expect(model.mainLibraryPick == .lidarrRoot)
        #expect(defaults.object(forKey: AppModel.autoMainLibraryKey(scope)) as? Int == 1)

        var setup = FindsSetup(lidarrScope: "lidarr", navidromeScope: scope)
        setup.library = NavidromeLibrary(id: 3, name: "Finds", path: "/finds")
        model.findsSetup = setup
        #expect(await eventually { model.findsSetup?.mainLibrary?.id == 1 }, "the Lidarr pick shows in Settings")
        #expect(model.libraryScope == 1 && model.mainLibraryPickedAutomatically)
    }

    /// The fallback never picks the remembered Finds library, and learning it redoes the pick.
    @Test func fallbackRedoneWhenFindsIsLearned() async throws {
        stubLibraries()
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        #expect(model.libraryScope == 3)
        defaults.set(3, forKey: AppModel.findsLibraryKey(scope))
        model.findsLibraryLearned()
        #expect(await eventually { model.libraryScope == 1 })
    }

    /// The owner's own choice is never replaced by a pick.
    @Test func ownersChoiceIsNeverReplaced() async throws {
        stubLibraries()
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope)
        var setup = FindsSetup(lidarrScope: "lidarr", navidromeScope: scope)
        setup.library = NavidromeLibrary(id: 3, name: "Finds", path: "/finds")
        model.findsSetup = setup
        model.chooseMainLibrary(NavidromeLibrary(id: 2, name: "Aurral Playlists", path: "/aurral"))
        model.lidarrSetup = LidarrSetup(base: URL(string: "http://127.0.0.1:8686")!, scope: "lidarr", rootFolderPath: "/music")
        await model.autoPickMainLibrary()
        #expect(model.libraryScope == 2 && model.mainLibraryPick == .chosen)
    }

    /// m1: a Lidarr root that's in no library picks nothing (no guess either), and Settings says so.
    @Test func lidarrRootInNoLibraryPicksNothing() async throws {
        stubLibraries()
        let model = try await signedInModel()
        model.lidarrSetup = LidarrSetup(base: URL(string: "http://127.0.0.1:8686")!, scope: "lidarr", rootFolderPath: "/data/elsewhere")
        await model.autoPickMainLibrary()
        #expect(model.libraryScope == nil && model.mainLibraryPick == .none)
        #expect(MainLibraryCopy.note(.none) == "No main library yet: Home, Library and Search show every library.")
        #expect(MainLibraryCopy.note(.lidarrRoot) != nil && MainLibraryCopy.note(.chosen) == nil)
    }

    // MARK: - Fix round 1: CarPlay, refresh, match index, label

    /// I2: the car's Recently downloaded playlist opens the phone's copy, so it plays offline.
    @Test func carRecentlyDownloadedPlaylistOpensThePhonesCopy() {
        let playlist = Playlist(id: "p1", name: "Road Mix", songCount: 2, duration: 0)
        let rows = CarPlayRows.home([CPHomeShelf(section: .downloaded, items: [.playlist(playlist)]),
                                     CPHomeShelf(section: .playlists, items: [.playlist(playlist)])]).flatMap(\.rows)
        #expect(rows.map(\.action) == [.open(.downloadedPlaylist(id: "p1", title: "Road Mix")),
                                       .open(.playlist(id: "p1", title: "Road Mix"))])
    }

    /// A scan already running (the owner's own): no second scan, no wait, one reload.
    @Test func refreshDuringARunningScanJustReloads() async throws {
        let model = try await signedInModel()
        scanAnswers.withLock { $0 = [true] }
        let before = transport.inner.requests.count
        var reloads = 0
        let outcome = await model.refreshPage(coverArtIds: [], reload: { reloads += 1 }, sleep: { _ in Issue.record("no wait") })
        #expect(outcome == .init(scanned: false, scanFinished: false, reloads: 1) && reloads == 1)
        #expect(!transport.inner.requests.dropFirst(before).contains { $0.url!.lastPathComponent == "startScan" })
    }

    /// The quick scan covers the main library and Finds, not every library.
    @Test func refreshScansTheMainLibraryAndFinds() async throws {
        let model = try await signedInModel()
        try chooseMainLibrary(model)
        scanAnswers.withLock { $0 = [false] }
        let before = transport.inner.requests.count
        await model.refreshPage(coverArtIds: [], reload: {}, sleep: { _ in })
        let scan = try #require(transport.inner.requests.dropFirst(before).first { $0.url!.lastPathComponent == "startScan" })
        let targets = URLComponents(url: scan.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "target" }.compactMap(\.value)
        #expect(targets == ["1:", "3:"])
    }

    /// The match index names the main library and Finds; unscoped it reads every library.
    @Test func matchIndexCoversMainAndFinds() async throws {
        let model = try await signedInModel()
        #expect(model.matchIndexLibraries == .all)
        try chooseMainLibrary(model)
        #expect(model.matchIndexLibraries == .only([1, 3]))
    }

    /// The label follows the stream the song is playing on, not a quality changed since.
    @Test func hearingFollowsThePlayingStreamNotTheSetting() async throws {
        let model = try await signedInModel()
        model.updatePreferences { $0.playback.wifi = .opusMedium }
        let song = Song(id: "st", title: "S", artist: "A", album: "B", duration: 60, suffix: "flac")
        model.play([song], startAt: 0)
        #expect(await eventually { model.player.currentURL != nil })
        model.updatePreferences { $0.playback.wifi = .aacHigh }
        #expect(model.playingSource(song) == .stream(.opusMedium))
    }

    @Test func singleLibrarySendsNothing() async throws {
        folders.withLock { $0 = [1] }
        let model = try await signedInModel()
        #expect(model.libraryScope == nil)
        let before = transport.inner.requests.count
        _ = try await model.homeShelves(for: [.recentlyAdded])
        for r in transport.inner.requests.dropFirst(before) { #expect(queryValue(r, "musicFolderId") == nil) }
    }

    // MARK: - Item 5: Playlists shelf, Recently downloaded, stale cache

    @Test func playlistsShelfOwnFirstThenMostRecentlyChanged() async throws {
        playlistsJSON.withLock {
            $0 = [
                #"{"id":"old-mine","name":"Old","owner":"admin","songCount":1,"changed":"2024-01-01T00:00:00Z"}"#,
                #"{"id":"new-theirs","name":"New","owner":"guest","public":true,"songCount":1,"changed":"2026-10-30T00:00:00Z"}"#,
                #"{"id":"new-mine","name":"Newer","owner":"Admin","songCount":1,"changed":"2026-10-31T00:00:00Z"}"#,
                #"{"id":"aaa-undated","name":"Aaa","owner":"admin","songCount":1}"#,
            ].joined(separator: ",")
        }
        let model = try await signedInModel()
        let shelf = try #require(try await model.homeShelves(for: [.playlists]).first)
        let ids = shelf.items.compactMap { if case .playlist(let p) = $0 { p.id } else { nil } }
        #expect(ids == ["new-mine", "old-mine", "aaa-undated", "new-theirs"])
        // The Discover hook (Y6) leaves a playlist out of the shelf.
        let all = [Playlist(id: "flow", name: "Weekly Flow", songCount: 1, duration: 0),
                   Playlist(id: "mine", name: "Mine", songCount: 1, duration: 0)]
        #expect(AppModel.homePlaylists(all, username: "admin", isDiscover: { $0.id == "flow" }).map(\.id) == ["mine"])
    }

    /// Newest download first; a downloaded playlist is one tile, and it opens the phone's copy.
    @Test func recentlyDownloadedByDateWithPlaylistsAsThemselves() async throws {
        let model = try await signedInModel()
        let s = { (id: String, album: String) in Song(id: id, title: id, artist: "A", album: album, albumId: album, duration: 60) }
        model.download([s("a1", "Aardvark")], reason: .album("Aardvark")); await model.downloads!.settled()
        try await Task.sleep(for: .milliseconds(20))
        model.download([s("x1", "Xylo"), s("y1", "Yarrow")], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Road Mix", coverArtId: nil, songIds: ["x1", "y1"], savedAt: .now))
        await model.downloads!.settled()
        try await Task.sleep(for: .milliseconds(20))
        model.download([s("z1", "Zebra")], reason: .album("Zebra")); await model.downloads!.settled()

        let shelf = try #require(try await model.homeShelves(for: [.downloaded]).first)
        #expect(shelf.section.title == "Recently downloaded")
        #expect(shelf.items.map(\.id) == ["album-Zebra", "playlist-p1", "album-Aardvark"], "newest first, not A–Z")
        #expect(shelf.items.allSatisfy { HomeShelf.fits($0, in: .downloaded) })
    }

    /// A saved shelf whose tiles aren't its section's kind (an older build's, another section's) is thrown away.
    @Test func staleCacheOfTheWrongKindIsThrownAway() throws {
        let cache = HomeShelfCache(root: tmp, scope: "stale")
        let album = Album(id: "a", name: "A", artist: "X", songCount: 1, duration: 0)
        let playlist = Playlist(id: "p", name: "P", songCount: 2, duration: 0)
        cache.save([HomeShelf(section: .playlists, items: [.album(album)]),
                    HomeShelf(section: .recentlyAdded, items: [.album(album)]),
                    HomeShelf(section: .downloaded, items: [.playlist(playlist), .downloadedAlbum(album)]),
                    HomeShelf(section: .mostPlayed, items: [.album(album), .playlist(playlist)])])
        #expect(cache.load().map(\.section) == [.recentlyAdded, .downloaded])
    }

    // MARK: - Item 4: pull to refresh

    @Test func refreshScansWaitsAndReloads() async throws {
        let model = try await signedInModel()
        scanAnswers.withLock { $0 = [false, true, true, false] }   // idle before the pull
        var reloads = 0
        var slept: [Duration] = []
        let before = transport.inner.requests.count
        let outcome = await model.refreshPage(coverArtIds: ["al-1"], reload: { reloads += 1 },
                                              sleep: { @MainActor d in slept.append(d) })
        #expect(outcome == .init(scanned: true, scanFinished: true, reloads: 2))
        #expect(reloads == 2, "once at once, once after the scan")
        #expect(slept.count == 3)
        let sent = transport.inner.requests.dropFirst(before)
        let scan = try #require(sent.first { $0.url!.lastPathComponent == "startScan" })
        #expect(queryValue(scan, "fullScan") == "false", "a quick scan, never a full one")
        #expect(sent.filter { $0.url!.lastPathComponent == "getScanStatus" }.count == 4, "one before, three while waiting")
    }

    @Test func refreshGivesUpWaitingAfterTwentySeconds() async throws {
        let model = try await signedInModel()
        scanAnswers.withLock { $0 = [false, true] }   // idle before the pull, then never done
        var reloads = 0
        var waited: Duration = .zero
        let outcome = await model.refreshPage(coverArtIds: [], reload: { reloads += 1 },
                                              sleep: { @MainActor d in waited += d })
        #expect(outcome == .init(scanned: true, scanFinished: false, reloads: 1))
        #expect(waited == AppModel.scanWait && reloads == 1)
    }

    /// An account that may not scan (not an admin): the page still reloads, without waiting.
    @Test func refreshWithoutScanStillReloads() async throws {
        let model = try await signedInModel()
        scanAllowed.withLock { $0 = false }
        var reloads = 0
        let outcome = await model.refreshPage(coverArtIds: [], reload: { reloads += 1 }, sleep: { _ in Issue.record("no wait") })
        #expect(outcome == .init(scanned: false, scanFinished: false, reloads: 1) && reloads == 1)
    }

    /// The page's saved Popular, its cover's colours and its image in memory go; offline only the phone is read again.
    @Test func refreshClearsPageCachesAndOfflineRereadsThePhone() async throws {
        let model = try await signedInModel()
        let scope = try #require(model.navidromeScope), memoryScope = try #require(model.artworkScope)
        let popular = PopularSongsCache(root: tmp, scope: scope)
        popular.save([Song(id: "t1", title: "Top", artist: "A", album: "B", duration: 1)], artistId: "ar1")
        let key = ArtworkCache.key(scope: memoryScope, coverArtId: "ar-1", size: 120)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        ArtworkCache.shared.store(image, for: key)
        _ = await ArtPaletteCache.shared.palette(for: "ar-1") { image }
        #expect(ArtPaletteCache.shared.cached("ar-1") != nil && popular.load(artistId: "ar1") != nil)

        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = transport.inner.requests.count
        var reloads = 0
        let outcome = await model.refreshPage(artistId: "ar1", coverArtIds: ["ar-1", nil], reload: { reloads += 1 })
        #expect(outcome.reloads == 1 && !outcome.scanned && reloads == 1)
        #expect(transport.inner.requests.count == before, "offline: nothing asked of the server")
        #expect(popular.load(artistId: "ar1") == nil)
        #expect(ArtPaletteCache.shared.cached("ar-1") == nil)
        #expect(ArtworkCache.shared.cached(key) == nil)
    }

    // MARK: - Item 11: what you hear

    @Test func hearingLabelPerSource() {
        func label(_ source: SongInfo.Source, _ suffix: String?, _ bitRate: Int? = nil, _ rate: Int? = nil, _ depth: Int? = nil) -> HearingLabel {
            HearingLabel(source: source, suffix: suffix, bitRate: bitRate, samplingRate: rate, bitDepth: depth)
        }
        // The original, lossless.
        #expect(label(.stream(.original), "flac", 2800, 96000, 24).text == "Lossless \u{00B7} FLAC 24/96")
        #expect(label(.stream(.original), "flac", 900, 44100, 16).text == "Lossless \u{00B7} FLAC 16/44.1")
        #expect(label(.stream(.original), "flac").text == "Lossless \u{00B7} FLAC")
        // A lossy original.
        #expect(label(.stream(.original), "mp3", 320).text == "MP3 320")
        // Transcoded: no Lossless hallmark.
        let opus = label(.stream(.opusMedium), "flac", 900, 44100, 16)
        #expect(opus.text == "Transcoded \u{00B7} Opus 160 kbps (from FLAC)" && opus.transcoded)
        #expect(opus.hallmark(.lossless) == .standard)
        // A file already in that format at no more than that rate is sent as it is.
        #expect(label(.stream(.mp3High), "mp3", 256).text == "MP3 256")
        #expect(label(.stream(.mp3Low), "mp3", 320).text == "Transcoded \u{00B7} MP3 128 kbps (from MP3)")
        // Fallback to the original after a failed transcode: the original, and its hallmark.
        let fallback = label(.stream(.original), "flac", 900, 44100, 16)
        #expect(!fallback.transcoded && fallback.hallmark(.lossless) == .lossless)
        // Downloaded.
        #expect(label(.onPhone(.original), "flac", 900, 96000, 24).text == "On this iPhone \u{00B7} Lossless \u{00B7} FLAC 24/96")
        #expect(label(.onPhone(.aacHigh), "flac").text == "On this iPhone \u{00B7} AAC 256 kbps (from FLAC)")
        #expect(label(.onPhone(.original), nil).text == "On this iPhone")
        // Nothing known about a stream: no line.
        #expect(label(.stream(.original), nil).text == nil)
        // A kept find's "Lossless soon" stays while the original plays.
        #expect(label(.stream(.original), "mp3", 320).hallmark(.losslessSoon) == .losslessSoon)
    }

    /// The source follows what plays: a download, the original after a failed transcode, else the current quality.
    @Test func playingSourceFollowsWhatPlays() async throws {
        let model = try await signedInModel()
        model.updatePreferences { $0.playback.wifi = .opusMedium }
        let streamed = Song(id: "st", title: "S", artist: "A", album: "B", duration: 60, suffix: "flac")
        #expect(model.playingSource(streamed) == .stream(.opusMedium))
        #expect(model.hearing(streamed).text == "Transcoded \u{00B7} Opus 160 kbps (from FLAC)")
        let local = Song(id: "dl", title: "D", artist: "A", album: "B", duration: 60, suffix: "flac")
        model.download([local], reason: .song); await model.downloads!.settled()
        #expect(await eventually { model.downloads?.localQualities["dl"] != nil })
        guard case .onPhone = model.playingSource(local) else { Issue.record("a download plays from the phone"); return }
    }
}
