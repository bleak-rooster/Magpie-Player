import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 12 item 2 (Y2): the car's long lists in A–Z letter sections with CarPlay's letter scrubber, and a letters screen
/// first when a list is over the car's item limit.
@Suite struct LetterGroupsTests {
    func artists(_ names: [String]) -> [Artist] {
        names.enumerated().map { Artist(id: "ar\($0.offset)", name: $0.element, albumCount: 1) }
    }

    func titles(_ sections: [CPSectionModel]) -> [[String]] { sections.map { $0.rows.map(\.title) } }

    // MARK: Sectioning

    @Test func artistsComeInOneSectionPerLetterWithIndexTitles() {
        let sections = CarPlayRows.artists(artists(["Cure", "ABBA", "Beatles", "Air"]))
        #expect(sections.map(\.header) == ["A", "B", "C"])
        #expect(sections.map(\.indexTitle) == ["A", "B", "C"])
        #expect(titles(sections) == [["ABBA", "Air"], ["Beatles"], ["Cure"]])
        #expect(sections[0].rows[0].action == .open(.artist(id: "ar1", name: "ABBA")), "under the limit, rows still open")
    }

    /// As the phone's A–Z (W3): artists and albums drop Navidrome's articles; playlists keep them.
    @Test func leadingArticlesAreDroppedLikeThePhone() {
        let sections = CarPlayRows.artists(artists(["The Beatles", "Blur", "Los Lobos", "The"]))
        #expect(sections.map(\.header) == ["B", "L", "T"])
        #expect(titles(sections) == [["The Beatles", "Blur"], ["Los Lobos"], ["The"]], "a name that is only an article keeps it")

        let albums = CarPlayRows.albums([Album(id: "a1", name: "A Night at the Opera", artist: "Queen", songCount: 1, duration: 1),
                                         Album(id: "a2", name: "Abbey Road", artist: "The Beatles", songCount: 1, duration: 1)])
        #expect(albums.map(\.header) == ["A", "N"])

        let playlists = CarPlayRows.playlists([Playlist(id: "p1", name: "The Drive", songCount: 3, duration: 9),
                                               Playlist(id: "p2", name: "Drive", songCount: 3, duration: 9)])
        #expect(playlists.map(\.header) == ["D", "T"])
    }

    /// Digits, symbols, other scripts and blank names file under one "#" section, first (the phone's index order).
    @Test func numbersSymbolsAndOtherScriptsGoUnderHash() {
        let sections = CarPlayRows.artists(artists(["Zed", "2Pac", "おやすみ", "!!!", "Ãngel", ""]))
        #expect(sections.map(\.header) == ["#", "A", "Z"])
        #expect(sections[0].rows.count == 4)
        #expect(sections[0].indexTitle == "#")
        #expect(sections[1].rows.map(\.title) == ["Ãngel"], "diacritics fold")
    }

    @Test func emptyListsStillSayNothingHere() {
        #expect(CarPlayRows.artists([]) == CarPlayRows.state(.empty))
        #expect(CarPlayRows.playlists([]) == CarPlayRows.state(.empty))
    }

    // MARK: Range merging and paging

    /// Letters stay apart while the letters screen fits; when it doesn't, the smallest neighbours merge first.
    @Test func smallNeighbouringLettersMergeIntoRanges() {
        let fits = CarPlayRows.letterGroups([("A", 5), ("B", 4), ("C", 6), ("X", 1), ("Y", 1), ("Z", 1)], maxItems: 12)
        #expect(fits.map(\.title) == ["A", "B", "C", "X", "Y", "Z"])
        let groups = CarPlayRows.letterGroups([("A", 4), ("B", 4), ("C", 1), ("D", 1), ("E", 1), ("F", 2)], maxItems: 4)
        #expect(groups.map(\.title) == ["A", "B", "C–E", "F"])
        #expect(groups.map(\.range) == [0..<4, 4..<8, 8..<11, 11..<13])
    }

    @Test func aLetterOverTheLimitIsPaged() {
        let groups = CarPlayRows.letterGroups([("R", 2), ("S", 30), ("T", 3)], maxItems: 12)
        #expect(groups.map(\.title) == ["R", "S (1 of 3)", "S (2 of 3)", "S (3 of 3)", "T"])
        #expect(groups.map(\.range) == [0..<2, 2..<14, 14..<26, 26..<32, 32..<35])
        #expect(groups.allSatisfy { $0.range.count <= 12 })
    }

