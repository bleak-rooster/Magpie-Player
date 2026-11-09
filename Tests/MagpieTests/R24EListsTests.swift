import Foundation
import MagpieCore
import MagpieTestSupport
import os
import Playback
import Search
import Testing
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
        (0..<n).map { i in "\(Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i % 26))))\(i)" }.sorted()
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

    // MARK: - Whole-row history (D226)

    /// Every search-history list in the app: its row's label carries `.contentShape(Rectangle())`, so the empty space
    /// beside a short query is part of the button (round 24, owner item 9).
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

    private func songRowIsShaped(_ root: URL) throws -> Bool {
        let source = try String(contentsOf: root.appending(path: "Packages/MagpieKit/Sources/DesignSystem/Components/SongRow.swift"),
                                encoding: .utf8)
        return source.contains(".contentShape(Rectangle())") && source.contains(".frame(maxWidth: .infinity")
    }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [Int] = []
    func add(_ offset: Int) { lock.withLock { offsets.append(offset) } }
    var all: [Int] { lock.withLock { offsets } }
}
