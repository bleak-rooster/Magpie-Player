import CarPlayUI
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Testing
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Task 22: the car's Home follows the owner's order and switches (minus Made for you), its shelves sized to fit the
/// car's list together; the car's Library is the owner's rows without Songs and Requests (spec §3, D12).
@MainActor @Suite(.serialized) final class CarPlayCustomisationTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayCustomisationTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CarPlayCustomisationTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Every album list answers 12 albums (`<type>0`…`<type>11`); playlists [p1].
    func signedInModel(fetcher: any AudioFetching) async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok)
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "type" }?.value ?? ""
            let albums = (0..<12).map { #"{"id":"\#(type)\#($0)","name":"\#(type) \#($0)","artist":"A","songCount":1}"# }
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        transport.inner.stub(pathSuffix: "/rest/getPlaylists",
                             body: subsonic(#""playlists":{"playlist":[{"id":"p1","name":"Road","songCount":3,"duration":600}]}"#))
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: fetcher)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    func album(_ id: String) -> Album { Album(id: id, name: "Album \(id)", artist: "A", songCount: 1, duration: 1) }

    // MARK: - The brief's tests

    @Test func homeShelfSizeBySectionCount() {
        #expect([1, 3, 4, 5, 6, 9].map(CarPlayRows.homeShelfSize(sectionCount:)) == [4, 4, 3, 2, 2, 2])
    }

    @Test func homeFollowsOrder() {
        let s = CarPlayRows.home([CPHomeShelf(section: .mostPlayed, items: [.album(album("a"))]),
                                  CPHomeShelf(section: .jumpBackIn, items: [.album(album("b"))])])
        #expect(s.map(\.header) == ["Most played", "Jump back in"])
    }

    @Test func emptyHomeIsEmptyState() { #expect(CarPlayRows.home([]) == CarPlayRows.state(.empty)) }

    @Test func libraryRootFollowsRowsWithoutRequestsOrSongs() {
        let titles = CarPlayRows.libraryRoot([.albums, .songs, .requests, .playlists, .genres], hasFindsTab: true)
            .flatMap(\.rows).map(\.title)
        #expect(titles == ["Albums", "Playlists", "Genres"])
    }

    @Test func findsRowOnlyWithoutFindsTab() {
        #expect(CarPlayRows.libraryRoot([.finds], hasFindsTab: false).flatMap(\.rows).map(\.title) == ["Finds"])
        #expect(CarPlayRows.libraryRoot([.finds, .albums], hasFindsTab: true).flatMap(\.rows).map(\.title) == ["Albums"])
    }

    @Test func homeRowsOpenTheirScreens() {
        let rows = CarPlayRows.home([CPHomeShelf(section: .genres, items: [.genreGroup(id: "rock", name: "Rock", albumCount: 3)]),
                                     CPHomeShelf(section: .playlists, items: [.playlist(Playlist(id: "p1", name: "Mix", songCount: 2, duration: 1))])])
            .flatMap(\.rows)
        #expect(rows.map(\.id) == ["home.genres.rock", "home.playlists.p1"])
        #expect(rows[0].action == .open(.genreGroup(id: "rock", name: "Rock")) && rows[1].action == .open(.playlist(id: "p1", title: "Mix")))
    }

    @Test func adapterDropsMadeForYouAndFollowsPrefs() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        try model.setListenBrainzToken("tok")
        model.updatePreferences { $0.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0) }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
        #expect(adapter.homeSections == [.mostPlayed, .jumpBackIn, .recentlyAdded])
        #expect(adapter.libraryRows == [.playlists, .artists, .albums, .genres, .favourites, .downloads])
    }

    @Test func adapterShelvesCutToSize() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())   // getAlbumList2 recent answers 12 albums
        let shelves = try await CarPlayLibraryAdapter(model: model).homeShelves([.jumpBackIn], size: 3)
        #expect(shelves.map(\.section) == [.jumpBackIn] && shelves[0].items.count == 3)
    }

    // MARK: - Controller additions

    /// The Library follows the owner's order and switches; Finds shows as a row only where the car has no Finds tab.
    @Test func adapterLibraryFollowsOrderAndSwitches() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences {
            $0.layout.library.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)   // Downloads first
            $0.layout.setLibraryRow(.artists, visible: false)
        }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(adapter.libraryRows == [.downloads, .playlists, .albums, .genres, .favourites])
        let rows = CarPlayRows.libraryRoot(adapter.libraryRows, hasFindsTab: false).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Downloads", "Playlists", "Albums", "Genres", "Favourites"])
        #expect(rows.map(\.action) == [.open(.downloads), .open(.playlists), .open(.albums), .open(.genres), .open(.favourites)])
    }

    /// Every section the car supports, switched on: one shelf each in the owner's order, and together they fit the car's
    /// 12-item list (D12) without "Showing x of y".
    @Test func everySupportedSectionFitsTheCar() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { for s in HomeSection.allCases { $0.layout.home.set(s, visible: true, keepingOneOf: []) } }
        let adapter = CarPlayLibraryAdapter(model: model)
        let sections = adapter.homeSections
        #expect(sections == [.jumpBackIn, .recentlyAdded, .mostPlayed, .favourites, .randomAlbums, .playlists, .genres, .downloaded])
        let size = CarPlayRows.homeShelfSize(sectionCount: sections.count)
        let shelves = try await adapter.homeShelves(sections, size: size)
        #expect(shelves.map(\.section) == [.jumpBackIn, .recentlyAdded, .mostPlayed, .favourites, .randomAlbums, .playlists],
                "empty sections (no genres, nothing downloaded) are skipped")
        #expect(shelves.allSatisfy { $0.items.count <= size })
        let home = CarPlayRows.home(shelves)
        #expect(home.flatMap(\.rows).count <= 12)
        #expect(clamp(home, maxItems: 12, maxSections: 12) == home)
    }

    /// A Downloaded tile opens the album from the phone, not the server's album screen.
    @Test func downloadedShelfOpensFromThePhone() {
        let rows = CarPlayRows.home([CPHomeShelf(section: .downloaded, items: [.album(album("d1"))]),
                                     CPHomeShelf(section: .jumpBackIn, items: [.album(album("d1"))])]).flatMap(\.rows)
        #expect(rows.map(\.id) == ["home.downloaded.d1", "home.jumpBackIn.d1"])
        #expect(rows.map(\.action) == [.open(.downloadedAlbum(id: "d1", title: "Album d1")), .open(.album(id: "d1", title: "Album d1"))])
    }

    /// Shelves are cut by the builder too, and an id a shelf repeats is shown once.
    @Test func homeShelvesCappedAndUnique() {
        let many = (0..<10).map { CPHomeShelf.Item.album(album("a\($0)")) }
        let rows = CarPlayRows.home([CPHomeShelf(section: .jumpBackIn, items: [.album(album("x"))] + [.album(album("x"))] + many)])
            .flatMap(\.rows)
        #expect(rows.map(\.id) == ["home.jumpBackIn.x", "home.jumpBackIn.a0", "home.jumpBackIn.a1", "home.jumpBackIn.a2"])
    }

    /// The new destinations have names for their template titles, and stay within the depth budget from Home and Library.
    @Test func newDestinationTitles() {
        #expect([CPDestination.genres, .favourites, .downloads, .finds].map(\.title) == ["Genres", "Favourites", "Downloads", "Finds"])
        #expect(CPDestination.genreGroup(id: "rock", name: "Rock").title == "Rock")
        #expect(CPDestination.downloadedAlbum(id: "a", title: "Continuum").title == "Continuum")
        var nav = CPNavigator()
        #expect(nav.push(.genres) && nav.push(.genreGroup(id: "rock", name: "Rock")) && !nav.push(.album(id: "a", title: "A")))
    }

    /// The car's Library while the layout changes: the template model follows the owner's switches (the controller's
    /// watch re-applies it).
    @Test func layoutChangesReachTheCar() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let adapter = CarPlayLibraryAdapter(model: model)
        let before = CarPlayRows.libraryRoot(adapter.libraryRows, hasFindsTab: true)
        model.updatePreferences { $0.layout.setLibraryRow(.genres, visible: false) }
        let after = CarPlayRows.libraryRoot(adapter.libraryRows, hasFindsTab: true)
        #expect(before.flatMap(\.rows).map(\.id).contains("library.genres"))
        #expect(!after.flatMap(\.rows).map(\.id).contains("library.genres"))
        #expect(needsRebuild(old: before, new: after), "a shape change: held until the tab is off screen")
    }
}
