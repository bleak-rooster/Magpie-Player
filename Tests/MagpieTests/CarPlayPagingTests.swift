import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
import UIKit
@testable import CarPlayUI
@testable import Magpie

private let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)
private let loginJSON = Data(#"""
{"id":"u1","isAdmin":false,"name":"Jordan","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://nas.local:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 24 item 8 (owner, 2026-11-08) through `CarPlayController` and the app's adapter: every list reaches its end
/// within the car's ceiling. "More…" replaces the page (never deeper, D232), a new ceiling lays the pages out again,
/// Songs read only the page shown, and Playlists keep All / Yours (D179) with whose they are (D230).
@MainActor @Suite(.serialized) final class CarPlayPagingTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayPagingTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CarPlayPagingTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// Thirty songs, all under A, in the server's title order.
    nonisolated static let songTitles = (0..<30).map { String(format: "A%02d", $0) }

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            func value(_ name: String) -> Int { Int(items.first { $0.name == name }?.value ?? "0") ?? 0 }
            let titles = Self.songTitles
            let rows = titles.indices.dropFirst(value("_start")).prefix(max(0, value("_end") - value("_start"))).map {
                #"{"id":"s\#($0)","title":"\#(titles[$0])","artist":"A","album":"B","duration":60}"#
            }
            return MockTransport.Response(status: 200, body: Data("[\(rows.joined(separator: ","))]".utf8),
                                          headers: ["X-Total-Count": "\(titles.count)"])
        }
        t.stub(pathSuffix: "/rest/getAlbumList2", body: subsonic(#""albumList2":{"album":[]}"#))
        t.stub(pathSuffix: "/rest/getPlaylists", body: subsonic(#"""
        "playlists":{"playlist":[{"id":"p1","name":"Drive","songCount":2,"owner":"jordan","readonly":false},
        {"id":"p2","name":"Run","songCount":3,"owner":"alex","readonly":true}]}
        """#))
    }

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel() async throws -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: engine, defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences {
            $0.downloads.preDownload = 0
            $0.layout.home = .build13
        }
        return model
    }

    func car(_ model: AppModel, limits: (items: Int, sections: Int)? = nil) -> (FakeCarInterface, CarPlayController) {
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        if let limits { controller.listLimits = { limits } }
        controller.setAvailability(.ready(account: "one"))
        return (car, controller)
    }

    /// A letter group of `n` rows (A01, A02, …), each playing nothing in particular.
    static func group(_ n: Int) -> [CPSectionModel] {
        [CPSectionModel(header: "A", rows: (1...n).map {
            CPRowModel(id: "r\($0)", title: String(format: "A%02d", $0), action: .play(.songs([], startAt: 0)))
        }, indexTitle: "A")]
    }

    static func detail(_ text: String, in list: CPListTemplate?) -> String? {
        list?.sections.flatMap(\.items).compactMap { $0 as? CPListItem }.first { $0.text == text }?.detailText
    }

    // MARK: D232: a page replaces the one before it

    @Test func carList_moreReplacesTemplate_depthNeverGrows() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model, limits: (items: 12, sections: 12))
        defer { controller.disconnect() }
        // At the deepest browse level (tab → three pushes): a page must never go deeper.
        controller.perform(.open(.letterGroup(title: "One", sections: [])))
        controller.perform(.open(.letterGroup(title: "Two", sections: [])))
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(car.templates.count == 4 && controller.browseDepth == 4)
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        #expect(FakeCarInterface.texts(car.topList).count == 12)

        car.tap("More\u{2026}", in: car.topList)
        #expect(car.templates.count == 4, "replaced, not pushed")
        #expect(car.topList?.title == "Mix (2 of 3)", "titled with its place in the list")
        #expect(await eventually { FakeCarInterface.texts(car.topList).first == "Previous\u{2026}" })
        #expect(FakeCarInterface.texts(car.topList).dropFirst().first == "A12")
        #expect((car.templates[2] as? CPListTemplate)?.title == "Two", "the screen below is unchanged")

        car.tap("More\u{2026}", in: car.topList)
        #expect(car.templates.count == 4)
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "A30" })

        car.tap("Previous\u{2026}", in: car.topList)
        #expect(car.templates.count == 4)
        #expect(await eventually { FakeCarInterface.texts(car.topList).dropFirst().first == "A12" })
    }

    /// Up Next sits above Now Playing (CarPlay's fifth): its pages replace it too.
    @Test func carList_upNextPagesKeepTheDepth() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model, limits: (items: 12, sections: 12))
        defer { controller.disconnect() }
        let songs = (0..<30).map { Song(id: "q\($0)", title: "Song \($0)", artist: "A", album: "B", duration: 60) }
        controller.start(songs, at: 0, shuffled: false)
        controller.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
        let depth = car.templates.count
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        #expect(!FakeCarInterface.texts(car.topList).contains { $0.hasPrefix("Showing") })
        car.tap("More\u{2026}", in: car.topList)
        #expect(car.templates.count == depth)
        #expect(car.templates[depth - 2] === CPNowPlayingTemplate.shared)
        #expect(await eventually { FakeCarInterface.texts(car.topList).contains("Song 11") })
    }

    // MARK: Fix round 1

    /// I1: a real pop answers later; a second tap on "More…" meanwhile opens nothing more (one push, same depth).
    @Test func carList_doubleTapOnMore_pushesOnce() async throws {
        let model = try await signedInModel()
        let car = DeferredPopCar()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        controller.listLimits = { (items: 12, sections: 12) }
        controller.setAvailability(.ready(account: "one"))
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.templates.last as? CPListTemplate).last == "More\u{2026}" })
        let depth = car.templates.count, pushes = car.pushes
        car.tap("More\u{2026}")
        car.tap("More\u{2026}")
        #expect(car.pendingPops.count == 1, "the second tap waits for nothing: it is refused")
        car.answerPops()
        #expect(car.pushes == pushes + 1)
        #expect(car.templates.count == depth)
        #expect((car.templates.last as? CPListTemplate)?.title == "Mix (2 of 3)")
        // Once the page is up, More works again.
        #expect(await eventually { FakeCarInterface.texts(car.templates.last as? CPListTemplate).last == "More\u{2026}" })
        car.tap("More\u{2026}")
        car.answerPops()
        #expect(car.pushes == pushes + 2 && car.templates.count == depth)
    }

    /// M2: when the car refuses the pop, nothing is pushed and the page that would have opened is let go.
    @Test func carList_refusedPop_pushesNothing() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model, limits: (items: 12, sections: 12))
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        let depth = car.templates.count, bindings = controller.bindings.count
        car.failsPops = true
        car.tap("More\u{2026}", in: car.topList)
        #expect(car.templates.count == depth)
        #expect(car.topList?.title == "Mix")
        #expect(controller.bindings.count == bindings, "the unshown page's binding is dropped")
        #expect(!controller.bindings.values.contains { $0.template.title == "Mix (2 of 3)" })
        car.failsPops = false
        car.tap("More\u{2026}", in: car.topList)
        #expect(car.topList?.title == "Mix (2 of 3)", "and More still works afterwards")
    }

    /// M3: a page on screen when the ceiling changes is opened again for the new ceiling, so its title is right.
    @Test func carList_ceilingChange_retitlesThePageShown() async throws {
        let model = try await signedInModel()
        var limits = (items: 24, sections: 12)
        let (car, controller) = car(model)
        controller.listLimits = { limits }
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        car.tap("More\u{2026}", in: car.topList)
        #expect(car.topList?.title == "Mix (2 of 2)")
        let depth = car.templates.count

        limits = (items: 12, sections: 12)
        controller.sessionConfiguration(CPSessionConfiguration(delegate: controller), limitedUserInterfacesChanged: [.keyboard])
        #expect(await eventually { car.topList?.title == "Mix (3 of 3)" }, "row A24 is on the third page now")
        #expect(car.templates.count == depth)
        #expect(await eventually { FakeCarInterface.texts(car.topList).dropFirst().first == "A22" })
        #expect(FakeCarInterface.texts(car.topList).count <= 12)
    }

    /// M3: a page covered by another screen when the ceiling changes is opened again when it shows.
    @Test func carList_ceilingChange_retitlesACoveredPageWhenItShows() async throws {
        let model = try await signedInModel()
        var limits = (items: 24, sections: 12)
        let (car, controller) = car(model)
        controller.listLimits = { limits }
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        car.tap("More\u{2026}", in: car.topList)
        let page = try #require(car.topList)
        #expect(page.title == "Mix (2 of 2)")
        controller.perform(.open(.letterGroup(title: "Other", sections: Self.group(2))))

        limits = (items: 12, sections: 12)
        controller.sessionConfiguration(CPSessionConfiguration(delegate: controller), limitedUserInterfacesChanged: [.keyboard])
        await Task { @MainActor in }.value
        #expect(car.topList?.title == "Other", "the screen on top is left alone")
        car.pop(to: page, animated: false, completion: nil)
        controller.templateWillAppear(page, animated: false)
        controller.templateDidAppear(page, animated: false)
        #expect(await eventually { car.topList?.title == "Mix (3 of 3)" })
    }

    /// M5: a change that leaves the limits as they were lays nothing out again.
    @Test func carList_sameLimits_refreshesNothing() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model, limits: (items: 12, sections: 12))
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.topList).last == "More\u{2026}" })
        let list = try #require(car.topList)
        let binding = try #require(controller.bindings[ObjectIdentifier(list)])
        let generation = binding.generation
        controller.sessionConfiguration(CPSessionConfiguration(delegate: controller), limitedUserInterfacesChanged: [.keyboard])
        await Task { @MainActor in }.value   // runs after anything the change scheduled on the main actor
        await Task { @MainActor in }.value
        #expect(binding.generation == generation)
    }

    // MARK: A new ceiling

    @Test func carList_ceilingChangeMidSession_rebuildsPages() async throws {
        let model = try await signedInModel()
        var limits = (items: 24, sections: 12)
        let (car, controller) = car(model)
        controller.listLimits = { limits }
        defer { controller.disconnect() }
        controller.perform(.open(.letterGroup(title: "Mix", sections: Self.group(30))))
        #expect(await eventually { FakeCarInterface.texts(car.topList).count == 24 })
        controller.perform(.open(.letterGroup(title: "Other", sections: Self.group(2))))
        let mix = try #require(car.templates[1] as? CPListTemplate)

        limits = (items: 12, sections: 12)
        controller.sessionConfiguration(CPSessionConfiguration(delegate: controller), limitedUserInterfacesChanged: [.keyboard])
        #expect(await eventually { FakeCarInterface.texts(mix).count == 12 }, "laid out again for the new ceiling")
        #expect(FakeCarInterface.texts(mix).last == "More\u{2026}")
    }

    // MARK: Songs: a page reads only its songs

    @Test func carList_songPagesReadOnlyTheirSongs() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        controller.listLimits = { (items: 4, sections: 12) }   // after the Library tab is laid out, so Songs shows
        car.tap("Songs", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList).first == "A\u{2013}E" })
        car.tap("A\u{2013}E", in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["A00", "A01", "A02", "More\u{2026}"] })
        /// Reads of more than one song (the index's seeks read one row each).
        func pageReads() -> [String] {
            transport.inner.requests.compactMap { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } }
                .filter { c in
                    func value(_ name: String) -> Int { Int(c.queryItems?.first { $0.name == name }?.value ?? "0") ?? 0 }
                    return c.path.hasSuffix("/api/song") && value("_end") - value("_start") > 1
                }
                .compactMap(\.query)
        }
        let before = pageReads().count, depth = car.templates.count
        car.tap("More\u{2026}", in: car.topList)
        #expect(car.templates.count == depth, "the page replaces the one before it")
        #expect(car.topList?.title == "A\u{2013}E (2 of 14)")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Previous\u{2026}", "A03", "A04", "More\u{2026}"] })
        let reads = pageReads().dropFirst(before)
        #expect(reads.count == 1 && reads.allSatisfy { $0.contains("_start=3") && $0.contains("_end=5") }, "\(reads)")
        #expect(!FakeCarInterface.texts(car.topList).contains { $0.hasPrefix("Showing") })
    }

    // MARK: D179: All or Yours, and whose

    @Test func carList_playlists_allAndYours_respected() async throws {
        let model = try await signedInModel()
        model.playlistShow = .all
        let (car, controller) = car(model)
        #expect(await eventually { FakeCarInterface.texts(car.tab(2)) == ["Drive", "Run"] })
        #expect(Self.detail("Drive", in: car.tab(2)) == "2 songs", "your own: no name")
        #expect(Self.detail("Run", in: car.tab(2)) == "3 songs \u{00B7} alex")
        controller.disconnect()

        model.playlistShow = .yours
        let (yours, again) = self.car(model)
        defer { again.disconnect() }
        #expect(await eventually { FakeCarInterface.texts(yours.tab(2)) == ["Drive"] })
        #expect(Self.detail("Drive", in: yours.tab(2)) == "2 songs")
    }
}

/// R24F fix round 1 (I1): the car's screen with a real `CPInterfaceController`'s timing: a pop answers later, as the
/// animation ends. Pushes are counted.
@MainActor
final class DeferredPopCar: CarPlayInterface {
    weak var delegate: (any CPInterfaceControllerDelegate)?
    private(set) var templates: [CPTemplate] = []
    var topTemplate: CPTemplate? { templates.last }
    var presentedTemplate: CPTemplate? { nil }
    let carTraitCollection = UITraitCollection(displayScale: 2)
    private(set) var pushes = 0
    /// Pops asked for and not yet answered.
    private(set) var pendingPops: [() -> Void] = []

    func setRootTemplate(_ rootTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        templates = [rootTemplate]
        completion?(true, nil)
    }

    func pushTemplate(_ templateToPush: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        pushes += 1
        templates.append(templateToPush)
        completion?(true, nil)
    }

    func pop(to targetTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        pendingPops.append { [weak self] in
            guard let self else { return }
            if let index = self.templates.firstIndex(where: { $0 === targetTemplate }) {
                self.templates = Array(self.templates.prefix(index + 1))
            }
            completion?(true, nil)
        }
    }

    func presentTemplate(_ templateToPresent: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
        completion?(true, nil)
    }

    func dismissTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) { completion?(true, nil) }

    /// The pops end, in order.
    func answerPops() {
        let pops = pendingPops
        pendingPops = []
        pops.forEach { $0() }
    }

    /// Taps the row titled `text` on the top list.
    func tap(_ text: String) {
        guard let item = (templates.last as? CPListTemplate)?.sections.flatMap(\.items).compactMap({ $0 as? CPListItem })
            .first(where: { $0.text == text }) else { Issue.record("no row \(text)"); return }
        item.handler?(item) {}
    }
}
