import Foundation
import MagpieCore

/// Round 28 S (owner, 2026-11-15): what Search's song and album rows say under their titles, and what VoiceOver
/// reads. Every song row says "Song · <artist>" and every album row "Album · <artist>" (an outside album its kind,
/// "EP · <artist>"), so the artist is named on each one; an artist that came back empty or blank leaves just the kind,
/// never a blank line or a dangling " · " (D338). Artist rows keep their own line ("Artist · N albums"). Pure.
public enum SearchRowText {
    private static let dot = " \u{00B7} "

    /// "Song · Corin Hale"; "Song" when the artist is empty.
    public static func songDetail(_ song: Song) -> String { songDetail(artist: song.artist) }

    public static func songDetail(artist: String) -> String {
        line(kind: "Song", artist: artist)
    }

    /// "Album · Corin Hale", or an outside album's kind ("EP · Corin Hale"); "Album" / "EP" when the artist is empty.
    /// A compilation reads "Album · Various Artists" (the library's own album artist).
    public static func albumDetail(artist: String, kind: String? = nil) -> String {
        line(kind: albumKind(kind), artist: artist)
    }

    /// VoiceOver: "Harbour Lights, song by Corin Hale"; "Harbour Lights, song" when the artist is empty.
    public static func songLabel(_ song: Song) -> String { songLabel(title: song.title, artist: song.artist) }

    public static func songLabel(title: String, artist: String) -> String {
        label(title: title, kind: "song", artist: artist)
    }

    /// VoiceOver: "Glasshouse, album by Corin Hale"; an outside album "Low Tide, EP by Corin Hale".
    public static func albumLabel(name: String, artist: String, kind: String? = nil) -> String {
        let word = albumKind(kind)
        // Spoken mid-sentence: "single", "album", "live" (even "LIVE"); only a short initialism on the allow-list stays
        // in capitals ("EP"), fix round 1 (L3).
        let spoken = spokenInitialisms.contains(word.uppercased()) ? word.uppercased() : word.lowercased()
        return label(title: name, kind: spoken, artist: artist)
    }

    /// Kinds VoiceOver reads letter by letter.
    static let spokenInitialisms: Set = ["EP", "LP"]

    // MARK: - Private

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func albumKind(_ kind: String?) -> String {
        let kind = trimmed(kind ?? "")
        return kind.isEmpty ? "Album" : kind
    }

    private static func line(kind: String, artist: String) -> String {
        let artist = trimmed(artist)
        return artist.isEmpty ? kind : kind + dot + artist
    }

    private static func label(title: String, kind: String, artist: String) -> String {
        let artist = trimmed(artist)
        let what = artist.isEmpty ? kind : "\(kind) by \(artist)"
        let title = trimmed(title)
        return title.isEmpty ? what : "\(title), \(what)"
    }
}
