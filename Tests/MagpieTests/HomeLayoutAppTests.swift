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
        #expect(HomeAndLibraryView.summary(model) == "3 sections")
        model.updatePreferences { $0.layout.home.set(.jumpBackIn, visible: false, keepingOneOf: []) }
        model.updatePreferences { for s in [HomeSection.recentlyAdded, .mostPlayed] { $0.layout.home.set(s, visible: false, keepingOneOf: []) } }
        model.updatePreferences { $0.layout.home.set(.genres, visible: true, keepingOneOf: []) }
        #expect(HomeAndLibraryView.summary(model) == "1 section")
    }
}
