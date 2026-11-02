import Foundation
import MagpieCore
import Testing
@testable import Search

private func describe(_ item: SearchItem?) -> String {
    switch item {
    case .song(let s): "song:\(s.title)|\(s.artist)"
    case .album(let a): "album:\(a.name)|\(a.artist)"
    case .artist(let a): "artist:\(a.name)"
    case nil: "none"
    }
}

/// Y1 (plan item 1): field-aware ranking. Every row ranks the whole fixture library for a real-world query and names
/// the Top result it must pick.
@Suite struct SearchRankerTests {
    static let table: [(query: String, top: String)] = [
        ("hey jude beatles", "song:Hey Jude|The Beatles"),
        ("beatles hey jude", "song:Hey Jude|The Beatles"),
        ("the beatles hey jude", "song:Hey Jude|The Beatles"),
        ("Hey Jude - The Beatles", "song:Hey Jude|The Beatles"),
        ("hey jude wilson pickett", "album:Hey Jude|Wilson Pickett"),  // his album has the same name: a tie, album first
        ("hey jude", "album:Hey Jude|Wilson Pickett"),               // an exact name: album before song, as before
        ("the national bloodbuzz", "song:Bloodbuzz Ohio|The National"),
        ("national bloodbuzz", "song:Bloodbuzz Ohio|The National"),
        ("bloodbuzz ohio the national", "song:Bloodbuzz Ohio|The National"),
        ("the national", "artist:The National"),
        ("national", "artist:The National"),                          // the article is optional
        ("national anthem", "song:National Anthem|Radiohead"),
        ("radiohead national", "song:National Anthem|Radiohead"),
        ("beatels hey jude", "song:Hey Jude|The Beatles"),            // typo in the artist
        ("hey jued beatles", "song:Hey Jude|The Beatles"),            // swapped letters in the title
        ("bohemian rapsody", "song:Bohemian Rhapsody|Queen"),
        ("quen bohemian", "song:Bohemian Rhapsody|Queen"),
        ("sigur ros hoppipolla", "song:Hoppípolla|Sigur Rós"),        // diacritics folded
        ("HOPPÍPOLLA", "song:Hoppípolla|Sigur Rós"),
        ("bjork joga", "song:Jóga|Björk"),
        ("beyonce halo", "song:Halo|Beyoncé"),
        ("мумий тролль владивосток", "song:Владивосток 2000|Мумий Тролль"),
        ("владивосток", "song:Владивосток 2000|Мумий Тролль"),
        ("戦場", "song:戦場のメリークリスマス|坂本龍一"),
        ("坂本 戦場", "song:戦場のメリークリスマス|坂本龍一"),
        ("坂本龍一", "artist:坂本龍一"),
        ("daft punk around the world", "song:Around the World|Daft Punk"),
        ("skinny love bon iver", "song:Skinny Love|Bon Iver"),
        ("bon iver skinny", "song:Skinny Love|Bon Iver"),
        ("sweet child o mine guns n roses", "song:Sweet Child o' Mine|Guns N' Roses"),
        ("acdc highway", "album:Highway to Hell|AC/DC"),
        ("ac/dc", "artist:AC/DC"),
        ("the the", "artist:The The"),
        ("yesterday beatles", "song:Yesterday|The Beatles"),
        ("radiohead", "artist:Radiohead"),
        ("ok computer", "album:OK Computer|Radiohead"),
        ("olafur arnalds saman", "song:Saman|Ólafur Arnalds"),
        ("stand by me", "song:Stand by Me|Ben E. King"),
        ("help beatles", "album:Help!|The Beatles"),
        ("aurora lowlands", "album:Lowlands|Aurora Field"),
    ]

    @Test(arguments: table)
    func topResult(query: String, top: String) {
        let s = SearchSections.library(Fixture.all, query: query)
        #expect(describe(s.top) == top, "query \"\(query)\"")
    }

    /// A song covering every word (title + artist) beats one covering only the title, and a plain title beats the same
    /// title with an aside.
    @Test func songsCoveringTitleAndArtistComeFirst() {
        let s = SearchSections.library(Fixture.all, query: "hey jude beatles")
        #expect(s.songs.prefix(3).map(\.id) == ["s04", "s02", "s01"])
        #expect(s.artists.first?.name == "The Beatles")
    }

    /// The same scorer orders every section; ties keep the server's order.
    @Test func sectionsAreOrderedByTheSameScore() {
        let s = SearchSections.library(Fixture.all, query: "beatles")
        #expect(describe(s.top) == "artist:The Beatles")
        #expect(s.artists.first?.name == "The Beatles")
        // Every Beatles song covers the one word; they keep the server's order.
        #expect(s.songs.prefix(5).map(\.id) == ["s02", "s03", "s04", "s06", "s07"])
    }

    @Test func scoresCompareCoverageFirst() {
        let q = SearchRanker.Query("hey jude beatles")
        let full = SearchRanker.score(Fixture.songs[3], q)         // Hey Jude, The Beatles
        let titleOnly = SearchRanker.score(Fixture.songs[0], q)    // Hey Jude, Wilson Pickett
        #expect(full.covered == 3 && titleOnly.covered == 2)
        #expect(full > titleOnly)
        #expect(full.usesTitleAndArtist && !titleOnly.usesTitleAndArtist)
    }

    @Test func nameMatchesAllowsTyposArticlesAndUnspacedScripts() {
        #expect(SearchRanker.nameMatches("The Beatles", "beatels"))
        #expect(SearchRanker.nameMatches("The Beatles", "the beatles"))
        #expect(SearchRanker.nameMatches("The Beatles", "beat"))
        #expect(!SearchRanker.nameMatches("Wilson Pickett", "beatles"))
        #expect(SearchRanker.nameMatches("Sigur Rós", "sigur ros"))
        #expect(SearchRanker.nameMatches("坂本龍一", "坂本"))
        #expect(!SearchRanker.nameMatches("Queen", "qu een x"))
        #expect(SearchRanker.nameMatches("AC/DC", "acdc"))
    }

    /// Outside results go through the same ranker (a stable sort: equal scores keep the source's order).
    @Test func outsideRowsAreRanked() {
        let lb = [ExternalRecording(title: "Hey Jude", artist: "Wilson Pickett", source: .listenBrainz),
                  ExternalRecording(title: "Hey Jude", artist: "The Beatles", source: .listenBrainz)]
        let ranked = SearchRanker.rank(lb, SearchRanker.Query("hey jude beatles"), SearchRanker.score(recording:_:))
        #expect(ranked.map(\.artist) == ["The Beatles", "Wilson Pickett"])
    }
}
