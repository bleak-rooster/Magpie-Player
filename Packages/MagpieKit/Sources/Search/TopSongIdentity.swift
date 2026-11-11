import Foundation
import MagpieCore
import MatchIndex

/// Round 26 K1 (owner, 2026-11-10): "the same song" when an artist's top song is looked for on one of their albums or EPs
/// (the album step, D260/D261). A single's "Song (Radio Edit)" is the album's "Song"; "Song (Reprise)", "Song (Live)" or
/// "Song (Taylor's Version)" never are.
///
/// `SongIdentity.titleKey`'s folding and bracket/dash splitting, with more notes counted as housekeeping: everything in
/// `Normalize.sameRecordingPhrases` (radio edit/version, album/single/LP/mono/stereo/explicit/clean version, original
/// mix/version, 7"/12" version), plus "edit", "single edit" and "radio mix", a featured-artist credit, a remaster and
/// explicit/clean. Any other note stays part of the key on either side (a wrong song is worse than a skipped one).
/// `SongIdentity` itself is not changed: Try keeps "Radio Edit" significant (D104a M6).
public enum TopSongIdentity {
    /// Whole notes (after punctuation is dropped) that name the same recording.
    static let housekeepingPhrases: Set<String> = Normalize.sameRecordingPhrases.union(["edit", "single edit", "radio mix"])

    /// Words that make a note name another recording even when it also says "remastered", "explicit" or "clean"
    /// ("Live / Remastered 2011" stays apart).
    static let otherRecordingWords: Set<String> = Normalize.versionWords.subtracting(["version", "edit"]).union([
        "reprise", "interlude", "intro", "outro", "extended", "dub", "rehearsal", "session", "sessions", "orchestral",
        "reimagined", "rerecorded", "taylors",
    ])

    /// A note that starts with one of these words is a featured-artist credit. Fix round 1 (M1 ruling): not "with", unlike
    /// `SongIdentity`: "(With Strings)" is another arrangement; a skipped "(with Sam)" is the price.
    private static let featuring: Set<String> = ["feat", "ft", "featuring"]

    /// The title's key: folded (case, accents, width, punctuation), housekeeping notes dropped, every other note kept.
    /// Empty only when the title has no letters or digits.
    public static func titleKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var main = folded
        var notes: [String] = []
        if let dash = folded.range(of: " - ") {
            main = String(folded[..<dash.lowerBound])
            notes.append(String(folded[dash.upperBound...]))
        }
        let (outside, bracketed) = splitBrackets(main)
        notes = bracketed + notes
        let kept = notes.map(words).filter { !$0.isEmpty && !isHousekeeping($0) }
        let base = words(removingFeat(outside))
        // A title that is all brackets ("(Untitled)") keeps its words.
        if base.isEmpty { return words(main) }
        return ([base] + kept).joined(separator: " ")
    }

    /// `note` is already in `words` form.
    static func isHousekeeping(_ note: String) -> Bool {
        if housekeepingPhrases.contains(note) { return true }
        let parts = note.split(separator: " ").map(String.init)
        guard let first = parts.first else { return true }
        if featuring.contains(first) { return true }
        let tidy = parts.contains { $0.hasPrefix("remaster") || $0 == "explicit" || $0 == "clean" }
        let other = parts.contains { otherRecordingWords.contains($0) }
        // "Remastered Version" and "Radio Edit / Remastered" are tidy; anything else in such a note keeps it.
        let rest = parts.filter { !$0.hasPrefix("remaster") && !["explicit", "clean", "version", "radio", "edit",
                                                                 "single", "album", "digitally"].contains($0)
                                  && !$0.allSatisfy(\.isNumber) }
        return tidy && !other && rest.isEmpty
    }

    /// Cuts an unbracketed credit ("song feat. x" → "song"); never at the first word.
    private static func removingFeat(_ s: String) -> String {
        var kept: [Substring] = []
        for (i, word) in s.split(whereSeparator: \.isWhitespace).enumerated() {
            if i > 0, word == "featuring" || word.hasPrefix("feat.") || word.hasPrefix("ft.") { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// The text outside brackets, and each bracketed note (as `SongIdentity` splits them).
    private static func splitBrackets(_ s: String) -> (String, [String]) {
        var out = ""
        var notes: [String] = []
        var current = ""
        var depth = 0
        for c in s {
            if c == "(" || c == "[" {
                if depth == 0 { current = "" } else { current.append(" ") }
                depth += 1
                continue
            }
            if c == ")" || c == "]" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 { notes.append(current) }
                }
                continue
            }
            if depth == 0 { out.append(c) } else { current.append(c) }
        }
        if depth > 0 { notes.append(current) }
        return (out, notes)
    }

    /// Apostrophes dropped ("Taylor's" is "taylors"), every other non-alphanumeric a space, runs collapsed.
    private static func words(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0 != "'" && $0 != "\u{2019}" }
        return String(String.UnicodeScalarView(kept))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
