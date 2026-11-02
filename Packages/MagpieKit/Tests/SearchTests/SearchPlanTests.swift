import Testing
@testable import Search

/// Y1 (plan item 1): the whole query plus at most 4 title/artist splits, in both orders; separators parse straight
/// into a split with no guessing.
@Suite struct SearchPlanTests {
    private func splits(_ q: String) -> [String] {
        SearchPlan(q).splits.map { "\($0.title)|\($0.artist)" }
    }

    @Test func oneWordHasNoSplits() {
        #expect(SearchPlan("beatles").whole == "beatles")
        #expect(SearchPlan("  beatles ").splits.isEmpty)
        #expect(SearchPlan("").splits.isEmpty)
    }

    @Test func wordBoundariesInBothOrders() {
        #expect(splits("hey jude beatles") == ["hey jude|beatles", "jude beatles|hey", "hey|jude beatles", "beatles|hey jude"])
        #expect(splits("bon iver") == ["bon|iver", "iver|bon"])
        #expect(SearchPlan("hey jude beatles").whole == "hey jude beatles")
    }

    @Test func atMostFourSplits() {
        #expect(SearchPlan("sweet child o mine guns n roses").splits.count == SearchPlan.maxSplits)
        #expect(SearchPlan.maxSplits == 4)
    }

    /// A split whose artist (or title) part is only an article searches for nothing useful and is skipped.
    @Test func articleOnlyPartsAreSkipped() {
        #expect(splits("the national bloodbuzz") == ["the national|bloodbuzz", "bloodbuzz|the national"])
    }

    @Test func dashesParseIntoBothOrders() {
        let plan = SearchPlan("Hey Jude - The Beatles")
        #expect(plan.whole == "Hey Jude The Beatles")
        #expect(splits("Hey Jude - The Beatles") == ["Hey Jude|The Beatles", "The Beatles|Hey Jude"])
        #expect(splits("beatles – hey jude") == ["beatles|hey jude", "hey jude|beatles"])
        // Fix round 1 (M3): a dash inside a name ("a–ha") is not a separator.
        #expect(SearchPlan("a–ha take on me").whole == "a–ha take on me")
        #expect(splits("a–ha take") == ["a–ha|take", "take|a–ha"])
        #expect(splits("The National — Bloodbuzz Ohio") == ["The National|Bloodbuzz Ohio", "Bloodbuzz Ohio|The National"])
    }

    /// "title by artist" is one split; the whole query stays as typed ("Stand by Me" is a title).
    @Test func byParsesTitleThenArtist() {
        let plan = SearchPlan("skinny love by bon iver")
        #expect(plan.whole == "skinny love by bon iver")
        #expect(splits("skinny love by bon iver") == ["skinny love|bon iver"])
        #expect(splits("stand by me") == ["stand|me"])
        #expect(splits("Hey Jude BY The Beatles") == ["Hey Jude|The Beatles"])
    }

    @Test func aSeparatorWithAnEmptySideFallsBackToWords() {
        #expect(splits("- beatles") == [])
        #expect(splits("hey jude -") == ["hey|jude", "jude|hey"])
    }
}
