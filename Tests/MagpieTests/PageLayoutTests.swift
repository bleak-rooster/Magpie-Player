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
            frames.byIndex[$0] = $1
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
            ("artist", AnyView(ArtistView(artistId: "ar1")), 2),
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
