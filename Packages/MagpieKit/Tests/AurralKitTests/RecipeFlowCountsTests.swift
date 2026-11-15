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
        r.counts[.mix] = -3   // never below 0
        #expect(r.counts[.mix] == 0)
        #expect(FlowRecipe(name: "New").size == FlowRecipe.defaultSize)
    }

    /// Fix round 1 (I4): as Aurral's editor, up to 100 songs a source and so up to 500 in all; a source over 100 is
    /// refused unsent; 100 in each of two sources (200 in all) is fine.
    @Test func counts_overHundredRefused() async {
        let r = Self.recipe([.discover: 101, .mix: 40])
        #expect(r.counts[.discover] == 101, "kept as it is, refused, never shrunk")
        #expect(r.problem == "A source holds up to 100 songs.")
        #expect(Self.recipe([.discover: 100, .mix: 100]).problem == nil)
        #expect(Self.recipe([.discover: 100, .mix: 100]).size == 200)
        #expect(FlowRecipe.maxSongsPerSource == 100 && FlowRecipe.maxSongs == 500)
        await #expect(throws: AurralError.self) { try await client.createRecipeFlow(r) }
        #expect(stub.asked.isEmpty)
    }

    /// Fix round 1 (I4): a flow of 150 songs (made on Aurral) reads back at 150 and an unchanged save sends nothing;
    /// a changed name sends only the name.
    @Test func counts_150SongFlowRoundTrips() throws {
        let flow = try #require(FlowRecipe.decode(["name": "Big", "size": 150, "scheduleDays": [5],
                                                   "mix": ["discover": 66.67, "mix": 33.33, "trending": 0, "focus": 0, "newReleases": 0]]))
        #expect(flow.size == 150)
        #expect(flow.counts[.discover] == 100 && flow.counts[.mix] == 50)
        #expect(flow.problem == nil)
        #expect(flow.changes(from: flow).isEmpty)
        var renamed = flow
        renamed.name = "Bigger"
        #expect(Set(renamed.changes(from: flow).keys) == ["name"])
        // A stored size over what one source may hold still reads back whole (the editor then asks to bring it down).
        let one = try #require(FlowRecipe.decode(["name": "One", "size": 150, "scheduleDays": [5], "mix": ["discover": 100]]))
        #expect(one.size == 150 && one.problem == "A source holds up to 100 songs.")
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
