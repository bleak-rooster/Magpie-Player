import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 12 Y6: Discover in the car's Library, like other playlists.
@Suite struct DiscoverRowsTests {
    @Test func libraryRootHasDiscoverWhenTheLayoutSaysSo() {
        let rows = CarPlayRows.libraryRoot([.playlists, .discover], hasFindsTab: false).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Playlists", "Discover"])
        #expect(rows.last?.action == .open(.discover))
        #expect(CPDestination.discover.title == "Discover")
    }

    @Test func discoverListOpensPlaylists() {
        let playlists = [Playlist(id: "p1", name: "Discover Weekly", songCount: 14, duration: 0),
                         Playlist(id: "p2", name: "", songCount: 1, duration: 0)]
        let rows = CarPlayRows.discover(playlists).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Discover Weekly", "Untitled playlist"])
        #expect(rows.map(\.detail) == ["14 songs", "1 song"])
        #expect(rows.first?.action == .open(.playlist(id: "p1", title: "Discover Weekly")))
        #expect(CarPlayRows.discover([]).flatMap(\.rows).allSatisfy { $0.action == nil || $0.id.hasPrefix("state.") })
    }
}
