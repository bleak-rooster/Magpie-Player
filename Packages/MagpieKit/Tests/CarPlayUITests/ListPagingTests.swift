import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 24 item 8 (owner, 2026-11-08): the car's lists stopped at the head unit's item ceiling ("Showing N of M").
/// Now every list reaches its end within Apple's limits: Playlists over the ceiling open on the five letter groups
/// (D230), any list still longer than the ceiling is paged with a "More…" row (D231), and a page replaces the one before
/// it, so CarPlay's depth never grows (D232).
@Suite struct ListPagingTests {
    static let bandTitles = ["A\u{2013}E", "F\u{2013}J", "K\u{2013}O", "P\u{2013}T", "U\u{2013}Z & #"]

    func row(_ id: String, _ title: String? = nil) -> CPRowModel {
        CPRowModel(id: id, title: title ?? id, action: .play(.songs([], startAt: 0)))
    }

    func playlist(_ id: String, _ name: String, owner: String? = nil) -> Playlist {
        Playlist(id: id, name: name, songCount: 2, duration: 9, owner: owner)
    }

    /// The link a page's navigation rows open, as data (the controller turns it into a page of the list).
    func link(_ link: CPPageLink) -> RowAction {
        .open(.page(CPPageRef(base: nil, baseTitle: "List", title: link.title(listTitle: "List"), start: link.start)))
    }

    func start(_ row: CPRowModel?) -> Int? {
        if case .open(.page(let ref)) = row?.action { return ref.start }
        return nil
    }

    /// One letter section per `(letter, count)`, its rows "A1", "A2", … filed under the letter (the scrubber's index
    /// title).
    func lettered(_ counts: [(String, Int)]) -> [CPSectionModel] {
        counts.map { key, n in
            CPSectionModel(header: key, rows: (1...n).map { row("\(key)\($0)") }, indexTitle: key)
        }
    }

    // MARK: D230: Playlists get the letter groups over the ceiling

    @Test func carList_playlistsOverCeiling_groupsByLetter() throws {
        let names = (0..<30).map { "\(["Abba", "Blur", "Moby", "Pulp", "Zola"][$0 % 5]) mix \($0)" }
        let lists = names.enumerated().map { playlist("p\($0.offset)", $0.element) }
        let sections = CarPlayRows.playlistBands(lists, maxItems: 12, maxSections: 12)
        #expect(sections.count == 1)
        let rows = sections[0].rows
        #expect(rows.map(\.title) == Self.bandTitles)
        #expect(rows.map(\.detail) == ["12 playlists", "No playlists", "6 playlists", "6 playlists", "6 playlists"])
        guard case .open(.letterGroup(let title, let group)) = rows[0].action else { Issue.record("A–E opens"); return }
        #expect(title == Self.bandTitles[0])
        #expect(group.map(\.header) == ["A", "B"])
        #expect(group.map(\.indexTitle) == ["A", "B"], "the group keeps CarPlay's letter scrubber")
        #expect(group.flatMap(\.rows).count == 12)
    }

    @Test func carList_playlistsUnderCeiling_keepLetterSections() {
        let lists = [playlist("p1", "Drive"), playlist("p2", "Abba gold"), playlist("p3", "2 step")]
        let sections = CarPlayRows.playlistBands(lists, maxItems: 12, maxSections: 12)
        #expect(sections.map(\.header) == ["#", "A", "D"])
        #expect(sections.flatMap(\.rows).map(\.title) == ["2 step", "Abba gold", "Drive"])
        #expect(sections[2].rows[0].action == .open(.playlist(id: "p1", title: "Drive")))
    }

    // MARK: D179 / D223 rule: whose playlist, in the row's detail

