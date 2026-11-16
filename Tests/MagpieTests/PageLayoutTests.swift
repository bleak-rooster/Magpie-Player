import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// Hands the ActionBar probe to the hosted screens (`ScreenFixture`).
enum ScreenFixtureProbe {
    @MainActor static func apply<V: View>(_ content: V, _ probe: (@MainActor (Int, CGRect) -> Void)?) -> some View {
        content.environment(\.actionBarProbe, probe)
    }
}

/// Y7 (plan item 10): the main pages, loaded from stubs and hosted in an iPhone-sized window, all lay out their
/// action bar the same way: Play, Shuffle and Download (where there is one) as equal slots in one row, one height of
/// at least 44 pt, inside the 16 pt margins, in every Character, and stacked at accessibility sizes.
@MainActor @Suite(.serialized) struct PageLayoutTests {
    private func measure(_ screen: AnyView, model: AppModel, theme: Theme = Theme(), scheme: UIUserInterfaceStyle = .light,
                         typeSize: DynamicTypeSize = .large) async throws -> ActionBarFrames {
        let frames = ActionBarFrames()
        let window = try await ScreenFixture.host(screen, model: model, theme: theme, scheme: scheme, typeSize: typeSize) {
            frames.record($0, $1)
        }
        window.isHidden = true
        return frames
    }

    @Test func mainPagesShareOneBar() async throws {
        let fixture = ScreenFixture()
        let model = try await fixture.signedInModel()
        let pages: [(String, AnyView, Int)] = [
            ("album", AnyView(AlbumView(albumId: "a1")), 3),
            ("playlist", AnyView(PlaylistView(playlistId: "p1")), 3),
            ("artist", AnyView(ArtistView(artistId: "ar1")), 3),   // round 27 A (D305): Play, Shuffle, Automix
            ("genre", AnyView(GenreView(name: "Ambient")), 2),
            ("favourites", AnyView(FavouritesView()), 2),   // phase 2: Favourites gets Play and Shuffle too
        ]
        var widthsByCount: [Int: Set<CGFloat>] = [:]
        for (name, page, count) in pages {
            for character in DesignSystem.Character.allCases {
                let frames = try await measure(page, model: model, theme: Theme(character: character))
                ActionBarTests.expectBar(frames, count: count, width: 402, label: "\(name) \(character)")
                if let play = frames.byIndex[0] { widthsByCount[count, default: []].insert(play.width.rounded()) }
            }
        }
        // Play is the same width on every page with the same actions.
        #expect(widthsByCount.values.allSatisfy { $0.count == 1 }, "\(widthsByCount)")
    }

