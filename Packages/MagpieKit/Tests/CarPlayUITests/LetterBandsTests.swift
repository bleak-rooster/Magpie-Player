import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 13 items 3 and 4: Artists, Songs and Albums open on five letter groups (A–E, F–J, K–O, P–T, U–Z & #), each with
/// its count; a group's list keeps CarPlay's letter scrubber. Albums start with Newest, and each letter's albums are
/// newest first.
@Suite struct LetterBandsTests {
    static let bandTitles = ["A\u{2013}E", "F\u{2013}J", "K\u{2013}O", "P\u{2013}T", "U\u{2013}Z & #"]

    func artists(_ names: [String]) -> [Artist] {
        names.enumerated().map { Artist(id: "ar\($0.offset)", name: $0.element, albumCount: 1) }
    }

    func album(_ id: String, _ name: String, year: Int? = nil, created: Date? = nil) -> Album {
        Album(id: id, name: name, artist: "X", year: year, songCount: 1, duration: 1, created: created)
    }

    func opened(_ row: CPRowModel) -> (title: String, sections: [CPSectionModel])? {
        if case .open(.letterGroup(let title, let sections)) = row.action { return (title, sections) }
        return nil
    }

    // MARK: Item 3

    /// Always five groups, even for a short list (the over-limit-only letters screen is gone), each with its count.
    @Test func artistsOpenOnFiveGroupsWithCounts() throws {
        let sections = CarPlayRows.artistBands(artists(["Abba", "Blur", "Cure", "Moby", "The Wombats", "2Pac"]))
        #expect(sections.count == 1)
        let rows = sections[0].rows
        #expect(rows.map(\.title) == Self.bandTitles)
        #expect(rows.map(\.detail) == ["3 artists", "No artists", "1 artist", "No artists", "2 artists"])
        #expect(rows[1].action == .none, "an empty group can't be opened")
        #expect(Set(rows.map(\.id)).count == 5)
        let first = try #require(opened(rows[0]))
        #expect(first.title == Self.bandTitles[0])
        #expect(first.sections.map(\.header) == ["A", "B", "C"])
        #expect(first.sections.map(\.indexTitle) == ["A", "B", "C"], "the group's list keeps the letter scrubber")
        #expect(first.sections[0].rows[0].action == .open(.artist(id: "ar0", name: "Abba")))
    }

    /// "The Wombats" files under W (Navidrome's articles), and "#" comes last in U–Z & #.
    @Test func theLastGroupHoldsUToZThenHash() throws {
        let rows = CarPlayRows.artistBands(artists(["The Wombats", "2Pac", "Ultravox", "おやすみ"]))[0].rows
        let last = try #require(opened(rows[4]))
        #expect(last.sections.map(\.header) == ["U", "W", "#"])
        #expect(last.sections[2].rows.map(\.title) == ["2Pac", "おやすみ"])
    }

    @Test func emptyListsSayNothingHere() {
        #expect(CarPlayRows.artistBands([]) == CarPlayRows.state(.empty))
        #expect(CarPlayRows.albumBands([]) == CarPlayRows.state(.empty))
        #expect(CarPlayRows.songBands(CPSongIndex(total: 0, starts: [0, 0, 0, 0, 0, 0])) == CarPlayRows.state(.empty))
    }

    /// A group over the car's item limit is split into pages ("A–E (1 of 3)", first to last), so every item stays
    /// reachable within the depth (D12).
    @Test func aGroupOverTheLimitIsPaged() throws {
        let names = (0..<30).map { String(format: "B%02d", $0) } + ["Moby"]
        let rows = CarPlayRows.artistBands(artists(names), maxItems: 12)[0].rows
        #expect(rows.map(\.title) == ["A\u{2013}E (1 of 3)", "A\u{2013}E (2 of 3)", "A\u{2013}E (3 of 3)"] + Self.bandTitles.dropFirst())
        #expect(rows[0].detail == "B00 to B11")
        #expect(rows[2].detail == "B24 to B29")
        let page = try #require(opened(rows[1]))
        #expect(page.title == "A\u{2013}E (2 of 3)")
        #expect(page.sections.flatMap(\.rows).count == 12)
        #expect(Set(rows.map(\.id)).count == rows.count, "stable, distinct ids")
    }

    /// The group screen itself always fits the car's list: pages grow when there would be too many.
    @Test func theGroupScreenNeverOverflows() {
        let names = (0..<500).map { "Name \($0)" } + (0..<500).map { "Zed \($0)" }
        let rows = CarPlayRows.artistBands(artists(names), maxItems: 6)[0].rows
        #expect(rows.count <= 6)
        #expect(rows.count >= 5)
    }

    // MARK: Item 4: albums

    /// Newest first: by year, then by when the server first listed it; every album, paged like a group.
    @Test func albumsStartWithNewest() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let albums = [album("a1", "Abbey Road", year: 1969), album("a2", "Blue", year: 2024, created: day),
                      album("a3", "Zen", year: 2024, created: day.addingTimeInterval(60)), album("a4", "Moon"),
                      album("a5", "Kid A", year: 2000)]
        let rows = CarPlayRows.albumBands(albums)[0].rows
        #expect(rows.map(\.title) == ["Newest"] + Self.bandTitles)
        #expect(rows[0].detail == "5 albums")
        let newest = try #require(opened(rows[0]))
        #expect(newest.title == "Newest")
        #expect(newest.sections.flatMap(\.rows).map(\.title) == ["Zen", "Blue", "Kid A", "Abbey Road", "Moon"],
                "year, then created; an album without a year last")
        #expect(newest.sections.flatMap(\.rows)[0].detail == "X \u{00B7} 2024")
        #expect(newest.sections.flatMap(\.rows)[0].action == .open(.album(id: "a3", title: "Zen")))
    }

    /// Inside a letter group the albums are still filed by letter, each letter newest first.
    @Test func eachLettersAlbumsAreNewestFirst() throws {
        let albums = [album("a1", "Abbey Road", year: 1969), album("a2", "Aja", year: 1977), album("a3", "Blue", year: 1971),
                      album("a4", "The Bends", year: 1995)]
        let group = try #require(opened(CarPlayRows.albumBands(albums)[0].rows[1]))
        #expect(group.sections.map(\.header) == ["A", "B"])
        #expect(group.sections.map { $0.rows.map(\.title) } == [["Aja", "Abbey Road"], ["The Bends", "Blue"]])
    }

    /// Past 5000 albums the screen says how many it shows (fix round 1's note, kept).
    @Test func aCappedReadSaysHowManyItShows() {
        let albums = (0..<9).map { album("a\($0)", "Album \($0)") }
        let rows = CarPlayRows.albumBands(albums, total: 12)[0].rows
        #expect(rows.last?.title == "Showing 9 of 12")
        #expect(rows.last?.action == RowAction.none)
    }

    // MARK: Item 3: songs (read by offset from the server's title order)

    /// The groups are offset ranges: A–E from A to F, …, U–Z & # from U past Z, then the "#" songs that sort first
    /// (digits) and last (other scripts).
    @Test func songGroupsAreOffsetRanges() throws {
        // 2 "#" first, A–E 10, F–J 0, K–O 5, P–T 3, U–Z 4, then 1 in another script.
        let index = CPSongIndex(total: 25, starts: [2, 12, 12, 17, 20, 24])
        #expect(index.ranges(.aToE) == [2..<12])
        #expect(index.ranges(.fToJ) == [])
        #expect(index.ranges(.uToZ) == [20..<24, 0..<2, 24..<25])
        let rows = CarPlayRows.songBands(index)[0].rows
        #expect(rows.map(\.title) == Self.bandTitles)
        #expect(rows.map(\.detail) == ["10 songs", "No songs", "5 songs", "3 songs", "7 songs"])
        #expect(rows[4].action == .open(.songRange(title: Self.bandTitles[4], ranges: [20..<24, 0..<2, 24..<25])))
    }

    @Test func aSongGroupOverTheLimitIsPagedAcrossItsRanges() {
        let index = CPSongIndex(total: 30, starts: [5, 5, 5, 5, 5, 25])   // 5 "#" first, 20 U–Z, 5 after Z
        let rows = CarPlayRows.songBands(index, maxItems: 12)[0].rows
        let last = rows.suffix(3)
        #expect(last.map(\.title) == ["U\u{2013}Z & # (1 of 3)", "U\u{2013}Z & # (2 of 3)", "U\u{2013}Z & # (3 of 3)"])
        #expect(last.map(\.action) == [
            .open(.songRange(title: "U\u{2013}Z & # (1 of 3)", ranges: [5..<17])),
            .open(.songRange(title: "U\u{2013}Z & # (2 of 3)", ranges: [17..<25, 0..<4])),
            .open(.songRange(title: "U\u{2013}Z & # (3 of 3)", ranges: [4..<5, 25..<30])),
        ])
        #expect(last.map(\.detail) == ["12 songs", "12 songs", "6 songs"])
    }

    /// A page of songs: letter sections in the order read ("#" last in U–Z & #), each song playing the page from it.
    @Test func aSongPageHasLetterSectionsAndPlays() {
        let songs = ["Under", "Zoo", "2 Become 1", "おやすみ"].enumerated().map {
            Song(id: "s\($0.offset)", title: $0.element, artist: "A", album: "B", duration: 60)
        }
        let sections = CarPlayRows.songPage(songs, playingId: "s1")
        #expect(sections.map(\.header) == ["U", "Z", "#"])
        #expect(sections.map(\.indexTitle) == ["U", "Z", "#"])
        let rows = sections.flatMap(\.rows)
        #expect(rows.map(\.playing) == [false, true, false, false])
        #expect(rows[2].action == .play(.songs(songs, startAt: 2)))
        // Round 24 (D231): a page never says "Showing N of M"; the controller pages past the ceiling.
        #expect(!sections.flatMap(\.rows).contains { $0.title.hasPrefix("Showing") })
    }

    /// The index is found by seeks over the server's title order (single-row reads), including the "#" tail.
    @Test func theSongIndexIsReadBySeeks() async throws {
        let titles = ["1999", "Abc", "Bee", "Fox", "Kite", "Pear", "Under", "Zoo", "おやすみ"]
        let index = try await CPSongIndex.read(total: titles.count) { offset in
            titles.indices.contains(offset) ? titles[offset] : nil
        }
        #expect(index == CPSongIndex(total: 9, starts: [1, 3, 4, 5, 6, 8]))
        let unknownTotal = try await CPSongIndex.read(total: nil) { offset in
            titles.indices.contains(offset) ? titles[offset] : nil
        }
        #expect(unknownTotal == index, "without the count header the end is found by seeks too")
    }

    /// Offline the phone's songs are put in the server's order first, so the same index applies.
    @Test func theOfflineOrderMatchesTheServers() {
        let titles = ["おやすみ", "zoo", "The Cat", "Àlbum", "1999", "apple"]
        let sorted = CPSongIndex.titleOrder(titles.enumerated().map { ($0.offset, $0.element) }).map(\.1)
        #expect(sorted == ["1999", "Àlbum", "apple", "The Cat", "zoo", "おやすみ"])
        #expect(CPSongIndex(sortedTitles: sorted) == CPSongIndex(total: 6, starts: [1, 3, 3, 3, 4, 5]))
    }
}
