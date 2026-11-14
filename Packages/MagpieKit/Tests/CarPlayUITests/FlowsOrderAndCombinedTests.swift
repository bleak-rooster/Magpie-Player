import Foundation
import MagpieCore
import Testing
@testable import CarPlayUI

/// Round 27 H (owner, 2026-11-14): "In carplay, there should be a switch in the settings to show aurral playlists/flows
/// and playlists combined" (D300), and another user's flow says whose it is in the car (D299, D233's " · sam").
@Suite struct FlowsOrderAndCombinedTests {
    func playlist(_ id: String, _ name: String, owner: String? = nil) -> Playlist {
        Playlist(id: id, name: name, songCount: 2, duration: 9, owner: owner)
    }

    // MARK: - D300: the combined Playlists list

    /// Your playlists and the flows Discover shows, together A to Z in D230's letter sections; each flow opens as a
    /// playlist does (the adapter gives it its library copies).
    @Test func car_combinedMixesAtoZ() {
        let mine = [playlist("p1", "Road trip", owner: "jordan"), playlist("p2", "Abba gold", owner: "jordan")]
        let flows = [playlist("f1", "Discover Weekly", owner: "aurral"), playlist("f2", "Moody evenings", owner: "aurral")]
        let combined = CarPlayRows.playlistsWithFlows(mine, flows: flows, captions: [:], signedInUser: "jordan")
        #expect(combined.map(\.name) == ["Abba gold", "Discover Weekly", "Moody evenings", "Road trip"])
        let rows = CarPlayRows.playlistBands(combined, signedInUser: "jordan").flatMap(\.rows)
        #expect(rows.map(\.title) == ["Abba gold", "Discover Weekly", "Moody evenings", "Road trip"])
        #expect(rows.map(\.detail) == ["2 songs", "2 songs", "2 songs", "2 songs"],
                "your own flows name nobody, whoever the server says made the playlist")
        #expect(rows[1].action == .open(.playlist(id: "f1", title: "Discover Weekly")))
    }

    /// Another user's flow (shown only with everyone's on, decided by the app) ends " · sam", in All and in Yours; a
    /// flow already in your playlists (D188) is listed once.
    @Test func car_combinedRespectsYoursAndEveryone() {
        let mine = [playlist("p1", "Road trip", owner: "jordan"), playlist("f1", "Discover Weekly", owner: "aurral")]
        let flows = [playlist("f1", "Discover Weekly", owner: "aurral"), playlist("f3", "Late Night", owner: "aurral")]
        let combined = CarPlayRows.playlistsWithFlows(mine, flows: flows, captions: ["f3": "sam"], signedInUser: "jordan")
        #expect(combined.map(\.id) == ["f1", "f3", "p1"], "once each")
        let rows = CarPlayRows.playlistBands(combined, signedInUser: "jordan").flatMap(\.rows)
        #expect(rows.map(\.detail) == ["2 songs", "2 songs \u{00B7} sam", "2 songs"])
    }

    @Test func car_combinedWithNoFlowsIsYourPlaylists() {
        let mine = [playlist("p1", "Road trip", owner: "jordan"), playlist("p2", "Abba gold", owner: "sam")]
        let combined = CarPlayRows.playlistsWithFlows(mine, flows: [], captions: [:], signedInUser: "jordan")
        #expect(Set(combined) == Set(mine))
        #expect(combined.first(where: { $0.id == "p2" })?.owner == "sam", "a playlist's own owner is kept")
    }

    // MARK: - D299: whose flow, in the car's Discover rows

    @Test func carRow_captionOnlyForOthers() {
        let flows = [playlist("f1", "Discover Weekly"), playlist("f3", "Late Night")]
        let rows = CarPlayRows.discover(flows, captions: ["f3": "sam"]).flatMap(\.rows)
        #expect(rows.map(\.detail) == ["2 songs", "2 songs \u{00B7} sam"])
        #expect(CarPlayRows.discover(flows).flatMap(\.rows).map(\.detail) == ["2 songs", "2 songs"], "today's rows")

        let shelf = CPHomeShelf(section: .discover, items: flows.map(CPHomeShelf.Item.playlist), captions: ["f3": "sam"])
        let home = CarPlayRows.home([shelf]).flatMap(\.rows)
        #expect(home.map(\.detail) == ["2 songs", "2 songs \u{00B7} sam"])
        let plain = CarPlayRows.home([CPHomeShelf(section: .discover, items: flows.map(CPHomeShelf.Item.playlist))])
        #expect(plain.flatMap(\.rows).map(\.detail) == ["2 songs", "2 songs"])
    }

    // MARK: - D231 property: the pager still reaches every row of a mixed list

    func link(_ link: CPPageLink) -> RowAction {
        .open(.page(CPPageRef(base: nil, baseTitle: "List", title: link.title(listTitle: "List"), start: link.start)))
    }

    func start(_ row: CPRowModel?) -> Int? {
        if case .open(.page(let ref)) = row?.action { return ref.start }
        return nil
    }

    /// Every row a letter group's list holds, following "More…" pages as the controller does.
    func reachable(_ sections: [CPSectionModel], items: Int, groups: Int) -> [String] {
        var seen: [String] = [], at = 0
        for _ in 0...sections.flatMap(\.rows).count {
            let page = clamp(sections, maxItems: items, maxSections: groups, start: at, link: link)
            seen += page.flatMap(\.rows).filter { !$0.id.hasPrefix("page.") }.map(\.id)
            guard let next = start(page.flatMap(\.rows).first { $0.id == "page.more" }) else { break }
            at = next
        }
        return seen
    }

    @Test func carPagerStillReachesEveryRow() {
        var rng = SplitMix64(seed: 0x27D)
        let words = ["Abba", "blur", "Échos", "Moby", "pulp", "Zola", "2 step", "Ünder", "Kites", "Fjords"]
        for _ in 0..<150 {
            let mineCount = Int.random(in: 0...60, using: &rng), flowCount = Int.random(in: 0...40, using: &rng)
            let mine = (0..<mineCount).map { playlist("p\($0)", "\(words[Int(rng.next() % 10)]) \($0)", owner: "jordan") }
            let flows = (0..<flowCount).map { playlist("f\($0)", "\(words[Int(rng.next() % 10)]) flow \($0)") }
            let captions = Dictionary(uniqueKeysWithValues: flows.filter { _ in rng.next() % 3 == 0 }.map { ($0.id, "sam") })
            let combined = CarPlayRows.playlistsWithFlows(mine, flows: flows, captions: captions, signedInUser: "jordan")
            let items = Int.random(in: 6...24, using: &rng), groups = Int.random(in: 3...12, using: &rng)
            let screen = CarPlayRows.playlistBands(combined, maxItems: items, maxSections: groups, signedInUser: "jordan")
            var seen: [String] = []
            for row in screen.flatMap(\.rows) {
                switch row.action {
                case .open(.letterGroup(_, let sections)): seen += reachable(sections, items: items, groups: groups)
                case .open(.playlist): seen.append(row.id)
                default: break
                }
            }
            let all = Set((mine + flows).map { "playlist.\($0.id)" })
            #expect(Set(seen) == all, "every playlist and flow reachable (\(mineCount)+\(flowCount), \(items)/\(groups))")
            #expect(seen.count == all.count, "each once")
        }
    }
}
