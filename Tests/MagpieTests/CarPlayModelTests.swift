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
        // Finds (D12): a find plays; a not-yet song offers Try in a modal sheet. Neither pushes.
        let finds = CPFindsShelf(newFinds: [CPFind(song: song("n"), daysLeft: 7, isNew: true)],
                                 finds: [CPFind(song: song("f"), daysLeft: 2, isNew: false)])
        walk(CarPlayRows.finds(finds, playingId: nil), depth: 1)
        let outside = ExternalRecording(title: "Elsewhere", artist: "Someone", source: .listenBrainz)
        for row in CarPlayRows.finds(finds, playingId: nil).flatMap(\.rows)
            + CarPlayRows.searchItems(found, notYet: [outside], offer: .next) {
            if case .open = row.action, row.id.hasPrefix("find.") || row.id.hasPrefix("notyet.") {
                Issue.record("\(row.id) pushes")
            }
        }
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
        #expect(CarPlayRows.state(.findsOff).flatMap(\.rows).map(\.title) == ["Finds aren't set up on this iPhone"])
        for state in [CarPlayState.locked, .notSetUp, .outOfReach, .failed, .empty, .findsOff] {
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

/// Task 7.1d: the Finds tab, the system add-to-library button as Keep, and "Try it next" from search (D3, D5, D6,
/// D12). Pure models; the app's side (same shelf, same Keep path, the landing) is in `CarPlayFindsAppTests`.
@Suite struct CarPlayFindsModelTests {
    private func song(_ id: String, artist: String = "Aurora Field", cover: String? = nil) -> Song {
        Song(id: id, title: "Song \(id)", artist: artist, album: "Lowlands", duration: 200, coverArtId: cover)
    }

    private let recording = ExternalRecording(recordingMBID: MBID("c2272a15-8f3a-4cdc-8f32-7e723352d44d")!,
                                              title: "Harbour Lights", artist: "Judie Tzuke", source: .listenBrainz)

    /// New finds, then the finds with days left: round records with a text status and a symbol (D3); a tap plays
    /// from there; nothing pushes (the tab root's rows play, D12).
    @Test func findsTabRows() {
        let shelf = CPFindsShelf(newFinds: [CPFind(song: song("n1", cover: "al-1"), daysLeft: 7, isNew: true)],
                                 finds: [CPFind(song: song("f1"), daysLeft: 3, isNew: false),
                                         CPFind(song: song("f2"), daysLeft: 1, isNew: false),
                                         CPFind(song: song("f3"), daysLeft: 0, isNew: false)])
        let sections = CarPlayRows.finds(shelf, playingId: "f1")
        #expect(sections.map(\.header) == ["New finds", "Finds"])
        let rows = sections.flatMap(\.rows)
        #expect(rows.map(\.id) == ["find.n1", "find.f1", "find.f2", "find.f3"])
        #expect(rows.map(\.detail) == ["New find · Aurora Field", "Find · 3 days left · Aurora Field",
                                       "Find · 1 day left · Aurora Field", "Find · time to decide · Aurora Field"])
        #expect(rows.map(\.statusSymbol) == ["sparkles", "hourglass", "hourglass", "hourglass"])
        #expect(rows.allSatisfy { $0.round }, "finds are records, never sleeves")
        #expect(rows.first?.artworkKey == "al-1")
        #expect(rows.filter(\.playing).map(\.id) == ["find.f1"])
        let all = [song("n1", cover: "al-1"), song("f1"), song("f2"), song("f3")]
        #expect(rows.map(\.action) == (0..<4).map { RowAction.play(.songs(all, startAt: $0)) })

        // Not set up / nothing yet: a row that describes the state.
        #expect(CarPlayRows.finds(nil, playingId: nil).flatMap(\.rows).map(\.title) == ["Finds aren't set up on this iPhone"])
        #expect(CarPlayRows.finds(CPFindsShelf(newFinds: [], finds: []), playingId: nil) == CarPlayRows.state(.empty))
        // Only New finds: no empty Finds section.
        let onlyNew = CarPlayRows.finds(CPFindsShelf(newFinds: shelf.newFinds, finds: []), playingId: nil)
        #expect(onlyNew.map(\.header) == ["New finds"])
        // A find that has been played moves from New finds to Finds: a change of shape (held back while browsed).
        let played = CarPlayRows.finds(CPFindsShelf(newFinds: [], finds: [CPFind(song: song("n1"), daysLeft: 7, isNew: false)]
                                                  + shelf.finds), playingId: nil)
        #expect(needsRebuild(old: sections, new: played))
    }

    /// The system add-to-library button is Keep (D12, CarPlay M1): shown only while the current song is a find that
    /// may be kept; while the Keep runs and after it, selected and disabled.
    @Test func keepButtonOnlyForAKeepableFind() {
        #expect(CPKeepButton.state(songId: nil, mayKeep: false, keeping: [], kept: []) == .hidden)
        #expect(CPKeepButton.state(songId: "lib-1", mayKeep: false, keeping: [], kept: []) == .hidden, "a library song")
        #expect(CPKeepButton.state(songId: "find-1", mayKeep: true, keeping: [], kept: []) == .offered)
        #expect(CPKeepButton.state(songId: "find-1", mayKeep: false, keeping: ["find-1"], kept: []) == .keeping)
        #expect(CPKeepButton.state(songId: "find-1", mayKeep: false, keeping: [], kept: ["find-1"]) == .kept)
        #expect(CPKeepButton.state(songId: "find-2", mayKeep: false, keeping: [], kept: ["find-1"]) == .hidden)
        #expect(CPKeepButton.offered.isShown && CPKeepButton.offered.isEnabled && !CPKeepButton.offered.isSelected)
        #expect(CPKeepButton.keeping.isShown && !CPKeepButton.keeping.isEnabled && CPKeepButton.keeping.isSelected)
        #expect(CPKeepButton.kept.isShown && !CPKeepButton.kept.isEnabled && CPKeepButton.kept.isSelected)
        #expect(!CPKeepButton.hidden.isShown)

        // What Keep says in the car: describes, never instructs (D12), no service names.
        #expect(CPKeepResult.moved.message == "Kept. It's in your library now.")
        #expect(CPKeepResult.keptInPlace.message == "Kept. It'll stay in your Finds folder for now.")
        let all: [CPKeepResult] = [.moved, .keptInPlace, .stillMoving, .changesOff, .notSetUp, .notAFind, .moveFailed,
                                   .needsAttention, .unavailable]
        #expect(all.filter(\.isKept) == [.moved, .keptInPlace, .stillMoving])
        for result in all { describesNeverInstructs(result.message) }
    }

    /// Not-yet songs in the car's search: round art, "Not in your library · Try", and a tap offers Try (no push).
    /// When Try isn't possible here the row only says it's not in the library, and does nothing.
    @Test func searchNotYetRows() {
        let result = LibrarySearchResult(songs: [song("s1")])
        let rows = CarPlayRows.searchItems(result, notYet: [recording], offer: .next)
        #expect(rows.map(\.id) == ["song.0.s1", "notyet.0.c2272a15-8f3a-4cdc-8f32-7e723352d44d"])
        let notYet = rows[1]
        #expect(notYet.title == "Harbour Lights")
        #expect(notYet.detail == "Not in your library · Try · Judie Tzuke")
        #expect(notYet.round && notYet.artworkKey == nil && notYet.statusSymbol == "record.circle")
        #expect(notYet.action == .tryNext(recording))
        let off = CarPlayRows.searchItems(result, notYet: [recording], offer: .unavailable)[1]
        #expect(off.detail == "Not in your library · Judie Tzuke" && off.action == RowAction.none)
        // The recent-search list gets the same rows, in their own section after the library's.
        let list = CarPlayRows.searchResults(result, notYet: [recording], offer: .next, playingId: nil)
        #expect(list.map(\.header) == ["Songs", "Not in your library"])
        #expect(list.last?.rows.first?.action == .tryNext(recording))
        // A long list keeps up to a third for songs not in the library (library first, D4).
        let many = LibrarySearchResult(songs: (0..<20).map { song("s\($0)") })
        let others = (0..<5).map { ExternalRecording(title: "Out \($0)", artist: "Someone", source: .listenBrainz) }
        let fitted = CarPlayRows.fitSearchItems(CarPlayRows.searchItems(many, notYet: others, offer: .next), maxItems: 12)
        #expect(fitted.count == 12)
        #expect(fitted.prefix(8).allSatisfy { $0.id.hasPrefix("song.") } && fitted.suffix(4).allSatisfy { $0.id.hasPrefix("notyet.") })
        let few = CarPlayRows.fitSearchItems(CarPlayRows.searchItems(result, notYet: others, offer: .next), maxItems: 4)
        #expect(few.map(\.id).first == "song.0.s1" && few.count == 4, "room left by the library goes to outside songs")
        #expect(CarPlayRows.fitSearchItems(rows, maxItems: 12) == rows)
        // No outside hits, no band.
        #expect(CarPlayRows.searchItems(result, notYet: [], offer: .next).map(\.id) == ["song.0.s1"])
    }

    /// The action sheet is "Try it next" / "Cancel" (CarPlay H3). Its message says what will happen: next in the
    /// queue (never cutting in), a library mix first when nothing plays, and Patient requests are only asked for.
    @Test func tryItNextSheet() throws {
        let playing = try #require(CarPlayRows.trySheet(recording, offer: .next, playing: true))
        #expect(playing.title == "Harbour Lights")
        #expect(playing.confirm == "Try it next" && CPTrySheet.cancel == "Cancel")
        #expect(playing.message == "By Judie Tzuke. It goes next in your queue once it's here.")
        let idle = try #require(CarPlayRows.trySheet(recording, offer: .next, playing: false))
        #expect(idle.message == "By Judie Tzuke. Songs from your library play until it's here, then it goes next.")
        let ask = try #require(CarPlayRows.trySheet(recording, offer: .ask(intoFinds: true), playing: false))
        #expect(ask.confirm == "Ask for it")
        #expect(ask.message == "By Judie Tzuke. This one is asked for, not played now. It shows up in your Finds when it's home.")
        let askLibrary = try #require(CarPlayRows.trySheet(recording, offer: .ask(intoFinds: false), playing: true))
        #expect(askLibrary.message.hasSuffix("It shows up in your library when it's home."))
        #expect(CarPlayRows.trySheet(recording, offer: .unavailable, playing: false) == nil)
        for sheet in [playing, idle, ask, askLibrary] {
            #expect(sheet.confirm.count <= 16, "CarPlay L4: short action titles")
            describesNeverInstructs(sheet.message)
        }
        for problem in [CPTryProblem.tooMany, .notSetUp, .unavailable, .other] { describesNeverInstructs(problem.message) }
    }

    /// D6 in the car: a find never interrupts something playing. Only a "Try it next" with nothing playing starts the
    /// bridge (Patient requests are only asked for).
    @Test func tryItNextLanding() {
        #expect(CPTryOffer.next.startsBridge(playing: false))
        #expect(!CPTryOffer.next.startsBridge(playing: true))
        #expect(!CPTryOffer.ask(intoFinds: true).startsBridge(playing: false))
        #expect(!CPTryOffer.unavailable.startsBridge(playing: false))
    }

    /// The bridge (CarPlay H3, review D6): library songs only, the artist's first, topped up from the rest of the
    /// library, each song once, finds left out, capped.
    @Test func bridgeMixIsLibraryOnlyArtistFirst() {
        let byArtist = [song("a1", artist: "Judie Tzuke"), song("a2", artist: "Judie Tzuke"), song("a1", artist: "Judie Tzuke")]
        let fill = [song("x1"), song("a2", artist: "Judie Tzuke"), song("find-1"), song("x2")]
        let mix = BridgeMix.songs(artistSongs: byArtist, fill: fill, excluding: ["find-1"], limit: 50, shuffle: { _ in })
        #expect(mix.map(\.id) == ["a1", "a2", "x1", "x2"])
        let capped = BridgeMix.songs(artistSongs: byArtist, fill: fill, excluding: [], limit: 3, shuffle: { _ in })
        #expect(capped.map(\.id) == ["a1", "a2", "x1"])
        // The artist's songs and the fill are shuffled separately: the artist's always come first.
        let shuffled = BridgeMix.songs(artistSongs: byArtist, fill: fill, excluding: ["find-1"], limit: 50,
                                       shuffle: { $0.reverse() })
        #expect(shuffled.map(\.id) == ["a2", "a1", "x2", "x1"])
        #expect(BridgeMix.songs(artistSongs: [], fill: [], excluding: [], limit: 50).isEmpty)
    }

    private func describesNeverInstructs(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let lower = text.lowercased()
        for word in ["tap", "turn on", "go to", "open", "please", "try again", "settings", "lidarr", "navidrome",
                     "listenbrainz"] {
            #expect(!lower.contains(word), "\(text)", sourceLocation: sourceLocation)
        }
    }
}

/// The search template's answers when queries finish out of order.
@Suite struct LatestResultsTests {
    @Test func staleQueryNeverBlanksNewerResults() {
        var gate = LatestResults<String>()
        let a = gate.begin()          // "a" (slow)
        let ab = gate.begin()         // "ab" (fast)
        #expect(gate.complete(ab, with: ["Abba", "Abbey Road"]) == ["Abba", "Abbey Road"])
        // "a" finishes later: it hands back what's showing, not its own results and not [].
        #expect(gate.complete(a, with: ["Adele"]) == ["Abba", "Abbey Road"])
        #expect(gate.delivered == ["Abba", "Abbey Road"])
        #expect(gate.stale() == ["Abba", "Abbey Road"])
    }

    @Test func newestQueryWinsAndClearingIsAllowed() {
        var gate = LatestResults<String>()
        let first = gate.begin()
        #expect(gate.isCurrent(first))
        #expect(gate.complete(first, with: ["x"]) == ["x"])
        let cleared = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.complete(cleared, with: []) == [], "the newest query may show nothing (empty text)")
        #expect(gate.stale() == [])
    }
}
