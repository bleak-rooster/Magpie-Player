import CarPlayUI
import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Observation
import Playback
import Search
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

/// Task 22: the car's Home follows the owner's order and switches (Made for you with a ListenBrainz token, as on the
/// phone), its shelves sized to fit the car's list together; the car's Library is the owner's rows without Songs and
/// Requests (spec §3, D12). Task 23: Genres, Favourites, Downloads, Made for you, offline; Y2: Favourite in Now Playing instead of the sleep timer.
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

    /// Every album list answers 12 albums (`<type>0`…`<type>11`); playlists [p1]; genres Indie Rock and Alt Rock (both
    /// Rock), 300 songs each (`ir0`…, `ar0`…). The paths in `failing` answer 500.
    func signedInModel(fetcher: any AudioFetching, failing: [String] = []) async throws -> AppModel {
        for path in failing { transport.inner.stub(pathSuffix: path, status: 500) }
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
        transport.inner.stub(pathSuffix: "/rest/getGenres", body: subsonic(#"""
        "genres":{"genre":[{"value":"Indie Rock","songCount":300,"albumCount":1},{"value":"Alt Rock","songCount":300,"albumCount":2}]}
        """#))
        transport.inner.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let genre = value("genre") ?? ""
            let prefix = genre == "Indie Rock" ? "ir" : genre == "Alt Rock" ? "ar" : ""
            let offset = Int(value("offset") ?? "0") ?? 0, count = Int(value("count") ?? "0") ?? 0
            let ids = prefix.isEmpty ? [] : (0..<300).map { "\(prefix)\($0)" }.dropFirst(offset).prefix(count)
            let songs = ids.map { #"{"id":"\#($0)","title":"\#($0)","genre":"\#(genre)"}"# }.joined(separator: ",")
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":{"song":[\#(songs)]}"#))
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

    func album(_ id: String) -> Album { Album(id: id, name: "Album \(id)", artist: "A", songCount: 1, duration: 1) }

    // MARK: - The brief's tests

    /// One place sizes the shelves (T23): from the shelves that have tiles, at most four each, the earlier shelves first,
    /// never more than the car's list holds.
    @Test func homeShelfSizesShareTheList() {
        #expect(CarPlayRows.homeShelfSizes([12], maxItems: 12) == [4])
        #expect(CarPlayRows.homeShelfSizes([12, 12, 12], maxItems: 12) == [4, 4, 4])
        #expect(CarPlayRows.homeShelfSizes([12, 12, 12, 12], maxItems: 12) == [3, 3, 3, 3])
        #expect(CarPlayRows.homeShelfSizes([12, 12, 12, 12, 12], maxItems: 12) == [3, 3, 2, 2, 2])
        #expect(CarPlayRows.homeShelfSizes(Array(repeating: 12, count: 9), maxItems: 12) == [2, 2, 2, 1, 1, 1, 1, 1, 1])
        #expect(CarPlayRows.homeShelfSizes([1, 12, 12], maxItems: 12) == [1, 4, 4], "a short shelf leaves its share unused")
        #expect(CarPlayRows.homeShelfSizes([0, 3], maxItems: 12) == [0, 3])
        #expect(CarPlayRows.homeShelfSizes(Array(repeating: 12, count: 14), maxItems: 12).filter { $0 > 0 }.count == 12)
        #expect(CarPlayRows.homeShelfSizes([12, 12], maxItems: 0) == [0, 0])
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

    /// Controller ruling (T23): the car shows Made for you when a ListenBrainz token is saved, as the phone does.
    @Test func adapterShowsMadeForYouWithTokenAndFollowsPrefs() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(adapter.homeSections == [.jumpBackIn, .recentlyAdded, .mostPlayed], "no token: no Made for you")
        try model.setListenBrainzToken("tok")
        model.updatePreferences { $0.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0) }
        #expect(model.homeSections == [.mostPlayed, .jumpBackIn, .madeForYou, .recentlyAdded])
        #expect(adapter.homeSections == model.homeSections)
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

    /// Every section switched on and every one with tiles, Made for you included (T22 parked minor 1): one shelf each in
    /// the owner's order, sized together in one place so they fit the car's 12-item list (D12) without "Showing x of y";
    /// a car with fewer sections keeps the first shelves.
    @Test func everySectionWithTilesFitsTheCar() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        try model.setListenBrainzToken("tok")
        model.madeForYouShelf = [MadeForYou.Playlist(id: MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11")!, title: "Weekly Exploration")]
        model.download([Song(id: "s1", title: "T1", artist: "A", album: "B", albumId: "al-1", track: 1, duration: 200)],
                       reason: .album("al-1"), coverArtId: "al-1")
        await model.downloads!.settled()
        model.updatePreferences { for s in HomeSection.allCases { $0.layout.home.set(s, visible: true, keepingOneOf: []) } }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(adapter.homeSections == [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites, .randomAlbums,
                                         .playlists, .genres, .downloaded])
        let shelves = try await adapter.homeShelves(adapter.homeSections, size: CarPlayRows.homeShelfMaxSize)
        #expect(shelves.map(\.section) == adapter.homeSections, "every section has tiles")
        #expect(shelves.allSatisfy { $0.items.count <= CarPlayRows.homeShelfMaxSize })
        let home = CarPlayRows.home(shelves, maxItems: 12, maxSections: 12)
        #expect(home.map(\.header) == adapter.homeSections.map(\.title))
        #expect(home.map(\.rows.count) == [2, 1, 2, 2, 1, 1, 1, 1, 1], "12 tiles, earlier shelves first")
        #expect(clamp(home, maxItems: 12, maxSections: 12) == home)
        #expect(home[1].rows.map(\.action) == [.open(.madeForYou(id: "5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11",
                                                                 title: "Weekly Exploration"))])
        let narrow = CarPlayRows.home(shelves, maxItems: 12, maxSections: 4)
        #expect(narrow.map(\.header) == ["Jump back in", "Made for you", "Recently added", "Most played"])
        #expect(narrow.map(\.rows.count) == [4, 1, 4, 3] && clamp(narrow, maxItems: 12, maxSections: 4) == narrow)
    }

    /// One failing Home section doesn't blank the car's Home: the others still show.
    @Test func oneFailingSectionKeepsTheRest() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher(), failing: ["/rest/getPlaylists"])
        model.updatePreferences { $0.layout.home.set(.playlists, visible: true, keepingOneOf: []) }
        let adapter = CarPlayLibraryAdapter(model: model)
        let shelves = try await adapter.homeShelves(adapter.homeSections, size: CarPlayRows.homeShelfMaxSize)
        #expect(shelves.map(\.section) == [.jumpBackIn, .recentlyAdded, .mostPlayed])
        #expect(CarPlayRows.home(shelves).map(\.header) == ["Jump back in", "Recently added", "Most played"])
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

    // MARK: - Task 23: the brief's tests

    @Test func genreGroupRows() {
        let s = CarPlayRows.genreGroup(id: "rock", subgenres: [Genre(name: "Alt Rock", songCount: 20, albumCount: 2),
                                                                Genre(name: "Indie Rock", songCount: 10, albumCount: 1)])
        let rows = s.flatMap(\.rows)
        #expect(rows.map(\.title) == ["Shuffle", "Alt Rock", "Indie Rock"])
        #expect(rows[0].action == .play(.genreGroup(id: "rock", shuffled: true)))
        #expect(rows[2].action == .play(.genre(name: "Indie Rock", shuffled: false)))
        #expect(rows.allSatisfy { if case .open = $0.action { false } else { true } }, "leaves never push")
    }

    @Test func genresListOpensGroups() {
        let rows = CarPlayRows.genres([(id: "rock", name: "Rock", albumCount: 3)]).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Rock"] && rows[0].detail == "3 albums")
        #expect(rows[0].action == .open(.genreGroup(id: "rock", name: "Rock")))
    }

    @Test func genreDepthBudget() {
        var nav = CPNavigator()
        #expect(nav.push(.genres) && nav.push(.genreGroup(id: "rock", name: "Rock")))
        #expect(nav.depth == CPNavigator.maxBrowseDepth)
        let third = nav.push(.genres)   // #expect can't call a mutating method itself
        #expect(!third, "only two pushes below the tab")
    }

    @Test func downloadsRowsOpenDownloadedAlbum() {
        let rows = CarPlayRows.downloads(albums: [Album(id: "a1", name: "Continuum", artist: "Aurora Field", songCount: 6, duration: 1)],
                                         playlists: [Playlist(id: "p1", name: "Mix", songCount: 2, duration: 1)]).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Continuum", "Mix"])
        // Fix round 1 (b): a downloaded playlist opens from the phone (only its songs there), not the server's playlist.
        #expect(rows[0].action == .open(.downloadedAlbum(id: "a1", title: "Continuum"))
                && rows[1].action == .open(.downloadedPlaylist(id: "p1", title: "Mix")))
    }

    @Test func favouritesRowsPlay() {
        let song = Song(id: "s1", title: "One", artist: "A", album: "B", duration: 200)
        let rows = CarPlayRows.favourites(Starred(songs: [song], albums: []), playingId: "s1").flatMap(\.rows)
        #expect(rows.map(\.title) == ["One"] && rows[0].playing && rows[0].action == .play(.songs([song], startAt: 0)))
    }

    /// The brief has `[.downloads]`; T22's controller ruling (one offline rule for the phone and the car) keeps Genres,
    /// read from the phone, when it is switched on, as the phone does.
    @Test func offlineCarLibraryIsDownloadsOnly() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(adapter.isOffline && adapter.libraryRows == [.genres, .downloads] && adapter.homeSections == [.downloaded])
        model.updatePreferences { $0.layout.setLibraryRow(.genres, visible: false) }
        #expect(adapter.libraryRows == [.downloads])
    }

    @Test func carSongsForGenreRequests() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(try await adapter.songs(for: .genre(name: "Indie Rock", shuffled: false)).prefix(2).map(\.id) == ["ir0", "ir1"])
        #expect(try await adapter.songs(for: .genreGroup(id: "rock", shuffled: true)).count == 500)
        // Fix round 1 (6): the adapter doesn't shuffle (the controller's `start` does): one genre at a time in turn.
        #expect(try await adapter.songs(for: .genreGroup(id: "rock", shuffled: true)).prefix(4).map(\.id) == ["ir0", "ar0", "ir1", "ar1"])
    }

    // MARK: - Task 23: controller additions

    /// Y2 (2b): the sleep timer left the car for Favourite; what the car says when a favourite doesn't go through.
    @Test func carFavouriteMessages() {
        #expect(CarPlayRows.favouriteMessage(.failed(adding: true)) == "Couldn't add to your favourites")
        #expect(CarPlayRows.favouriteMessage(.failed(adding: false)) == "Couldn't remove from your favourites")
        #expect(CarPlayRows.favouriteMessage(.offline) == "You're offline")
        #expect(CarPlayRows.favouriteMessage(.done) == nil)
    }

    /// Genres in the car (D41): the list is the phone's groups; a group page is Shuffle, then its genres in server order.
    @Test func adapterGenresAreThePhones() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let adapter = CarPlayLibraryAdapter(model: model)
        let groups = try await adapter.genreGroups()
        #expect(groups.map(\.id) == ["rock"] && groups.map(\.name) == ["Rock"] && groups.map(\.albumCount) == [3])
        #expect(try await adapter.genreSubgenres("rock").map(\.name) == ["Indie Rock", "Alt Rock"])
        #expect(try await adapter.genreSubgenres("jazz").isEmpty)
        let genre = try await adapter.songs(for: .genre(name: "Indie Rock", shuffled: true))
        #expect(genre.count == 300 && genre.prefix(2).map(\.id) == ["ir0", "ir1"], "start shuffles, not the adapter")
    }

    /// Downloads in the car: Albums, Artists and Playlists on the phone; an album or an artist opens from the phone, a
    /// playlist from the server online and from the phone offline.
    @Test func downloadsBrowseWhatsOnThePhone() {
        let album = Album(id: "a1", name: "Continuum", artist: "Aurora Field", songCount: 1, duration: 1)
        let sections = CarPlayRows.downloads(albums: [album], artists: [Artist(id: "r1", name: "Aurora Field", albumCount: 1)],
                                             playlists: [Playlist(id: "p1", name: "Mix", songCount: 2, duration: 1)])
        #expect(sections.map(\.header) == ["Albums", "Artists", "Playlists"])
        #expect(sections[1].rows.map(\.detail) == ["1 album"])
        #expect(sections[1].rows.map(\.action) == [.open(.downloadedArtist(id: "r1", name: "Aurora Field"))])
        #expect(CarPlayRows.downloads(albums: [], playlists: []) == CarPlayRows.state(.empty))
    }

    /// A downloaded album or artist plays only what's on the phone: no server album is asked for.
    @Test func downloadedLeavesPlayTheirSongs() {
        let songs = [Song(id: "s1", title: "One", artist: "A", album: "B", duration: 200),
                     Song(id: "s2", title: "Two", artist: "A", album: "B", duration: 200)]
        let album = Album(id: "a1", name: "B", artist: "A", songCount: 2, duration: 400, songs: songs)
        let rows = CarPlayRows.downloadedAlbum(album, playingId: "s2").flatMap(\.rows)
        #expect(rows.map(\.title) == ["Shuffle", "One", "Two"] && rows[2].playing)
        #expect(rows.map(\.action) == [.play(.shuffle(songs)), .play(.songs(songs, startAt: 0)), .play(.songs(songs, startAt: 1))])
        let other = Album(id: "a2", name: "C", artist: "A", songCount: 1, duration: 1, songs: [songs[0]])
        let artist = CarPlayRows.downloadedArtist(Artist(id: "r", name: "A", albumCount: 2), albums: [album, other]).flatMap(\.rows)
        #expect(artist.map(\.title) == ["Shuffle", "B", "C"])
        #expect(artist.map(\.action) == [.play(.shuffle(songs + [songs[0]])), .play(.songs(songs, startAt: 0)),
                                         .play(.songs([songs[0]], startAt: 0))])
        #expect((rows + artist).allSatisfy { if case .open = $0.action { false } else { true } }, "depth 3: leaves")
        #expect(CarPlayRows.downloadedAlbum(Album(id: "x", name: "X", artist: "A", songCount: 0, duration: 0), playingId: nil)
                == CarPlayRows.state(.empty))
    }

    /// Favourites: starred songs (they play) and starred albums (they open).
    @Test func favouritesSongsThenAlbums() {
        let song = Song(id: "s1", title: "One", artist: "A", album: "B", duration: 200)
        let sections = CarPlayRows.favourites(Starred(songs: [song], albums: [album("a1")]), playingId: nil)
        #expect(sections.map(\.header) == ["Songs", "Albums"])
        #expect(sections[1].rows.map(\.action) == [.open(.album(id: "a1", title: "Album a1"))])
        #expect(CarPlayRows.favourites(Starred(), playingId: nil) == CarPlayRows.state(.empty))
    }

    /// Made for you in the car: library songs play (among the playlist's library songs), songs not in the library offer
    /// Try, as in the car's search; nothing pushes.
    @Test func madeForYouRows() {
        let one = Song(id: "s1", title: "One", artist: "A", album: "B", duration: 200)
        let two = Song(id: "s2", title: "Two", artist: "A", album: "B", duration: 200)
        let outside = ExternalRecording(title: "Elsewhere", artist: "Someone", source: .listenBrainz)
        let rows = CarPlayRows.madeForYou([.song(one), .notYet(outside), .song(two)], offer: .next, playingId: "s2").flatMap(\.rows)
        #expect(rows.map(\.title) == ["One", "Elsewhere", "Two"] && rows[2].playing)
        #expect(rows.map(\.action) == [.play(.songs([one, two], startAt: 0)), .tryNext(outside), .play(.songs([one, two], startAt: 1))])
        #expect(Set(rows.map(\.id)).count == 3 && rows[1].statusSymbol == RowState.notYet.statusSymbol)
        let noTry = CarPlayRows.madeForYou([.notYet(outside)], offer: .unavailable, playingId: nil).flatMap(\.rows)
        #expect(noTry.map(\.action) == [RowAction.none])
        #expect(CarPlayRows.madeForYou([], offer: .next, playingId: nil) == CarPlayRows.state(.empty))
        #expect(CPDestination.madeForYou(id: "x", title: "Daily Jams").title == "Daily Jams")
    }

    /// The layout watch's decision (T22 parked minor 5): a Home change or going offline reloads Home; a Library change
    /// redraws the Library tab; nothing else does anything.
    @Test func layoutWatchDecision() {
        let base = CPLayout(home: [.jumpBackIn], library: [.albums, .downloads], offline: false)
        var home = base; home.home = [.mostPlayed]
        var library = base; library.library = [.downloads]
        var offline = base; offline.offline = true
        #expect(CPLayoutChange(from: base, to: base) == CPLayoutChange(reloadsHome: false, redrawsLibrary: false))
        #expect(CPLayoutChange(from: base, to: home) == CPLayoutChange(reloadsHome: true, redrawsLibrary: false))
        #expect(CPLayoutChange(from: base, to: library) == CPLayoutChange(reloadsHome: false, redrawsLibrary: true))
        #expect(CPLayoutChange(from: base, to: offline) == CPLayoutChange(reloadsHome: true, redrawsLibrary: false))
    }

    /// What's on the phone, through the adapter: the snapshot's albums, artists and playlists, and an album by id (local
    /// ids included).
    @Test func adapterDownloadsReadThePhone() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let songs = [Song(id: "s1", title: "T1", artist: "A", artistId: "ar-1", album: "B", albumId: "al-1", track: 1, duration: 200),
                     Song(id: "s2", title: "T2", artist: "A", artistId: "ar-1", album: "B", albumId: "al-1", track: 2, duration: 200)]
        model.download(songs, reason: .album("al-1"), coverArtId: "al-1")
        await model.downloads!.settled()
        let adapter = CarPlayLibraryAdapter(model: model)
        #expect(await adapter.downloadedAlbums().map(\.id) == ["al-1"])
        #expect(await adapter.downloadedArtists().map(\.id) == ["ar-1"])
        #expect(await adapter.downloadedPlaylists().isEmpty)
        #expect(await adapter.downloadedAlbum(id: "al-1")?.songs?.map(\.id) == ["s1", "s2"])
        #expect(await adapter.downloadedAlbum(id: "nope") == nil)
        let artist = await adapter.downloadedArtist(id: "ar-1")
        #expect(artist?.0.name == "A" && artist?.1.map(\.id) == ["al-1"])
        // A playlist as downloaded: only its songs on the phone, online too (fix round 1 b).
        model.download([songs[0]], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Road", coverArtId: nil, songIds: ["s1", "s9"], savedAt: .now))
        await model.downloads!.settled()
        let playlist = await adapter.downloadedPlaylist(id: "p1")
        #expect(playlist?.0.name == "Road" && playlist?.1.map(\.id) == ["s1"])
        #expect(await adapter.downloadedPlaylist(id: "nope") == nil)
    }

    /// Fix round 1 (2): any failed read while offline says so, with its symbol, never "out of reach" or Local Network.
    @Test func offlineFailuresSayOffline() {
        #expect(CarPlayState.unavailable(outOfReach: true, localNetwork: .denied, offline: true) == .offline)
        #expect(CarPlayState.unavailable(outOfReach: false, localNetwork: .pending, offline: true) == .offline)
        #expect(CarPlayState.unavailable(outOfReach: true, localNetwork: .denied) == .localNetworkDenied)
        let row = CarPlayRows.state(.offline).flatMap(\.rows).first
        #expect(row?.title == "You're offline" && row?.statusSymbol == "wifi.slash" && row?.action == RowAction.none)
    }

    /// Fix round 1 (4): Made for you is read once per token, so an empty answer isn't asked for on every Home reload;
    /// a new token asks again.
    @Test func madeForYouReadOncePerToken() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        try model.setListenBrainzToken("tok")
        let adapter = CarPlayLibraryAdapter(model: model)
        func reads() -> Int { transport.inner.requests.filter { $0.url?.host == "api.listenbrainz.org" && $0.url?.path.hasSuffix("validate-token") == true }.count }
        let before = reads()
        _ = try await adapter.homeShelves(adapter.homeSections, size: CarPlayRows.homeShelfMaxSize)
        let once = reads()
        _ = try await adapter.homeShelves(adapter.homeSections, size: CarPlayRows.homeShelfMaxSize)
        #expect(once == before + 1 && reads() == once, "an empty answer isn't asked for again")
        try model.setListenBrainzToken("other")
        _ = try await adapter.homeShelves(adapter.homeSections, size: CarPlayRows.homeShelfMaxSize)
        #expect(reads() > once, "a new token is read")
    }

    /// Fix round 1 (a): `-MagpieNetwork wifi` pins the network only together with `-MagpieUITesting YES`.
    @Test func networkPinOnlyForUITests() {
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieUITesting", "YES", "-MagpieNetwork", "wifi"]) == .wifi)
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieNetwork", "wifi"]) == nil, "never without the UI-test flag")
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieUITesting", "NO", "-MagpieNetwork", "wifi"]) == nil)
        // P1: the Downloading now UI test pins mobile data, so its download waits for Wi-Fi.
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieUITesting", "YES", "-MagpieNetwork", "cellular"])
            == NetworkStatus(isConnected: true, isCellular: true, isConstrained: false))
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieNetwork", "cellular"]) == nil)
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieUITesting", "YES", "-MagpieNetwork", "5g"]) == nil)
        #expect(UITestNetworkPin.status(arguments: ["Magpie", "-MagpieUITesting", "YES"]) == nil)
        #expect(UITestNetworkPin.status(arguments: ProcessInfo.processInfo.arguments) == nil, "this test host isn't a UI test")
    }

    /// Late changes reach the car (T22 review): the reads the controller follows are observable.
    @Test func carReadsAreObservable() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let adapter = CarPlayLibraryAdapter(model: model)
        func changes<T>(_ read: @escaping @MainActor () -> T, when change: () throws -> Void) rethrows -> Bool {
            let fired = Flag()
            withObservationTracking { _ = read() } onChange: { fired.set() }
            try change()
            return fired.isSet
        }
        let finds = changes({ adapter.libraryRows }) {
            model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: "n",
                                          library: NavidromeLibrary(id: 2, name: "Samples", path: "/music/samples"))
        }
        let token = try changes({ adapter.homeSections }) { try model.setListenBrainzToken("tok") }
        let offline = changes({ adapter.isOffline }) { model.updatePreferences { prefs in prefs.downloads.offlineMode = .on } }
        let favourite = changes({ adapter.isFavourite(songId: "s1") }) { model.noteFavourite(.song("s1"), true) }
        #expect(finds, "findsSetup")
        #expect(token, "hasListenBrainzToken")
        #expect(offline, "isOffline")
        #expect(favourite, "isFavourite (Y2)")
    }
}

/// Set from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
