import Foundation

/// Round 14 A3 (D100, D103): the one rule for "the same song" across the server's charts, MusicBrainz tracklists and the
/// library, where no shared id exists: the artist (folded), the title (folded, without version notes such as
/// "(feat. …)" or " - Remastered 2011") and the length within 3 s. Both lengths must be known: never by name alone.
public enum SongIdentity {
    public static let durationTolerance: TimeInterval = 3

    /// Case, accents, width and punctuation folded; a trailing " - …" note and bracketed notes dropped.
    public static func titleKey(_ title: String) -> String {
        var s = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }
        let stripped = removingBrackets(s)
        if !words(stripped).isEmpty { s = stripped }
        return words(s)
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

    private static func removingBrackets(_ s: String) -> String {
        var out = ""
        var depth = 0
        for c in s {
            if c == "(" || c == "[" { depth += 1; continue }
            if c == ")" || c == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(c) }
        }
        return out
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
