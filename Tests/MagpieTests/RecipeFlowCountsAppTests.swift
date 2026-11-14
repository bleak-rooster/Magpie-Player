import AurralKit
import Foundation
import MagpieCore
import MagpieTestSupport
import SwiftUI
import Testing
import DesignSystem
import UIKit
@testable import Magpie

/// Round 27 D2 (owner item 13, 2026-11-14, D316): the flow editor asks for a number of songs per source (a checkmark
/// and a stepper each, "N songs"), with "N songs in all" below; the share sliders and the separate size field are gone.
@MainActor @Suite(.serialized) struct RecipeFlowCountsAppTests {
    @Test func countCopy() {
        #expect(RecipeFlowCountCopy.songsInAll(30) == "30 songs in all")
        #expect(RecipeFlowCountCopy.songsInAll(1) == "1 song in all")
        #expect(RecipeFlowCountCopy.sourceLabel(.mix, 12) == "Library, 12 songs")
        #expect(RecipeFlowCountCopy.sourceLabel(.newReleases, 1) == "New releases, 1 song")
        #expect(RecipeFlowCountCopy.longPressStep == 5)
        // Fix round 1 (design H4): the buttons' and actions' words.
        #expect(RecipeFlowCountCopy.include(.mix) == "Include Library" && RecipeFlowCountCopy.leaveOut(.focus) == "Leave out Focus")
        #expect(RecipeFlowCountCopy.fewer == "Fewer" && RecipeFlowCountCopy.more == "More")
        #expect(RecipeFlowCountCopy.includeAction == "Include" && RecipeFlowCountCopy.leaveOutAction == "Leave out")
        #expect(RecipeFlowCountCopy.fiveMore == "5 more" && RecipeFlowCountCopy.fiveFewer == "5 fewer")
        // The summary in Your flows counts the songs in all.
        let recipe = FlowRecipe(name: "Mine", counts: [.discover: 12, .trending: 3])
        #expect(RecipeFlowCopy.summary(recipe) == "15 songs \u{00B7} Discover, Trending")
    }

    /// A step of one (five by VoiceOver's actions), never below 0 or up past 100 (fix round 1 I4: a count already over
    /// 100 only steps down); checking a source gives it ten, unchecking none.
    @Test func steppingCounts() {
        var recipe = FlowRecipe(name: "Mine", counts: [.discover: 3])
        RecipeFlowCountCopy.step(&recipe, .discover, by: -5)
        #expect(recipe.counts[.discover] == 0 && recipe.size == 0)
        RecipeFlowCountCopy.step(&recipe, .discover, by: 1)
        #expect(recipe.counts[.discover] == 1)
        RecipeFlowCountCopy.step(&recipe, .focus, by: 5)
        #expect(recipe.counts[.focus] == 5)
        recipe.counts[.mix] = 98
        RecipeFlowCountCopy.step(&recipe, .mix, by: 5)
        #expect(recipe.counts[.mix] == 100)
        RecipeFlowCountCopy.step(&recipe, .mix, by: 1)
        #expect(recipe.counts[.mix] == 100, "More stops at 100")
        recipe.counts[.newReleases] = 140   // a flow made bigger on the server
        RecipeFlowCountCopy.step(&recipe, .newReleases, by: 1)
        #expect(recipe.counts[.newReleases] == 140, "never up past what it was")
        RecipeFlowCountCopy.step(&recipe, .newReleases, by: -1)
        #expect(recipe.counts[.newReleases] == 139, "one fewer, not cut to 100")
        recipe.setSource(.trending, on: true)
        #expect(recipe.counts[.trending] == 10)
        recipe.setSource(.trending, on: false)
        #expect(recipe.counts[.trending] == 0)
    }

    @Test func editor_noShareSliders() async throws {
        let name = "RecipeFlowCountsAppTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        for advanced in [false, true] {
            var recipe = FlowRecipe(name: "Mine", counts: [.discover: 12, .mix: 10, .trending: 8])
            if advanced { recipe.excludeTags = ["metal"] }   // opens on Advanced
            let wanted: Set<String> = ["total:30 songs in all", "source:Discover, 12 songs", "source:Library, 10 songs",
                                       "source:Trending, 8 songs", "source:Focus, 0 songs", "source:New releases, 0 songs"]
            let frames = try await DiscoverArtistsLinkAppTests.host(RecipeFlowEditor(target: .new(recipe)), typeSize: .large,
                                                                    height: 2_400, model: model, waitFor: wanted)
            #expect(wanted.isSubset(of: Set(frames.keys)), "advanced \(advanced): \(frames.keys.sorted())")
            #expect(!frames.keys.contains { $0.hasSuffix("%") }, "no shares: \(frames.keys.sorted())")
            #expect(frames.filter { $0.key.hasPrefix("source:") }.values.allSatisfy { $0.height >= Tokens.minHitSize })
        }
    }

    /// Fix round 1 (design H3, H4): at the largest accessibility size each source row fits the screen's width, and its
    /// Include, Fewer and More are real buttons of at least 44 pt.
    @Test func editor_sourceRowsAtAccessibilitySizes() async throws {
        let name = "RecipeFlowCountsAppTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        let recipe = FlowRecipe(name: "Mine", counts: [.discover: 12, .mix: 10, .trending: 8])
        let wanted: Set<String> = Set(FlowSource.allCases.flatMap { ["include:\($0.rawValue)", "fewer:\($0.rawValue)", "more:\($0.rawValue)"] })
        let frames = try await DiscoverArtistsLinkAppTests.host(RecipeFlowEditor(target: .new(recipe)), typeSize: .accessibility5,
                                                                height: 6_000, model: model, waitFor: wanted)
        #expect(wanted.isSubset(of: Set(frames.keys)), "\(frames.keys.sorted())")
        for key in wanted {
            let frame = try #require(frames[key])
            #expect(frame.width >= Tokens.minHitSize && frame.height >= Tokens.minHitSize, "\(key): \(frame)")
            #expect(frame.maxX <= 375.5, "\(key) fits: \(frame)")
        }
        let include = try #require(frames["include:discover"]), more = try #require(frames["more:discover"])
        #expect(more.minY >= include.maxY - 1, "the count goes under the name: \(include) \(more)")
    }
}
