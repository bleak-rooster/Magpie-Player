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
    static let allowedStates: Set<String> = [CarPlayRows.nothingDownloaded, "You're offline", "Nothing here yet",
                                              "Finds aren't set up on this iPhone"]
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
        let onlineTabs = car.tabs
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
            #expect(await eventually { car.tabs !== onlineTabs && car.templates.count == 1 }, "\(ctx): back to the first lists")
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
            let loaded = await eventually { !FakeCarInterface.texts(car.topList).isEmpty }
            let shown = FakeCarInterface.texts(car.topList)
            #expect(loaded, "\(ctx): \(title) never loaded")
            #expect(Self.deadStates.isDisjoint(with: shown), "\(ctx): \(title) shows \(shown)")
            if title == "Favourites" { #expect(shown == ["You're offline"], "\(ctx): Favourites says why") }
            if title == "Downloads" { #expect(shown.contains("A"), "\(ctx): Downloads lists the album on the phone") }
        }
        // Home: only shelves the phone can fill, none failing.
        let sections = adapter.homeSections
        #expect(Set(sections).isSubset(of: [.downloaded, .discover, .playlists]), "\(ctx): \(sections)")
        #expect(sections.contains(.discover) == aurral, "\(ctx): Discover's flows only with Aurral")
        let shelves = try await adapter.homeShelves(sections, size: 4)
        #expect(shelves.contains { $0.section == .downloaded }, "\(ctx): Downloaded")
        if aurral { #expect(shelves.contains { $0.section == .discover }, "\(ctx): the flow on the phone") }

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