    @Test func carList_ownerCaption_onlyOtherPeoplesWhenEveryonesShow() {
        #expect(CarPlayRows.ownerCaption(owner: "alex", signedInUser: "jordan") == "alex")
        #expect(CarPlayRows.ownerCaption(owner: "Jordan", signedInUser: "jordan") == nil, "your own: nothing")
        #expect(CarPlayRows.ownerCaption(owner: nil, signedInUser: "jordan") == nil, "unknown owner: nothing")
        #expect(CarPlayRows.ownerCaption(owner: "  ", signedInUser: "jordan") == nil)
        #expect(CarPlayRows.ownerCaption(owner: "alex", signedInUser: nil) == nil, "Yours (or no user): nothing")

        let lists = [playlist("p1", "Drive", owner: "jordan"), playlist("p2", "Run", owner: "alex"), playlist("p3", "Sea")]
        let all = CarPlayRows.playlistBands(lists, signedInUser: "jordan").flatMap(\.rows)
        #expect(all.map(\.detail) == ["2 songs", "2 songs \u{00B7} alex", "2 songs"])
        let yours = CarPlayRows.playlistBands(lists, signedInUser: nil).flatMap(\.rows)
        #expect(yours.map(\.detail) == ["2 songs", "2 songs", "2 songs"])
    }

    // MARK: D231: "More…" pages

    @Test func carList_groupOverCeiling_pagesWithMore() throws {
        let sections = lettered([("A", 8), ("B", 8), ("F", 8), ("J", 6)])
        let first = clamp(sections, maxItems: 12, maxSections: 12, link: link)
        let rows = first.flatMap(\.rows)
        #expect(rows.count == 12)
        let more = try #require(rows.last)
        #expect(more.title == "More\u{2026}")
        #expect(more.detail == "10 more, B to F", "the next page's size and range")
        #expect(start(more) == 11)
        #expect(first.last?.header == nil && first.last?.indexTitle == nil, "the More… row is apart from the letters")
        #expect(first.dropLast().map(\.indexTitle) == ["A", "B"], "the letter scrubber stays where sections fit")

        let second = clamp(sections, maxItems: 12, maxSections: 12, start: 11, link: link).flatMap(\.rows)
        #expect(second.first?.title == "Previous\u{2026}")
        #expect(second.first?.detail == "A to B")
        #expect(start(second.first) == 0)
        #expect(second.count <= 12)
        guard case .open(.page(let ref)) = second.last?.action else { Issue.record("a third page"); return }
        #expect(ref.title == "F\u{2013}J", "a page of letters is titled with its range")
    }

    /// Rows without letters say their first and last titles, and the page is titled with its place.
    @Test func carList_unletteredPagesNameFirstAndLast() throws {
        let sections = [CPSectionModel(header: nil, rows: (1...25).map { row("r\($0)", "Song \($0)") })]
        let more = try #require(clamp(sections, maxItems: 12, maxSections: 12, link: link).flatMap(\.rows).last)
        #expect(more.detail == "10 more, Song 12 to Song 21")
        guard case .open(.page(let ref)) = more.action else { Issue.record("More… opens a page"); return }
        #expect(ref.title == "List (2 of 3)")
    }

    /// Fix round 1 (M6): a list without a title names its pages "Page 2 of 3", never with a leading space.
    @Test func carList_untitledListPagesAreNamedPageNOfM() {
        let link = CPPageLink(start: 11, count: 10, index: 1, pageCount: 3)
        #expect(link.title(listTitle: "") == "Page 2 of 3")
        #expect(link.title(listTitle: "  ") == "Page 2 of 3")
        #expect(link.title(listTitle: "Mix") == "Mix (2 of 3)")
        #expect(CPPageLink(start: 0, count: 11, index: 0, pageCount: 3).title(listTitle: "Mix") == "Mix")
    }

    /// Fix round 1 (M3): the page holding a row is found again under new limits, with its title.
    @Test func carList_pageHoldingARow_isFoundForNewLimits() throws {
        let sections = [CPSectionModel(header: nil, rows: (0..<30).map { row("r\($0)") })]
        let parked = try #require(CPPager.page(sections, holding: 23, maxItems: 24, maxSections: 12))
        #expect(parked.start == 23 && parked.title(listTitle: "Mix") == "Mix (2 of 2)")
        let driving = try #require(CPPager.page(sections, holding: 23, maxItems: 12, maxSections: 12))
        #expect(driving.start == 21 && driving.title(listTitle: "Mix") == "Mix (3 of 3)")
        let songs = try #require(CPPager.page(rowCount: 30, holding: 3, maxItems: 4, maxSections: 12))
        #expect(songs.start == 3 && songs.count == 2 && songs.title(listTitle: "A\u{2013}E") == "A\u{2013}E (2 of 14)")
        #expect(CPPager.page([], holding: 0, maxItems: 12, maxSections: 12) == nil)
    }

