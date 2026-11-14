import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 27 D2 (owner, 2026-11-14): a flow's songs are a count per source, as Aurral's editor has them, not shares. The
/// flow's size is their sum (1–100), sent as `mix` (the counts) and `size`; a stored mix reads back with Aurral's
/// largest-remainder split (`lib/flows.ts` `splitFlowTotal`) (D316).
@Suite struct RecipeFlowCountsTests {
    let stub: StubAurral
    let client: AurralClient

    init() {
        stub = StubAurral()
        stub.useAurral213()
        client = AurralClient(base: stub.base, session: stub.signedInSession(), transport: stub)
    }

    static func recipe(_ counts: [FlowSource: Int]) -> FlowRecipe {
        FlowRecipe(name: "Counts", counts: counts, tags: ["indie"], scheduleDays: [1], scheduleHour: 9)
    }

    /// Aurral's `normalizeFlowMix`: what the server stores (percentages, two decimals).
    static func normalised(_ counts: [FlowSource: Int]) -> [String: Any] {
        let sum = Double(counts.values.reduce(0, +))
        var out: [String: Any] = [:]
        for source in FlowSource.allCases {
            out[source.rawValue] = ((Double(counts[source] ?? 0) / sum) * 10000).rounded() / 100
        }
        return out
    }

    @Test func counts_sumIsSize() {
        var r = Self.recipe([.discover: 12, .trending: 5])
        #expect(r.size == 17)
        #expect(r.sources == [.discover, .trending])
        r.setSource(.focus, on: true)
        #expect(r.counts[.focus] == 10 && r.size == 27)
        r.setSource(.discover, on: false)
        #expect(r.counts[.discover] == 0 && r.size == 15 && r.sources == [.trending, .focus])
        r.counts[.mix] = 150   // each count is held to 0–100
        #expect(r.counts[.mix] == 100)
        r.counts[.mix] = -3
        #expect(r.counts[.mix] == 0)
        #expect(FlowRecipe(name: "New").size == FlowRecipe.defaultSize)
    }

    @Test func counts_overHundredRefused() async {
        let r = Self.recipe([.discover: 60, .mix: 41])
        #expect(r.size == 101)
        #expect(r.problem == "A flow holds up to 100 songs in all.")
        #expect(Self.recipe([.discover: 60, .mix: 40]).problem == nil)
        await #expect(throws: AurralError.self) { try await client.createRecipeFlow(r) }
        #expect(stub.asked.isEmpty)
    }

    @Test func counts_zeroRefused() async {
        let r = Self.recipe([:])
        #expect(r.size == 0)
        #expect(r.problem == "Choose at least one song.")
        await #expect(throws: AurralError.self) { try await client.createRecipeFlow(r) }
        #expect(stub.asked.isEmpty)
    }

    @Test func counts_sentAsMix() async throws {
        let id = try await client.createRecipeFlow(Self.recipe([.discover: 7, .mix: 2, .focus: 1]))
        let body = try #require(stub.requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["mix"] as? [String: Int]) == ["discover": 7, "mix": 2, "trending": 0, "focus": 1, "newReleases": 0])
        #expect(body["size"] as? Int == 10)
        // An edit of one count sends the new mix and the new size; the other fields stay unsent.
        let old = Self.recipe([.discover: 7, .mix: 2, .focus: 1])
        var new = old
        new.counts[.trending] = 5
        #expect(try await client.updateRecipeFlow(id, from: old, to: new))
        let edit = try #require(stub.requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(edit.keys) == ["mix", "size"])
        #expect(edit["size"] as? Int == 15)
    }

    /// The cases from Aurral's `.tests/flows/flow-mix.test.ts`: counts saved (normalised to percentages) read back the
    /// same, including a one-song source; plus the tie and the empty mix.
    @Test func counts_loadedBySplitFlowTotal() throws {
        let cases: [[FlowSource: Int]] = [
            [.discover: 100, .trending: 100, .focus: 1],
            [.discover: 7, .mix: 2, .focus: 1],
            [.discover: 20, .focus: 10],
        ]
        for counts in cases {
            let total = counts.values.reduce(0, +)
            let stored = Self.normalised(counts)
            let weights = Dictionary(uniqueKeysWithValues: FlowSource.allCases.map { ($0, stored[$0.rawValue] as? Double ?? 0) })
            let expected = Dictionary(uniqueKeysWithValues: FlowSource.allCases.map { ($0, counts[$0] ?? 0) })
            #expect(FlowRecipe.splitFlowTotal(weights, total: total) == expected, "\(weights) \(String(describing: FlowRecipe.splitFlowTotal(weights, total: total)))")
        }
        // Ties go by source order (Aurral's stable sort): 10 over three equal shares is 4, 3, 3.
        let tie = try #require(FlowRecipe.splitFlowTotal([.discover: 34, .mix: 33, .trending: 33], total: 10))
        #expect(tie[.discover] == 4 && tie[.mix] == 3 && tie[.trending] == 3)
        let even = try #require(FlowRecipe.splitFlowTotal([.mix: 50, .trending: 50], total: 5))
        #expect(even[.mix] == 3 && even[.trending] == 2)
        #expect(FlowRecipe.splitFlowTotal([:], total: 30) == nil)
        // A flow in the status: its stored percentages and size become counts.
        let flow = try #require(FlowRecipe.decode(["name": "Mine", "size": 30,
                                                   "mix": ["discover": 34, "mix": 33, "trending": 33, "focus": 0, "newReleases": 0]]))
        // 10.2, 9.9, 9.9: floors 10, 9, 9; the two left go to the largest remainders, Library before Trending.
        #expect(flow.counts[.discover] == 10 && flow.counts[.mix] == 10 && flow.counts[.trending] == 10)
        #expect(flow.size == 30)
        // Nothing changed: an edit sends nothing.
        #expect(flow.changes(from: flow).isEmpty)
    }

    @Test func counts_focusNeedsSeed() {
        var focus = Self.recipe([.focus: 20])
        focus.tags = []
        #expect(focus.problem == "Focus needs a tag, a similar artist or your recent listening.")
        focus.recentListening = true
        #expect(focus.problem == nil)
        focus.recentListening = false
        focus.relatedArtists = ["Ana Frango Elétrico"]
        #expect(focus.problem == nil)
    }

    @Test func unevenCountsNeedNoAdvanced() {
        // Simple and Advanced both show counts now, so uneven counts alone don't need Advanced.
        let r = Self.recipe([.discover: 25, .mix: 3])
        #expect(!r.usesAdvanced)
    }
}
