import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func queryValue(_ request: URLRequest, _ name: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

/// Task 21: the Library's rows follow the owner's order and switches (Finds only when set up, Requests only with
/// Lidarr), the Recently added grid has its own switch, Songs pages by title and Favourites reads `getStarred2`.
/// Offline, the Library is Downloads (and Genres, read from the phone).
@MainActor @Suite(.serialized) final class LibraryLayoutAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "LibraryLayoutAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "LibraryLayoutAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Task 12's fixture: `/api/song` answers `[]`; `getStarred2` answers two songs and one album.
    func signedInModel(fetcher: FakeFetcher) async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getStarred2", body: Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","starred2":{"song":[{"id":"s7","title":"Seven"},\#
        {"id":"s8","title":"Eight"}],"album":[{"id":"a1","name":"One","artist":"A","songCount":1}]}}}
        """#.utf8))
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        return model
    }

    // MARK: - The brief's tests

    @Test func songsListPagesByTitle() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        await model.matchIndexSettled()   // the match index reads `/api/song` (by id) at sign-in
        _ = try await model.songsPage(0); _ = try await model.songsPage(1)
        let pages = Array(transport.inner.requests.filter { $0.url?.path.hasSuffix("/api/song") == true }.suffix(2))
        #expect(pages.map { queryValue($0, "_sort") } == ["title", "title"])
        #expect(pages.map { queryValue($0, "_start") } == ["0", "100"] && pages.map { queryValue($0, "_end") } == ["100", "200"])
        #expect(AppModel.songsPageSize == 100)
    }

    @Test func libraryRowsFollowPreferences() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(model.libraryRows == [.playlists, .artists, .albums, .songs, .genres, .favourites, .downloads],
                "Finds isn't set up and no Lidarr is connected")
        model.updatePreferences {
            _ = $0.layout.library.set(.songs, visible: false, keepingOneOf: LayoutPreferences.alwaysAvailableRows)
            $0.layout.library.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        }
        #expect(model.libraryRows == [.genres, .playlists, .artists, .albums, .favourites, .downloads])
        #expect(!model.libraryRows.contains(.requests), "no Lidarr connected")
    }

    /// Controller addition: offline the Library is Downloads plus Genres (read from the phone), in the owner's order;
    /// Downloads shows even when switched off, Genres only when switched on.
    @Test func recentlyAddedGridToggleAndOffline() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(model.showsRecentlyAddedGrid)
        model.updatePreferences { $0.layout.showsRecentlyAdded = false }
        #expect(!model.showsRecentlyAddedGrid)
        model.updatePreferences { $0.layout.showsRecentlyAdded = true; $0.downloads.offlineMode = .on }
        #expect(!model.showsRecentlyAddedGrid && model.libraryRows == [.genres, .downloads])
        model.updatePreferences {
            $0.layout.library.moveUp(.downloads); $0.layout.library.moveUp(.downloads)
            $0.layout.library.set(.downloads, visible: false, keepingOneOf: LayoutPreferences.alwaysAvailableRows)
        }
        #expect(model.libraryRows == [.downloads, .genres], "the owner's order; Downloads always shows offline")
        model.updatePreferences { $0.layout.library.set(.genres, visible: false, keepingOneOf: LayoutPreferences.alwaysAvailableRows) }
        #expect(model.libraryRows == [.downloads])
    }

    @Test func favouritesReadStarred() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let f = try await model.favourites()
        #expect(f.songs.count == 2 && f.albums.count == 1)
        #expect(f.songs.map(\.id) == ["s7", "s8"] && f.albums.map(\.id) == ["a1"])
    }

    // MARK: - Settings

    /// Settings › Home & Library: "N sections · M rows" (online counts).
    @Test func homeAndLibrarySummaryCountsRows() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        #expect(HomeAndLibraryView.summary(model) == "9 sections · 7 rows")   // round 14: the Spotify-style Home
        #expect(LibraryLayoutView.summary(model) == "7 rows")
        model.updatePreferences {
            for row in LibraryRow.allCases where row != .albums {
                $0.layout.library.set(row, visible: false, keepingOneOf: LayoutPreferences.alwaysAvailableRows)
            }
        }
        #expect(HomeAndLibraryView.summary(model) == "9 sections · 1 row")
        #expect(!OrderedVisibilityEditor<LibraryRow>.canToggle(.albums, in: model.preferences.layout.library,
                                                               keepingOneOf: LayoutPreferences.alwaysAvailableRows),
                "at least one row stays visible")
    }
}
