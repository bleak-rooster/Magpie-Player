import Foundation
import MagpieCore
import Testing
@testable import Search

private func song(_ id: String, _ title: String? = nil, library: Int? = 1) -> Song {
    Song(id: id, title: title ?? "Title \(id)", artist: "Aurora Field", album: "First Light", duration: 200, libraryId: library)
}

private func ids(_ songs: [Song]) -> [String] { songs.map(\.id) }

/// Round 27 A (owner item 1, 2026-11-14: "there should be an option to play the top songs. It should start in sequence,
/// but in the queue there should be maximum 15 of the top songs"; D304): the list Play top songs queues, in order.
@Suite struct TopSongsToPlayTests {
    @Test func playTopSongs_inOrderMaxFifteen() {
        let list = TopSongsToPlay.list([(1...10).map { song("a\($0)") }, (1...10).map { song("b\($0)") }])
        #expect(ids(list) == (1...10).map { "a\($0)" } + (1...5).map { "b\($0)" })
        #expect(TopSongsToPlay.limit == 15)
    }

    /// An artist Lidarr hasn't got: the shown rows' library songs, then Navidrome's top songs not yet in, then the source's
    /// further library rows; no song twice (by id, and by its strict title).
    @Test func playTopSongs_otherArtistLibraryRowsThenNavidrome() {
        let shown = [song("s1", "Harbour"), song("s2", "Wide Open")]
        let navidrome = [song("s2", "Wide Open"), song("n1", "Low Tide"), song("n9", "Harbour (Remastered)")]
        let further = [song("f1", "Ember"), song("n1", "Low Tide")]
        let list = TopSongsToPlay.list([shown, navidrome, further])
        #expect(ids(list) == ["s1", "s2", "n1", "f1"], "the remaster is the same song as Harbour")
    }

    @Test func playTopSongs_neverDiscoverCopyOrFind() {
        let list = TopSongsToPlay.list(
            [[song("flow", library: 9), song("copy"), song("find", library: 4), song("tried"), song("main")]],
            discoverSongIds: ["copy"], discoverLibraries: [9], isFind: { $0.libraryId == 4 || $0.id == "tried" })
        #expect(ids(list) == ["main"])
    }

    @Test func playTopSongs_hiddenWithNoLibrarySong() {
        #expect(TopSongsToPlay.list([[], []]).isEmpty)
        #expect(TopSongsToPlay.list([[song("flow", library: 9)]], discoverLibraries: [9]).isEmpty)
    }

    @Test func playTopSongs_offlineOnlyOnThePhone() {
        let list = TopSongsToPlay.list([[song("a"), song("b"), song("c")]], onPhone: ["c", "a"])
        #expect(ids(list) == ["a", "c"])
    }

    /// What the fill adds behind what's queued: the rest of the full list, in order, never past fifteen in all.
    @Test func fill_addsTheRestInOrder() {
        let queued = [song("s1"), song("s2")]
        let full = [song("s1"), song("s2")] + (1...20).map { song("n\($0)") }
        #expect(ids(TopSongsToPlay.fill(queued: queued, full: full)) == (1...13).map { "n\($0)" })
        let changed = [song("n1"), song("s2"), song("n2")]
        #expect(ids(TopSongsToPlay.fill(queued: queued, full: changed)) == ["n1", "n2"], "what's queued isn't added twice")
        #expect(TopSongsToPlay.fill(queued: (1...15).map { song("q\($0)") }, full: [song("x")]).isEmpty)
    }
}
