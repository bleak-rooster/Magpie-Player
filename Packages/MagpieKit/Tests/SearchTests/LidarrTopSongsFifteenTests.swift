import Foundation
import MagpieCore
import Testing
@testable import Search

private func song(_ id: String) -> Song {
    Song(id: id, title: "Title \(id)", artist: "Aurora Field", album: "First Light", duration: 200)
}

/// Round 27 A (owner item 1, 2026-11-14; D303, amends D258): an artist Lidarr has keeps fifteen top songs behind the five
/// the section shows, so Play top songs has its whole list the moment it's tapped. The same reads (depth 25) fill them.
@Suite struct LidarrTopSongsFifteenTests {
    @Test func merge_fillsFifteenShowsFive() async {
        let aurral = (1...6).map { song("a\($0)") }
        let library = (1...25).map { song("n\($0)") }
        let result = await LidarrTopSongs.merge(
            sources: .init(aurral: .answered(aurral), listenBrainz: .unavailable, library: .answered(library)),
            limit: LidarrTopSongs.playLimit) { _, s in .song(s) }
        #expect(LidarrTopSongs.playLimit == 15 && LidarrTopSongs.limit == 5)
        #expect(result.rows.map(\.song.id) == (1...6).map { "a\($0)" } + (1...9).map { "n\($0)" })
        #expect(result.complete)
        #expect(LidarrTopSongs.shown(result.rows.map(\.song)).map(\.id) == (1...5).map { "a\($0)" }, "five shown")
    }

    @Test func merge_neverMoreThanFifteen() async {
        let library = (1...25).map { song("n\($0)") }
        let result = await LidarrTopSongs.merge(
            sources: .init(aurral: .unavailable, listenBrainz: .unavailable, library: .answered(library)),
            limit: 40) { _, s in .song(s) }
        #expect(result.rows.count == 15)
        let fallback = await LidarrTopSongs.merge(
            sources: .init(aurral: .unavailable, listenBrainz: .unavailable, library: .answered(library))) { _, s in .song(s) }
        #expect(fallback.rows.count == 5, "the default is still the five shown")
    }
}
