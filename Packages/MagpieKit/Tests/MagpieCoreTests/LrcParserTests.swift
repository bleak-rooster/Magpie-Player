import Foundation
import MagpieTestSupport
import Testing
@testable import MagpieCore

/// Round 27 L (owner, 2026-11-14): LRCLIB's lyrics read on the phone. Synced lyrics first (LRC stamps, several to a
/// line, sorted, `[offset:]` applied, other tags skipped), plain lyrics next, then the instrumental note; at most 2,000
/// lines of 500 characters; anything unparsable is none (D312).
@Suite struct LrcParserTests {
    @Test func lrc_parsesMultiStampAndSorts() throws {
        let text = """
        [ti:Wide Open]
        [ar:Aurora Field]
        [00:12.50][01:02.25]Chorus line
        [00:05.00] First line
        [00:30.123]Thousandths
        [100:00.00]Late
        """
        let lyrics = try #require(LrcParser.synced(text))
        #expect(lyrics.synced)
        #expect(lyrics.lines == [
            LyricLine(start: 5, text: "First line"),
            LyricLine(start: 12.5, text: "Chorus line"),
            LyricLine(start: 30.123, text: "Thousandths"),
            LyricLine(start: 62.25, text: "Chorus line"),
            LyricLine(start: 6000, text: "Late"),
        ])
    }

    @Test func lrc_keepsEmptyStampedLinesAndStampsWithoutFraction() throws {
        let lyrics = try #require(LrcParser.synced("[00:01]One\n[00:02.00]\n[00:03.5]Three"))
        #expect(lyrics.lines.map(\.text) == ["One", "", "Three"])
        #expect(lyrics.lines.map(\.start) == [1, 2, 3.5])
    }

    @Test func lrc_appliesOffset() throws {
        // A positive offset shows the lines sooner; a negative one later; never before zero.
        let sooner = try #require(LrcParser.synced("[offset:+500]\n[00:01.00]a\n[00:10.00]b"))
        #expect(sooner.lines.map(\.start) == [0.5, 9.5])
        let later = try #require(LrcParser.synced("[offset:-1500]\n[00:01.00]a"))
        #expect(later.lines.map(\.start) == [2.5])
        let clamped = try #require(LrcParser.synced("[offset:5000]\n[00:01.00]a"))
        #expect(clamped.lines.map(\.start) == [0])
        let silly = try #require(LrcParser.synced("[offset:99999999999999999999]\n[00:01.00]a"))
        #expect(silly.lines.map(\.start) == [1], "an offset that doesn't read is ignored")
    }

    @Test func lrc_rejectsBadStamps() {
        #expect(LrcParser.synced("[1000:00.00]too many minutes") == nil)
        #expect(LrcParser.synced("[00:61.00]bad seconds") == nil)
        #expect(LrcParser.synced("[00:01.0000]four digits") == nil)
        #expect(LrcParser.synced("just words") == nil)
        #expect(LrcParser.synced("") == nil)
        #expect(LrcParser.synced("[ar:Someone]\n[ti:Nothing else]") == nil)
    }

    @Test func lrc_plainFallback() throws {
        let answer = LrcParser.answer(synced: "no stamps at all", plain: "\n  One  \n\nTwo\n\n", instrumental: false)
        #expect(answer == .lines(Lyrics(synced: false, lines: [LyricLine(text: "One"), LyricLine(text: ""), LyricLine(text: "Two")])))
        #expect(LrcParser.answer(synced: nil, plain: "  \n ", instrumental: false) == nil)
        #expect(LrcParser.answer(synced: "[00:01.00]sung", plain: "plain", instrumental: false)
                == .lines(Lyrics(synced: true, lines: [LyricLine(start: 1, text: "sung")])), "synced first")
    }

    @Test func lrc_instrumental() {
        #expect(LrcParser.answer(synced: nil, plain: nil, instrumental: true) == .instrumental)
        #expect(LrcParser.answer(synced: "", plain: "", instrumental: true) == .instrumental)
        #expect(LrcParser.answer(synced: nil, plain: nil, instrumental: false) == nil)
    }

    @Test func lrc_bounds() throws {
        let many = (0..<2_500).map { String(format: "[%02d:%02d.00]line %d", $0 / 60, $0 % 60, $0) }.joined(separator: "\n")
        let synced = try #require(LrcParser.synced(many))
        #expect(synced.lines.count == LrcParser.maxLines && LrcParser.maxLines == 2_000)
        let long = try #require(LrcParser.synced("[00:01.00]" + String(repeating: "x", count: 900)))
        #expect(long.lines[0].text.count == 500 && LrcParser.maxLineLength == 500)
        let plain = try #require(LrcParser.plain(String(repeating: "y\n", count: 3_000) + String(repeating: "z", count: 700)))
        #expect(plain.lines.count == 2_000 && plain.lines.allSatisfy { $0.text.count <= 500 })
    }

    /// Seeded fuzz: 500 random LRC-like texts (stamps, tags, brackets, digits, unicode and control characters). Never a
    /// trap; every answer within the bounds, sorted, with finite non-negative starts.
    @Test func lrc_boundsAndGarbage() {
        var rng = SeededRNG(seed: 27_0014)
        let pieces = ["[", "]", ":", ".", "0", "5", "9", "12", "999", "1000", "-", "+", "offset", "ar", "ti", "\n", "\r\n",
                      "\r", " ", "la", "é", "🎵", "\u{0}", "\u{202E}", "[00:01.00]", "[59:59.999]", "[offset:-300]",
                      "[00:", "99999999999999999999", String(repeating: "w", count: 600)]
        for _ in 0..<500 {
            let count = Int.random(in: 0...200, using: &rng)
            let text = (0..<count).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
            let asPlain = Bool.random(using: &rng)
            let answer = LrcParser.answer(synced: asPlain ? nil : text, plain: asPlain ? text : nil,
                                          instrumental: Bool.random(using: &rng))
            guard case .lines(let lyrics) = answer else { continue }
            #expect(!lyrics.lines.isEmpty && lyrics.lines.count <= LrcParser.maxLines)
            #expect(lyrics.lines.allSatisfy { $0.text.count <= LrcParser.maxLineLength })
            #expect(lyrics.lines.contains { !$0.text.isEmpty })
            if lyrics.synced {
                let starts = lyrics.lines.compactMap(\.start)
                #expect(starts.count == lyrics.lines.count)
                #expect(starts.allSatisfy { $0.isFinite && $0 >= 0 })
                #expect(starts == starts.sorted())
            }
        }
    }
}
