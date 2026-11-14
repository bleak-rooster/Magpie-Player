import AurralKit
import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Search
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Aurral (stub) for its host, Navidrome (mock) for the rest; `search3` can be held to show the 5 s deadline.
final class ArtistLinkRouting: HTTPTransport, @unchecked Sendable {
    let aurral = StubAurral()
    let navidrome = MockTransport()
    private let lock = NSLock()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var listed: [(id: String, name: String, mbid: String?, library: Int)] = []

    /// The artists `search3` lists, and the library each is in.
    var artists: [(id: String, name: String, mbid: String?, library: Int)] {
        get { lock.withLock { listed } }
        set { lock.withLock { listed = newValue } }
    }

    func hold(_ on: Bool) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = on
            guard !on else { return [] }
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.host == aurral.host { return try await aurral.send(request) }
        if request.url?.path.hasSuffix("/rest/search3") == true, lock.withLock({ holding }) {
            await withCheckedContinuation { continuation in
                let wait = lock.withLock { () -> Bool in
                    guard holding else { return false }
                    held.append(continuation)
                    return true
                }
                if !wait { continuation.resume() }
            }
        }
        return try await navidrome.send(request)
    }
}

/// Round 27 D2 (owner items 4 and 5, 2026-11-14, D315): "Artists in this playlist" open the artist's page (the library
/// page by MusicBrainz id or one same-named artist in the listed libraries, else the outside page), and each row's Add
/// says "Add" on one line with VoiceOver's full label unchanged.
@MainActor @Suite(.serialized) final class DiscoverArtistsLinkAppTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "DiscoverArtistsLinkAppTests-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let suite = "DiscoverArtistsLinkAppTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let transport = ArtistLinkRouting()
    let nav = DiscoverNavidrome()
    let aurralStore = MemoryAurralStore()
    var artists: [(id: String, name: String, mbid: String?, library: Int)] {
        get { transport.artists }
        set { transport.artists = newValue }
    }

    static let lowMbid = "4ad9b3a4-8a3a-4c7f-8b0f-6b7e6f2c0a11"
    static let otherMbid = "5bd0c4b5-9b4b-4d8f-9c1f-7c8f7f3d1b22"

    deinit {
        store.clear()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    var aurral: StubAurral { transport.aurral }

    nonisolated private static func ok(_ body: String) -> Data {
        Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
    }

    func signedIn(aurralSetUp: Bool = true, lidarr: Bool = false) async throws -> AppModel {
        // Registered first, so it answers `search3` (artists only; the scoped libraries as Navidrome would).
        let transport = self.transport
        transport.navidrome.stub(pathSuffix: "/rest/search3") { r in
            let items = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let folders = Set(items.filter { $0.name == "musicFolderId" }.compactMap { $0.value.flatMap(Int.init) })
            let rows = transport.artists
                .filter { folders.isEmpty || folders.contains($0.library) }
                .map { a in #"{"id":"\#(a.id)","name":"\#(a.name)","albumCount":1\#(a.mbid.map { #","musicBrainzId":"\#($0)""# } ?? "")}"# }
            return .init(status: 200, body: Self.ok(#""searchResult3":{"artist":[\#(rows.joined(separator: ","))]}"#))
        }
        nav.install(on: transport.navidrome)
        aurral.setFlows([.init(id: "flow-dw", name: "Discover Weekly")])
        aurral.setJobs([
            .init(flowId: "flow-dw", artistName: "Low", trackName: "Lullaby", artistMbid: Self.lowMbid,
                  trackMbid: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", durationMs: 251_000,
                  finalPath: "/data/downloads/aurral/_flows/flow-dw/Low/Single/Lullaby.flac"),
        ])
        let lidarrStore = MemoryLidarrStore()
        if lidarr { try lidarrStore.save(LidarrConnection(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "test-key")) }
        let model = AppModel(store: store, lidarrStore: lidarrStore, tokenStore: MemoryTokenStore(),
                             aurralStore: aurralStore, matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "admin", password: "pw")
        await model.refreshMusicFolders()
        if aurralSetUp {
            _ = try await model.connectAurral(base: aurral.base, username: StubAurral.defaultUsername,
                                              password: StubAurral.defaultPassword)
        }
        return model
    }

    private var searches: [URLRequest] {
        transport.navidrome.requests.filter { $0.url?.path.hasSuffix("/rest/search3") == true }
    }

    private func outside(_ name: String, _ mbid: String?) -> Route {
        .outsideArtist(NotYetArtist(name: name, mbid: mbid.flatMap(MBID.init)))
    }

    // MARK: - Where a row goes

    @Test func artistRow_opensLibraryPageByMBID() async throws {
        artists = [(id: "ar-low-2", name: "LOW (band)", mbid: Self.lowMbid, library: 1),
                   (id: "ar-low", name: "Low", mbid: Self.otherMbid, library: 1)]
        let model = try await signedIn()
        defer { model.signOut() }
        let route = await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid)))
        #expect(route == .artist(id: "ar-low-2"), "the same MusicBrainz id, whatever the name")
        let asked = try #require(searches.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        #expect(asked.first { $0.name == "query" }?.value == "Low")
        #expect(asked.first { $0.name == "artistCount" }?.value == "10")
        #expect(asked.first { $0.name == "songCount" }?.value == "0" && asked.first { $0.name == "albumCount" }?.value == "0")
    }

    @Test func artistRow_opensLibraryPageByUniqueName() async throws {
        artists = [(id: "ar-low", name: "  lów ", mbid: nil, library: 1), (id: "ar-lower", name: "Lower", mbid: nil, library: 1)]
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: nil)) == .artist(id: "ar-low"))
        // With an id the library row doesn't carry, one same-named artist is still them.
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid))) == .artist(id: "ar-low"))
    }

    @Test func artistRow_twoSameNamesOpensOutside() async throws {
        artists = [(id: "ar-low-1", name: "Low", mbid: nil, library: 1), (id: "ar-low-2", name: "low", mbid: nil, library: 1)]
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: nil)) == outside("Low", nil))
        // A same-named artist with another MusicBrainz id is someone else.
        artists = [(id: "ar-low-1", name: "Low", mbid: Self.otherMbid, library: 1)]
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid)))
                == outside("Low", Self.lowMbid))
    }

    @Test func artistRow_notInLibraryOpensOutside() async throws {
        artists = [(id: "ar-q", name: "Q", mbid: nil, library: 1)]
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Nobody", mbid: MBID(Self.lowMbid)))
                == outside("Nobody", Self.lowMbid))
    }

    /// An artist only in Discover's library (Aurral's copies) isn't a library artist: the search is scoped to the
    /// listed libraries, never Discover's.
    @Test func artistRow_aurralOnlyArtistOpensOutside() async throws {
        artists = [(id: "ar-low-aurral", name: "Low", mbid: Self.lowMbid, library: 2)]
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discoverLibraryIds == [2] && model.listedLibraryIds == [1])
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid)))
                == outside("Low", Self.lowMbid))
        let folders = searches.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
            .filter { $0.name == "musicFolderId" }.compactMap(\.value)
        #expect(folders == ["1"], "only the listed library")
    }

    @Test func artistRow_deadlineOpensOutside() async throws {
        artists = [(id: "ar-low", name: "Low", mbid: Self.lowMbid, library: 1)]
        let model = try await signedIn()
        defer { model.signOut(); transport.hold(false) }
        transport.hold(true)
        // The deadline's clock passes at once; the held search never answers in time.
        let route = await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid)), sleep: { _ in })
        #expect(route == outside("Low", Self.lowMbid))
        #expect(AppModel.discoverArtistLinkDeadline == .seconds(5))
    }

    @Test func artistRow_offlineNoLink() async throws {
        artists = [(id: "ar-low", name: "Low", mbid: nil, library: 1)]
        let model = try await signedIn()
        defer { model.signOut() }
        #expect(model.discoverArtistLinksAvailable)
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(!model.discoverArtistLinksAvailable, "rows don't open, and show no chevron")
        let before = searches.count
        #expect(await model.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: nil)) == nil)
        #expect(searches.count == before, "nothing asked")
    }

    // MARK: - The row (hosted)

    /// "Add" stays on one line at the largest non-accessibility size, however narrow the room; VoiceOver keeps the full
    /// label.
    @Test func addButtonOneLineWithFullLabel() {
        #expect(DiscoverArtistLinkCopy.add == "Add")
        #expect(DiscoverArtistLinkCopy.addLabel("Low") == "Add Low to your library")
        func size(_ width: CGFloat) -> CGSize {
            UIHostingController(rootView: DiscoverAddButton(artistName: "Low") {}.environment(\.dynamicTypeSize, .xxxLarge))
                .sizeThatFits(in: CGSize(width: width, height: 1_000))
        }
        let roomy = size(400), narrow = size(30)
        #expect(narrow.height == roomy.height, "never wraps: \(narrow) vs \(roomy)")
        #expect(roomy.height >= Tokens.minHitSize && roomy.width >= Tokens.minHitSize, "44 pt: \(roomy)")
    }

    /// The row is a container: the link ("<artist>, <status>") and Add are separate controls with their own VoiceOver
    /// labels, side by side, each at least 44 pt (at the largest non-accessibility size too).
    @Test func addAndLinkSeparateElements() async throws {
        #expect(DiscoverArtistLinkCopy.linkLabel(name: "Low", status: "Not in Lidarr") == "Low, Not in Lidarr")
        #expect(DiscoverArtistLinkCopy.linkLabel(name: "Low", status: nil) == "Low")
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let frames = try await Self.host(List {
                DiscoverArtistRowContent(name: "The Midnight Cartographers", status: ("Not in Lidarr", "plus.circle"),
                                         showsAdd: true, opening: false, open: {}, add: {})
            }, typeSize: size, waitFor: ["link:The Midnight Cartographers, Not in Lidarr",
                                         "add:Add The Midnight Cartographers to your library"])
            let link = try #require(frames["link:The Midnight Cartographers, Not in Lidarr"], "\(size): \(frames.keys)")
            let add = try #require(frames["add:Add The Midnight Cartographers to your library"], "\(size): \(frames.keys)")
            #expect(!link.intersects(add), "two separate targets: \(link) \(add)")
            #expect(link.height >= Tokens.minHitSize && add.height >= Tokens.minHitSize && add.width >= Tokens.minHitSize,
                    "\(size): \(link) \(add)")
        }
        // Offline (no link): the row says who and where they stand, with no chevron and nothing to tap.
        let frames = try await Self.host(List {
            DiscoverArtistRowContent(name: "Low", status: nil, showsAdd: false, opening: false, open: nil, add: {})
        }, typeSize: .large, waitFor: [])
        #expect(frames.keys.allSatisfy { !$0.hasPrefix("link:") && !$0.hasPrefix("add:") }, "\(frames.keys)")
    }

    /// Fix round 1 (design M7, M6): at accessibility sizes Add goes under the name and status; "Opening" while looked up.
    @Test func addUnderNameAtAccessibilitySizes() async throws {
        #expect(DiscoverArtistLinkCopy.opening == "Opening" && DiscoverArtistLinkCopy.openingAnnouncement("Low") == "Opening Low")
        let frames = try await Self.host(List {
            DiscoverArtistRowContent(name: "The Midnight Cartographers", status: ("Not in Lidarr", "plus.circle"),
                                     showsAdd: true, opening: false, open: {}, add: {})
        }, typeSize: .accessibility3, height: 900, waitFor: ["link:The Midnight Cartographers, Not in Lidarr",
                                                             "add:Add The Midnight Cartographers to your library"])
        let link = try #require(frames["link:The Midnight Cartographers, Not in Lidarr"])
        let add = try #require(frames["add:Add The Midnight Cartographers to your library"])
        #expect(add.minY >= link.maxY - 1, "Add under the name: \(link) \(add)")
        #expect(add.maxX <= 375.5)
    }

    /// Fix round 2 (R1): from an artist's page opened in the sheet, an album opens too (the sheet's path takes the
    /// pages' own routes as well as the artist page).
    @Test func albumFromSheetArtistPageOpens() async throws {
        artists = []
        let model = try await signedIn()
        defer { model.signOut() }
        var path = NavigationPath()
        path.append(ArtistPage(route: .outsideArtist(NotYetArtist(name: "Low", mbid: nil))))
        path.append(Route.album(id: "al-sheet-1"))   // what the artist page's album link appends
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 700)
        let host = UIHostingController(rootView: DiscoverArtistsView(artists: [], adder: DiscoverArtistAdder(), path: path)
            .environment(model))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let albumAsked = await eventually {
            host.view.layoutIfNeeded()
            return self.transport.navidrome.requests.contains {
                $0.url?.path.hasSuffix("/rest/getAlbum") == true && $0.url?.query?.contains("id=al-sheet-1") == true
            }
        }
        #expect(albumAsked, "the album page appeared and read its album")
    }

    /// Hosts `view` in a window and collects what the layout probe reports (until `waitFor` all arrived, or a deadline).
    static func host(_ view: some View, typeSize: DynamicTypeSize, height: CGFloat = 400,
                     model: AppModel? = nil, waitFor: Set<String>) async throws -> [String: CGRect] {
        let box = ProbeFrames()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: height)
        let root = view
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.discoverLayoutProbe) { key, frame in box.frames[key] = frame }
        let host: UIViewController = if let model { UIHostingController(rootView: root.environment(model)) }
            else { UIHostingController(rootView: root) }
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        } while ContinuousClock.now < deadline && !waitFor.isSubset(of: Set(box.frames.keys))
        if waitFor.isEmpty {   // nothing to wait for: let the layout settle a few passes
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); host.view.layoutIfNeeded() }
        }
        return box.frames
    }

    // MARK: - Setups (D321)

    @Test func fourSetups() async throws {
        artists = [(id: "ar-low", name: "Low", mbid: Self.lowMbid, library: 1)]
        // Navidrome alone: no Discover, so no artists sheet.
        let alone = try await signedIn(aurralSetUp: false)
        #expect(try await alone.discoverPlaylists().isEmpty)
        alone.signOut()
        // + Lidarr: still no Discover.
        let withLidarr = try await signedIn(aurralSetUp: false, lidarr: true)
        let lidarrOnly = try await withLidarr.discoverPlaylists()
        #expect(withLidarr.lidarr != nil && lidarrOnly.isEmpty)
        withLidarr.signOut()
        // + Aurral: rows open their pages without Lidarr (the outside page then has no Lidarr line).
        let withAurral = try await signedIn()
        #expect(withAurral.lidarr == nil)
        #expect(await withAurral.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: MBID(Self.lowMbid))) == .artist(id: "ar-low"))
        #expect(await withAurral.discoverArtistRoute(DiscoverArtist(name: "Wren", mbid: nil)) == outside("Wren", nil))
        withAurral.signOut()
        // All: the same links, and Lidarr is there for Add.
        let all = try await signedIn(lidarr: true)
        defer { all.signOut() }
        #expect(all.lidarr != nil && all.discoverArtistLinksAvailable)
        #expect(await all.discoverArtistRoute(DiscoverArtist(name: "Low", mbid: nil)) == .artist(id: "ar-low"))
    }
}

/// What the layout probe reported, by key (`DiscoverArtistsLinkAppTests.host`).
@MainActor final class ProbeFrames { var frames: [String: CGRect] = [:] }
