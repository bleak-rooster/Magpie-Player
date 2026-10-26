import CarPlayUI
import MagpieCore
import Testing
import UIKit

/// Pure CarPlay models: list limits, in-place vs rebuild diffing, the depth budget and record art.
@Suite struct CarPlayModelTests {
    private func row(_ id: String, detail: String? = nil, playing: Bool = false,
                     action: RowAction = .none) -> CPRowModel {
        CPRowModel(id: id, title: "Row \(id)", detail: detail, artworkKey: nil, round: false,
                   playing: playing, action: action)
    }

    private func album(_ id: String) -> Album {
        Album(id: id, name: "Album \(id)", artist: "Artist", songCount: 2, duration: 400,
              songs: [song("\(id)-1"), song("\(id)-2")])
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: "Song \(id)", artist: "Artist", album: "Album", duration: 200)
    }

    @Test func clampRespectsLimits() {
        let sections = [CPSectionModel(header: nil, rows: (0..<30).map { row("\($0)") })]
        let clamped = clamp(sections, maxItems: 12, maxSections: 5)
        let rows = clamped.flatMap(\.rows)
        #expect(rows.count == 12)
        // Never truncates silently: the last row says how much is shown, and does nothing.
        #expect(rows.last?.title == "Showing 11 of 30")
        #expect(rows.last?.action == RowAction.none)
        #expect(rows.dropLast().map(\.id) == (0..<11).map { "\($0)" })
    }

    @Test func clampDropsEmptySectionsAndCapsSections() {
        let sections = [
            CPSectionModel(header: "Empty", rows: []),
            CPSectionModel(header: "A", rows: [row("a1"), row("a2")]),
            CPSectionModel(header: "B", rows: [row("b1")]),
            CPSectionModel(header: "C", rows: [row("c1")]),
        ]
        let clamped = clamp(sections, maxItems: 50, maxSections: 2)
        #expect(clamped.map(\.header) == ["A", "B"])
        #expect(clamped.flatMap(\.rows).last?.title == "Showing 2 of 4")

        let fits = clamp(Array(sections.prefix(3)), maxItems: 50, maxSections: 5)
        #expect(fits.flatMap(\.rows).map(\.id) == ["a1", "a2", "b1"])
    }

    @Test func detailChangeIsNotRebuild() {
        let old = [CPSectionModel(header: "Songs", rows: [row("1", detail: "3:41"), row("2")])]
        var new = old
        new[0].rows[0].detail = "Playing"
        new[0].rows[1].playing = true
        new[0].rows[1].action = .open(.albums)
        #expect(!needsRebuild(old: old, new: new))
        #expect(!needsRebuild(old: old, new: old))
    }

    @Test func reorderIsRebuild() {
        let old = [CPSectionModel(header: nil, rows: [row("1"), row("2"), row("3")])]
        let reordered = [CPSectionModel(header: nil, rows: [row("2"), row("1"), row("3")])]
        let added = [CPSectionModel(header: nil, rows: [row("1"), row("2"), row("3"), row("4")])]
        let regrouped = [CPSectionModel(header: nil, rows: [row("1")]),
                         CPSectionModel(header: nil, rows: [row("2"), row("3")])]
        let renamed = [CPSectionModel(header: "Now", rows: [row("1"), row("2"), row("3")])]
        #expect(needsRebuild(old: old, new: reordered))
        #expect(needsRebuild(old: old, new: added))
        #expect(needsRebuild(old: old, new: regrouped))
        #expect(needsRebuild(old: old, new: renamed))
    }

    @Test func depthNeverExceeds() {
        // Tab root (1) → push Albums (2) → push an album (3) → nothing further.
        var nav = CPNavigator()
        #expect(nav.depth == 1)
        let pushedList = nav.push(.albums)
        let pushedAlbum = nav.push(.album(id: "a", title: "A"))
        #expect(pushedList && pushedAlbum)
        #expect(nav.depth == CPNavigator.maxBrowseDepth)
        let pushedFourth = nav.push(.album(id: "b", title: "B"))
        let pushedSearch = nav.push(.search)
        #expect(!pushedFourth && !pushedSearch)
        #expect(nav.depth == 3)
        nav.pop()
        let pushedAfterPop = nav.push(.playlist(id: "p", title: "P"))
        #expect(pushedAfterPop)

        // Screens that can sit at depth 3 offer no further pushes: every row plays (or does nothing).
        let a = album("x")
        let deepest: [[CPSectionModel]] = [
            CarPlayRows.album(a, playingId: nil),
            CarPlayRows.playlist(Playlist(id: "p", name: "P", songCount: 2, duration: 400),
                                 songs: [song("1"), song("2")], playingId: "1"),
            CarPlayRows.artist(Artist(id: "r", name: "R", albumCount: 2), albums: [album("y"), album("z")]),
        ]
        for sections in deepest {
            for row in sections.flatMap(\.rows) {
                if case .open = row.action { Issue.record("depth-3 row \(row.id) pushes") }
            }
        }

        // Walk every push reachable from the tab roots: none goes past depth 3.
        let found = LibrarySearchResult(songs: [song("s")], albums: [a])
        func screen(_ destination: CPDestination) -> [CPSectionModel] {
            switch destination {
            case .playlists: CarPlayRows.playlists([Playlist(id: "p", name: "P", songCount: 1, duration: 9)])
            case .artists: CarPlayRows.artists([Artist(id: "r", name: "R", albumCount: 1)])
            case .albums: CarPlayRows.albums([a])
            case .album: CarPlayRows.album(a, playingId: nil)
            case .playlist: CarPlayRows.playlist(Playlist(id: "p", name: "P", songCount: 1, duration: 9),
                                                 songs: [song("s")], playingId: nil)
            case .artist: CarPlayRows.artist(Artist(id: "r", name: "R", albumCount: 1), albums: [a])
            case .searchResults: CarPlayRows.searchResults(found, playingId: nil)
            case .search: [CPSectionModel(header: nil, rows: CarPlayRows.searchItems(found))]
            }
        }
        func walk(_ sections: [CPSectionModel], depth: Int) {
            for row in sections.flatMap(\.rows) {
                guard case .open(let destination) = row.action else { continue }
                #expect(depth + 1 <= CPNavigator.maxBrowseDepth, "\(row.id) pushes to \(depth + 1)")
                walk(screen(destination), depth: depth + 1)
            }
        }
        let home = CarPlayRows.home(recent: [a], newest: [a], frequent: [a])
        walk(home, depth: 1)
        walk(CarPlayRows.libraryRoot(), depth: 1)
        walk(CarPlayRows.searchRoot(recents: ["glass"], keyboardLimited: false), depth: 1)
    }

    @Test func searchRootDisablesTypingWhileDriving() {
        let parked = CarPlayRows.searchRoot(recents: ["glass"], keyboardLimited: false)
        let driving = CarPlayRows.searchRoot(recents: ["glass"], keyboardLimited: true)
        let typeParked = parked.flatMap(\.rows).first { $0.id == "search.type" }
        let typeDriving = driving.flatMap(\.rows).first { $0.id == "search.type" }
        #expect(typeParked?.action == .open(.search))
        #expect(typeDriving?.action == RowAction.none)
        #expect(typeDriving?.detail == "Unavailable while driving")
        // Same rows either way: the change is applied in place, not by rebuilding the list.
        #expect(!needsRebuild(old: parked, new: driving))
    }

    @Test func statesDescribeNeverInstruct() {
        #expect(CarPlayRows.state(.locked).flatMap(\.rows).map(\.title) == ["Locked until this iPhone is unlocked"])
        #expect(CarPlayRows.state(.notSetUp).flatMap(\.rows).map(\.title) == ["Not set up on this iPhone yet"])
        #expect(CarPlayRows.state(.outOfReach).flatMap(\.rows).map(\.title) == ["Your library is out of reach"])
        for state in [CarPlayState.locked, .notSetUp, .outOfReach, .failed, .empty] {
            for row in CarPlayRows.state(state).flatMap(\.rows) {
                #expect(row.action == RowAction.none)
                let text = (row.title + " " + (row.detail ?? "")).lowercased()
                for word in ["unlock your", "open", "set up magpie", "tap", "go to", "please"] {
                    #expect(!text.contains(word), "\(state): \(text)")
                }
            }
        }
    }

    @Test func playingMarksTheCurrentSong() {
        let rows = CarPlayRows.album(album("x"), playingId: "x-2").flatMap(\.rows)
        #expect(rows.filter(\.playing).map(\.title) == ["Song x-2"])
    }

    @Test func roundArtMasksCornersAndSpindleHole() throws {
        let side = 120.0
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        let record = RoundArt.render(cover, size: CGSize(width: side, height: side))
        #expect(record.size == CGSize(width: side, height: side))
        let cg = try #require(record.cgImage)
        // Redraw into a known RGBA8 layout, then read alpha bytes.
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                .map { $0.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true } ?? false
        }
        #expect(drawn)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }
        let px = Int(side * record.scale)
        #expect(alpha(1, 1) == 0, "corner is transparent")
        #expect(alpha(px / 2, px / 2) == 0, "spindle hole is transparent")
        #expect(alpha(px / 2, px / 2 - px / 4) == 255, "label is opaque")
        #expect(alpha(px / 2, px / 30) == 255, "grooves are opaque")
    }
}
