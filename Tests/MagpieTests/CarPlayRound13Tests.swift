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
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func subsonic(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 13 items 3, 4, 9, 10 and 11 through `CarPlayController` and the app's adapter: letter groups for Artists, Songs
/// and Albums (Newest first), Up Next from Now Playing, the chosen third tab (Finds is gone) and the car's own Home.
@MainActor @Suite(.serialized) final class CarPlayRound13Tests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "CarPlayRound13Tests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "CarPlayRound13Tests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    let engine = FakeEngine()
    /// The server's songs in its title order (`/api/song?_sort=title`).
    nonisolated static let songTitles = ["1999", "Abc", "Bee", "Fox", "Kite", "Pear", "Under", "Zoo", "おやすみ"]

    init() {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: ok)
        t.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        t.stub(pathSuffix: "/api/song") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            func value(_ name: String) -> Int { Int(items.first { $0.name == name }?.value ?? "0") ?? 0 }
            let titles = Self.songTitles
            // "Bee" is a missing file: it holds its place in the order, and `songsPage` drops it.
            let rows = titles.indices.dropFirst(value("_start")).prefix(max(0, value("_end") - value("_start"))).map {
                #"{"id":"s\#($0)","title":"\#(titles[$0])","artist":"A","album":"B","duration":60,"missing":\#($0 == 2)}"#
            }
            return MockTransport.Response(status: 200, body: Data("[\(rows.joined(separator: ","))]".utf8),
                                          headers: ["X-Total-Count": "\(titles.count)"])
        }
        t.stub(pathSuffix: "/rest/getAlbumList2") { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let type = items.first { $0.name == "type" }?.value ?? ""
            let offset = Int(items.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let albums = type == "alphabeticalByName" && offset == 0
                ? [#"{"id":"a1","name":"Abbey Road","artist":"B","songCount":1,"year":1969}"#,
                   #"{"id":"a2","name":"Kid A","artist":"R","songCount":1,"year":2000,"created":"2026-01-02T00:00:00Z"}"#,
                   #"{"id":"a3","name":"Kid B","artist":"R","songCount":1,"year":2000,"created":"2026-03-02T00:00:00Z"}"#]
                : type == "alphabeticalByName" ? [] : [#"{"id":"\#(type)1","name":"\#(type) 1","artist":"A","songCount":1}"#]
            return MockTransport.Response(status: 200, body: subsonic(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        t.stub(pathSuffix: "/rest/getPlaylists", body: subsonic(#""playlists":{"playlist":[{"id":"p1","name":"Drive","songCount":2}]}"#))
        t.stub(pathSuffix: "/api/artist", body: Data(#"[{"id":"ar1","name":"Abba","albumCount":1},{"id":"ar2","name":"The Wombats","albumCount":2}]"#.utf8),
               headers: ["X-Total-Count": "2"])
        t.stub(pathSuffix: "/rest/getArtists", body: subsonic(#"""
        "artists":{"index":[{"name":"A","artist":[{"id":"ar1","name":"Abba","albumCount":1}]},{"name":"W","artist":[{"id":"ar2","name":"The Wombats","albumCount":2}]}]}
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
        try await model.signIn(urls: [home], username: "admin", password: "pw")
        await model.downloads!.settled()
        model.updatePreferences {
            $0.downloads.preDownload = 0
            $0.layout.home = .build13   // round 14: these tests are about the car, from build 13's phone Home
        }
        return model
    }

    func car(_ model: AppModel) -> (FakeCarInterface, CarPlayController) {
        let car = FakeCarInterface()
        let controller = CarPlayController(interfaceController: car, library: CarPlayLibraryAdapter(model: model),
                                           player: model.player)
        controller.setAvailability(.ready(account: "one"))
        return (car, controller)
    }

    func tabTitles(_ car: FakeCarInterface) -> [String?] {
        car.tabs?.templates.map { ($0 as? CPListTemplate)?.tabTitle } ?? []
    }

    static let bands = ["A\u{2013}E", "F\u{2013}J", "K\u{2013}O", "P\u{2013}T", "U\u{2013}Z & #"]

    // MARK: Item 10: the third tab

    /// Finds is gone; the third tab is Playlists by default and follows Settings › CarPlay at once.
    @Test func theThirdTabIsChosenInSettings() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        #expect(tabTitles(car) == ["Home", "Library", "Playlists", "Search"])
        #expect(await eventually { FakeCarInterface.texts(car.tab(2)) == ["Drive"] })

        model.updatePreferences { $0.carPlay.thirdTab = .artists }
        #expect(await eventually { self.tabTitles(car) == ["Home", "Library", "Artists", "Search"] })
        #expect(await eventually { FakeCarInterface.texts(car.tab(2)) == Self.bands })
        car.tap(Self.bands[0], in: car.tab(2))
        #expect(car.topList?.title == Self.bands[0])
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Abba"] })
        #expect(controller.browseDepth == 2, "the third tab's root is depth 1")

        // Discover without Aurral set up: Playlists.
        model.updatePreferences { $0.carPlay.thirdTab = .discover }
        #expect(await eventually { self.tabTitles(car) == ["Home", "Library", "Playlists", "Search"] })
        #expect(CarPlaySettingsView.summary(model.preferences.carPlay, discoverSetUp: false) == "Playlists tab \u{00B7} Home as on iPhone")
    }

    // MARK: Items 3 and 4

    /// Library › Artists opens on the five groups with counts; a group keeps the letter scrubber.
    @Test func artistsOpenOnLetterGroups() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        car.tap("Artists", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == Self.bands })
        let details = car.topList?.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.detailText }
        #expect(details == ["1 artist", "No artists", "No artists", "No artists", "1 artist"])
        car.tap(Self.bands[4], in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["The Wombats"] })
        #expect(car.topList?.sections.map(\.sectionIndexTitle) == ["W"])
    }

    /// Library › Songs: the groups from seeks over the server's title order; a group reads its songs and plays them.
    @Test func songsOpenOnLetterGroupsAndPlay() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        car.tap("Songs", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == Self.bands })
        let details = car.topList?.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.detailText }
        #expect(details == ["2 songs", "1 song", "1 song", "1 song", "4 songs"])
        car.tap(Self.bands[4], in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Under", "Zoo", "1999", "おやすみ"] })
        #expect(car.topList?.sections.map(\.sectionIndexTitle) == ["U", "Z", "#"])
        car.tap("Zoo", in: car.topList)
        #expect(await eventually { model.player.queue.current?.song.id == "s7" })
        #expect(model.player.queue.main.map(\.song.id) == ["s6", "s7", "s0", "s8"])
    }

    /// Library › Albums starts with Newest (year, then when the server listed it); every group's albums newest first.
    @Test func albumsStartWithNewest() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        car.tap("Albums", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Newest"] + Self.bands })
        car.tap("Newest", in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Kid B", "Kid A", "Abbey Road"] })
        car.pop(to: car.tabs!, animated: false, completion: nil)
        car.tap("Albums", in: car.tab(1))
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Newest"] + Self.bands })
        car.tap(Self.bands[2], in: car.topList)
        #expect(await eventually { FakeCarInterface.texts(car.topList) == ["Kid B", "Kid A"] })
    }

    // MARK: Item 9: Up Next

    /// The button is on while there is a queue; it opens the queue, and a tap jumps there and goes back to Now Playing.
    @Test func upNextOpensTheQueueAndJumps() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        let songs = (0..<4).map { Song(id: "q\($0)", title: "Song \($0)", artist: "A", album: "B", duration: 60) }
        controller.start(songs, at: 0, shuffled: false)
        #expect(await eventually { CPNowPlayingTemplate.shared.isUpNextButtonEnabled })
        #expect(car.topTemplate === CPNowPlayingTemplate.shared)
        controller.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
        #expect(car.topList?.title == "Up Next")
        #expect(await eventually { FakeCarInterface.texts(car.topList) == songs.map(\.title) })
        #expect(car.topList?.sections.map(\.header) == ["Now playing", "Up next"])
        car.tap("Song 2", in: car.topList)
        #expect(model.player.queue.current?.song.id == "q2")
        #expect(car.topTemplate === CPNowPlayingTemplate.shared, "back to Now Playing")
        #expect(model.player.queue.upcoming.map(\.song.id) == ["q3"])
    }

    /// Now Playing at CarPlay's depth limit (5): Up Next goes from the tab bar instead (Now Playing, then Up Next).
    @Test func upNextKeepsTheDepth() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        for title in ["One", "Two", "Three"] { controller.perform(.open(.letterGroup(title: title, sections: []))) }
        let songs = [Song(id: "q0", title: "Song 0", artist: "A", album: "B", duration: 60)]
        controller.start(songs, at: 0, shuffled: false)
        #expect(car.templates.count == 5)
        controller.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
        #expect(car.templates.count == 3)
        #expect(car.templates[1] === CPNowPlayingTemplate.shared && car.topList?.title == "Up Next")
    }

    // MARK: Z3 review

    /// I2: a change between driving and parked with the same list limits reads nothing again; new limits lay out the
    /// list already read again, without reading it.
    @Test func aLimitsFlipReadsNothingAgain() async throws {
        let model = try await signedInModel()
        model.updatePreferences { $0.carPlay.thirdTab = .albums }
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        #expect(await eventually { FakeCarInterface.texts(car.tab(2)) == ["Newest"] + Self.bands })
        func reads() -> Int {
            transport.inner.requests.filter { $0.url?.query?.contains("alphabeticalByName") == true }.count
        }
        let before = reads()
        let session = CPSessionConfiguration(delegate: controller)
        controller.sessionConfiguration(session, limitedUserInterfacesChanged: [.keyboard])
        controller.sessionConfiguration(session, limitedUserInterfacesChanged: [])
        try await Task.sleep(for: .milliseconds(300))
        #expect(reads() == before, "same limits: nothing read again")

        controller.listLimits = { (items: 4, sections: 12) }
        controller.sessionConfiguration(session, limitedUserInterfacesChanged: [.keyboard])
        #expect(await eventually { controller.thirdRoot?.limits?.items == 4 }, "laid out again for the new limits")
        try await Task.sleep(for: .milliseconds(300))
        #expect(reads() == before, "from what was read already")
        #expect(FakeCarInterface.texts(car.tab(2)) == ["Newest"] + Self.bands)
    }

    /// M3: a page shortened by a missing file doesn't end its range: the rest of the range is still read.
    @Test func aShortPageDoesntEndTheRange() async throws {
        let model = try await signedInModel()
        let (songs, total) = try await CarPlayController.readSongs(CarPlayLibraryAdapter(model: model), ranges: [1..<6],
                                                                   limit: 100, pageSize: 2)
        #expect(songs.map(\.id) == ["s1", "s3", "s4", "s5"])
        #expect(total == 5, "the count includes the missing file")
    }

    /// M5: when the car refuses the pop back to the tabs, Up Next pushes nothing (Now Playing never twice).
    @Test func upNextPushesNothingWhenThePopFails() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        for title in ["One", "Two", "Three"] { controller.perform(.open(.letterGroup(title: title, sections: []))) }
        controller.start([Song(id: "q0", title: "Song 0", artist: "A", album: "B", duration: 60)], at: 0, shuffled: false)
        car.failsPops = true
        controller.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
        #expect(car.templates.count == 5)
        #expect(car.templates.filter { $0 === CPNowPlayingTemplate.shared }.count == 1)
    }

    // MARK: Item 11: the car's Home

    /// The car's Home follows the phone's until changed in Settings › CarPlay › Home; then it is the car's own.
    @Test func theCarsHomeIsItsOwnOnceChanged() async throws {
        let model = try await signedInModel()
        let (car, controller) = car(model)
        defer { controller.disconnect() }
        func shownHome() -> [String?] {
            guard let list = car.tab(0) else { return [] }
            controller.templateWillAppear(list, animated: false)
            return FakeCarInterface.headers(list)
        }
        #expect(await eventually { shownHome() == ["Jump back in", "Recently added", "Most played"] })

        var list = model.preferences.carPlay.homeList(following: model.preferences.layout.home)
        list.set(.randomAlbums, visible: true, keepingOneOf: [])
        list.moveUp(.randomAlbums)
        list.set(.recentlyAdded, visible: false, keepingOneOf: [])
        model.updatePreferences { $0.carPlay.home = list }
        #expect(await eventually { shownHome() == ["Jump back in", "Most played", "Random albums"] })

        model.updatePreferences { $0.layout.home.set(.mostPlayed, visible: false, keepingOneOf: []) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(shownHome() == ["Jump back in", "Most played", "Random albums"], "the phone's change doesn't move the car's")
        #expect(model.homeSections == [.jumpBackIn, .recentlyAdded], "and the car's doesn't move the phone's")

        model.updatePreferences { $0.carPlay.home = nil }   // Same as iPhone
        #expect(await eventually { shownHome() == ["Jump back in", "Recently added"] })
    }
}
