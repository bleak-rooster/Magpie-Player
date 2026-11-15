import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import Playback
import Requests
import Search
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Round 28 S (owner, 2026-11-15): "When you search for a song, when presenting the resulting songs, you should also
/// give the artist name. This is also relevant to albums within search. Obviously for artists you don't need to double
/// up on this information." Every song row in Search reads "Song · <artist>", every album row "Album · <artist>" (an
/// outside album its kind), never blank, with VoiceOver "song by" / "album by" (D338, Q5). Offline, Search lists the
/// downloads only: "Recently played on this phone" goes (D339, Q2). Search is shown with set results in an
/// iPhone-sized window; each row tells the test what it says as it appears (`searchRowProbe`).
@MainActor @Suite(.serialized) final class SearchRowArtistAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "SearchRowArtistAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "SearchRowArtistAppTests.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel(offline: Bool) -> AppModel {
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false,
                             network: FakeNetwork(.wifi), audioFetcher: FakeFetcher())
        model.updatePreferences { $0.downloads.offlineMode = offline ? .on : .off }
        return model
    }

    // MARK: - Fixtures

    private static let corin = "Corin Hale"
    private static let harbour = Song(id: "s-harbour", title: "Harbour Lights", artist: corin, album: "Saltwater Hymns",
                                      duration: 215)
    /// A song whose artist came back blank: "Song", never a dangling " · ".
    private static let blank = Song(id: "s-blank", title: "Untitled Sketch", artist: "  ", album: "Demos", duration: 90)
    private static let glasshouse = Album(id: "al-glass", name: "Glasshouse", artist: corin, songCount: 10, duration: 2400)
    private static let various = Album(id: "al-va", name: "Late Summer", artist: "Various Artists", songCount: 18, duration: 4000)
    private static let lowTide = NotYetAlbum(title: "Low Tide", artist: corin, kind: "EP")
    private static let artist = Artist(id: "ar-corin", name: corin, albumCount: 3)
    private static func recording(_ title: String, artist: String = corin) -> ExternalRecording {
        ExternalRecording(title: title, artist: artist, releaseTitle: "Northern Rooms", duration: 200, source: .lidarr)
    }

    /// What each setup's Search can show (D96–D98): the library alone; with Lidarr its songs and albums not in the
    /// library; with Aurral its albums and artists, and songs the library has that its search didn't list.
    enum Setup: String, CaseIterable, CustomTestStringConvertible {
        case navidromeAlone, lidarr, aurral, all
        var testDescription: String { rawValue }
        var lidarr: Bool { self == .lidarr || self == .all }
        var aurral: Bool { self == .aurral || self == .all }
    }

    private static func sections(_ setup: Setup) -> SearchSections {
        var s = SearchSections(top: .song(harbour), songs: [harbour, blank], artists: [artist], albums: [glasshouse, various])
        if setup.lidarr {
            s.notYet.songs = [recording("Northern Rooms"), recording("Quiet Hours", artist: "")]
            s.notYet.albums = [lowTide]
        }
        if setup.aurral {
            s.notYet.albums += [NotYetAlbum(title: "Salt Roads", artist: "", kind: "Single")]
            s.notYet.artists = [NotYetArtist(name: "Wren Ashby")]
            s.notYet.owned = [OwnedOutsideSong(recording: recording("Tidewater"), songId: "s-tide")]
        }
        return s
    }

    // MARK: - Hosting

    final class RowLog {
        var rows: [String: SearchRowReport] = [:]
        /// What each `SongRow` rendered (by song id), wherever it was built (fix round 1, review M6).
        var songRows: [String: SearchRowReport] = [:]
    }

    /// Shows Search with `sections` for "harbour" in a tall iPhone-wide window (every row on screen) and returns what
    /// the rows said. `prepare` sets the model up first (requests); `typeSize` is the text size.
    private func show(_ sections: SearchSections, offline: Bool = false, typeSize: DynamicTypeSize = .large,
                      prepare: (AppModel) -> Void = { _ in },
                      until expected: Set<String>) async throws -> (RowLog, UIWindow, AppModel) {
        let app = makeModel(offline: offline)
        #expect(app.isOffline == offline, "the model's offline state")   // fix round 1 (review M1)
        prepare(app)
        let model = SearchModel(search: { _, _ in sections }, sleep: { _ in }, debounce: .zero)
        model.update(query: "harbour")
        #expect(await eventually { model.phase == .done }, "the search never finished")
        let log = RowLog()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: typeSize.isAccessibilitySize ? 9000 : 3000)
        let root = NavigationStack { SearchContent(model: model, scope: .constant(.all), depth: 0) }
            .environment(app)
            .environment(\.songIsDownloaded, app.songIsDownloaded)
            .magpieTheme(Theme())
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.searchRowProbe, SearchRowProbeSink { id, row in log.rows[id] = row })
            .environment(\.songRowProbe, SongRowProbeSink { id, detail, label in
                log.songRows[id] = SearchRowReport(detail: detail, label: label)
            })
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        let shown = await eventually { expected.isSubset(of: Set(log.rows.keys)) }
        #expect(shown, "rows shown: \(log.rows.keys.sorted()), expected \(expected.sorted())")
        return (log, window, app)
    }

    private func expectSong(_ log: RowLog, _ id: String, title: String, artist: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let row = log.rows[id]
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        let detail = trimmed.isEmpty ? "Song" : "Song \u{00B7} \(trimmed)"
        let label = trimmed.isEmpty ? "\(title), song" : "\(title), song by \(trimmed)"
        #expect(row?.detail == detail, "\(id) reads \(String(describing: row?.detail))", sourceLocation: sourceLocation)
        #expect(row?.label == label, "\(id) says \(String(describing: row?.label))", sourceLocation: sourceLocation)
    }

    // MARK: - Every song section (D338)

    /// The five places Search shows songs: Top result, Songs, offline Downloads, "Also in your library" and "Not in
    /// your library". Each row's second line is "Song · <artist>" and VoiceOver hears "<title>, song by <artist>".
    enum SongSection: String, CaseIterable, CustomTestStringConvertible {
        case top, songs, offlineDownloads, alsoInYourLibrary, notInYourLibrary
        var testDescription: String { rawValue }
    }

    @Test(arguments: SongSection.allCases)
    func searchRows_everySongSectionUsesTheDetail(_ section: SongSection) async throws {
        let all = Self.sections(.all)
        switch section {
        case .top:
            let (log, window, _) = try await show(all, until: ["search-top"])
            defer { window.isHidden = true }
            expectSong(log, "search-top", title: "Harbour Lights", artist: Self.corin)
        case .songs:
            let (log, window, _) = try await show(all, until: ["search-song-0", "search-song-1"])
            defer { window.isHidden = true }
            expectSong(log, "search-song-0", title: "Harbour Lights", artist: Self.corin)
            expectSong(log, "search-song-1", title: "Untitled Sketch", artist: "")
        case .offlineDownloads:
            // Offline the same songs are the phone's downloads (OfflineSearch's sections carry no top or band).
            let downloads = SearchSections(songs: [Self.harbour, Self.blank], albums: [Self.glasshouse])
            let (log, window, _) = try await show(downloads, offline: true, until: ["search-song-0", "search-song-1"])
            defer { window.isHidden = true }
            expectSong(log, "search-song-0", title: "Harbour Lights", artist: Self.corin)
            expectSong(log, "search-song-1", title: "Untitled Sketch", artist: "")
        case .alsoInYourLibrary:
            let (log, window, _) = try await show(all, until: ["search-owned-s-tide"])
            defer { window.isHidden = true }
            expectSong(log, "search-owned-s-tide", title: "Tidewater", artist: Self.corin)
        case .notInYourLibrary:
            let (log, window, _) = try await show(all, until: ["search-notyet-song-0", "search-notyet-song-1"])
            defer { window.isHidden = true }
            expectSong(log, "search-notyet-song-0", title: "Northern Rooms", artist: Self.corin)
            expectSong(log, "search-notyet-song-1", title: "Quiet Hours", artist: "")
        }
    }

    /// Album rows: "Album · <artist>" (a compilation "Album · Various Artists"), outside ones their kind; a blank
    /// artist leaves just the kind. VoiceOver "<name>, album by <artist>" / "<name>, EP by <artist>".
    @Test func searchRows_albumsNameTheArtist() async throws {
        let ids: Set = ["search-album-al-glass", "search-album-al-va", "search-notyet-album-Low Tide",
                        "search-notyet-album-Salt Roads"]
        let (log, window, _) = try await show(Self.sections(.all), until: ids)
        defer { window.isHidden = true }
        #expect(log.rows["search-album-al-glass"]?.detail == "Album \u{00B7} Corin Hale")
        #expect(log.rows["search-album-al-glass"]?.label == "Glasshouse, album by Corin Hale")
        #expect(log.rows["search-album-al-va"]?.detail == "Album \u{00B7} Various Artists")
        #expect(log.rows["search-notyet-album-Low Tide"]?.detail == "EP \u{00B7} Corin Hale")
        #expect(log.rows["search-notyet-album-Low Tide"]?.label == "Low Tide, EP by Corin Hale")
        #expect(log.rows["search-notyet-album-Salt Roads"]?.detail == "Single")
        #expect(log.rows["search-notyet-album-Salt Roads"]?.label == "Salt Roads, single")
    }

    /// Library › Songs' own search field (D224) keeps the plain artist line: only Search's rows say "Song ·", and the
    /// screen-wide song row text is set nowhere but Search.
    @Test func searchRows_kindSearchFieldUnchanged() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appending(path: "App"), includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "read the app's sources")
        var setters: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".environment(\\.songRowText") { setters.append(file.lastPathComponent) }
            if !file.path.contains("/Screens/Search/") {
                #expect(!source.contains("SearchRowText."), "\(file.lastPathComponent): Search's row text outside Search")
            }
        }
        #expect(setters == ["SearchView.swift"], "\(setters)")
        for name in ["SongsListView.swift", "KindSearchField.swift"] {
            let source = try String(contentsOf: root.appending(path: "App/Screens/Library/\(name)"), encoding: .utf8)
            let rows = source.components(separatedBy: "\n").filter { $0.contains("SongRow(") }
            #expect(!rows.isEmpty && rows.allSatisfy { !$0.contains("detail:") }, "\(name): Library › Songs keeps the artist line")
        }
    }

    // MARK: - Offline search (D339, Q2)

    /// Offline, Search lists the downloads only: a cached song that has played (fetched ahead, not downloaded) is never
    /// listed, and there is no "Recently played on this phone".
    @Test func offlineSearch_downloadsOnly() async throws {
        // A download and a cached song, both played (entries decoded as the store keeps them, as R24EListsTests does).
        func entry(_ id: String, kind: AudioKind) throws -> AudioEntry {
            let song = Song(id: id, title: "Harbour \(id)", artist: Self.corin, album: "Saltwater Hymns", albumId: "al-salt",
                            duration: 60)
            let meta = String(decoding: try JSONEncoder().encode(AudioMetadata(song)), as: UTF8.self)
            return try JSONDecoder().decode(AudioEntry.self, from: Data(
                #"{"songId":"\#(id)","quality":"original","fileName":"\#(id).mp3","size":1,"kind":"\#(kind.rawValue)","lastPlayed":100,"metadata":\#(meta)}"#.utf8))
        }
        let catalog = OfflineCatalog(entries: [try entry("d1", kind: .download), try entry("c1", kind: .cache)], playlists: [])
        #expect(!catalog.recentlyPlayed(matching: "harbour").isEmpty, "precondition: a cached song that played")
        let sections = OfflineSearch(catalog: catalog).sections("harbour")
        #expect(sections.songs.map(\.id) == ["d1"])
        #expect(sections.recentlyPlayed.isEmpty, "Recently played on this phone went (Q2)")

        // Even handed sections with recently played songs, the offline screen lists none of them.
        var handed = SearchSections(songs: [Self.harbour])
        handed.recentlyPlayed = [Song(id: "c1", title: "Harbour c1", artist: Self.corin, album: "", duration: 60)]
        let (log, window, _) = try await show(handed, offline: true, until: ["search-song-0"])
        defer { window.isHidden = true }
        #expect(log.rows.keys.filter { $0.hasPrefix("search-recent") }.isEmpty, "\(log.rows.keys.sorted())")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Screens/Search/SearchView.swift"), encoding: .utf8)
        #expect(!source.contains("header(\"Recently played on this phone\")"), "the section's heading is gone")
        #expect(!source.contains("sections.recentlyPlayed"), "nothing reads the recently played songs")
    }

    // MARK: - Four setups

    /// Each setup's sections, online: every song and album row names its artist (or its kind alone when the artist is
    /// blank); artist rows never repeat it (they aren't song or album rows). What varies per setup (fix round 1, review
    /// M2) is only the sections fed in, the ones that setup's sources can produce (`sections(_:)`): the model isn't
    /// connected to Lidarr or Aurral, because Search's rows don't read the setup, only the sections they're given.
    @Test(arguments: Setup.allCases)
    func fourSetups(_ setup: Setup) async throws {
        let sections = Self.sections(setup)
        var expected: Set = ["search-top", "search-song-0", "search-song-1", "search-album-al-glass", "search-album-al-va"]
        if setup.lidarr { expected.formUnion(["search-notyet-song-0", "search-notyet-song-1", "search-notyet-album-Low Tide"]) }
        if setup.aurral { expected.formUnion(["search-owned-s-tide", "search-notyet-album-Salt Roads"]) }
        let (log, window, _) = try await show(sections, until: expected)
        defer { window.isHidden = true }
        #expect(Set(log.rows.keys) == expected, "\(setup): \(log.rows.keys.sorted())")
        for (id, row) in log.rows {
            let kind = row.detail.components(separatedBy: " \u{00B7} ").first ?? ""
            #expect(["Song", "Album", "EP", "Single"].contains(kind), "\(setup) \(id): \(row.detail)")
            #expect(!row.detail.hasSuffix("\u{00B7} ") && !row.detail.hasSuffix(" \u{00B7}") && !row.detail.isEmpty,
                    "\(setup) \(id): \(row.detail)")
            #expect(row.label.contains(" by ") || !row.detail.contains("\u{00B7}"), "\(setup) \(id): \(row.label)")
        }
    }

    // MARK: - Accessibility sizes (fix round 1: review I1, design H2 and M1)

    private static let longName = "The Extraordinarily Long-Named Midnight Cartographers Ensemble and All Their Friends"

    /// At AX3 the artist line wraps instead of being cut off: each row with a long artist is taller than the same row
    /// with a short one (a one-line limit would make them the same height, the long one cut off with "…").
    @Test func searchRows_artistLineWrapsAtAX3() async throws {
        func song(_ id: String, _ artist: String) -> Song {
            Song(id: id, title: "Harbour Lights", artist: artist, album: "Saltwater Hymns", duration: 215)
        }
        func album(_ id: String, _ artist: String) -> Album {
            Album(id: id, name: "Glasshouse", artist: artist, songCount: 10, duration: 2400)
        }
        var s = SearchSections(songs: [song("s-short", Self.corin), song("s-long", Self.longName)],
                               albums: [album("al-short", Self.corin), album("al-long", Self.longName)])
        s.notYet.albums = [NotYetAlbum(title: "Tide A", artist: Self.corin, kind: "EP"),
                           NotYetAlbum(title: "Tide B", artist: Self.longName, kind: "EP")]
        s.notYet.owned = [OwnedOutsideSong(recording: Self.recording("Tidewater"), songId: "o-short"),
                          OwnedOutsideSong(recording: Self.recording("Tidewater", artist: Self.longName), songId: "o-long")]
        // Fix round 2 (m1): outside albums on their way (`RequestedItemRow`), short and long artist.
        let shortGroup = MBID("00000000-0000-4000-8000-000000000031")!, longGroup = MBID("00000000-0000-4000-8000-000000000032")!
        s.notYet.albums += [NotYetAlbum(title: "Req A", artist: Self.corin, mbid: shortGroup, kind: "EP"),
                            NotYetAlbum(title: "Req B", artist: Self.longName, mbid: longGroup, kind: "EP")]
        let requests = [Self.request(Self.recording("Req A Opener"), state: .searching, releaseGroup: shortGroup),
                        Self.request(Self.recording("Req B Opener"), state: .searching, releaseGroup: longGroup)]
        let pairs = [("search-song-0", "search-song-1"), ("search-album-al-short", "search-album-al-long"),
                     ("search-notyet-album-Tide A", "search-notyet-album-Tide B"),
                     ("search-owned-o-short", "search-owned-o-long"),
                     ("search-requested-album-Req A", "search-requested-album-Req B")]
        let ids = Set(pairs.flatMap { [$0.0, $0.1] })
        let (log, window, _) = try await show(s, typeSize: .accessibility3, prepare: { $0.requests = requests }, until: ids)
        defer { window.isHidden = true }
        func taller(_ pair: (String, String)) -> Bool {
            guard let short = log.rows[pair.0]?.height, let long = log.rows[pair.1]?.height, short > 0 else { return false }
            return long > short + 10
        }
        _ = await eventually { pairs.allSatisfy(taller) }
        for pair in pairs {
            let long = log.rows[pair.1]?.height ?? 0, short = log.rows[pair.0]?.height ?? 0
            #expect(taller(pair), "\(pair.1) (\(long)) isn't taller than \(pair.0) (\(short)): cut off at AX3")
        }
    }


    // MARK: - Rows other views build (fix round 1: review M6, design L4 and M3)

    private static let releaseGroup = MBID("00000000-0000-4000-8000-000000000010")!

    private static func request(_ recording: ExternalRecording, state: RequestState,
                                releaseGroup: MBID? = nil) -> MagpieRequest {
        var r = MagpieRequest(recording: recording, tier: .standard, createdAt: Date(timeIntervalSince1970: 1_900_000_000))
        r.state = state
        if let releaseGroup {
            let other = MBID("00000000-0000-4000-8000-000000000020")!
            r.plan = Plan(recordingMBID: other, releaseGroupMBID: releaseGroup, artistMBID: other, lidarrArtistId: 7,
                          mode: .fallback)
        }
        return r
    }

    /// A ready request in "Not in your library" is the library song in its place (built by `NotYetSongLink`): the
    /// `SongRow` it renders says "Song · <artist>" and "song by" too, through Search's `songRowText`.
    @Test func searchRows_readyRequestBecomesALibrarySongNamingTheArtist() async throws {
        var s = SearchSections()
        s.notYet.songs = [Self.recording("Northern Rooms")]
        let ready = Self.request(Self.recording("Northern Rooms"), state: .ready)
        let landed = Song(id: "landed", title: "Northern Rooms", artist: Self.corin, album: "Northern Rooms", duration: 200)
        let (log, window, app) = try await show(s, prepare: { app in
            app.requests = [ready]
            app.readySongs[ready.id] = landed
        }, until: [])
        defer { window.isHidden = true }
        #expect(RequestLinks.songRow(for: Self.recording("Northern Rooms"), in: app.requests, readySongs: app.readySongs)
                == .library(landed, ready.id), "precondition: the row is the library song")
        #expect(await eventually { log.songRows["landed"] != nil }, "the library song's row never showed")
        #expect(log.songRows["landed"]?.detail == "Song \u{00B7} Corin Hale")
        #expect(log.songRows["landed"]?.label == "Northern Rooms, song by Corin Hale")
    }

    /// A song or album on its way: VoiceOver hears "song by" / "EP by", never the middle dot. Elsewhere (Activity) a
    /// request row keeps "<title>, <artist>".
    @Test func searchRows_requestRowsSayByNotTheDot() async throws {
        let song = Self.request(Self.recording("Northern Rooms"), state: .searching)
        #expect(RequestRow.accessibilityLabel(song, label: nil, screenText: .search) == "Northern Rooms, song by Corin Hale")
        #expect(RequestRow.accessibilityLabel(song, label: nil, screenText: nil) == "Northern Rooms, Corin Hale")
        #expect(RequestRow.accessibilityLabel(song, label: "Mine", screenText: .search) == "Mine")
        #expect(RequestedItemRow.accessibilityLabel(title: "Low Tide", detail: "EP \u{00B7} Corin Hale", label: nil)
                == "Low Tide, EP \u{00B7} Corin Hale")
        #expect(RequestedItemRow.accessibilityLabel(title: "Low Tide", detail: "EP \u{00B7} Corin Hale",
                                                    label: "Low Tide, EP by Corin Hale") == "Low Tide, EP by Corin Hale")

        // In Search, the album on its way gets the "EP by" label.
        var s = SearchSections()
        s.notYet.albums = [NotYetAlbum(title: "Low Tide", artist: Self.corin, mbid: Self.releaseGroup, kind: "EP")]
        let album = Self.request(Self.recording("Low Tide Opener"), state: .searching, releaseGroup: Self.releaseGroup)
        let (log, window, _) = try await show(s, prepare: { $0.requests = [album] },
                                              until: ["search-requested-album-Low Tide"])
        defer { window.isHidden = true }
        #expect(log.rows["search-requested-album-Low Tide"]?.label == "Low Tide, EP by Corin Hale")
        #expect(log.rows["search-requested-album-Low Tide"]?.detail == "EP \u{00B7} Corin Hale")
    }
}