    @Test func carList_noShowingNOfMRow() {
        let sections = [CPSectionModel(header: nil, rows: (0..<300).map { row("r\($0)") })]
        for items in [3, 10, 12, 24] {
            let rows = clamp(sections, maxItems: items, maxSections: 5, link: link).flatMap(\.rows)
            #expect(!rows.contains { $0.title.hasPrefix("Showing") })
            #expect(rows.last?.title == "More\u{2026}")
            #expect(rows.last?.action != RowAction.none, "never a dead row")
        }
    }

    /// Property: following "More…" from the first page visits every row exactly once, each page within the ceiling
    /// (navigation rows and sections counted), and "Previous…" leads back to the page before.
    @Test func carList_everySongReachableThroughMore() {
        var rng = SplitMix64(seed: 0x24F)
        for _ in 0..<400 {
            let sectionCount = Int.random(in: 0...12, using: &rng)
            let sections = (0..<sectionCount).map { s in
                CPSectionModel(header: rng.next() % 3 == 0 ? nil : "S\(s)",
                               rows: (0..<Int.random(in: 0...40, using: &rng)).map { row("s\(s).\($0)") },
                               indexTitle: rng.next() % 2 == 0 ? "S\(s)" : nil)
            }
            let all = sections.flatMap(\.rows).map(\.id)
            let items = Int.random(in: 2...30, using: &rng), groups = Int.random(in: 1...10, using: &rng)
            var seen: [String] = []
            var at = 0, previous: Int?
            var pages = 0
            while true {
                pages += 1
                guard pages <= all.count + 1 else { Issue.record("no end (\(items), \(groups))"); return }
                let page = clamp(sections, maxItems: items, maxSections: groups, start: at, link: link)
                let rows = page.flatMap(\.rows)
                #expect(rows.count <= items, "items \(items)")
                #expect(page.count <= groups, "sections \(groups)")
                #expect(page.allSatisfy { !$0.rows.isEmpty })
                let nav = rows.filter { $0.id.hasPrefix("page.") }
                seen += rows.filter { !$0.id.hasPrefix("page.") }.map(\.id)
                if items >= 3 {
                    #expect(start(nav.first { $0.id == "page.previous" }) == previous, "Previous… goes back a page")
                }
                guard let next = start(nav.first { $0.id == "page.more" }) else { break }
                #expect(next > at)
                previous = at
                at = next
            }
            #expect(seen == all, "every row once, in order (\(items), \(groups))")
        }
    }

    /// A page is found again by its first row when the ceiling changes: the rows around it are laid out for the new
    /// ceiling, and nothing is skipped.
    @Test func carList_ceilingChangeMidSession_rebuildsPages() {
        let sections = [CPSectionModel(header: nil, rows: (0..<40).map { row("r\($0)") })]
        let parked = clamp(sections, maxItems: 24, maxSections: 12, start: 23, link: link).flatMap(\.rows)
        #expect(parked.dropFirst().first?.id == "r23")
        let driving = clamp(sections, maxItems: 12, maxSections: 12, start: 23, link: link).flatMap(\.rows)
        #expect(driving.count <= 12)
        #expect(driving.contains { $0.id == "r23" }, "the page holding the same first row")
        #expect(start(driving.first) != nil && start(driving.last) != nil)
    }

    /// A short list is shown as it is: no navigation rows.
    @Test func carList_underCeiling_isUnchanged() {
        let sections = lettered([("A", 3), ("B", 2)])
        #expect(clamp(sections, maxItems: 12, maxSections: 12, link: link) == sections)
    }

    /// Songs read a page at a time: the breaks for a count alone, as the list's.
    @Test func carList_songPagesBreakByCount() {
        let breaks = CPPager.breaks(rowCount: 30, maxItems: 12, maxSections: 12)
        #expect(breaks == [0..<11, 11..<21, 21..<30])
        #expect(CPPager.breaks(rowCount: 12, maxItems: 12, maxSections: 12) == [0..<12])
        #expect(CPPager.breaks(rowCount: 0, maxItems: 12, maxSections: 12) == [])
    }
}

/// A small seeded generator, so the property test is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
