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
private let home = URL(string: "http://192.168.1.2:4533")!
private let failed = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"no"}}}"#.utf8)

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

private func queryValue(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

/// Task 20: Home's sections follow the owner's order and switches; each section is fetched only when shown, from its own
/// source, and an empty one is left out. Offline, Home is the Downloaded shelf only.
@MainActor @Suite(.serialized) final class HomeLayoutAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "HomeLayoutAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "HomeLayoutAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// `getAlbumList2` types that answer with a Subsonic error.
    let failing = OSAllocatedUnfairLock(initialState: Set<String>())
    /// What `getGenres` answers.
    let genres = OSAllocatedUnfairLock(initialState: #"{"value":"Ambient","songCount":12,"albumCount":2}"#)

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The fixture: `recent` [r1], `starred` [f1] (or none), `newest`, `frequent` and `random` one album each,
    /// playlists [p1], genres Ambient (12 songs, 2 albums).
    func signedInModel(fetcher: any AudioFetching, starredEmpty: Bool = false) async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let failing = failing
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = queryValue(request, "type") ?? ""
            if failing.withLock({ $0.contains(type) }) { return MockTransport.Response(status: 200, body: failed) }
            let ids: [String] = switch type {
            case "recent": ["r1"]
            case "starred": starredEmpty ? [] : ["f1"]
            case "newest": ["n1"]
            case "frequent": ["m1"]
            case "random": ["x1"]
            default: []
            }
            let albums = ids.map { #"{"id":"\#($0)","name":"\#($0)","artist":"A","songCount":1}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums)]}"#))
        }
        transport.inner.stub(pathSuffix: "/rest/getPlaylists",
                             body: subsonic(#""playlists":{"playlist":[{"id":"p1","name":"Road","songCount":3,"duration":600}]}"#))
        let genres = genres
        transport.inner.stub(pathSuffix: "/rest/getGenres") { _ in
            MockTransport.Response(status: 200, body: subsonic(#""genres":{"genre":[\#(genres.withLock { $0 })]}"#))
        }
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    func album(_ id: String) -> Album { Album(id: id, name: id, artist: "A", songCount: 1, duration: 0) }
    func song(_ id: String) -> Song { PlayerTests.song(id) }

    // MARK: - The brief's tests

    @Test func onlyRequestedSectionsAreFetched() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let before = transport.inner.requests.count
        let shelves = try await model.homeShelves(for: [.favourites, .jumpBackIn])
        let sent = transport.inner.requests.dropFirst(before)
        #expect(Set(sent.compactMap { queryValue($0, "type") }) == ["starred", "recent"])
        #expect(!sent.contains { $0.url!.path.hasSuffix("getPlaylists") || $0.url!.path.hasSuffix("getGenres") })
        #expect(shelves.map(\.section) == [.favourites, .jumpBackIn])
        #expect(shelves[0].items == [.album(album("f1"))])
        #expect(shelves[1].items == [.album(album("r1"))])
    }

    /// Build 8 launch crash (Index out of range in `homeRead`): Home's load task is cancelled and restarted at
    /// launch; a cancelled read must neither trap nor mislabel shelves. It reports cancellation instead.
    @Test(arguments: 0..<25) func cancelledReadNeverTraps(_ round: Int) async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let all = HomeSection.allCases
        let task = Task { try await model.homeRead(for: all) }
        if round % 2 == 0 { await Task.yield() }
        task.cancel()
        switch await task.result {
        case .success(let read):
            // Finished before the cancel landed: every shelf still sits under its own section.
            for shelf in read.shelves { #expect(all.contains(shelf.section)) }
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    /// The build 8 trap, deterministically: results with gaps (and a short array) never index out of range, and every
    /// shelf stays under its own section; the gaps count as not read.
    @Test func gapsInResultsNeverShiftOrTrap() throws {
        let wanted: [HomeSection] = [.jumpBackIn, .recentlyAdded, .mostPlayed, .downloaded]
        let items: [HomeShelf.Item] = [.album(album("x"))]
        let read = try AppModel.assemble(wanted: wanted, results: [nil, .success(items), nil])
        #expect(read.shelves.map(\.section) == [.recentlyAdded])
        // P5: a gap was cut short, not failed; it is read again and never says "Couldn't load".
        #expect(read.cancelled == [.jumpBackIn, .mostPlayed, .downloaded] && read.failed.isEmpty)
        // Every server section missing: reported as a failed read, not a trap.
        #expect(throws: CancellationError.self) { try AppModel.assemble(wanted: wanted, results: []) }
    }

    @Test func emptySectionsSkipped() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher(), starredEmpty: true)
        #expect(try await model.homeShelves(for: [.favourites, .jumpBackIn]).map(\.section) == [.jumpBackIn])
    }

    @Test func playlistsAndGenresShelves() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let shelves = try await model.homeShelves(for: [.playlists, .genres])
        #expect(shelves.map(\.section) == [.playlists, .genres])
        guard case .playlist(let p) = shelves[0].items.first, case .genreGroup(let g) = shelves[1].items.first else {
            Issue.record("kinds"); return
        }
        #expect(p.id == "p1" && g.group.id == "electronic")
    }

    @Test func homeSectionsFollowPreferences() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(model.homeSections == [.jumpBackIn, .recentlyAdded, .mostPlayed], "Made for you only with a token")
        model.updatePreferences {
            $0.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
            $0.layout.home.set(.randomAlbums, visible: true, keepingOneOf: [])
        }
        #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded, .randomAlbums])
    }

    @Test func offlineHomeIsDownloadedOnly() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .album("a1")); await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(model.homeSections == [.downloaded])
        let shelves = try await model.homeShelves(for: model.homeSections)
        #expect(shelves.map(\.section) == [.downloaded] && shelves[0].items.count == 1)
        guard case .downloadedAlbum = shelves[0].items.first else { Issue.record("albums only"); return }
    }

    // MARK: - Controller additions

    /// Every section the editor offers, in the default order, each from its own source (the starred variant included).
    @Test func everySectionHasItsSource() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.download([song("s1")], reason: .album("a1")); await model.downloads!.settled()
        let shelves = try await model.homeShelves(for: HomeSection.allCases)
        #expect(shelves.map(\.section) == [.jumpBackIn, .recentlyAdded, .mostPlayed, .favourites, .randomAlbums,
                                           .playlists, .genres, .downloaded], "Made for you has its own shelf")
        #expect(shelves.map(\.items.count) == [1, 1, 1, 1, 1, 1, 1, 1])
        #expect(shelves[4].items == [.album(album("x1"))])
    }

    /// Only when every server section fails does Home fail; otherwise the ones that answered show.
    @Test func throwsOnlyWhenEveryServerSectionFails() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        failing.withLock { $0 = ["recent"] }
        #expect(try await model.homeShelves(for: [.jumpBackIn, .recentlyAdded]).map(\.section) == [.recentlyAdded])
        failing.withLock { $0 = ["recent", "newest"] }
        await #expect(throws: (any Error).self) { try await model.homeShelves(for: [.jumpBackIn, .recentlyAdded]) }
        #expect(try await model.homeShelves(for: []).isEmpty, "no server section asked, nothing failed")
    }

    /// Genres shows the groups with the most albums first, at most a shelf of them.
    @Test func genresShelfByAlbumCount() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        genres.withLock {
            $0 = #"{"value":"Ambient","songCount":12,"albumCount":2},{"value":"Indie Rock","songCount":30,"albumCount":5},"#
                + #"{"value":"Jazz","songCount":4,"albumCount":1}"#
        }
        let shelf = try #require(try await model.homeShelves(for: [.genres]).first)
        #expect(shelf.items.compactMap { if case .genreGroup(let g) = $0 { g.group.id } else { nil } } == ["rock", "electronic", "jazz"])
    }

    /// The editor's switches: one that would leave none of `keepingOneOf` showing is disabled; Reset restores the table.
    @Test func editorRules() {
        var list = LayoutPreferences.defaultValue.library
        for row in LibraryRow.allCases where row != .songs { list.set(row, visible: false, keepingOneOf: []) }
        let keep = LayoutPreferences.alwaysAvailableRows
        #expect(!OrderedVisibilityEditor<LibraryRow>.canToggle(.songs, in: list, keepingOneOf: keep))
        #expect(OrderedVisibilityEditor<LibraryRow>.canToggle(.albums, in: list, keepingOneOf: keep), "showing is always allowed")
        #expect(OrderedVisibilityEditor<LibraryRow>.canToggle(.requests, in: list, keepingOneOf: keep))
        let home = LayoutPreferences.defaultValue.home
        #expect(HomeSection.allCases.allSatisfy { OrderedVisibilityEditor<HomeSection>.canToggle($0, in: home, keepingOneOf: []) })
        #expect(HomeLayoutView.footer(.madeForYou) == "Shows when a ListenBrainz token is saved")
        #expect(HomeLayoutView.footer(.downloaded) != nil && HomeLayoutView.footer(.jumpBackIn) == nil)
    }

    /// Settings › Home & Library: the count of Home sections that show.
    @Test func homeAndLibrarySummary() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(HomeAndLibraryView.homeSummary(model) == "3 sections")
        model.updatePreferences { $0.layout.home.set(.jumpBackIn, visible: false, keepingOneOf: []) }
        model.updatePreferences { for s in [HomeSection.recentlyAdded, .mostPlayed] { $0.layout.home.set(s, visible: false, keepingOneOf: []) } }
        model.updatePreferences { $0.layout.home.set(.genres, visible: true, keepingOneOf: []) }
        #expect(HomeAndLibraryView.homeSummary(model) == "1 section")
    }

    // MARK: - Task 21: the parked Task 20 minors

    func key(_ sections: [HomeSection], offline: Bool = false, onPhone: Int? = nil,
             genres: GenrePreferences? = nil) -> HomeLoad.Key {
        HomeLoad.Key(sections: sections, offline: offline, onPhone: onPhone, genres: genres)
    }

    func shelf(_ section: HomeSection) -> HomeShelf { HomeShelf(section: section, items: [.album(album(section.rawValue))]) }

    /// A section that fails during an incremental read isn't marked read: the next key change reads it again (with
    /// the new section), and it shows "Couldn't load" until then. A reorder reads nothing; pull to refresh reads all.
    @Test func incrementalLoadRetriesFailedSections() {
        var load = HomeLoad()
        let first = key([.jumpBackIn, .madeForYou, .recentlyAdded])
        let read1 = load.read(for: first, fresh: false)
        #expect(read1.sections == [.jumpBackIn, .recentlyAdded], "Made for you has its own shelf")
        load.record(read1, for: first, shelves: [shelf(.jumpBackIn)], failed: [.recentlyAdded])
        #expect(load.failed == [.recentlyAdded] && Set(load.found.keys) == [.jumpBackIn])
        #expect(load.showsFailure(.recentlyAdded) && !load.showsFailure(.jumpBackIn))

        let more = key([.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed])
        let read2 = load.read(for: more, fresh: false)
        #expect(read2.sections == [.recentlyAdded, .mostPlayed], "the failed section is read again, with the new one")
        load.record(read2, for: more, shelves: [shelf(.recentlyAdded), shelf(.mostPlayed)], failed: [])
        #expect(load.failed.isEmpty && Set(load.found.keys) == [.jumpBackIn, .recentlyAdded, .mostPlayed])

        let reordered = key([.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
        #expect(load.read(for: reordered, fresh: false).sections.isEmpty, "a reorder reads nothing")
        #expect(load.read(for: reordered, fresh: true).sections == [.mostPlayed, .jumpBackIn, .recentlyAdded])

        // A failed re-read keeps the shelf already on screen (no "Couldn't load" line over it), still not marked read.
        let fresh = load.read(for: reordered, fresh: true)
        load.record(fresh, for: reordered, shelves: [shelf(.jumpBackIn), shelf(.recentlyAdded)], failed: [.mostPlayed])
        #expect(load.found[.mostPlayed] != nil && !load.showsFailure(.mostPlayed))
        #expect(load.read(for: key([.mostPlayed, .jumpBackIn]), fresh: false).sections == [.mostPlayed])
    }

    /// Downloaded is read again when songs land; Genres when the genre preferences change (both only while they
    /// show); everything when going offline or back online.
    @Test func incrementalLoadFollowsWhatSectionsDependOn() {
        var genres = GenrePreferences.defaultValue
        var load = HomeLoad()
        let first = key([.genres, .downloaded], onPhone: 1, genres: genres)
        load.record(load.read(for: first, fresh: false), for: first, shelves: [shelf(.genres), shelf(.downloaded)], failed: [])
        #expect(load.read(for: first, fresh: false).sections.isEmpty)
        genres.hidden = ["rock"]
        #expect(load.read(for: key([.genres, .downloaded], onPhone: 1, genres: genres), fresh: false).sections == [.genres])
        #expect(load.read(for: key([.genres, .downloaded], onPhone: 2, genres: GenrePreferences.defaultValue),
                          fresh: false).sections == [.downloaded])
        let offline = key([.downloaded], offline: true, onPhone: 1)
        let read = load.read(for: offline, fresh: false)
        #expect(read.sections == [.downloaded] && read.fresh)
        load.record(read, for: offline, shelves: [], failed: [])
        #expect(load.found.isEmpty, "going offline drops the online shelves; an empty Downloaded is left out")
    }

    /// The key holds the songs on the phone only while Downloaded shows, and the genre preferences only while Genres
    /// shows, so a change to either reads nothing when its section is off.
    @Test func loadKeyHoldsOnlyWhatShownSectionsNeed() {
        var genres = GenrePreferences.defaultValue
        genres.hidden = ["jazz"]
        #expect(HomeLoad.Key.make(sections: [.jumpBackIn], offline: false, onPhone: 3, genres: genres)
                == key([.jumpBackIn]))
        #expect(HomeLoad.Key.make(sections: [.genres, .downloaded], offline: false, onPhone: 3, genres: genres)
                == key([.genres, .downloaded], onPhone: 3, genres: genres))
    }

    /// `homeRead(for:)` names the sections that couldn't be read, for the "Couldn't load" line.
    @Test func homeReadReportsFailedSections() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        failing.withLock { $0 = ["newest"] }
        let read = try await model.homeRead(for: [.jumpBackIn, .recentlyAdded])
        #expect(read.shelves.map(\.section) == [.jumpBackIn] && read.failed == [.recentlyAdded])
        #expect(HomeCopy.couldNotLoad(.recentlyAdded) == "Couldn't load Recently added. Pull to refresh.")
    }

    /// Shelf tiles are identified by what they are (album, playlist, group), not by position.
    @Test func shelfItemIdsAreStable() throws {
        let section = try #require(GenreGroups.grouped([Genre(name: "Rock", songCount: 1, albumCount: 1)],
                                                       preferences: .defaultValue).first)
        let playlist = Playlist(id: "p1", name: "Road", songCount: 1, duration: 0)
        let items: [HomeShelf.Item] = [.album(album("a1")), .downloadedAlbum(album("a2")), .playlist(playlist),
                                       .genreGroup(section)]
        #expect(items.map(\.id) == ["album-a1", "album-a2", "playlist-p1", "group-rock"])
    }

    /// D15: a switch that can't turn off says why; a Move action says what it did.
    @Test func editorAccessibilityCopy() {
        var list = LayoutPreferences.defaultValue.library
        for row in LibraryRow.allCases where row != .songs { list.set(row, visible: false, keepingOneOf: []) }
        let keep = LayoutPreferences.alwaysAvailableRows
        #expect(OrderedVisibilityEditor<LibraryRow>.hint(.songs, in: list, keepingOneOf: keep) == "At least one must stay on")
        #expect(OrderedVisibilityEditor<LibraryRow>.hint(.albums, in: list, keepingOneOf: keep) == nil)
        #expect(OrderedVisibilityEditor<LibraryRow>.movedUp == "Moved up" && OrderedVisibilityEditor<LibraryRow>.movedDown == "Moved down")
    }
}
