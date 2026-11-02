import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import os
import Playback
import Search
import Testing
import UIKit
@testable import CarPlayUI
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// The car's screen as the controller drives it: a template stack, with what was presented. `CPInterfaceController`
/// has no public initialiser, so the controller takes any `CarPlayInterface`.
@MainActor
final class FakeCarInterface: CarPlayInterface {
    weak var delegate: (any CPInterfaceControllerDelegate)?
    private(set) var templates: [CPTemplate] = []
    private(set) var presentedTemplate: CPTemplate?
    private(set) var presented: [CPTemplate] = []
    var topTemplate: CPTemplate? { templates.last }
    let carTraitCollection = UITraitCollection(displayScale: 2)

    func setRootTemplate(_ rootTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        templates = [rootTemplate]
        completion?(true, nil)
    }

    func pushTemplate(_ templateToPush: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        templates.append(templateToPush)
        completion?(true, nil)
    }

    func pop(to targetTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        if let index = templates.firstIndex(where: { $0 === targetTemplate }) { templates = Array(templates.prefix(index + 1)) }
        completion?(true, nil)
    }

    func presentTemplate(_ templateToPresent: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        presentedTemplate = templateToPresent
        presented.append(templateToPresent)
        completion?(true, nil)
    }

    func dismissTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        presentedTemplate = nil
        completion?(true, nil)
    }

    // MARK: Reading the screen

    var tabs: CPTabBarTemplate? { templates.first as? CPTabBarTemplate }
    func tab(_ index: Int) -> CPListTemplate? { tabs?.templates[index] as? CPListTemplate }
    var topList: CPListTemplate? { templates.last as? CPListTemplate }

    static func headers(_ list: CPListTemplate?) -> [String?] { list?.sections.map(\.header) ?? [] }
    static func texts(_ list: CPListTemplate?) -> [String] {
        list?.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.text } ?? []
    }

    /// Taps the row titled `text`, as the driver would.
    func tap(_ text: String, in list: CPListTemplate?) {
        guard let item = list?.sections.flatMap(\.items).compactMap({ $0 as? CPListItem }).first(where: { $0.text == text })
        else { Issue.record("no row \(text)"); return }
        item.handler?(item) {}
    }
}

