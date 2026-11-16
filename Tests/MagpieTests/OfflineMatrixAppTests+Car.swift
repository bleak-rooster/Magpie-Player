import CarPlay
import Foundation
import MagpieCore
import MagpieTestSupport
import Playback
import Testing
import UIKit
@testable import CarPlayUI
@testable import Magpie

/// Round 28 O4 (owner, 2026-11-15: "Ensure this works in all possible configurations and there are no edge case errors";
/// plan §7.2, car half; D345, D347, D348): the car in the four setups (Navidrome alone, + Lidarr, + Aurral, all with
/// ListenBrainz) × three states (online, automatic offline, manual offline). In each offline cell every Library row and
/// Home shelf opens something that plays or says why (never "didn't send this" or "out of reach"), Requests never
/// shows, Favourites says "You're offline", manual offline sends nothing and automatic offline only the reconnect
/// check (ping, login).
@MainActor @Suite(.serialized) final class OfflineMatrixCarAppTests {
    enum Setup: CaseIterable { case navidrome, lidarr, aurral, all }
    enum State: CaseIterable { case online, automatic, manual }

    /// What a car list may show offline: real rows, or a state that says why (D348, Task 23).
    static let allowedStates: Set<String> = [CarPlayRows.nothingDownloaded, "No playlists on this iPhone",
                                              "No genres on this iPhone", "You're offline", "Nothing here yet",
                                              "Finds aren't set up on this iPhone", CarPlayRows.offlineHomeLine,
                                              "Not on this iPhone",
                                              // Round 28 O3 merge (D340): the car's Library offline now has Artists,
                                              // Albums, Songs and Playlists; their A–Z bands show an empty band
                                              // disabled with what it lacks (LetterBands, round 13).
                                              "No artists", "No albums", "No songs", "No playlists"]