    /// The letters screen itself must fit the car's list: when pages alone would overflow it, groups grow instead.
    @Test func theLettersScreenNeverOverflows() {
        let runs = LetterIndexLetters.all.map { ($0, 40) }
        let groups = CarPlayRows.letterGroups(runs, maxItems: 12)
        #expect(groups.count <= 12)
        #expect(groups.first?.range.lowerBound == 0 && groups.last?.range.upperBound == 27 * 40)
        for (a, b) in zip(groups, groups.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound, "no gaps") }
    }

    // MARK: The letters screen

    @Test func overTheLimitTheListOpensWithALettersScreen() throws {
        let names = (0..<3).map { "A\($0)" } + (0..<3).map { "B\($0)" } + ["The Cure", "Zed"]
        let sections = CarPlayRows.artists(artists(names), maxItems: 3, maxSections: 12)
        #expect(sections.count == 1)
        let rows = sections[0].rows
        #expect(rows.map(\.title) == ["A", "B", "C–Z"])
        #expect(rows.map(\.detail) == ["3 artists", "3 artists", "2 artists"])
        guard case .open(.letterGroup(let title, let groupSections)) = rows[2].action else {
            Issue.record("a group opens its list"); return
        }
        #expect(title == "C–Z")
        #expect(groupSections.map(\.header) == ["C", "Z"], "a merged group keeps its letter sections")
        #expect(groupSections.map(\.indexTitle) == ["C", "Z"])
        // D12: the group list is a third screen, so its rows play and never push.
        let cure = try #require(groupSections.first?.rows.first)
        #expect(cure.title == "The Cure" && cure.action == .play(.artistShuffle(id: "ar6")))
        #expect(cure.detail == "Shuffle · 1 album")
    }

    @Test func pagedLettersSayWhereTheyRun() {
        let names = (0..<15).map { String(format: "S%02d", $0) }
        let sections = CarPlayRows.artists(artists(names), maxItems: 12, maxSections: 12)
        #expect(sections[0].rows.map(\.title) == ["S (1 of 2)", "S (2 of 2)"])
        #expect(sections[0].rows.map(\.detail) == ["S00 to S11", "S12 to S14"])
        #expect(Set(sections[0].rows.map(\.id)).count == 2, "stable, distinct ids")
    }

    @Test func tooManyLettersForTheSectionLimitAlsoUseTheLettersScreen() {
        let sections = CarPlayRows.artists(artists(["Abba", "Blur", "Cure", "Doors"]), maxItems: 100, maxSections: 3)
        #expect(sections.flatMap(\.rows).map(\.title) == ["A", "B", "C", "D"])
    }

    @Test func albumAndPlaylistGroupsPlayFromTheirList() {
        let albums = (0..<13).map { Album(id: "al\($0)", name: "Album \($0)", artist: "X", songCount: 1, duration: 1) }
        guard case .open(.letterGroup(_, let albumSections)) = CarPlayRows.albums(albums, maxItems: 12, maxSections: 12)[0]
            .rows[0].action else { Issue.record("albums group"); return }
        #expect(albumSections[0].rows[0].action == .play(.album(id: "al0", shuffled: false)))
        #expect(albumSections[0].rows[0].detail == "X")

        let playlists = (0..<13).map { Playlist(id: "p\($0)", name: "Mix \($0)", songCount: 2, duration: 9) }
        guard case .open(.letterGroup(_, let playlistSections)) = CarPlayRows.playlists(playlists, maxItems: 12,
                                                                                         maxSections: 12)[0]
            .rows[0].action else { Issue.record("playlists group"); return }
        #expect(playlistSections[0].rows[0].action == .play(.playlist(id: "p0")))
    }

    /// Clamping keeps a section's index title (the scrubber stays).
    @Test func clampKeepsIndexTitles() {
        let sections = CarPlayRows.artists(artists(["Abba", "Blur"]))
        #expect(clamp(sections, maxItems: 10, maxSections: 10).map(\.indexTitle) == ["A", "B"])
        let reindexed = sections.map { CPSectionModel(header: $0.header, rows: $0.rows) }
        #expect(needsRebuild(old: reindexed, new: sections), "an index title change reshapes the list")
    }
}

/// "#", then A to Z.
enum LetterIndexLetters {
    static let all = ["#"] + (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }
}
