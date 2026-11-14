import DesignSystem
import Foundation
import MagpieCore
import Search
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Round 27 H (owner, 2026-11-14): "There should be an option to view albums as smaller icons" (D296). One choice for
/// every album grid: Large (columns of at least 150 pt, two at least) or Small (at least 100 pt, three at least);
/// accessibility sizes unchanged.
@MainActor @Suite(.serialized) struct AlbumCoverSizeTests {
    /// A 375 pt phone's grid is 335 pt wide (20 pt margins).
    static let phone375: CGFloat = 375 - 2 * Tokens.Spacing.largeTitleMargin
    static let phone320: CGFloat = 320 - 2 * Tokens.Spacing.largeTitleMargin

    @Test func columns_small375IsThree() {
        #expect(AlbumGrid.columnCount(width: Self.phone375, accessibility: false, size: .small) == 3)
        #expect(AlbumGrid.columnCount(width: Self.phone320, accessibility: false, size: .small) == 3, "three at least")
        #expect(AlbumGrid.columnCount(width: 700, accessibility: false, size: .small) == 6)
        let tile = AlbumGrid.tileWidth(width: Self.phone375, columns: 3, size: .small)
        #expect(abs(tile - 101) < 0.5, "\(tile)")
        let narrow = AlbumGrid.tileWidth(width: Self.phone320, columns: 3, size: .small)
        #expect(3 * narrow + 2 * Tokens.Spacing.l <= Self.phone320 + 0.5, "three fit a 320 pt phone: \(narrow)")
    }

    @Test func columns_large375IsTwo() {
        #expect(AlbumGrid.columnCount(width: Self.phone375, accessibility: false, size: .large) == 2)
        #expect(AlbumGrid.columnCount(width: Self.phone375, accessibility: false) == 2, "large is the default")
        #expect(AlbumGrid.columnCount(width: 700, accessibility: false, size: .large) == 4)
        #expect(AlbumGrid.tileWidth(width: Self.phone320, columns: 2, size: .large) >= 100, "as before")
    }

    @Test func columns_accessibilityUnchanged() {
        for size in AlbumCoverSize.allCases {
            #expect(AlbumGrid.columnCount(width: 362, accessibility: true, size: size) == 1)
            #expect(AlbumGrid.columnCount(width: 700, accessibility: true, size: size) == 3)
        }
        #expect(!AlbumGrid.usesSmallTiles(.small, accessibility: true), "accessibility sizes keep the large tile")
        #expect(AlbumGrid.usesSmallTiles(.small, accessibility: false))
        #expect(!AlbumGrid.usesSmallTiles(.large, accessibility: false))
    }

    /// A small tile keeps its title and subtitle (one line each), and is at least 44 pt high and no wider than its
    /// column; VoiceOver reads both.
    @Test func smallTilesKeep44ptAndLabels() {
        func size(_ title: String) -> CGSize {
            UIHostingController(rootView: SmallAlbumTile(title: title, subtitle: "The Midnight Cartographers", artwork: nil,
                                                         width: 101))
                .sizeThatFits(in: CGSize(width: 101, height: 1_000))
        }
        let short = size("Glasshouse")
        let long = size("Atlas of Small Hours and Every Other Thing We Left in the Car on the Way Home")
        #expect(short.height >= Tokens.minHitSize && short.width <= 101.5, "\(short)")
        #expect(long.height == short.height, "one line each, truncated: \(long) vs \(short)")
        #expect(SmallAlbumTile.accessibilityLabel(title: "Glasshouse", subtitle: "Corin Hale") == "Glasshouse, Corin Hale")
    }

    /// Library › Albums' toolbar button switches the one setting, saved like any preference.
    @Test func albumsToolbarToggles() throws {
        let name = "covers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        #expect(model.preferences.layout.albumCovers == .large)
        #expect(AlbumCoversCopy.toolbarLabel(.large) == "Smaller covers")
        #expect(AlbumCoversCopy.toolbarSymbol(.large) == "square.grid.3x3")
        AlbumsListView.toggleCovers(model)
        #expect(model.preferences.layout.albumCovers == .small)
        #expect(LayoutPreferences.decode(defaults.data(forKey: LayoutPreferences.key)).albumCovers == .small, "saved")
        #expect(AlbumCoversCopy.toolbarLabel(.small) == "Larger covers")
        #expect(AlbumCoversCopy.toolbarSymbol(.small) == "square.grid.2x2")
        AlbumsListView.toggleCovers(model)
        #expect(model.preferences.layout.albumCovers == .large)
        #expect(AlbumCoversCopy.setting == "Album covers")
        #expect(AlbumCoverSize.allCases.map(AlbumCoversCopy.title) == ["Large", "Small"])
    }

    /// D225's letter jump lands on the letter's header, or a row above the album, with three tiles to a row.
    @Test func letterJumpLandsWithThreeColumns() {
        let columns = AlbumGrid.columnCount(width: Self.phone375, accessibility: false, size: .small)
        let names = (0..<7).map { "Album \($0)" } + (0..<33).map { "Blue \($0)" }
        let runs = LetterIndex.sections(names) { $0 }
        #expect(runs.map(\.range) == [0..<7, 7..<40])
        #expect(LetterSectionHeader.scrollTarget(index: 7, runs: runs, rowLength: columns) == .header("letter-header-B-7"))
        #expect(LetterSectionHeader.scrollTarget(index: 9, runs: runs, rowLength: columns) == .header("letter-header-B-7"),
                "on the run's first row of three")
        #expect(LetterSectionHeader.scrollTarget(index: 10, runs: runs, rowLength: columns) == .item(7), "a row up")
    }
}