/// Drives `CarPlayController` itself (T22 review): the custom Home and its layout watch, the Library's new screens
/// through the custom fetcher and play handling, the sleep button, and a cold launch from the car.
@MainActor @Suite(.serialized) final class CarPlayControllerTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayControllerTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CarPlayControllerTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// Y2: how many albums the server's A–Z holds (paged by offset); nil answers every album list with 12.
    let azAlbums = OSAllocatedUnfairLock<Int?>(initialState: nil)

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let azAlbums = azAlbums
        t.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let type = items.first { $0.name == "type" }?.value ?? ""
            if type == "alphabeticalByName", let total = azAlbums.withLock({ $0 }) {   // Y2: a big library, paged
                func value(_ name: String) -> Int { Int(items.first { $0.name == name }?.value ?? "0") ?? 0 }
                let albums = (0..<total).dropFirst(value("offset")).prefix(value("size"))
                    .map { #"{"id":"al\#($0)","name":"Album \#(String(format: "%04d", $0))","artist":"A","songCount":1}"# }
                return MockTransport.Response(status: 200,
                                              body: subsonic(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
            }
            let albums = (0..<12).map { #"{"id":"\#(type)\#($0)","name":"\#(type) \#($0)","artist":"A","songCount":1}"# }
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getGenres", body: subsonic(#"""
        "genres":{"genre":[{"value":"Indie Rock","songCount":300,"albumCount":1},{"value":"Alt Rock","songCount":300,"albumCount":2}]}
        """#))
        t.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let genre = value("genre") ?? ""
            let prefix = genre == "Indie Rock" ? "ir" : "ar"
            let offset = Int(value("offset") ?? "0") ?? 0, count = Int(value("count") ?? "0") ?? 0
            let songs = (0..<300).dropFirst(offset).prefix(count)
                .map { #"{"id":"\#(prefix)\#($0)","title":"\#(prefix)\#($0)","genre":"\#(genre)"}"# }
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":{"song":[\#(songs.joined(separator: ","))]}"#))
        }
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel(store: any SessionStoring, unlocked: Bool = true) -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: FakeFetcher(), protectedDataAvailableAtLaunch: unlocked)
    }

    func signedInModel() async throws -> AppModel {
        let model = makeModel(store: store)
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.preDownload = 0 }
        return model
    }

    /// Lists as the car shows them: a Home reshape held back while Home is on screen goes in as it reappears.
    func shown(_ car: FakeCarInterface, _ controller: CarPlayController, tab index: Int) -> CPListTemplate? {
        guard let list = car.tab(index) else { return nil }
        controller.templateWillAppear(list, animated: false)
        return list
    }

    @Test func homeFollowsTheLayoutAndTheWatchDoesntStack() async throws {
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        #expect(await eventually {
            FakeCarInterface.headers(self.shown(car, controller, tab: 0)) == ["Jump back in", "Recently added", "Most played"]
        })
        #expect(FakeCarInterface.texts(car.tab(1)) == ["Playlists", "Artists", "Albums", "Genres", "Favourites", "Downloads"])
        let watches = controller.watches.count
        let first = try #require(controller.layoutWatch)

        // A second account replaces the layout watch rather than stacking another.
        controller.setAvailability(.ready(account: "two"))
        #expect(controller.watches.count == watches && first.isCancelled && controller.layoutWatch != first)

        model.updatePreferences {
            $0.layout.home.set(.recentlyAdded, visible: false, keepingOneOf: [])
            $0.layout.home.set(.genres, visible: true, keepingOneOf: [])
            $0.layout.setLibraryRow(.artists, visible: false)
        }
        #expect(await eventually {
            FakeCarInterface.headers(self.shown(car, controller, tab: 0)) == ["Jump back in", "Most played", "Genres"]
        })
        #expect(await eventually {
            FakeCarInterface.texts(self.shown(car, controller, tab: 1)) == ["Playlists", "Albums", "Genres", "Favourites", "Downloads"]
        })
        #expect(controller.watches.count == watches)
    }

    /// Library › Genres › Rock › Indie Rock: the group page is Shuffle then the genres; a genre plays its songs in order.
    @Test func genresThroughTheController() async throws {
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        car.tap("Genres", in: car.tab(1))
        #expect(car.topList?.title == "Genres")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Rock"] })
        car.tap("Rock", in: car.topList)
        #expect(car.topList?.title == "Rock")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Shuffle", "Indie Rock", "Alt Rock"] })
        let rock = try #require(car.topList)
        car.tap("Indie Rock", in: rock)
        #expect(await eventually { model.player.queue.main.prefix(2).map(\.song.id) == ["ir0", "ir1"] })
        #expect(model.player.queue.main.count == 300)
        #expect(model.player.queue.current?.song.id == "ir0" && !model.player.isShuffled)
        #expect(await eventually { car.templates.last === CPNowPlayingTemplate.shared })

        // Fix round 1 (7): the group's Shuffle plays its genres' songs, capped at 500, with shuffle on.
        car.pop(to: rock, animated: false, completion: nil)
        car.tap("Shuffle", in: rock)
        #expect(await eventually { model.player.isShuffled && model.player.queue.main.count == AppModel.groupSongCap })
        let ids = Set(model.player.queue.main.map(\.song.id))
        #expect(ids.contains("ir0") && ids.contains("ar0") && ids.count == AppModel.groupSongCap)
    }

    /// Fix round 1 (3): a Made for you playlist that can't be read is empty, not a library failure.
    @Test func unreadableMadeForYouIsEmpty() async throws {
        let model = try await signedInModel()
        try model.setListenBrainzToken("tok")
        model.madeForYouShelf = [MadeForYou.Playlist(id: MBID("5a2b8c4e-7a0b-4f61-9a0e-0c8f2d1e9b11")!, title: "Daily Jams")]
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        #expect(await eventually { FakeCarInterface.texts(self.shown(car, controller, tab: 0)).contains("Daily Jams") })
        car.tap("Daily Jams", in: car.tab(0))
        #expect(car.topList?.title == "Daily Jams")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Nothing here yet"] })
    }

    /// Downloads and Favourites through the custom fetcher.
    @Test func downloadsAndFavouritesThroughTheController() async throws {
        transport.inner.stub(pathSuffix: "/rest/getStarred2", body: subsonic(#"""
        "starred2":{"song":[{"id":"st1","title":"Starred one","artist":"A"}],"album":[{"id":"sa1","name":"Starred album","artist":"A","songCount":1}]}
        """#))
        let model = try await signedInModel()
        let s1 = Song(id: "s1", title: "T1", artist: "A", album: "Continuum", albumId: "al-1", track: 1, duration: 200)
        model.download([s1], reason: .album("al-1"), coverArtId: "al-1")
        model.download([s1], reason: .playlist("p1"),
                       playlist: DownloadedPlaylist(id: "p1", name: "Road", coverArtId: nil, songIds: ["s1", "s9"], savedAt: .now))
        await model.downloads!.settled()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        car.tap("Downloads", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Continuum", "A", "Road"] })
        // Fix round 1 (b): online too, a downloaded playlist shows only its songs on the phone (no server playlist).
        let downloads = try #require(car.topList)
        car.tap("Road", in: downloads)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "T1"] })
        car.pop(to: downloads, animated: false, completion: nil)
        car.tap("Continuum", in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "T1"] })
        car.tap("T1", in: car.topList)
        #expect(await eventually { model.player.queue.current?.song.id == "s1" })

        let back = try #require(car.tab(1))
        car.pop(to: car.tabs!, animated: false, completion: nil)
        car.tap("Favourites", in: back)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Starred one", "Starred album"] })
    }

    // MARK: - Round 12 item 2b (Y2): Favourite in Now Playing, instead of the sleep timer

    private func starButton() -> CPNowPlayingImageButton? {
        CPNowPlayingTemplate.shared.nowPlayingButtons.compactMap { $0 as? CPNowPlayingImageButton }.first
    }

    private func starRequests(_ suffix: String) -> [String?] {
        transport.inner.requests.filter { $0.url?.path.hasSuffix(suffix) == true }.map { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
                .first { $0.name == "id" }?.value
        }
    }

    private let plain = Song(id: "s1", title: "Plain", artist: "A", album: "X", duration: 200)
    private let loved = Song(id: "s2", title: "Loved", artist: "A", album: "X", duration: 200, starred: true)

    /// The star follows the song playing (its favourite state on the phone); the sleep button is gone from the car.
    @Test func favouriteButtonFollowsTheSong() async throws {
        let model = try await signedInModel()
        let controller = CarPlayController(interfaceController: FakeCarInterface(), library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        #expect(starButton()?.isEnabled == false, "nothing playing: the star is there but off")
        #expect(!CPNowPlayingTemplate.shared.nowPlayingButtons.contains { $0.accessibilityLabel == "Sleep timer" })
        model.player.play([plain, loved], startAt: 0)
        #expect(await eventually {
            self.starButton()?.isEnabled == true && self.starButton()?.isSelected == false
                && self.starButton()?.accessibilityLabel == "Favourite"
        })
        model.player.next()
        #expect(await eventually {
            self.starButton()?.isSelected == true && self.starButton()?.accessibilityLabel == "Unfavourite"
        })
        // Starred on the phone: the car follows.
        await model.setFavourite(.song("s2"), false)
        #expect(await eventually { self.starButton()?.isSelected == false })
    }

    /// A tap goes through the phone's favourites (X3's `setFavourite`): the star fills at once and the server is told.
    @Test func favouriteTapStarsTheSongPlaying() async throws {
        transport.inner.stub(pathSuffix: "/rest/star", body: ok)
        transport.inner.stub(pathSuffix: "/rest/unstar", body: ok)
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        model.player.play([plain, loved], startAt: 0)
        #expect(await eventually { self.starButton()?.isEnabled == true })
        controller.favouriteTapped()
        #expect(await eventually { self.starRequests("/rest/star") == ["s1"] })
        #expect(await eventually { self.starButton()?.isSelected == true && model.isFavourite(.song("s1")) })
        #expect(car.presented.isEmpty, "a favourite that worked says nothing: the star shows it")
        model.player.next()
        #expect(await eventually { self.starButton()?.isSelected == true })
        controller.favouriteTapped()
        #expect(await eventually { self.starRequests("/rest/unstar") == ["s2"] })
        #expect(await eventually { self.starButton()?.isSelected == false && !model.isFavourite(.song("s2")) })
    }

    /// The server says no: the star goes back to the real state, and the car says why (in answer to the tap).
    @Test func favouriteFailureRollsBack() async throws {
        let refused = Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"no"}}}"#.utf8)
        transport.inner.stub(pathSuffix: "/rest/star", body: refused)
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        model.player.play([plain], startAt: 0)
        #expect(await eventually { self.starButton()?.isEnabled == true })
        controller.favouriteTapped()
        #expect(await eventually { !self.starRequests("/rest/star").isEmpty })
        #expect(await eventually { car.presented.contains { $0 is CPAlertTemplate } })
        let alert = try #require(car.presented.last as? CPAlertTemplate)
        #expect(alert.titleVariants == ["Couldn't add to your favourites"])
        #expect(self.starButton()?.isSelected == false && !model.isFavourite(.song("s1")))
        #expect(self.starButton()?.isEnabled == true, "and it can be tried again")
    }

    /// Offline nothing is sent: the car says so and the star stays as it was.
    @Test func favouriteOfflineSaysSo() async throws {
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        model.player.play([plain], startAt: 0)
        #expect(await eventually { self.starButton()?.isEnabled == true })
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { model.isOffline })
        controller.favouriteTapped()
        #expect(await eventually { (car.presented.last as? CPAlertTemplate)?.titleVariants == ["You're offline"] })
        #expect(starRequests("/rest/star").isEmpty && self.starButton()?.isSelected == false)
    }

    // MARK: - Round 12 item 2 (Y2): A–Z lists

    /// Playlists come in letter sections with CarPlay's letter scrubber.
    @Test func libraryListsShowTheLetterScrubber() async throws {
        transport.inner.stub(pathSuffix: "/rest/getPlaylists", body: subsonic(#"""
        "playlists":{"playlist":[{"id":"p1","name":"Road","songCount":1,"duration":9},{"id":"p2","name":"Beach","songCount":1,"duration":9},{"id":"p3","name":"Rain","songCount":1,"duration":9}]}
        """#))
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        car.tap("Playlists", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Beach", "Rain", "Road"] })
        #expect(car.topList?.sections.map(\.sectionIndexTitle) == ["B", "R"])
        #expect(FakeCarInterface.headers(car.topList) == ["B", "R"])
    }

    /// A letters screen's group opens its list (the third screen): letter sections, and rows that open their page.
    @Test func aLetterGroupOpensAListOfPages() async throws {
        transport.inner.stub(pathSuffix: "/rest/getPlaylist", body: subsonic(#"""
        "playlist":{"id":"p2","name":"Beach","songCount":1,"duration":9,"entry":[{"id":"b1","title":"Wave","artist":"A"}]}
        """#))
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        let playlists = [Playlist(id: "p1", name: "Road", songCount: 1, duration: 9),
                         Playlist(id: "p2", name: "Beach", songCount: 1, duration: 9)]
        let letters = CarPlayRows.playlists(playlists, maxItems: 2, maxSections: 1)
        #expect(letters.flatMap(\.rows).map(\.title) == ["B", "R"])
        let group = try #require(letters.first?.rows.first)
        controller.perform(group.action)
        #expect(car.topList?.title == "B")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Beach"] })
        #expect(car.topList?.sections.map(\.sectionIndexTitle) == ["B"])
        // Owner ruling: a group's row opens its page (Play and Shuffle there, 2c).
        car.tap("Beach", in: car.topList)
        #expect(car.topList?.title == "Beach")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "Wave"] })
        car.tap("Play", in: car.topList)
        #expect(await eventually { model.player.queue.current?.song.id == "b1" })
    }

    /// Albums are read past Navidrome's 500-per-page answer, so a big library reaches the letters screen (it was cut at
    /// 500 before, exactly the car's item limit, so albums after it were never shown).
    @Test func albumsPastTheFirstPageReachTheLettersScreen() async throws {
        azAlbums.withLock { $0 = 1200 }
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        car.tap("Albums", in: car.tab(1))
        let limit = Int(CPListTemplate.maximumItemCount)
        try #require(limit < 1200, "this simulator's limit is \(limit)")
        #expect(await eventually { FakeCarInterface.texts(car.topList).first?.hasPrefix("A (1 of ") == true })
        let pages = FakeCarInterface.texts(car.topList)
        #expect(pages.count == (1200 + limit - 1) / limit)
        car.tap(try #require(pages.last), in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "Album 1199" })
    }

    // MARK: - Round 12 item 2c: Play and Shuffle

    private func stubAlbumsAndArtist() {
        @Sendable nonisolated func songs(_ ids: [String], album: String) -> String {
            ids.map { #"{"id":"\#($0)","title":"\#($0)","artist":"A","artistId":"ar1","album":"\#(album)","albumId":"\#(album)","duration":60}"# }
                .joined(separator: ",")
        }
        transport.inner.stub(pathSuffix: "/rest/getAlbum") { request in
            let id = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
                .first { $0.name == "id" }?.value ?? ""
            let ids = id == "al2" ? ["c", "d"] : ["a1", "a2", "a3"]
            return MockTransport.Response(status: 200, body: subsonic(#"""
            "album":{"id":"\#(id)","name":"Album \#(id)","artist":"A","artistId":"ar1","songCount":\#(ids.count),"song":[\#(songs(ids, album: id))]}
            """#))
        }
        transport.inner.stub(pathSuffix: "/rest/getArtist", body: subsonic(#"""
        "artist":{"id":"ar1","name":"A","albumCount":2,"album":[{"id":"al1","name":"One","artist":"A","songCount":3},{"id":"al2","name":"Two","artist":"A","songCount":2}]}
        """#))
    }

    /// Album and artist pages start with Play and Shuffle; both replace the queue, never asking first (R12), and Play
    /// is in order from the first song.
    @Test func playAndShuffleReplaceTheQueue() async throws {
        stubAlbumsAndArtist()
        let model = try await signedInModel()
        model.updatePreferences { $0.playback.askBeforeReplacingQueue = true }
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        model.player.play([plain, loved], startAt: 0)
        model.player.setShuffled(true)

        controller.perform(.open(.album(id: "al1", title: "One")))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "a1", "a2", "a3"] })
        let album = try #require(car.topList)
        car.tap("Play", in: album)
        #expect(await eventually { model.player.queue.main.map(\.song.id) == ["a1", "a2", "a3"] })
        #expect(model.player.queue.current?.song.id == "a1" && !model.player.isShuffled)
        #expect(car.presented.isEmpty, "the car never asks before replacing")

        car.tap("Shuffle", in: album)
        #expect(await eventually { model.player.isShuffled })
        #expect(Set(model.player.queue.main.map(\.song.id)) == ["a1", "a2", "a3"])

        car.pop(to: car.tabs!, animated: false, completion: nil)
        controller.perform(.open(.artist(id: "ar1", name: "A")))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "One", "Two"] })
        car.tap("Play", in: car.topList)
        #expect(await eventually { model.player.queue.main.map(\.song.id) == ["a1", "a2", "a3", "c", "d"] })
        #expect(!model.player.isShuffled)
    }

    // MARK: - Round 12 item 2d: Now Playing's album and artist

    private func alertTitles(_ template: CPTemplate?) -> [String] {
        (template as? CPActionSheetTemplate)?.actions.map(\.title) ?? []
    }

    @Test func albumArtistButtonOffersBothPages() async throws {
        stubAlbumsAndArtist()
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        #expect(!CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled, "nothing playing")
        let song = Song(id: "a1", title: "a1", artist: "A", artistId: "ar1", album: "One", albumId: "al1", duration: 60)
        controller.perform(.play(.songs([song], startAt: 0)))
        #expect(await eventually { CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled })
        #expect(car.topTemplate === CPNowPlayingTemplate.shared)

        controller.nowPlayingTemplateAlbumArtistButtonTapped(CPNowPlayingTemplate.shared)
        #expect(alertTitles(car.presentedTemplate) == ["Go to album", "Go to artist", "Cancel"])
        car.dismissTemplate(animated: false, completion: nil)
        controller.go(to: .album(id: "al1", title: "One"))
        #expect(car.topList?.title == "One")
        #expect(await eventually { FakeCarInterface.texts(car.topList).first == "Play" })
        #expect(car.templates.count == 2, "from the tab bar, so the page has the whole depth budget")

        controller.perform(.play(.songs([song], startAt: 0)))
        controller.go(to: .artist(id: "ar1", name: "A"))
        #expect(car.topList?.title == "A")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "One", "Two"] })
    }

    @Test func albumArtistButtonGoesStraightToTheOnlyPage() async throws {
        stubAlbumsAndArtist()
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        let song = Song(id: "a1", title: "a1", artist: "A", album: "One", albumId: "al1", duration: 60)   // no artist id
        controller.perform(.play(.songs([song], startAt: 0)))
        #expect(await eventually { CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled })
        controller.nowPlayingTemplateAlbumArtistButtonTapped(CPNowPlayingTemplate.shared)
        #expect(car.presented.isEmpty)
        #expect(car.topList?.title == "One")
    }

    /// Offline (R10): the downloaded page, or the button is off.
    @Test func albumArtistButtonOffline() async throws {
        let model = try await signedInModel()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        let s1 = Song(id: "s1", title: "T1", artist: "A", artistId: "ar1", album: "Continuum", albumId: "al-1", track: 1,
                      duration: 200)
        model.download([s1], reason: .album("al-1"), coverArtId: "al-1")
        await model.downloads!.settled()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await eventually { model.isOffline })
        let away = Song(id: "x1", title: "Away", artist: "B", artistId: "ar9", album: "Gone", albumId: "al9", duration: 60)
        model.player.play([away], startAt: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled, "not on the phone: off")

        controller.perform(.play(.songs([s1], startAt: 0)))
        #expect(await eventually { CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled })
        controller.nowPlayingTemplateAlbumArtistButtonTapped(CPNowPlayingTemplate.shared)
        #expect(alertTitles(car.presentedTemplate) == ["Go to album", "Go to artist", "Cancel"])
        car.dismissTemplate(animated: false, completion: nil)
        controller.go(to: .downloadedAlbum(id: "al-1", title: "Continuum"))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Play", "Shuffle", "T1"] })
    }

    /// What the car reports for its list limits on this simulator (recorded in the Y2 report).
    @Test func listLimitsAreReadable() {
        print("Y2 CPListTemplate.maximumItemCount=\(CPListTemplate.maximumItemCount) maximumSectionCount=\(CPListTemplate.maximumSectionCount)")
        #expect(CPListTemplate.maximumItemCount > 0)
    }

    /// Cold launch from the car before first unlock: the car says it's locked, the preferences couldn't be read yet;
    /// once unlocked the saved session and the saved layout both apply.
    @Test func coldLaunchFromTheCarAppliesTheStoredLayout() async throws {
        let locked = LockableStore()
        let model = makeModel(store: locked, unlocked: false)
        model.resumeSavedSession()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(CarPlaySceneDelegate.availability(model))
        #expect(FakeCarInterface.texts(car.topList) == ["Locked until this iPhone is unlocked"])

        // What the owner saved, readable only now (UserDefaults can't be read before first unlock).
        var saved = model.preferences
        saved.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        saved.layout.library.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)
        PreferencesStore(defaults: defaults).save(saved, previous: model.preferences)
        locked.unlock(with: SavedSession(endpoint: ServerEndpoint(bases: [home]),
                                         credentials: NavidromeCredentials(username: "admin", password: "pw")))
        model.protectedDataBecameAvailable()
        #expect(model.preferences.layout == saved.layout)
        controller.setAvailability(CarPlaySceneDelegate.availability(model))
        #expect(await eventually {
            FakeCarInterface.headers(self.shown(car, controller, tab: 0)) == ["Most played", "Jump back in", "Recently added"]
        })
        #expect(FakeCarInterface.texts(car.tab(1)).first == "Downloads")
    }

    /// Fix round 1 (1): the reload after unlock happens only after a launch before first unlock, only once, and an
    /// area changed in memory meanwhile keeps that change.
    @Test func preferencesReloadOnceAfterALockedLaunch() throws {
        let unlockedLaunch = makeModel(store: LockableStore())
        var other = unlockedLaunch.preferences
        other.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        PreferencesStore(defaults: defaults).save(other, previous: unlockedLaunch.preferences)
        unlockedLaunch.protectedDataBecameAvailable()
        #expect(unlockedLaunch.preferences.layout != other.layout, "a normal launch never reloads")

        let fresh = UserDefaults(suiteName: "CarPlayControllerTests.locked.\(UUID().uuidString)")!
        let model = AppModel(store: LockableStore(), lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: engine, defaults: fresh, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher(), protectedDataAvailableAtLaunch: false)
        let launch = model.preferences
        model.updatePreferences { $0.playback.sleepTimer = .m60 }   // changed in the car before unlock
        // What was saved before this launch, readable only now (the write above was lost while locked).
        var saved = launch
        saved.layout.home.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        let store = PreferencesStore(defaults: fresh)
        store.save(saved, previous: model.preferences)
        model.protectedDataBecameAvailable()
        #expect(model.preferences.layout == saved.layout, "the saved layout applies")
        #expect(model.preferences.playback.sleepTimer == .m60, "the change made before unlock survives")
        #expect(store.load().playback.sleepTimer == .m60, "and is saved now")

        var later = model.preferences
        later.layout = launch.layout
        store.save(later, previous: model.preferences)
        model.protectedDataBecameAvailable()
        #expect(model.preferences.layout == saved.layout, "only once")
    }
}
