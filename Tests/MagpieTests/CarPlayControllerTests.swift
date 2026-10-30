import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
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

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let type = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "type" }?.value ?? ""
            let albums = (0..<12).map { #"{"id":"\#(type)\#($0)","name":"\#(type) \#($0)","artist":"A","songCount":1}"# }
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getGenres", body: subsonic(#"""
        "genres":{"genre":[{"value":"Indie Rock","songCount":2,"albumCount":1},{"value":"Alt Rock","songCount":2,"albumCount":2}]}
        """#))
        t.stub(pathSuffix: "/rest/getSongsByGenre") { request in
            let genre = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "genre" }?.value ?? ""
            let prefix = genre == "Indie Rock" ? "ir" : "ar"
            let songs = (0..<2).map { #"{"id":"\#(prefix)\#($0)","title":"\#(prefix)\#($0)","genre":"\#(genre)"}"# }
            return MockTransport.Response(status: 200, body: subsonic(#""songsByGenre":{"song":[\#(songs.joined(separator: ","))]}"#))
        }
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeModel(store: any SessionStoring) -> AppModel {
        AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                 matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                 engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                 network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
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
        car.tap("Indie Rock", in: car.topList)
        #expect(await eventually { model.player.queue.main.map(\.song.id) == ["ir0", "ir1"] })
        #expect(model.player.queue.current?.song.id == "ir0" && !model.player.isShuffled)
        #expect(await eventually { car.templates.last === CPNowPlayingTemplate.shared })
    }

    /// Downloads and Favourites through the custom fetcher.
    @Test func downloadsAndFavouritesThroughTheController() async throws {
        transport.inner.stub(pathSuffix: "/rest/getStarred2", body: subsonic(#"""
        "starred2":{"song":[{"id":"st1","title":"Starred one","artist":"A"}],"album":[{"id":"sa1","name":"Starred album","artist":"A","songCount":1}]}
        """#))
        let model = try await signedInModel()
        model.download([Song(id: "s1", title: "T1", artist: "A", album: "Continuum", albumId: "al-1", track: 1, duration: 200)],
                       reason: .album("al-1"), coverArtId: "al-1")
        await model.downloads!.settled()
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        defer { controller.disconnect() }
        controller.setAvailability(.ready(account: "one"))
        car.tap("Downloads", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Continuum", "A"] })
        car.tap("Continuum", in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Shuffle", "T1"] })
        car.tap("T1", in: car.topList)
        #expect(await eventually { model.player.queue.current?.song.id == "s1" })

        let back = try #require(car.tab(1))
        car.pop(to: car.tabs!, animated: false, completion: nil)
        car.tap("Favourites", in: back)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Starred one", "Starred album"] })
    }

    /// The sleep button sits in Now Playing (spec §5: the template allows a custom image button) and follows the timer.
    @Test func sleepButtonFollowsTheTimer() async throws {
        let model = try await signedInModel()
        let adapter = CarPlayLibraryAdapter(model: model)
        let controller = CarPlayController(interfaceController: FakeCarInterface(), library: adapter, player: model.player)
        defer { controller.disconnect() }
        func sleepButton() -> CPNowPlayingButton? {
            CPNowPlayingTemplate.shared.nowPlayingButtons.first { $0 is CPNowPlayingImageButton }
        }
        #expect(sleepButton()?.isSelected == false)
        adapter.toggleSleepTimer()
        #expect(await eventually { sleepButton()?.isSelected == true })
        adapter.toggleSleepTimer()
        #expect(await eventually { sleepButton()?.isSelected == false })
    }

    /// Cold launch from the car before first unlock: the car says it's locked, the preferences couldn't be read yet;
    /// once unlocked the saved session and the saved layout both apply.
    @Test func coldLaunchFromTheCarAppliesTheStoredLayout() async throws {
        let locked = LockableStore()
        let model = makeModel(store: locked)
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
}
