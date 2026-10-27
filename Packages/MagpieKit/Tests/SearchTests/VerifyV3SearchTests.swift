import Foundation
import LidarrKit
import MagpieCore
import MatchIndex
import Testing
@testable import Search

/// Verify V3: FLOWS.md §3e (Search) claims that had no test of their own. Fake sources only; the clock is the
/// suite's virtual `TestClock` (no sleeps).
@Suite struct VerifyV3SearchTests {
    let clock = TestClock()

    private func ext(_ artist: String, _ title: String) -> ExternalRecording {
        ExternalRecording(recordingMBID: nil, title: title, artist: artist, source: .listenBrainz)
    }

    /// "It is limited to 10 songs, 8 albums and 5 artists, with one row per artist and title."
    @Test func bandIsCappedAndHasOneRowPerArtistAndTitle() async {
        let songs = (0..<15).map { ext("Artist \($0)", "Song \($0)") }
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(songs: [ext("Ines Morrow", "Harbour Wall"), ext("INES MORROW", "harbour wall")] + songs)
        }
        let lidarr = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(albums: (0..<12).map { NotYetAlbum(title: "Album \($0)", artist: "Someone \($0)") },
                         artists: (0..<9).map { NotYetArtist(name: "Person \($0)") })
        }
        // A second source repeating a song the first one had: still one row.
        let again = MergedSearch.Source(timeout: .seconds(5)) { _ in ExternalHits(songs: [ext("Ines Morrow", "Harbour Wall")]) }
        let clock = self.clock
        let search = MergedSearch(library: { _ in LibrarySearchResult() }, sources: [lb, lidarr, again],
                                  index: { .empty }, sleep: { try await clock.sleep($0) })
        let s = await search.run("x")
        #expect(s.notYet.songs.count == 10 && s.notYet.albums.count == 8 && s.notYet.artists.count == 5)
        #expect(s.notYet.songs.filter { Normalize.name($0.title) == Normalize.name("Harbour Wall") }.count == 1)
        #expect(s.notYet.songs.first?.title == "Harbour Wall", "source order, first one kept")
    }

    /// "An outside hit is dropped when the match index, or the library rows on screen, already have it": with an
    /// empty index (first launch), the library rows on screen are enough.
    @Test func libraryRowsOnScreenDropOutsideHitsWhileTheIndexIsEmpty() async {
        let shown = Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 232)
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(songs: [ExternalRecording(recordingMBID: nil, title: "Harbour Lights", artist: "Corin Hale",
                                                   source: .listenBrainz)])
        }
        let lidarr = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(albums: [NotYetAlbum(title: "Saltwater Hymns", artist: "Corin Hale")],
                         artists: [NotYetArtist(name: "Corin Hale")])
        }
        let clock = self.clock
        let library = LibrarySearchResult(songs: [shown],
                                          albums: [Album(id: "al", name: "Saltwater Hymns", artist: "Corin Hale",
                                                         songCount: 1, duration: 232)],
                                          artists: [Artist(id: "ar", name: "Corin Hale", albumCount: 1)])
        let search = MergedSearch(library: { _ in library }, sources: [lb, lidarr], index: { .empty },
                                  sleep: { try await clock.sleep($0) })
        let s = await search.run("harbour")
        #expect(s.songs == [shown])
        #expect(s.notYet.isEmpty)
    }

    /// "Library rows come first and show as soon as the library answers": `libraryFirst` gets the library's rows
    /// while an outside source is still out; the band follows when it answers.
    @Test func libraryRowsArriveBeforeASlowSource() async throws {
        let shown = Song(id: "lib-1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 232)
        let clock = self.clock
        let slow = MergedSearch.Source(timeout: .seconds(5)) { _ in
            try await clock.sleep(.seconds(4))
            return ExternalHits(songs: [ExternalRecording(recordingMBID: nil, title: "Harbour Wall", artist: "Ines Morrow",
                                                          source: .listenBrainz)])
        }
        let search = MergedSearch(library: { _ in LibrarySearchResult(songs: [shown]) }, sources: [slow],
                                  index: { .empty }, sleep: { try await clock.sleep($0) })
        let early = EarlyBox()
        let task = Task { try await search.runReportingLibraryFailure("harbour") { early.set($0) } }
        for _ in 0..<100_000 where early.value == nil { await Task.yield() }
        #expect(early.value?.songs == [shown])
        #expect(early.value?.notYet.isEmpty == true)
        // The slow source and its deadline are both still waiting on the clock.
        await clock.until(waiting: 2)
        #expect(clock.waiting == 2)
        clock.advance(by: .seconds(4))
        let full = try await task.value
        #expect(full.songs == [shown])
        #expect(full.notYet.songs.map(\.title) == ["Harbour Wall"])
    }
}