    /// Review M2: what the list on top shows is real rows, or (rows that do nothing) one of `allowedStates`.
    func checkShown(_ car: FakeCarInterface, _ ctx: String) async {
        let loaded = await eventually { !FakeCarInterface.texts(car.topList).isEmpty }
        #expect(loaded, "\(ctx): never loaded")
        let items = car.topList?.sections.flatMap(\.items).compactMap { $0 as? CPListItem } ?? []
        for item in items where !item.isEnabled {
            #expect(Self.allowedStates.contains(item.text ?? "") || Self.allowedStates.contains(item.detailText ?? ""),
                    "\(ctx): a dead row \(item.text ?? "")")
        }
        #expect(Self.deadStates.isDisjoint(with: FakeCarInterface.texts(car.topList)), "\(ctx)")
    }

    func enabledTexts(_ list: CPListTemplate?) -> [String] {
        list?.sections.flatMap(\.items).compactMap { $0 as? CPListItem }.filter(\.isEnabled).compactMap(\.text) ?? []
    }

    /// The song playing is on the phone (a file), and playing.
    func playsFromThePhone(_ model: AppModel, _ engine: FakeEngine, _ ctx: String) async {
        #expect(await eventually { model.player.isPlaying }, "\(ctx): nothing plays")
        let current = model.player.queue.current?.id
        let url = engine.setItemsCalls.last?.items.first { $0.0 == current }?.1
        #expect(url?.isFileURL == true, "\(ctx): not from the phone")
    }
    static let deadStates: Set<String> = ["Your library didn't send this", "Your library is out of reach"]

    @Test func matrix_car_noDeadRows() async throws {
        for setup in Setup.allCases {
            for state in State.allCases {
                try await cell(setup, state)
            }
        }
    }

    func cell(_ setup: Setup, _ state: State) async throws {
        let h = CarPlayOfflineAppTests()
        let ctx = "\(setup) \(state)"
        let aurral = setup == .aurral || setup == .all
        let model = try await h.signedIn(aurralSetUp: aurral, lidarr: setup == .lidarr || setup == .all,
                                         listenBrainz: setup == .all)
        defer { model.signOut() }
        if aurral {
            _ = try await model.discoverPlaylists()
            _ = try await model.openDiscoverPage(playlistId: "pl-dw", fresh: false, waitForRead: false) { _ in }
        }
        await h.download(model, [CarPlayOfflineAppTests.song("m-ref1")])
        let clock = ManualReachabilityClock()
        model.useReachabilityClock(clock)
        let (car, controller) = await h.car(model)
        defer { controller.disconnect() }
        switch state {
        case .online:
            break
        case .automatic:
            h.routes.down = true
            model.reachabilityEvent(.pathChanged(connected: false))
            #expect(await model.advanceReachability(clock, to: 3), "\(ctx)")
            #expect(model.offlineState == .automatic, "\(ctx)")
        case .manual:
            await h.goOffline(model)
        }
        if state != .online {
            #expect(await eventually { car.templates.count == 1 }, "\(ctx): back to the first lists")
        }
        h.routes.forget()

        let adapter = CarPlayLibraryAdapter(model: model)
        let rows = adapter.libraryRows
        #expect(!rows.contains(.requests), "\(ctx): never Requests in the car")
        let titles = CarPlayRows.libraryRoot(rows).flatMap(\.rows).map(\.title)
        #expect(await eventually { FakeCarInterface.texts(car.tab(1)) == titles }, "\(ctx): the Library tab")
        guard state != .online else { return }   // online is today's car, pinned elsewhere
        #expect(rows.contains(.downloads), "\(ctx)")
        if !aurral { #expect(!rows.contains(.discover), "\(ctx): no Discover without Aurral") }

        // Every row opens a list that plays or says why.
        for title in titles {
            guard let tabs = car.tabs else { break }
            car.pop(to: tabs, animated: false, completion: nil)
            car.tap(title, in: car.tab(1))
            await checkShown(car, "\(ctx): \(title)")
            let shown = FakeCarInterface.texts(car.topList)
            if title == "Favourites" { #expect(shown == ["You're offline"], "\(ctx): Favourites says why") }
            if title == "Downloads" { #expect(shown.contains("A"), "\(ctx): Downloads lists the album on the phone") }
        }
        // Home: only shelves the phone can fill, none failing.
        let sections = adapter.homeSections
        #expect(Set(sections).isSubset(of: [.downloaded, .discover, .playlists]), "\(ctx): \(sections)")
        #expect(sections.contains(.discover) == aurral, "\(ctx): Discover's flows only with Aurral")
        let shelves = try await adapter.homeShelves(sections, size: 4)
        #expect(shelves.contains { $0.section == .downloaded }, "\(ctx): Downloaded")
        if aurral, sections.contains(.discover) {
            #expect(shelves.contains { $0.section == .discover }, "\(ctx): the flow on the phone")
        }

        // Design M4 / review M2: Home's tiles, an artist's album, an artist's Play and Up Next's rows all work.
        guard let tabs = car.tabs else { return }
        car.pop(to: tabs, animated: false, completion: nil)
        #expect(await eventually { FakeCarInterface.texts(car.tab(0)).first == CarPlayRows.offlineHomeLine }, "\(ctx): Home")
        for tile in enabledTexts(car.tab(0)) {
            car.pop(to: tabs, animated: false, completion: nil)
            car.tap(tile, in: car.tab(0))
            if car.templates.last === CPNowPlayingTemplate.shared {
                await playsFromThePhone(model, h.engine, "\(ctx): Home \(tile)")
            } else {
                await checkShown(car, "\(ctx): Home \(tile)")
            }
        }
        car.pop(to: tabs, animated: false, completion: nil)
        controller.open(.artist(id: "ar-q", name: "Q"))
        await checkShown(car, "\(ctx): artist")
        let artistPage = car.topList
        if let album = enabledTexts(artistPage).first(where: { $0 != "Play" && $0 != "Shuffle" }) {
            car.tap(album, in: artistPage)
            await checkShown(car, "\(ctx): artist › \(album)")
            car.pop(to: artistPage!, animated: false, completion: nil)
        }
        car.tap("Play", in: artistPage)
        await playsFromThePhone(model, h.engine, "\(ctx): artist Play")
        car.pop(to: tabs, animated: false, completion: nil)
        model.player.play([CarPlayOfflineAppTests.song("m-ref1"), CarPlayOfflineAppTests.song("m-lullaby")], startAt: 0)
        controller.showNowPlaying()
        controller.upNextTapped()
        await checkShown(car, "\(ctx): Up Next")
        #expect(enabledTexts(car.topList).contains("m-ref1"), "\(ctx): Up Next's song on the phone")
        car.tap("m-ref1", in: car.topList)
        await playsFromThePhone(model, h.engine, "\(ctx): Up Next row")
        car.pop(to: tabs, animated: false, completion: nil)

        // What left the phone meanwhile: nothing in manual offline; only the reconnect check in automatic.
        let sent = h.routes.sent
        switch state {
        case .manual:
            #expect(sent.isEmpty, "\(ctx): sent \(sent.map(\.path))")
        case .automatic:
            #expect(sent.allSatisfy { $0.path.hasSuffix("/rest/ping") || $0.path.hasSuffix("/auth/login") },
                    "\(ctx): sent \(sent.map(\.path))")
        case .online:
            break
        }
        // Back online (automatic), the car stays where it is.
        if state == .automatic {
            let stack = car.templates.map(ObjectIdentifier.init)
            h.routes.down = false
            model.reachabilityEvent(.pathChanged(connected: true))
            #expect(await model.advanceReachability(clock, to: 10), "\(ctx)")
            #expect(await eventually(10) { !model.isOffline }, "\(ctx)")
            #expect(car.templates.map(ObjectIdentifier.init) == stack, "\(ctx): the car stays where it was")
        }
    }
}
