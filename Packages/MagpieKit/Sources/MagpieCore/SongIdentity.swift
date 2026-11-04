import Foundation

/// Round 14 A3 (D100, D103): the one rule for "the same song" across the server's charts, MusicBrainz tracklists and the
/// library, where no shared id exists: the artist (folded), the title (folded, without version notes such as
/// "(feat. …)" or " - Remastered 2011") and the length within 3 s. Both lengths must be known: never by name alone.
public enum SongIdentity {
    public static let durationTolerance: TimeInterval = 3

    /// Case, accents, width and punctuation folded. A bracketed or trailing " - …" note is dropped only when it is noise
    /// (featured artists, a remaster, explicit/clean, album or single version: fix round 1, M6); a note that names another
    /// recording ("Live", "Remix", "Acoustic", "Demo", "Radio Edit"…) stays part of the title.
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
        let kept = notes.filter { !isNoise($0) }.map(words).filter { !$0.isEmpty }
        let base = words(outside)
        // A title that is all brackets ("(Untitled)") keeps its words.
        if base.isEmpty { return words(main) }
        return ([base] + kept).joined(separator: " ")
    }

    /// A note that starts with one of these words is featured artists.
    private static let featuring: Set<String> = ["feat", "ft", "featuring", "with"]
    private static let noiseWords = ["remaster", "explicit", "clean", "album version", "single version", "lp version",
                                     "mono version", "stereo version"]

    private static func isNoise(_ note: String) -> Bool {
        let w = words(note)
        guard let first = w.split(separator: " ").first else { return true }
        if featuring.contains(String(first)) { return true }
        return noiseWords.contains { w.contains($0) }
    }

    /// The artist's name folded the same way (a leading "the" kept: names are compared whole).
    public static func artistKey(_ artist: String) -> String {
        let folded = artist.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key = words(folded)
        // "Tides, The" reads as "The Tides".
        if key.hasSuffix(" the") { key = "the " + key.dropLast(4) }
        return key
    }

    /// Both known (finite, above zero) and within 3 s of each other.
    public static func sameDuration(_ a: TimeInterval?, _ b: TimeInterval?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(a - b) <= durationTolerance
    }

    public static func same(title: String, artist: String, duration: TimeInterval?,
                            as otherTitle: String, artist otherArtist: String, duration otherDuration: TimeInterval?) -> Bool {
        sameDuration(duration, otherDuration) && titleKey(title) == titleKey(otherTitle)
            && artistKey(artist) == artistKey(otherArtist) && !titleKey(title).isEmpty
    }

    /// The text outside brackets, and each bracketed note.
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

    private static func words(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0 != "'" && $0 != "\u{2019}" }
        return String(String.UnicodeScalarView(kept))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Round 14 A3 (owner answer 6, D104): where an artist's Top songs come from (Settings › Home & Library › Artist top
/// songs). Settings may name the services; everything else says "Top songs".
public enum ArtistTopSongsSource: String, CaseIterable, Codable, Hashable, Sendable {
    /// The server's (Aurral's) top songs, else ListenBrainz's, else the library's.
    case automatic
    case aurral
    case listenBrainz
    case library

    /// What the picker offers: without Aurral, no Aurral.
    public static func choices(aurral: Bool) -> [ArtistTopSongsSource] {
        aurral ? allCases : allCases.filter { $0 != .aurral }
    }
}
