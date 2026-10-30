import Foundation
import Testing
@testable import Search

struct LetterIndexTests {
    @Test func lettersAreHashThenAToZ() {
        #expect(LetterIndex.letters.count == 27)
        #expect(LetterIndex.letters.first == "#")
        #expect(LetterIndex.letters[1] == "A")
        #expect(LetterIndex.letters.last == "Z")
    }

    @Test(arguments: [("abba", "A"), ("Àlbum de famille", "A"), ("Ça ne fait rien", "C"), ("déjà-vu", "D"),
                      ("Œuvre inachevée", "O"), ("Ærøskøbing", "A"), ("Øresund", "O"), ("ßtraße", "S"),
                      ("Łódź", "L"), ("éléonore", "E"), ("  Zephyr", "Z"), ("The Midnight Cartographers", "T")])
    func foldsCaseAndDiacritics(_ name: String, _ expected: String) {
        #expect(LetterIndex.key(name) == expected)
    }

    @Test(arguments: ["4 AM Cartography", "1:1", "(What's the Story)", "'Round Midnight", "", "   ", "🎸 Riffs",
                      "👩🏽‍🎤", "おやすみ", "坂本光", "Ωmega", "#hashtag", "_underscore"])
    func digitsSymbolsEmptyEmojiAndOtherScriptsGoUnderHash(_ name: String) {
        #expect(LetterIndex.key(name) == "#")
    }

    @Test func articlesAreKeptUnlessAsked() {
        // Song titles: Navidrome sorts "The …" under T (verified on the dev stack).
        #expect(LetterIndex.key("The Cat Is Out") == "T")
        // Artists and albums: Navidrome drops its default articles.
        let articles = LetterIndex.navidromeArticles
        #expect(LetterIndex.key("The Cat Is Out", ignoringArticles: articles) == "C")
        #expect(LetterIndex.key("A Tribe Called Quest", ignoringArticles: articles) == "T")
        #expect(LetterIndex.key("the  cat", ignoringArticles: articles) == "C")
        // Only a whole word followed by a space, and never the whole name.
        #expect(LetterIndex.key("Theory", ignoringArticles: articles) == "T")
        #expect(LetterIndex.key("The", ignoringArticles: articles) == "T")
        #expect(LetterIndex.key("Abba", ignoringArticles: articles) == "A")
        #expect(LetterIndex.sortName("The Midnight Cartographers", ignoringArticles: articles) == "Midnight Cartographers")
    }

    @Test func sectionsAreContiguousRunsInListOrder() {
        let names = ["4 AM", "Àlbum", "abba", "Ça", "Compass", "Drift", "おやすみ", "星屑"]
        let sections = LetterIndex.sections(names) { $0 }
        #expect(sections.map(\.key) == ["#", "A", "C", "D", "#"])
        #expect(sections.map(\.range) == [0..<1, 1..<3, 3..<5, 5..<6, 6..<8])
        // A key seen again later (other scripts sort after Z) is not the index's target for that key.
        #expect(sections.map(\.isFirstOfKey) == [true, true, true, true, false])
        #expect(LetterIndex.sections([String]()) { $0 }.isEmpty)
    }

    @Test func targetIsTheLetterOrTheNextOneAfterIt() {
        let sections = LetterIndex.sections(["4 AM", "Abba", "Compass", "Drift", "Zed", "おやすみ"]) { $0 }
        #expect(LetterIndex.target("A", in: sections)?.range.lowerBound == 1)
        #expect(LetterIndex.target("B", in: sections)?.range.lowerBound == 2)   // no B: C
        #expect(LetterIndex.target("#", in: sections)?.range.lowerBound == 0)
        #expect(LetterIndex.target("E", in: sections)?.range.lowerBound == 4)   // E…Y absent: Z
        // Past the last letter: the last section that starts a key.
        let short = LetterIndex.sections(["Abba", "Compass"]) { $0 }
        #expect(LetterIndex.target("X", in: short)?.range.lowerBound == 1)
        #expect(LetterIndex.target("A", in: []) == nil)
    }

    @Test func targetInAnUnsortedListIsTheFirstMatchOrTheNearestLetterAfter() {
        // The curated genre groups (Rock, Pop, Electronic …) aren't A–Z.
        let sections = LetterIndex.sections(["Rock", "Pop", "Electronic", "Jazz", "Blues"]) { $0 }
        #expect(LetterIndex.target("J", in: sections)?.range.lowerBound == 3)
        #expect(LetterIndex.target("C", in: sections)?.range.lowerBound == 2)   // no C: the nearest after (E)
        #expect(LetterIndex.target("S", in: sections)?.range.lowerBound == 0)   // nothing after S: the nearest before (R)
    }

    @Test func tenThousandNamesAreFast() {
        let names = (0..<10_000).map { i in ["Àlbum", "Ça", "4 AM", "Zed", "🎸", "The Moon"][i % 6] + " \(i)" }
        let start = Date()
        let sections = LetterIndex.sections(names, ignoringArticles: LetterIndex.navidromeArticles) { $0 }
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(sections.count == 10_000)   // every neighbour differs
        #expect(sections.map(\.range.count).reduce(0, +) == 10_000)
    }

    // MARK: - Seek (server-paged lists)

