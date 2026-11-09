import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Playback
import Search
import SwiftUI
import Testing
import UIKit
@testable import Magpie

private let loginJSON = Data(#"""
{"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"jordan"}
"""#.utf8)
private let home = URL(string: "http://192.168.1.2:4533")!

private func ok(_ body: String = "") -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#.utf8)
}

/// One of each kind for "harbour": the server answers whatever it's asked, so a kind search that asked for the other
/// kinds would show them.
private let search3 = ok(#"""
"searchResult3":{"artist":[{"id":"ar1","name":"Harbour Kids","albumCount":2}],
 "album":[{"id":"al1","name":"Harbour Nights","artist":"Corin Hale","artistId":"ar2","songCount":9,"duration":2000}],
 "song":[{"id":"s1","title":"Harbour Lights","artist":"Corin Hale","album":"Saltwater Hymns","duration":232}]}
"""#)

/// Round 24 E (owner, 2026-11-08): the owner caption (D223), a search field per kind (D224), letter section headers
/// (D225) and whole-row search history (D226).
@MainActor @Suite(.serialized) final class R24EListsTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "R24EListsTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "R24EListsTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()
    /// What `search3` answers (a test can swap it).
    let searchBody = OSAllocatedUnfairLock(initialState: search3)

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    func signedInModel() async throws -> AppModel {
        transport.inner.stub(pathSuffix: "/rest/ping", body: ok())
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: loginJSON)
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        let body = searchBody
        transport.inner.stub(pathSuffix: "/rest/search3") { _ in .init(status: 200, body: body.withLock { $0 }) }
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [home], username: "jordan", password: "pw")
        return model
    }

    // MARK: - Owner caption (D223)

    @Test func ownerCaption_hiddenForOwnAndUnknown() {
        #expect(OwnerCaption.text(owner: "jordan", signedInUser: "jordan") == nil, "your own")
        #expect(OwnerCaption.text(owner: "JORDAN", signedInUser: "jordan") == nil, "your own, as Yours compares (D101)")
        #expect(OwnerCaption.text(owner: nil, signedInUser: "jordan") == nil, "unknown")
        #expect(OwnerCaption.text(owner: "", signedInUser: "jordan") == nil, "unknown")
        #expect(OwnerCaption.text(owner: "   ", signedInUser: "jordan") == nil, "blank is unknown")
        #expect(OwnerCaption.text(owner: nil, signedInUser: nil) == nil)
        #expect(OwnerCaption(owner: "jordan", signedInUser: "jordan").text == nil)
        #expect(OwnerCaption(owner: nil, signedInUser: "jordan").accessibilityText == nil)
    }

    @Test func ownerCaption_showsOtherUsersName() {
        #expect(OwnerCaption.text(owner: "sam", signedInUser: "jordan") == "sam")
        #expect(OwnerCaption.text(owner: " sam ", signedInUser: "jordan") == "sam", "shown trimmed")
        #expect(OwnerCaption.text(owner: "sam", signedInUser: nil) == "sam", "not known to be yours")
        let caption = OwnerCaption(owner: "sam", signedInUser: "jordan")
        #expect(caption.text == "sam")
        #expect(caption.accessibilityText == "made by sam")
        #expect(OwnerCaption.symbol == "person")
        // Playlists › All's footer (plan item c), verbatim.
        #expect(PlaylistShow.all.footer == "You see your own and everyone\u{2019}s shared playlists.")
        #expect(PlaylistShow.yours.footer == nil)
    }

    // MARK: - A search field per kind (D224)

    private func searched(_ kind: KindSearchKind, _ query: String = "harbour") async throws
        -> (SearchModel, [URLComponents]) {
        let model = try await signedInModel()
        let search = model.kindSearchModel(kind, sleep: { _ in })
        search.update(query: query)
        await search.settle()
        let asked = transport.inner.requests.compactMap(\.url).filter { $0.path.hasSuffix("/rest/search3") }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        return (search, asked)
    }

    private func count(_ name: String, in c: URLComponents) -> Int? {
        c.queryItems?.first { $0.name == name }?.value.flatMap { Int($0) }
    }

    @Test func artistsSearch_asksServerForArtistsOnly() async throws {
        let (search, asked) = try await searched(.artists)
        #expect(!asked.isEmpty, "search3 asked")
        for c in asked {
            #expect((count("artistCount", in: c) ?? 0) > 0)
            #expect(count("albumCount", in: c) == 0)
            #expect(count("songCount", in: c) == 0)
        }
        #expect(search.phase == .done)
        #expect(search.results.artists.map(\.id) == ["ar1"])
        #expect(search.results.albums.isEmpty && search.results.songs.isEmpty && search.results.top == nil)
        #expect(search.results.notYet.isEmpty, "the library only")
        #expect(KindSearchKind.artists.placeholder == "Search artists")
    }

    @Test func albumsSearch_asksServerForAlbumsOnly() async throws {
        let (search, asked) = try await searched(.albums)
        #expect(!asked.isEmpty)
        for c in asked {
            #expect((count("albumCount", in: c) ?? 0) > 0)
            #expect(count("artistCount", in: c) == 0)
            #expect(count("songCount", in: c) == 0)
        }
        #expect(search.results.albums.map(\.id) == ["al1"])
        #expect(search.results.artists.isEmpty && search.results.songs.isEmpty && search.results.top == nil)
        #expect(KindSearchKind.albums.placeholder == "Search albums")
    }

    @Test func songsSearch_asksServerForSongsOnly() async throws {
        // "x by y" makes splits (title + artist): each still asks for songs only, and none for artists.
        let (search, asked) = try await searched(.songs, "harbour lights corin hale")
        #expect(!asked.isEmpty)
        for c in asked {
            #expect((count("songCount", in: c) ?? 0) > 0)
            #expect(count("artistCount", in: c) == 0)
            #expect(count("albumCount", in: c) == 0)
        }
        #expect(search.results.songs.map(\.id) == ["s1"])
        #expect(search.results.artists.isEmpty && search.results.albums.isEmpty && search.results.top == nil)
        #expect(KindSearchKind.songs.placeholder == "Search songs")
        #expect(KindSearchKind.songs.emptyTitle("x") == "No songs match \u{201C}x\u{201D}.")
        #expect(KindSearchKind.artists.emptyTitle("x") == "No artists match \u{201C}x\u{201D}.")
        #expect(KindSearchKind.albums.emptyTitle("x") == "No albums match \u{201C}x\u{201D}.")
    }

    /// Search's batch size and load-more (Y1): the kind's next batch asks for that kind only.
    @Test func kindSearch_loadsMoreOfItsKindOnly() async throws {
        let model = try await signedInModel()
        let songs = (0..<20).map { #"{"id":"s\#($0)","title":"Harbour \#($0)","artist":"Corin Hale","album":"A","duration":1}"# }
        searchBody.withLock { $0 = ok(#""searchResult3":{"song":[\#(songs.joined(separator: ","))]}"#) }
        let search = model.kindSearchModel(.songs, sleep: { _ in })
        search.update(query: "harbour")
        await search.settle()
        #expect(search.results.hasMore(.songs))
        #expect(!search.results.hasMore(.artists) && !search.results.hasMore(.albums))
        search.loadMore(.songs)
        await search.settleMore()
        let asked = transport.inner.requests.compactMap(\.url).filter { $0.path.hasSuffix("/rest/search3") }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let more = asked.filter { (count("songOffset", in: $0) ?? 0) > 0 }
        #expect(more.first.flatMap { count("songOffset", in: $0) } == 20, "the next batch, from where the first ended")
        for c in more { #expect(count("artistCount", in: c) == 0 && count("albumCount", in: c) == 0) }
    }

    /// The letter list is kept under the results, untouched: clearing shows it again where it was (no read, no jump).
    @Test func kindSearch_clearReturnsToLetterListAtSamePlace() async throws {
        let model = try await signedInModel()
        let titles = LetterIndexAppTests.titles
        let reads = ReadLog()
        let list = PagedLetterList<String>(pageSize: 50, name: { $0 }, id: { $0 },
            read: { offset in
                reads.add(offset)
                let page = Array(titles[min(offset, titles.count)..<min(offset + 50, titles.count)])
                return PagedRead(items: page, next: offset + 50, end: offset + 50 >= titles.count)
            },
            seek: { letter in try await LetterIndex.seek(letter, total: titles.count) { titles.indices.contains($0) ? titles[$0] : nil } })
        await list.load()
        await list.jump(to: "F")
        let place = (list.windowStart, list.scrollRequest, list.items.value, reads.all)
        #expect(place.0 > 0, "jumped into the list")

        let search = model.kindSearchModel(.songs, sleep: { _ in })
        #expect(!KindSearch.showsResults(search), "no query: the letter list")
        search.update(query: "harbour")
        #expect(KindSearch.showsResults(search), "a query: the results, A–Z bar and headers hidden")
        await search.settle()
        #expect(KindSearch.showsResults(search))
        search.update(query: "")
        #expect(!KindSearch.showsResults(search), "cleared: the letter list again")
        #expect(search.results.songs.isEmpty)
        #expect(list.windowStart == place.0)
        #expect(list.scrollRequest == place.1, "no new jump")
        #expect(list.items.value == place.2)
        #expect(reads.all == place.3, "nothing read again")
    }

    /// Offline: the offline catalogue's own filter, that kind only; nothing asked of the server.
    @Test func kindSearch_offlineFiltersCatalogue() async throws {
        let songs = [
            Song(id: "s1", title: "Harbour Lights", artist: "Corin Hale", album: "Saltwater Hymns", duration: 232),
            Song(id: "s2", title: "Low Tide", artist: "Harbour Kids", album: "Harbour Nights", duration: 190),
        ]
        let entries = try songs.map { song in
            let meta = String(decoding: try JSONEncoder().encode(AudioMetadata(song)), as: UTF8.self)
            return try JSONDecoder().decode(AudioEntry.self, from: Data(
                #"{"songId":"\#(song.id)","quality":"original","fileName":"\#(song.id).flac","size":1,"kind":"download","metadata":\#(meta)}"#.utf8))
        }
        let catalog = OfflineCatalog(entries: entries, playlists: [])
        let songsOnly = KindSearch.offline("harbour", kind: .songs, catalog: catalog)
        #expect(Set(songsOnly.songs.map(\.id)) == ["s1", "s2"], "by title, artist or album, as the catalogue filters")
        #expect(songsOnly.artists.isEmpty && songsOnly.albums.isEmpty && songsOnly.top == nil)
        #expect(songsOnly.recentlyPlayed.isEmpty && songsOnly.paging == nil)
        let artistsOnly = KindSearch.offline("harbour", kind: .artists, catalog: catalog)
        #expect(artistsOnly.artists.map(\.name) == ["Harbour Kids"])
        #expect(artistsOnly.songs.isEmpty && artistsOnly.albums.isEmpty)
        let albumsOnly = KindSearch.offline("harbour", kind: .albums, catalog: catalog)
        #expect(albumsOnly.albums.map(\.name) == ["Harbour Nights"], "\"Saltwater Hymns\" is by Corin Hale")
        #expect(albumsOnly.songs.isEmpty && albumsOnly.artists.isEmpty)

        // Through the model, offline: the catalogue, never search3.
        let model = try await signedInModel()
        model.updatePreferences { $0.downloads.offlineMode = .on }
        let before = transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/search3") == true }.count
        let search = model.kindSearchModel(.songs, sleep: { _ in })
        search.update(query: "harbour")
        await search.settle()
        #expect(search.phase == .done)
        #expect(transport.inner.requests.filter { $0.url?.path.hasSuffix("/rest/search3") == true }.count == before)
    }

    // MARK: - Section headers (D225)

    private static func names(_ n: Int) -> [String] {
        (0..<n).map { i in "\(Swift.Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i % 26))))\(i)" }.sorted()
    }

    @Test func sectionHeaders_onlyAbove25WithBar() {
        let sections25 = LetterIndex.sections(Self.names(25), name: { $0 })
        let sections26 = LetterIndex.sections(Self.names(26), name: { $0 })
        #expect(LetterSectionHeader.runs(sections25, itemCount: 25, barShown: true).isEmpty, "25: no headers")
        #expect(!LetterSectionHeader.runs(sections26, itemCount: 26, barShown: true).isEmpty, "26 with the bar")
        #expect(LetterSectionHeader.runs(sections26, itemCount: 26, barShown: false).isEmpty, "no bar: no headers")
        #expect(LetterSectionHeader.runs([], itemCount: 100, barShown: true).isEmpty)
        #expect(LetterSectionHeader.minimumItems == 25)
    }

    @Test func sectionHeaders_matchLetterIndexRuns() async {
        let items = ["1999", "Apple", "Avocado", "Banana"] + (0..<30).map { "Cherry \($0)" } + ["Damson", "おやすみ"]
        let sections = LetterIndex.sections(items, name: { $0 })
        let runs = LetterSectionHeader.runs(sections, itemCount: items.count, barShown: true)
        #expect(runs == sections, "one header per LetterIndex run, the bar's own list")
        #expect(runs.map(\.key) == ["#", "A", "B", "C", "D", "#"])
        #expect(runs.map(\.range) == [0..<1, 1..<3, 3..<4, 4..<34, 34..<35, 35..<36])
        #expect(LetterSectionHeader.label("#") == "#")
        #expect(LetterSectionHeader.accessibilityLabel("C") == "C")

        // A paged list: headers only for the loaded runs.
        let titles = LetterIndexAppTests.titles
        let list = PagedLetterList<String>(pageSize: 150, name: { $0 }, id: { $0 },
            read: { offset in
                let page = Array(titles[min(offset, titles.count)..<min(offset + 150, titles.count)])
                return PagedRead(items: page, next: offset + 150, end: offset + 150 >= titles.count)
            },
            seek: { _ in 0 })
        await list.load()
        let paged = LetterSectionHeader.runs(list.sections, itemCount: list.items.value?.count ?? 0, barShown: true)
        #expect(paged.map(\.key) == ["A", "B"], "only what's loaded (150 of 1,000)")
        #expect(paged.last?.range.upperBound == 150)
    }

    /// Fix round 1 (M3): two "#" runs (digits first, other scripts last) have different header ids.
    @Test func sectionHeaders_twoHashRunsHaveTheirOwnIds() {
        let items = ["1999", "2046"] + (0..<30).map { "Cherry \($0)" } + ["おやすみ"]
        let runs = LetterSectionHeader.runs(LetterIndex.sections(items, name: { $0 }), itemCount: items.count, barShown: true)
        let ids = runs.map(LetterSectionHeader.id)
        #expect(ids == ["letter-header-#-0", "letter-header-C-2", "letter-header-#-32"])
        #expect(Set(ids).count == ids.count)
    }

    /// Fix round 1 (I2): a jump goes to the header of the run that holds the target, never to a row its own sticky
    /// header covers; inside a run, a row (a grid's row) before it; with no headers, the item itself.
    @Test func sectionHeaders_jumpTargetsTheRunsHeader() {
        let items = ["Apple", "Avocado"] + (0..<30).map { "Cherry \($0)" }
        let runs = LetterSectionHeader.runs(LetterIndex.sections(items, name: { $0 }), itemCount: items.count, barShown: true)
        #expect(LetterSectionHeader.scrollTarget(index: 0, runs: runs) == .header("letter-header-A-0"))
        #expect(LetterSectionHeader.scrollTarget(index: 2, runs: runs) == .header("letter-header-C-2"))
        #expect(LetterSectionHeader.scrollTarget(index: 10, runs: runs) == .item(9), "inside a run: the row before")
        #expect(LetterSectionHeader.scrollTarget(index: 3, runs: runs, rowLength: 2) == .header("letter-header-C-2"),
                "a grid's first row of the run: the header")
        #expect(LetterSectionHeader.scrollTarget(index: 10, runs: runs, rowLength: 2) == .item(8), "a grid row before")
        #expect(LetterSectionHeader.scrollTarget(index: 10, runs: []) == .item(10), "no headers: the item")
        #expect(LetterSectionHeader.scrollID(index: 2, runs: runs) { items[$0] } == AnyHashable("letter-header-C-2"))
        #expect(LetterSectionHeader.scrollID(index: 10, runs: []) { items[$0] } == AnyHashable("Cherry 8"))
    }

    /// Fix round 1 (M4): no search field over an empty or failed list; kept while it holds a query.
    @Test func kindSearch_fieldHiddenWithoutItems() {
        #expect(KindSearch.showsField(available: true, query: ""))
        #expect(!KindSearch.showsField(available: false, query: ""))
        #expect(KindSearch.showsField(available: false, query: "x"), "a query can always be cleared")
    }

    /// Controller ruling (fix round 1): every phone A–Z list gets the headers. Each list that shows the A–Z bar lays
    /// its rows out with the letter-run containers (and lands its jumps on the headers).
    @Test func sectionHeaders_everyLetterIndexListUsesThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "App"), includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var lists: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(".letterIndex(available:") else { continue }
            lists.append(file.lastPathComponent)
            #expect(["LetterSectionedRows(", "AlbumLetterGrid(", "SongLetterRows("].contains { source.contains($0) },
                    "\(file.lastPathComponent): an A–Z list without letter headers")
            #expect(source.contains("scrollToLetter("), "\(file.lastPathComponent): a jump that can land under a header")
        }
        #expect(Set(lists).isSuperset(of: ["LibraryLists.swift", "SongsListView.swift", "GenresView.swift",
                                           "DownloadsView.swift"]), "\(lists)")
    }

    // MARK: - Letter jumps on screen (fix round 1, I1 and I2)

    /// 26 letters × 4 rows, A–Z, so "M" is well over a screen down.
    private static let alphabet = (0..<104).map { i in "\(Swift.Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(i / 4))))\(i % 4) row" }

    /// Hosts `content` in an iPhone-sized window and reports header frames (the views' probe) and row frames.
    private func hostJump(_ content: some View, model: AppModel) async throws -> (UIWindow, LayoutLog) {
        let log = LayoutLog()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = NavigationStack { content }
            .environment(model)
            .environment(\.songIsDownloaded, model.songIsDownloaded)
            .magpieTheme(Theme())
            .environment(\.letterLayoutProbe) { id, frame in log.frames[id] = frame }
            .environment(\.jumpLog, log)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        return (window, log)
    }

    /// After a jump to M: M's header sits at the top of the scroll view, and M's first row (when the test can see it)
    /// is wholly below the header, not under it, and on screen. `headerInset`: how far the header's text sits inside its
    /// header (a `List`'s system header cell pads it; a pinned header's own bar is the frame).
    private func expectLanded(_ log: LayoutLog, header: String, row: String?, headerInset: CGFloat = 0,
                              _ what: String) async {
        let landed = await eventually(5) {
            guard let h = log.frames[header], let top = log.frames["viewport"] else { return false }
            return h.minY >= top.minY - 1 && h.minY - top.minY <= headerInset + 1.5
        }
        #expect(landed, "\(what): M's header is not at the top: \(String(describing: log.frames[header])) in \(String(describing: log.frames["viewport"]))")
        if let row, let h = log.frames[header], let view = log.frames["viewport"] {
            let below = await eventually(2) {
                guard let r = log.frames[row] else { return false }
                return r.minY >= h.maxY - 0.5 && r.maxY <= view.maxY
            }
            #expect(below, "\(what): the row \(String(describing: log.frames[row])) is under its header \(h) or off screen")
        }
    }

    @Test(arguments: [JumpHarness.Container.list, .stack])
    func letterJump_landsBelowItsHeader(container: JumpHarness.Container) async throws {
        let model = try await signedInModel()
        let trigger = JumpTrigger()
        let (window, log) = try await hostJump(JumpHarness(container: container, items: Self.alphabet, trigger: trigger),
                                               model: model)
        defer { window.isHidden = true }
        #expect(await eventually(5) { log.frames["letter-header-A-0"] != nil }, "\(container): no headers")
        trigger.letter = "M"
        await expectLanded(log, header: "letter-header-M-48", row: "row-M0 row",
                           headerInset: container == .list ? 16 : 0, "\(container)")
    }

    /// I1: the albums grid with more than 25 albums: a jump to a loaded letter more than a screen below lands on it.
    @Test func albumGrid_jumpToALoadedLetterLandsOnIt() async throws {
        let model = try await signedInModel()
        let trigger = JumpTrigger()
        let albums = Self.alphabet.enumerated().map { i, name in
            Album(id: "al\(i)", name: name, artist: "Corin Hale", songCount: 1, duration: 60)
        }
        let (window, log) = try await hostJump(AlbumJumpHarness(albums: albums, trigger: trigger), model: model)
        defer { window.isHidden = true }
        #expect(await eventually(5) { log.frames["letter-header-A-0"] != nil }, "no headers in the grid")
        #expect(log.frames["letter-header-M-48"] == nil || (log.frames["letter-header-M-48"]?.minY ?? 0) > 874,
                "M starts off screen")
        trigger.letter = "M"
        await expectLanded(log, header: "letter-header-M-48", row: nil, "album grid")
    }

    // MARK: - Whole-row history (D226)

    /// Search's two history lists (the only ones in the app; the car's recents are `CPListItem`s): its recent searches
    /// and, offline, its "Recently played on this phone". Each row is tappable across its whole width: the recent
    /// search's label carries `.contentShape(Rectangle())`; a recently played song is Search's `songRow`, whose
    /// `SongRow` body is full width and shaped itself (round 24, owner item 9). Any new `ForEach(recent…)` list is
    /// held to the same.
    @Test func everyHistoryList_hasContentShape() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appending(path: "App")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "read the app's sources")
        let history = try Regex(#"ForEach\((Array\()?recent"#)
        var blocks = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(history) {
                blocks += 1
                let block = lines[i..<min(i + 10, lines.count)].joined(separator: "\n")
                let shaped = block.contains(".contentShape(Rectangle())")
                    // A song row: `SongRow` makes its whole width tappable itself.
                    || (block.contains("songRow(") && (try? songRowIsShaped(root)) == true)
                #expect(shaped, "\(file.lastPathComponent):\(i + 1): a history row without .contentShape(Rectangle())")
            }
        }
        #expect(blocks >= 2, "Search's recent searches and its recently played songs")
    }

    /// Search's `songRow` labels its button with `SongRow`, and `SongRow`'s own `body` (not just anywhere in its file)
    /// is full width (`.frame(maxWidth: .infinity`) and shaped (`.contentShape(Rectangle())`).
    private func songRowIsShaped(_ root: URL) throws -> Bool {
        let search = try String(contentsOf: root.appending(path: "App/Screens/Search/SearchView.swift"), encoding: .utf8)
        guard let helper = Self.block(after: "private func songRow(", in: search), helper.contains("SongRow(") else {
            return false
        }
        let row = try String(contentsOf: root.appending(path: "Packages/MagpieKit/Sources/DesignSystem/Components/SongRow.swift"),
                             encoding: .utf8)
        guard let body = Self.block(after: "public var body: some View {", in: row) else { return false }
        return body.contains(".contentShape(Rectangle())") && body.contains(".frame(maxWidth: .infinity")
    }

    /// The text of the brace block that opens on the line holding `marker` (counted braces; nil if not found).
    static func block(after marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        var depth = 0, opened = false
        var end = source.endIndex
        for i in source[start.lowerBound...].indices {
            switch source[i] {
            case "{": depth += 1; opened = true
            case "}": depth -= 1
            default: break
            }
            if opened, depth == 0 { end = source.index(after: i); break }
        }
        return opened ? String(source[start.lowerBound..<end]) : nil
    }
}

// MARK: - Jump harnesses (fix round 1, I1 and I2)

/// The letter the harness jumps to (set by the test).
@MainActor @Observable final class JumpTrigger {
    var letter: String?
}

/// Frames on screen, by name: headers (through `letterLayoutProbe`), rows ("row-<name>") and the scroll view
/// ("viewport").
@MainActor final class LayoutLog {
    var frames: [String: CGRect] = [:]
}

extension EnvironmentValues {
    @Entry var jumpLog: LayoutLog?
}

private extension View {
    func logFrame(_ name: String, _ log: LayoutLog?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { log?.frames[name] = $0 }
    }
}

/// An A–Z list as Artists and Playlists lay it out (`List`), or as Genres, Downloads and Songs do (`LazyVStack` with
/// pinned headers), with the bar, and its jumps as the screens make them.
struct JumpHarness: View {
    enum Container: String, CustomStringConvertible, Sendable {
        case list, stack
        var description: String { rawValue }
    }

    let container: Container
    let items: [String]
    let trigger: JumpTrigger
    @Environment(\.jumpLog) private var log

    var body: some View {
        let sections = LetterIndex.sections(items) { $0 }
        ScrollViewReader { proxy in
            Group {
                switch container {
                case .list:
                    List {
                        LetterSectionedRows(items: items, sections: sections, id: \.self) { row($0) }
                    }
                    .listStyle(.plain)
                case .stack:
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            LetterSectionedRows(items: items, sections: sections, id: \.self, pinned: true) { row($0) }
                        }
                    }
                }
            }
            .logFrame("viewport", log)
            .letterIndex(available: Set(sections.map(\.key))) { _ in }
            .onChange(of: trigger.letter) { _, letter in
                guard let letter, let target = LetterIndex.target(letter, in: sections) else { return }
                proxy.scrollToLetter(index: target.range.lowerBound, sections: sections, itemCount: items.count) {
                    items[$0]
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func row(_ name: String) -> some View {
        Text(name)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .logFrame("row-\(name)", log)
    }
}

/// Library › Albums' grid over a list of albums already loaded, jumped as `PagedLetterList` asks (a scroll request).
struct AlbumJumpHarness: View {
    let albums: [Album]
    let trigger: JumpTrigger
    @State private var request: PagedLetterList<Album>.ScrollRequest?
    @Environment(\.jumpLog) private var log

    var body: some View {
        let sections = LetterIndex.sections(albums) { $0.name }
        ScrollViewReader { proxy in
            ScrollView {
                AlbumLetterGrid(albums: albums, sections: sections, scrollRequest: request, proxy: proxy)
            }
            .logFrame("viewport", log)
            .letterIndex(available: Set(sections.map(\.key))) { _ in }
            .onChange(of: trigger.letter) { _, letter in
                guard let letter, let target = LetterIndex.target(letter, in: sections) else { return }
                request = .init(id: albums[target.range.lowerBound].id, token: (request?.token ?? 0) + 1)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [Int] = []
    func add(_ offset: Int) { lock.withLock { offsets.append(offset) } }
    var all: [Int] { lock.withLock { offsets } }
}
