import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Playback
import Testing
import UIKit
@testable import Magpie

/// A provider of Home's provided sections for tests: answers from `items`, or fails while `failing`.
@MainActor final class FakeHomeShelves: HomeAurralShelves {
    var availableSections: Set<HomeSection>
    var items: [HomeSection: [HomeOutsideItem]] = [:]
    var failing = false
    private(set) var asked: [HomeSection] = []

    init(_ sections: Set<HomeSection>) { availableSections = sections }

    func items(for section: HomeSection, limit: Int) async throws -> [HomeOutsideItem] {
        asked.append(section)
        if failing { throw URLError(.timedOut) }
        return Array((items[section] ?? []).prefix(limit))
    }

    func route(for item: HomeOutsideItem, in section: HomeSection) -> Route? { nil }
    func artwork(for item: HomeOutsideItem, side: CGFloat) async -> UIImage? { nil }
}

private func ok(_ body: String) -> Data {
    Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
}

/// Round 14 A6: the Spotify-style Home. The quick grid, the provided sections in each setup (answer 9), the editor's
/// settings, and round 13's guarantees for the new sections. Stubs only: never the owner's servers.
@MainActor @Suite(.serialized) final class Round14HomeTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "Round14HomeTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "Round14HomeTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = SlowAurralRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var aurral: StubAurral { transport.aurral }

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Signed in to the Navidrome mock; with Aurral connected when `aurral` (the stub).
    func signedIn(aurral withAurral: Bool) async throws -> AppModel {
        nav.install(on: transport.navidrome)
        transport.navidrome.stub(pathSuffix: "/rest/getAlbumList2") { _ in
            let albums = (1...3).map { #"{"id":"al-r\#($0)","name":"Recent \#($0)","artist":"R","songCount":1,"duration":60}"# }
            return .init(status: 200, body: ok(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        if withAurral {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    static let artist = HomeOutsideItem(kind: .artist, key: "mbid-1", title: "Ada Okafor", subtitle: "92% match")
    static let provided: Set<HomeSection> = [.recommended, .newThisWeek, .becauseYouLike, .closeToHome, .furtherOut,
                                             .morePlaylists, .trending, .genreCharts]

    // MARK: Setups (answer 9)

    /// Navidrome only: the Spotify-style Home from the library, complete; no provided section, even with a provider.
    @Test func navidromeOnlyHome() async throws {
        let model = try await signedIn(aurral: false)
        defer { model.signOut() }
        #expect(model.homeSections == [.greeting, .filterChips, .quickAccess, .jumpBackIn, .recentlyAdded, .favourites,
                                       .mostPlayed, .playlists, .genres])
        model.homeAurralShelves = FakeHomeShelves(Self.provided)
        #expect(model.homeOutsideSections.isEmpty, "no Aurral: nothing provided shows")
        #expect(model.homeSections.filter(\.isProvided).isEmpty)
        #expect(HomeAndLibraryView.homeSummary(model) == "9 sections", "missing services don't count")
    }

    /// With Aurral: Your flows shows; the provided sections only once a provider offers them (none ships yet).
    @Test func aurralHomeFollowsTheProvider() async throws {
        let model = try await signedIn(aurral: true)
        defer { model.signOut() }
        #expect(model.homeSections.contains(.discover))
        #expect(model.homeSections.filter(\.isProvided).isEmpty, "the stub provider offers nothing")
        let fake = FakeHomeShelves([.trending, .recommended])
        model.homeAurralShelves = fake
        let shown = model.homeSections
        #expect(shown.filter(\.isProvided) == [.recommended, .trending], "in the default order")
        #expect(HomeAndLibraryView.homeSummary(model) == "12 sections")
        #expect(HomeFilter.offered(for: shown) == [.all, .discover, .recommended, .library])
    }

    /// A provided section is read through the provider, on its own: one failing keeps its last shelf, never takes
    /// another section's place, and Navidrome's sections still show (round 13).
    @Test func providedSectionsReadOnTheirOwn() async throws {
        let model = try await signedIn(aurral: true)
        defer { model.signOut() }
        let fake = FakeHomeShelves([.recommended, .trending])
        fake.items[.recommended] = [Self.artist]
        model.homeAurralShelves = fake
        let read = try await model.homeRead(for: [.recommended, .trending, .quickAccess, .greeting, .filterChips])
        #expect(read.shelves.map(\.section) == [.recommended, .quickAccess], "an empty Trending is left out")
        #expect(read.shelves.first?.items == [.outside(Self.artist)])
        #expect(Set(fake.asked) == [.recommended, .trending], "the greeting and chips read nothing")

        fake.failing = true
        let failed = try await model.homeRead(for: [.recommended, .quickAccess])
        #expect(failed.failed == [.recommended] && failed.shelves.map(\.section) == [.quickAccess])
        var load = HomeLoad()
        let key = HomeLoad.Key.make(sections: [.recommended, .quickAccess], offline: false, onPhone: nil, genres: .defaultValue)
        let first = load.read(for: key, fresh: true)
        load.record(first, for: key, shelves: read.shelves.filter { $0.section != .trending }, failed: [])
        load.record(load.read(for: key, fresh: false), for: key, shelves: failed.shelves, failed: failed.failed)
        #expect(load.found[.recommended]?.items == [.outside(Self.artist)], "the last good copy stays")
        #expect(!load.showsFailure(.recommended))
    }

    /// Provided tiles are saved for launch (no URL), and a saved shelf of the wrong kind is thrown away.
    @Test func providedShelvesAreSaved() throws {
        let cache = HomeShelfCache(root: tmp, scope: "r14")
        let seeded = HomeOutsideItem(kind: .artist, key: "mbid-2", title: "Low", subtitle: nil, artworkKey: "art-2",
                                     group: "Slowdive")
        cache.save([HomeShelf(section: .becauseYouLike, items: [.outside(seeded)]),
                    HomeShelf(section: .trending, items: [.album(Album(id: "a", name: "A", artist: "B", songCount: 1, duration: 0))]),
                    HomeShelf(section: .quickAccess, items: [.album(Album(id: "q", name: "Q", artist: "B", songCount: 1, duration: 0))])])
        let loaded = cache.load()
        #expect(loaded.map(\.section) == [.becauseYouLike, .quickAccess], "an album is no Trending tile")
        #expect(loaded.first?.items == [.outside(seeded)])
        let text = try String(contentsOf: cache.url, encoding: .utf8)
        #expect(!text.contains("http"))
    }

    // MARK: Quick access

    @Test func quickAccessOrdering() {
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        let flow = RecentPlay(kind: .playlist, itemId: "pl-dw", title: "Discover Weekly", playedAt: late)
        let album = RecentPlay(kind: .album, itemId: "al-r2", title: "Recent 2", subtitle: "R", playedAt: early)
        let server = (1...9).map { Album(id: "al-r\($0)", name: "Recent \($0)", artist: "R", songCount: 1, duration: 0) }
        let tiles = QuickAccess.tiles(history: [album, flow], recentAlbums: server, count: 8)
        #expect(tiles.map(\.id) == ["playlist-pl-dw", "album-al-r2", "album-al-r1", "album-al-r3", "album-al-r4",
                                    "album-al-r5", "album-al-r6", "album-al-r7"], "played first, newest first; no repeats")
        #expect(QuickAccess.tiles(history: [], recentAlbums: server, count: 4).count == 4)
        #expect(QuickAccess.tiles(history: [], recentAlbums: [], count: 8).isEmpty)
        var history: [RecentPlay] = []
        for i in 0..<20 { history = QuickAccess.noting(RecentPlay(kind: .album, itemId: "a\(i)", title: "A"), in: history) }
        history = QuickAccess.noting(RecentPlay(kind: .album, itemId: "a5", title: "A"), in: history)
        #expect(history.count == QuickAccess.historyLimit && history.first?.itemId == "a5")
        #expect(history.filter { $0.itemId == "a5" }.count == 1)
        #expect(HomeCopy.quickSubtitle(flow, isFlow: true) == "Flow" && HomeCopy.quickSubtitle(flow, isFlow: false) == "Playlist")
        #expect(HomeCopy.quickSubtitle(album, isFlow: false) == "R")
    }

    /// Playing from a page heads the grid at once, is saved per account, and nothing is saved after sign-out.
    @Test func playsAreRememberedPerAccount() async throws {
        let model = try await signedIn(aurral: false)
        let feed = model.homeFeed
        model.noteRecentlyPlayed(.album(Album(id: "al-r3", name: "Recent 3", artist: "R", songCount: 1, duration: 0)))
        model.noteRecentlyPlayed(.playlist(Playlist(id: "pl-road", name: "Road trip", songCount: 4, duration: 0)))
        #expect(model.quickAccessTiles(recentAlbums: []).map(\.id) == ["playlist-pl-road", "album-al-r3"])
        let scope = try #require(feed.scope)
        #expect(QuickAccessStore(root: tmp, scope: scope).load().map(\.id) == ["playlist-pl-road", "album-al-r3"])
        model.updatePreferences { $0.layout.setStyle(HomeSectionStyle(size: .small, count: 4), for: .quickAccess) }
        let albums = (1...6).map { Album(id: "s\($0)", name: "S", artist: "R", songCount: 1, duration: 0) }
        #expect(model.quickAccessTiles(recentAlbums: albums).count == 4, "the grid's own count")
        model.signOut()
        feed.notePlayed(RecentPlay(kind: .album, itemId: "late", title: "Late"))
        #expect(!FileManager.default.fileExists(atPath: QuickAccessStore(root: tmp, scope: scope).url.path),
                "sign-out removes it, and a late play isn't saved")
    }

    // MARK: Editor

    @Test func editorSettingsPersistAndReset() async throws {
        let model = try await signedIn(aurral: false)
        defer { model.signOut() }
        model.updatePreferences {
            $0.layout.setStyle(HomeSectionStyle(size: .large, count: 6), for: .recentlyAdded)
            $0.layout.becauseYouLikeRows = 2
        }
        #expect(model.preferences.layout.style(for: .recentlyAdded) == HomeSectionStyle(size: .large, count: 6))
        let reread = PreferencesStore(defaults: defaults).load()
        #expect(reread.layout.style(for: .recentlyAdded) == HomeSectionStyle(size: .large, count: 6))
        #expect(reread.layout.becauseYouLikeRows == 2)
        #expect(HomeLayoutCopy.settingsValue(.recentlyAdded, style: HomeSectionStyle(size: .large, count: 6), rows: 2)
                == "Large cards, 6 items")
        #expect(HomeLayoutCopy.settingsValue(.becauseYouLike, style: .init(size: .medium, count: 12), rows: 1)
                == "Medium cards, 12 items, 1 row")
        #expect(HomeLayoutCopy.settingsValue(.quickAccess, style: .init(size: .small, count: 8), rows: 3) == "8 items")
        model.updatePreferences { $0.layout.resetHome() }
        #expect(model.preferences.layout.isDefaultHome)
    }

    /// Sections whose service is missing: greyed with "Needs Aurral"; with it, no note.
    @Test func editorNeedsNotes() {
        #expect(HomeLayoutView.note(.trending, aurralSetUp: false, lidarrConnected: false) == "Needs Aurral")
        #expect(HomeLayoutView.note(.discover, aurralSetUp: false, lidarrConnected: true) == "Needs Aurral")
        #expect(HomeLayoutView.note(.trending, aurralSetUp: true, lidarrConnected: false) == nil)
        #expect(HomeLayoutView.note(.discover, aurralSetUp: true, lidarrConnected: false) == nil)
        #expect(HomeLayoutView.note(.madeForYou, aurralSetUp: false, lidarrConnected: false)
                == "Shows when a ListenBrainz token is saved")
        #expect(HomeLayoutView.note(.jumpBackIn, aurralSetUp: false, lidarrConnected: false) == nil)
        #expect(HomeLayoutView.missing(.greeting, aurralSetUp: false, lidarrConnected: false) == nil)
    }

    // MARK: The page

    @Test func greetingAndRows() {
        #expect(HomeCopy.greeting(hour: 7) == "Good morning")
        #expect(HomeCopy.greeting(hour: 12) == "Good afternoon" && HomeCopy.greeting(hour: 17) == "Good afternoon")
        #expect(HomeCopy.greeting(hour: 18) == "Good evening" && HomeCopy.greeting(hour: 2) == "Good evening")
        func item(_ key: String, _ seed: String?) -> HomeShelf.Item {
            .outside(HomeOutsideItem(kind: .artist, key: key, title: key, group: seed))
        }
        let items = [item("a", "Low"), item("b", "Slowdive"), item("c", "Low"), item("d", nil), item("e", "Cocteau Twins"),
                     item("f", "Beach House")]
        let rows = HomeShelfLayout.becauseYouLikeRows(items, rows: 3)
        #expect(rows.map(\.seed) == ["Low", "Slowdive", "Cocteau Twins"])
        #expect(rows.first?.items.map(\.id) == ["outside-artist-a", "outside-artist-c"])
        #expect(HomeShelfLayout.becauseYouLikeRows(items, rows: 1).map(\.seed) == ["Low"])
        #expect(HomeShelfLayout.becauseYouLikeRows(items, rows: 0).isEmpty)
        #expect(HomeCopy.becauseYouLike("Low") == "Because you like Low")
        #expect(HomeShelfLayout.width(.small) < HomeShelfLayout.width(.medium)
                && HomeShelfLayout.width(.medium) < HomeShelfLayout.width(.large))
    }

    /// No Home copy names Aurral or Lidarr (common rules): the titles, the chips and the greeting.
    @Test func homeCopyNeverNamesTheServices() {
        let copy = HomeSection.allCases.map(\.title) + HomeFilter.allCases.map(\.title)
            + [HomeCopy.greeting(hour: 9), HomeCopy.becauseYouLike("X")]
        #expect(copy.allSatisfy { !$0.contains("Aurral") && !$0.contains("Lidarr") })
    }
}

extension OrderedVisibility where Item == HomeSection {
    /// The phone's Home as build 13 had it by default, with round 14's sections after it, off (so it isn't migrated).
    /// Suites written for build 13's Home (the car's) start from it.
    static var build13: OrderedVisibility<HomeSection> {
        let on: Set<HomeSection> = [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .discover]
        let old: [HomeSection] = [.jumpBackIn, .madeForYou, .recentlyAdded, .mostPlayed, .favourites, .randomAlbums,
                                  .playlists, .genres, .downloaded, .discover]
        return OrderedVisibility((old + HomeSection.allCases.filter { !old.contains($0) }).map {
            .init(item: $0, visible: on.contains($0))
        })
    }
}