    /// Phase 2: Y6's Discover page uses the same bars: Play and Shuffle (one row, equal), then its own actions
    /// (Artists in this playlist; Refresh Flow when it has a flow) in a second ActionBar, all 44 pt and on the margins.
    /// Round 28 O3 (D343): Download (the flow to the phone) joins Play and Shuffle's row, the three equal.
    @Test func discoverPageUsesActionBars() async throws {
        let fixture = ScreenFixture()
        let model = try await fixture.signedInModel()
        for character in DesignSystem.Character.allCases {
            let frames = try await measure(AnyView(DiscoverPlaylistView(playlistId: "p1")), model: model,
                                           theme: Theme(character: character))
            let items = frames.all.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            #expect(items.count == 4, "\(character): \(items)")
            guard items.count == 4 else { continue }
            #expect(Set(items.map { ($0.height * 2).rounded() }).count == 1 && items[0].height >= 44, "\(character): \(items)")
            #expect(abs(items[0].width - items[1].width) < 0.5 && abs(items[1].width - items[2].width) < 0.5
                    && abs(items[0].minY - items[2].minY) < 0.5, "\(character): \(items)")
            #expect(abs(items[3].minX - 16) < 0.5 && abs(items[3].maxX - 386) < 0.5 && items[3].minY > items[0].maxY,
                    "\(character): \(items)")
        }
    }

    /// Round 27 A fix round 1 (design M4, D305): the artist page's Play, Shuffle and Automix never take three rows below
    /// accessibility sizes: on a 375 pt phone at xLarge to xxxLarge, in every Character, they're one row or two and one
    /// (Play and Shuffle side by side, Automix full width below). Album's bar (`pairsBeforeStacking` off) keeps its rule.
    @Test func artistBarGoesTwoAndOneAtXXXLarge() async throws {
        func bar(pairs: Bool) -> AnyView {
            AnyView(ActionBar(pairsBeforeStacking: pairs) {
                ActionButton("Play", symbol: "play.fill", prominence: .primary) {}
                ActionButton("Shuffle", symbol: "shuffle") {}
                ActionButton(AutomixCopy.actionBar, symbol: AutomixCopy.symbol) {}
            })
        }
        for size in [DynamicTypeSize.xLarge, .xxLarge, .xxxLarge] {
            for character in DesignSystem.Character.allCases {
                let label = "\(size) \(character)"
                let frames = try await ActionBarTests.host(bar(pairs: true), theme: Theme(character: character), typeSize: size)
                let a = (0..<3).compactMap { frames.byIndex[$0] }
                #expect(a.count == 3, "\(label): \(a)")
                guard a.count == 3 else { continue }
                let rows = Set(a.map { ($0.minY * 2).rounded() }).count
                #expect(rows <= 2, "\(label): never three rows \(a)")
                if rows == 2 {
                    #expect(abs(a[0].minY - a[1].minY) < 0.5 && abs(a[0].width - a[1].width) < 0.5, "\(label): \(a)")
                    #expect(a[2].minY >= a[0].maxY && abs(a[2].minX - 16) < 0.5 && abs(a[2].maxX - 359) < 0.5, "\(label): \(a)")
                }
                // The same three without the opt-in keep the old rule (one row, else one to a row): Album's bar is unchanged.
                let plain = try await ActionBarTests.host(bar(pairs: false), theme: Theme(character: character), typeSize: size)
                let b = (0..<3).compactMap { plain.byIndex[$0] }
                #expect(Set(b.map { ($0.minY * 2).rounded() }).count != 2, "\(label): no two and one without it \(b)")
            }
        }
        // In this harness the three fit one row at 375 pt even at xxxLarge (labels scale to 0.8), so the two-and-one step
        // itself is pinned by the pure rule below, and the page is held to asking for it.
        // Pure rule.
        #expect(ActionBarArrangement.rows(idealWidths: [150, 150, 150], width: 370, stacked: false, pairs: true) == [[0, 1], [2]])
        #expect(ActionBarArrangement.rows(idealWidths: [150, 150, 150], width: 370, stacked: false) == [[0], [1], [2]])
        #expect(ActionBarArrangement.rows(idealWidths: [90, 90, 90], width: 370, stacked: false, pairs: true) == [[0, 1, 2]])
        #expect(ActionBarArrangement.rows(idealWidths: [150, 150, 150], width: 370, stacked: true, pairs: true) == [[0], [1], [2]])
        // And the page itself asks for it.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "App/Screens/Artist/ArtistView.swift"), encoding: .utf8)
        #expect(source.contains("ActionBar(pairsBeforeStacking: true)"))
    }

    @Test func pagesStackTheBarAtAccessibilitySizes() async throws {
        let fixture = ScreenFixture()
        let model = try await fixture.signedInModel()
        for (name, page) in [("album", AnyView(AlbumView(albumId: "a1"))), ("artist", AnyView(ArtistView(artistId: "ar1")))] {
            let frames = try await measure(page, model: model, typeSize: .accessibility3)
            let all = frames.byIndex.keys.sorted().compactMap { frames.byIndex[$0] }
            #expect(all.count >= 2, "\(name): \(all)")
            #expect(all.allSatisfy { abs($0.minX - 16) < 0.5 && abs($0.maxX - 386) < 0.5 && $0.height >= 44 }, "\(name): \(all)")
            for (a, b) in zip(all, all.dropFirst()) { #expect(b.minY >= a.maxY, "\(name): \(all)") }
        }
    }
}
