import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Y7 (plan item 10): a signed-in model answered by stubs (no server), and the main screens hosted in a real
/// iPhone-sized window, so the audit can draw every screen in light, dark and the three Characters and the layout
/// tests can measure them.
@MainActor final class ScreenFixture {
    static let home = URL(string: "http://192.168.1.2:4533")!
    let tmp = FileManager.default.temporaryDirectory.appending(path: "ScreenFixture-\(UUID().uuidString)")
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "ScreenFixture.\(UUID().uuidString)")!
    let transport = HostSwitchTransport()

    deinit {
        store.clear()
        try? FileManager.default.removeItem(at: tmp)
    }

    static func subsonic(_ body: String) -> Data {
        Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#.utf8)
    }

    static let songTitles = ["North by Northwest", "Compass Rose", "Lantern Hours", "The Long Meridian",
                             "Paper Coastlines", "Night Ferry", "Tidewater", "Small Hours"]

    /// README screenshots only (`ScreenGalleryTests.drawReadmeScreenshots`): albums, songs and the artist carry cover ids,
    /// whose generated covers are put in the artwork cache first, so nothing is ever fetched. Off for every other test.
    static var withCovers = false

    static func cover(_ id: String) -> String { withCovers ? #","coverArt":"\#(id)""# : "" }

    static func songs(album: String = "a1", albumName: String = "Atlas of Small Hours") -> String {
        songTitles.enumerated().map { i, title in
            #"{"id":"\#(album)s\#(i + 1)","title":"\#(title)","artist":"The Midnight Cartographers","artistId":"ar1","album":"\#(albumName)","albumId":"\#(album)","track":\#(i + 1),"duration":\#(180 + i * 17),"suffix":"flac","bitRate":900\#(cover("al-" + album))}"#
        }.joined(separator: ",")
    }

    static let albums = [("a1", "Atlas of Small Hours", 2024), ("a2", "Harbour Lights", 2021), ("a3", "Weather Systems", 2018),
                         ("a4", "Signal Fires", 2016)]

    static var albumsJSON: String {
        albums.map { #"{"id":"\#($0.0)","name":"\#($0.1)","artist":"The Midnight Cartographers","artistId":"ar1","year":\#($0.2),"songCount":8,"duration":1800,"genre":"Ambient"\#(cover("al-" + $0.0))}"# }
            .joined(separator: ",")
    }

    func signedInModel() async throws -> AppModel {
        let t = transport.inner
        t.stub(pathSuffix: "/rest/ping", body: Self.subsonic(#""x":1"#))
        t.stub(method: "POST", pathSuffix: "/auth/login", body: Data(#"""
        {"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"admin"}
        """#.utf8))
        t.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        t.stub(pathSuffix: "/rest/getAlbum", body: Self.subsonic(
            #""album":{"id":"a1","name":"Atlas of Small Hours","artist":"The Midnight Cartographers","artistId":"ar1","year":2024,"songCount":8,"duration":1660,"genre":"Ambient"\#(Self.cover("al-a1")),"song":[\#(Self.songs())]}"#))
        t.stub(pathSuffix: "/rest/getArtist", body: Self.subsonic(
            #""artist":{"id":"ar1","name":"The Midnight Cartographers","albumCount":4\#(Self.cover("ar-ar1")),"album":[\#(Self.albumsJSON)]}"#))
        t.stub(pathSuffix: "/rest/getPlaylist", body: Self.subsonic(
            #""playlist":{"id":"p1","name":"Late Night Drive","songCount":8,"duration":1660,"owner":"admin","entry":[\#(Self.songs())]}"#))
        t.stub(pathSuffix: "/rest/getAlbumList2", body: Self.subsonic(#""albumList2":{"album":[\#(Self.albumsJSON)]}"#))
        t.stub(pathSuffix: "/rest/getPlaylists", body: Self.subsonic(
            #""playlists":{"playlist":[{"id":"p1","name":"Late Night Drive","songCount":8,"duration":1660,"owner":"admin"}]}"#))
        t.stub(pathSuffix: "/rest/getGenres", body: Self.subsonic(
            #""genres":{"genre":[{"value":"Ambient","songCount":32,"albumCount":4},{"value":"Jazz","songCount":12,"albumCount":2}]}"#))
        t.stub(pathSuffix: "/rest/getStarred2", body: Self.subsonic(#""starred2":{"song":[\#(Self.songs())],"album":[\#(Self.albumsJSON)]}"#))
        t.stub(pathSuffix: "/rest/getSongsByGenre", body: Self.subsonic(#""songsByGenre":{"song":[\#(Self.songs())]}"#))
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: tmp, transport: transport,
                             probeTransport: transport, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false, network: FakeNetwork(.wifi),
                             audioFetcher: FakeFetcher())
        try await model.signIn(urls: [Self.home], username: "admin", password: "pw")
        return model
    }

    /// The screens the audit draws, by name.
    static let screens: [(String, @MainActor () -> AnyView)] = [
        ("album", { AnyView(AlbumView(albumId: "a1")) }),
        ("artist", { AnyView(ArtistView(artistId: "ar1")) }),
        ("playlist", { AnyView(PlaylistView(playlistId: "p1")) }),
        ("genre", { AnyView(GenreView(name: "Ambient")) }),
        ("favourites", { AnyView(FavouritesView()) }),
        ("library", { AnyView(LibraryView()) }),
        ("home", { AnyView(HomeView()) }),
        ("settings", { AnyView(SettingsView()) }),
        ("discover", { AnyView(DiscoverPlaylistView(playlistId: "p1")) }),   // phase 2: Y6's Discover page
    ]

    /// `screen` in a NavigationStack in a `size` window, with the theme, scheme and text size applied, given time to
    /// load from the stubs and settle.
    static func host(_ screen: AnyView, model: AppModel, theme: Theme, scheme: UIUserInterfaceStyle,
                     typeSize: DynamicTypeSize = .large, size: CGSize = CGSize(width: 402, height: 874),
                     probe: (@MainActor (Int, CGRect) -> Void)? = nil) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = theme.character == .immersive ? .dark : scheme
        let root = NavigationStack { screen }
            .environment(model)
            .environment(\.songIsDownloaded, model.songIsDownloaded)
            .magpieTheme(theme)
            .tint(theme.colors(for: scheme == .dark || theme.character == .immersive ? .dark : .light).accentInkColor)   // as RootView
            .environment(\.dynamicTypeSize, typeSize)
            .modifier(ProbeModifier(probe: probe))
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        return window
    }

    static func png(_ window: UIWindow) -> Data? {
        let bounds = window.bounds
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }.pngData()
    }
}

/// Hands the page tests' ActionBar probe to the hosted screen (`ScreenFixtureProbe`, in PageLayoutTests.swift).
private struct ProbeModifier: ViewModifier {
    let probe: (@MainActor (Int, CGRect) -> Void)?
    func body(content: Content) -> some View { ScreenFixtureProbe.apply(content, probe) }
}

/// The audit's screenshots: every main screen in Classic, Signature (light and dark) and Immersive, plus Signature at
/// accessibility XL. Runs only when `Y7_SHOTS_DIR` is set (pass `TEST_RUNNER_Y7_SHOTS_DIR` to xcodebuild); writes PNGs
/// there.
@MainActor @Suite(.serialized) struct ScreenGalleryTests {
    @Test func drawEveryMainScreen() async throws {
        guard let dir = ProcessInfo.processInfo.environment["Y7_SHOTS_DIR"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fixture = ScreenFixture()
        let model = try await fixture.signedInModel()
        let looks: [(String, Theme, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("classic-light", Theme(character: .classic), .light, .large),
            ("classic-dark", Theme(character: .classic), .dark, .large),
            ("signature-light", Theme(character: .signature), .light, .large),
            ("signature-dark", Theme(character: .signature), .dark, .large),
            ("immersive", Theme(character: .immersive), .dark, .large),
            ("signature-light-axxl", Theme(character: .signature), .light, .accessibility3),
        ]
        for (name, make) in ScreenFixture.screens {
            for (look, theme, scheme, typeSize) in looks {
                let window = try await ScreenFixture.host(make(), model: model, theme: theme, scheme: scheme,
                                                          typeSize: typeSize)
                if let data = ScreenFixture.png(window) {
                    try data.write(to: out.appending(path: "\(name)-\(look).png"))
                }
                window.isHidden = true
            }
        }
    }
}

/// The README's screenshots: a few main screens in Signature, light and dark, with generated gradient covers (no real
/// artwork, no server). Runs only when `README_SHOTS_DIR` is set (pass `TEST_RUNNER_README_SHOTS_DIR` to xcodebuild).
@MainActor @Suite(.serialized) struct ReadmeScreenshotTests {
    /// One cover per id: a soft diagonal gradient with concentric rings, in the app's palette family.
    static func coverPNG(_ index: Int, side: Int) -> Data? {
        let palettes: [(UIColor, UIColor)] = [
            (UIColor(red: 0.16, green: 0.36, blue: 0.33, alpha: 1), UIColor(red: 0.52, green: 0.78, blue: 0.70, alpha: 1)),
            (UIColor(red: 0.20, green: 0.22, blue: 0.38, alpha: 1), UIColor(red: 0.93, green: 0.55, blue: 0.47, alpha: 1)),
            (UIColor(red: 0.44, green: 0.24, blue: 0.16, alpha: 1), UIColor(red: 0.95, green: 0.78, blue: 0.52, alpha: 1)),
            (UIColor(red: 0.13, green: 0.17, blue: 0.20, alpha: 1), UIColor(red: 0.55, green: 0.66, blue: 0.80, alpha: 1)),
            (UIColor(red: 0.30, green: 0.18, blue: 0.32, alpha: 1), UIColor(red: 0.86, green: 0.62, blue: 0.80, alpha: 1)),
        ]
        let (a, b) = palettes[index % palettes.count]
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a.cgColor, b.cgColor] as CFArray,
                                      locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            cg.setLineWidth(CGFloat(side) / 120)
            let centre = CGPoint(x: size.width * 0.62, y: size.height * 0.58)
            for ring in 1...7 {
                let r = CGFloat(side) * 0.07 * CGFloat(ring)
                cg.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
            }
        }
        return image.pngData()
    }

    @Test func drawReadmeScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["README_SHOTS_DIR"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        ScreenFixture.withCovers = true
        defer { ScreenFixture.withCovers = false }
        let fixture = ScreenFixture()
        let model = try await fixture.signedInModel()
        let scope = try #require(model.navidromeScope)
        let ids = ScreenFixture.albums.map { "al-" + $0.0 } + ["ar-ar1"]
        for (i, id) in ids.enumerated() {
            for side in [120, 300, 600, 1000] {
                let data = try #require(Self.coverPNG(i, side: side))
                await model.artworkDisk.save(data, scope: scope, coverArtId: id, size: side, generation: Int.max)
            }
        }
        let shots: [(String, @MainActor () -> AnyView, UIUserInterfaceStyle)] = [
            ("home", { AnyView(HomeView()) }, .light),
            ("album", { AnyView(AlbumView(albumId: "a1")) }, .light),
            ("artist", { AnyView(ArtistView(artistId: "ar1")) }, .dark),
            ("library", { AnyView(LibraryView()) }, .dark),
            ("settings", { AnyView(SettingsView()) }, .light),
        ]
        for (name, make, scheme) in shots {
            let window = try await ScreenFixture.host(make(), model: model, theme: Theme(character: .signature), scheme: scheme)
            if let data = ScreenFixture.png(window) {
                try data.write(to: out.appending(path: "\(name).png"))
            }
            window.isHidden = true
        }
    }
}

