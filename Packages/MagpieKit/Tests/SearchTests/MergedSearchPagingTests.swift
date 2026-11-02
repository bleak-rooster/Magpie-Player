import Foundation
import MagpieCore
import Testing
@testable import Search

/// Y1: MergedSearch with the paged library (split queries, ranking, load more) and plan item 1.3 (a song query
/// brings its artist and album along).
@Suite struct MergedSearchPagingTests {
    private func merged(_ server: FakeNavidrome) -> MergedSearch {
        MergedSearch(libraryPage: { try await server.search($0) }, sources: [], index: { .empty })
    }

    /// Navidrome's artist search finds nothing for "bloodbuzz the national"; the best song matches title
    /// and artist, so its artist and album are shown as rows too.
    @Test func aSongQueryBringsItsArtistAndAlbum() async throws {
        let server = FakeNavidrome()
        let s = try await merged(server).runReportingLibraryFailure("bloodbuzz the national")
        guard case .song(let top) = s.top else { Issue.record("top is \(String(describing: s.top))"); return }
        #expect(top.id == "s10")
        #expect(s.artists.first?.id == top.artistId && s.artists.first?.name == "The National")
        #expect(s.artists.first?.coverArtId == "ar-" + (top.artistId ?? ""))
        #expect(s.albums.first?.id == top.albumId && s.albums.first?.name == "High Violet")
        #expect(s.artists.count == Set(s.artists.map(\.id)).count)
    }

    /// Only a song that covers both its title and its artist does it; a title-only query doesn't invent rows.
    @Test func aTitleOnlyQueryAddsNothing() async throws {
        let s = try await merged(FakeNavidrome()).runReportingLibraryFailure("bloodbuzz")
        #expect(s.artists.isEmpty && s.albums.isEmpty)
    }

    @Test func libraryFirstAndTheResultCarryPaging() async throws {
        let box = EarlyBox()
        let s = try await merged(FakeNavidrome()).runReportingLibraryFailure("hey", libraryFirst: { box.set($0) })
        #expect(s.paging?.query == "hey")
        #expect(box.value?.paging == s.paging)
        #expect(s.paging?.seen(.songs) == Set(s.songs.map(\.id)))
    }

    @Test func moreAppendsWithoutDuplicatesAndKeepsTheTop() async throws {
        let songs = (0..<26).map { Fixture.song(String(format: "m%03d", $0), "Harbour \($0)", "Corin Hale", "Saltwater") }
        let server = FakeNavidrome(LibrarySearchResult(songs: songs))
        let search = merged(server)
        var s = try await search.runReportingLibraryFailure("harbour")
        let top = s.top
        let paging = try #require(s.paging)
        #expect(s.songs.count == 20 && s.hasMore(.songs))
        let more = try await search.more(.songs, paging: paging)
        s.append(more)
        #expect(s.songs.count == 26 && Set(s.songs.map(\.id)).count == 26)
        #expect(s.top == top)
        #expect(!s.hasMore(.songs) && s.loadedMore(.songs))
        #expect(!s.loadedMore(.albums))
    }

    /// The old string-only library (tests, offline) doesn't page.
    @Test func aStringLibraryDoesntPage() async {
        let s = await MergedSearch(library: { _ in Fixture.all }, sources: [], index: { .empty }).run("beatles")
        #expect(s.paging == nil && !s.hasMore(.songs))
    }

    @Test func outsideSongsAreRanked() async {
        let lb = MergedSearch.Source(timeout: .seconds(5)) { _ in
            ExternalHits(songs: [ExternalRecording(title: "Hey Jude", artist: "Wilson Pickett", source: .listenBrainz),
                                 ExternalRecording(title: "Hey Jude", artist: "The Beatles", source: .listenBrainz)])
        }
        let s = await MergedSearch(library: { _ in LibrarySearchResult() }, sources: [lb], index: { .empty })
            .run("hey jude beatles")
        #expect(s.notYet.songs.map(\.artist) == ["The Beatles", "Wilson Pickett"])
    }
}
