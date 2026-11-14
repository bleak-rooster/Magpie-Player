import Foundation
import Testing
@testable import MagpieCore

/// Round 27 H (owner, 2026-11-14): "an option to view albums as smaller icons" (D296), Home's flows "alphabetically or
/// based on last played" (D298), the car's Home flows by "the latest one that was played" (D297), and the car's
/// "aurral playlists/flows and playlists combined" (D300).
@Suite struct Round27LayoutPreferencesTests {
    // MARK: - D296: album covers

    @Test func albumCovers_defaultLargeAndMissingKeyReadsLarge() throws {
        #expect(LayoutPreferences.defaultValue.albumCovers == .large)
        #expect(AlbumCoverSize.allCases == [.large, .small])
        // A layout saved before round 27 has no key: it reads as large, and nothing else in it is lost.
        let old = Data(#"{"version":1,"showsRecentlyAdded":false,"albumArtistsOnly":false}"#.utf8)
        let read = LayoutPreferences.decode(old)
        #expect(read.albumCovers == .large)
        #expect(read.showsRecentlyAdded == false && read.albumArtistsOnly == false)
        // An unknown value reads as large too.
        let odd = Data(#"{"version":1,"albumCovers":"tiny","showsRecentlyAdded":false}"#.utf8)
        #expect(LayoutPreferences.decode(odd).albumCovers == .large)
        #expect(LayoutPreferences.decode(odd).showsRecentlyAdded == false)
    }

    @Test func albumCovers_smallRoundTrips() throws {
        var layout = LayoutPreferences.defaultValue
        layout.albumCovers = .small
        let data = try #require(layout.encoded())
        #expect(LayoutPreferences.decode(data).albumCovers == .small)
        #expect(LayoutPreferences.decode(data) == layout.normalised())
    }

    // MARK: - D298: Your flows on Home

    @Test func homeFlowsOrder_defaultLastPlayedAndMissingKey() throws {
        #expect(LayoutPreferences.defaultValue.homeFlowsOrder == .lastPlayed)
        #expect(HomeFlowsOrder.allCases == [.lastPlayed, .alphabetical])
        let old = Data(#"{"version":1,"becauseYouLikeRows":2}"#.utf8)
        #expect(LayoutPreferences.decode(old).homeFlowsOrder == .lastPlayed)
        #expect(LayoutPreferences.decode(old).becauseYouLikeRows == 2)
        var layout = LayoutPreferences.defaultValue
        layout.homeFlowsOrder = .alphabetical
        #expect(LayoutPreferences.decode(try #require(layout.encoded())).homeFlowsOrder == .alphabetical)
    }

    private func playlist(_ id: String, _ name: String) -> Playlist {
        Playlist(id: id, name: name, songCount: 3, duration: 600)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// D297 (the car, always) and D298 (Home's default): played flows newest first, then the rest A to Z, ignoring case
    /// and accents.
    @Test func lastPlayed_playedNewestFirstThenAToZ() {
        let flows = [playlist("p1", "zebra mix"), playlist("p2", "Éclair"), playlist("p3", "apple"),
                     playlist("p4", "Discover Weekly"), playlist("p5", "Banana")]
        let plays = ["p4": now.addingTimeInterval(-60), "p1": now, "gone": now.addingTimeInterval(10)]
        let sorted = HomeFlowsOrder.lastPlayed.sorted(flows, lastPlayed: plays)
        #expect(sorted.map(\.id) == ["p1", "p4", "p3", "p5", "p2"], "\(sorted.map(\.name))")
    }

    @Test func alphabetical_ignoresPlaysCaseAndAccents() {
        let flows = [playlist("p1", "zebra mix"), playlist("p2", "Éclair"), playlist("p3", "apple"),
                     playlist("p4", "Discover Weekly")]
        let sorted = HomeFlowsOrder.alphabetical.sorted(flows, lastPlayed: ["p1": now])
        #expect(sorted.map(\.name) == ["apple", "Discover Weekly", "Éclair", "zebra mix"])
    }

    /// Two flows with the same name (another user's "Discover Weekly") keep a stable order: by id.
    @Test func sameNamesAreStable() {
        let flows = [playlist("p9", "Discover Weekly"), playlist("p2", "discover weekly")]
        #expect(HomeFlowsOrder.alphabetical.sorted(flows, lastPlayed: [:]).map(\.id) == ["p2", "p9"])
        #expect(HomeFlowsOrder.lastPlayed.sorted(flows, lastPlayed: [:]).map(\.id) == ["p2", "p9"])
        let same = ["p9": now, "p2": now]
        #expect(HomeFlowsOrder.lastPlayed.sorted(flows, lastPlayed: same).map(\.id) == ["p2", "p9"])
    }

    // MARK: - D300: flows with your playlists, in the car

    @Test func flowsWithPlaylists_offByDefaultAndMissingKey() throws {
        #expect(CarPlayPreferences.defaultValue.flowsWithPlaylists == false)
        #expect(Preferences.standard.carPlay.flowsWithPlaylists == false)
        let old = Data(#"{"version":1,"thirdTab":"albums"}"#.utf8)
        let read = CarPlayPreferences.decode(old)
        #expect(read.flowsWithPlaylists == false && read.thirdTab == .albums)
        var car = CarPlayPreferences.defaultValue
        car.flowsWithPlaylists = true
        let saved = CarPlayPreferences.decode(try #require(car.encoded()))
        #expect(saved.flowsWithPlaylists && saved.thirdTab == .playlists && saved.home == nil)
    }
}