    /// The dev stack's song titles in Navidrome's order (title sort, verified 2026-10-30).
    static let devTitles = ["4 AM Cartography", "Àlbum de famille", "Ça ne fait rien", "Compass Rose", "Dead Reckoning",
                            "Drift", "Estuary", "Here Be Dragons", "L'été où tout a changé", "Meridian", "Œuvre inachevée",
                            "Terra Incognita", "おやすみ", "星屑"]

    @Test func seekFindsTheFirstOffsetOfALetterWithAKnownTotal() async throws {
        let titles = Self.devTitles
        let probes = Probes()
        @Sendable func at(_ i: Int) async -> String? { await probes.count(); return i < titles.count ? titles[i] : nil }
        #expect(try await LetterIndex.seek("D", total: titles.count, nameAt: at) == 4)
        #expect(try await LetterIndex.seek("O", total: titles.count, nameAt: at) == 10)
        #expect(try await LetterIndex.seek("A", total: titles.count, nameAt: at) == 1)
        #expect(try await LetterIndex.seek("#", total: titles.count, nameAt: at) == 0)
        #expect(try await LetterIndex.seek("B", total: titles.count, nameAt: at) == 2)    // no B: C
        #expect(try await LetterIndex.seek("U", total: titles.count, nameAt: at) == 12)   // past T: the other scripts
        #expect(await probes.n <= 6 * 6)
    }

    @Test func seekWithoutATotalGallopsAndIsBounded() async throws {
        let titles = (0..<5_000).map { i -> String in
            let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i / 200)))
            return "\(letter)song \(i)"
        }
        let probes = Probes()
        @Sendable func at(_ i: Int) async -> String? { await probes.count(); return i < titles.count ? titles[i] : nil }
        #expect(try await LetterIndex.seek("M", total: nil, nameAt: at) == 12 * 200)
        #expect(await probes.n <= 2 * 14)
        #expect(try await LetterIndex.seek("A", total: nil, nameAt: at) == 0)
        // Every name sorts before the letter: the end of the list.
        #expect(try await LetterIndex.seek("Z", total: nil, nameAt: at) == 5_000)
    }

    @Test func seekOverAnEmptyListIsZero() async throws {
        #expect(try await LetterIndex.seek("M", total: 0) { _ in nil } == 0)
        #expect(try await LetterIndex.seek("M", total: nil) { _ in nil } == 0)
    }

    @Test func seekRanksDropArticlesWhenAsked() async throws {
        let albums = ["Atlas", "Café", "The Cat Is Out", "Continuum", "Lowlands", "Paper Planes"]
        @Sendable func at(_ i: Int) async -> String? { i < albums.count ? albums[i] : nil }
        #expect(try await LetterIndex.seek("D", total: albums.count, ignoringArticles: LetterIndex.navidromeArticles,
                                            nameAt: at) == 4)
    }

    private actor Probes {
        var n = 0
        func count() { n += 1 }
    }
}

struct LetterJumpTests {
    let songs = ["4 AM", "Abba", "Compass", "Drift", "Meridian"]

    @Test func aLoadedLetterScrollsWithoutTheServer() {
        let sections = LetterIndex.sections(songs) { $0 }
        #expect(LetterIndex.loadedTarget("C", sections: sections, windowStart: 0, complete: false) == 2)
        #expect(LetterIndex.loadedTarget("#", sections: sections, windowStart: 0, complete: false) == 0)
        // Not loaded yet, and more may come: ask the server.
        #expect(LetterIndex.loadedTarget("P", sections: sections, windowStart: 0, complete: false) == nil)
        #expect(LetterIndex.loadedTarget("B", sections: sections, windowStart: 0, complete: false) == nil)
        // The whole list is loaded: the nearest letter.
        #expect(LetterIndex.loadedTarget("B", sections: sections, windowStart: 0, complete: true) == 2)
        #expect(LetterIndex.loadedTarget("P", sections: sections, windowStart: 0, complete: true) == 4)
    }

    @Test func aWindowStartingMidListOnlyTrustsLettersAfterItsFirstRun() {
        // The window starts at offset 300 inside the A run: A's first song may be earlier.
        let sections = LetterIndex.sections(["Abba 2", "Compass", "Drift"]) { $0 }
        #expect(LetterIndex.loadedTarget("A", sections: sections, windowStart: 300, complete: false) == nil)
        #expect(LetterIndex.loadedTarget("C", sections: sections, windowStart: 300, complete: false) == 1)
        #expect(LetterIndex.loadedTarget("#", sections: sections, windowStart: 300, complete: true) == nil)
    }

    @Test func aServerOffsetPagesForwardNearbyAndRestartsFarAway() {
        #expect(LetterIndex.move(toOffset: 120, windowStart: 100, windowEnd: 200, forwardLimit: 300) == .scroll(20))
        #expect(LetterIndex.move(toOffset: 450, windowStart: 0, windowEnd: 200, forwardLimit: 300) == .pageForward(untilOffset: 450))
        #expect(LetterIndex.move(toOffset: 600, windowStart: 0, windowEnd: 200, forwardLimit: 300) == .restart(at: 600))
        // Before the window: start again there.
        #expect(LetterIndex.move(toOffset: 10, windowStart: 100, windowEnd: 200, forwardLimit: 300) == .restart(at: 10))
        #expect(LetterIndex.move(toOffset: -5, windowStart: 0, windowEnd: 200, forwardLimit: 300) == .scroll(0))
    }
}
