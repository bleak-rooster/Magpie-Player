import Foundation
import MagpieCore
import ListenBrainzKit

/// Picks the release group to bring in for a song (A8): the smallest that contains it.
public struct ReleasePicker {
    /// - Parameter available: when non-nil, only these release groups may be chosen (A7: an artist already in
    ///   Lidarr only offers the release groups it has).
    /// Order: releases whose group has no secondary types (Live, Compilation, Remix, ...) unless none remain;
    /// then Official status, then Single, EP, Album, then (round 19) the one named after the song (its own single, not
    /// another single it is the B-side of), then earliest date.
    public static func smallest(containing recording: MBRecording, available rgIds: Set<MBID>?) -> MBID? {
        ordered(containing: recording, available: rgIds).first
    }

    /// Round 17: every release group holding the song, best first (the order `smallest` picks by), each once: the
    /// single, then an EP, then an album, so a release Lidarr can't find gives way to the next.
    public static func ordered(containing recording: MBRecording, available rgIds: Set<MBID>?) -> [MBID] {
        var candidates = recording.releases
        if let rgIds { candidates = candidates.filter { rgIds.contains($0.releaseGroup.id) } }
        let plain = candidates.filter { $0.releaseGroup.secondaryTypes.isEmpty }
        if !plain.isEmpty { candidates = plain }
        var seen = Set<MBID>()
        let song = SongIdentity.titleKey(recording.title)
        return candidates.sorted { ranks($0, $1, song: song) }.map(\.releaseGroup.id).filter { seen.insert($0).inserted }
    }

    private static func ranks(_ a: MBRelease, _ b: MBRelease, song: String) -> Bool {
        let (ka, kb) = (key(a), key(b))
        if ka.official != kb.official { return ka.official < kb.official }
        if ka.type != kb.type { return ka.type < kb.type }
        let (na, nb) = (named(a, song), named(b, song))
        if na != nb { return na }
        if ka.date != kb.date { return ka.date < kb.date }
        return a.releaseGroup.id.rawValue < b.releaseGroup.id.rawValue
    }

    /// The release is named after the song (round 19).
    private static func named(_ r: MBRelease, _ song: String) -> Bool {
        !song.isEmpty && SongIdentity.titleKey(r.title) == song
    }

    private static func key(_ r: MBRelease) -> (official: Int, type: Int, date: String) {
        let official = r.status?.lowercased() == "official" ? 0 : 1
        let type: Int
        switch r.releaseGroup.primaryType?.lowercased() {
        case "single": type = 0
        case "ep": type = 1
        case "album": type = 2
        default: type = 3
        }
        // Undated releases sort last; partial dates ("1985" < "1985-03") compare lexicographically.
        let date = (r.date?.isEmpty == false) ? r.date! : "9999"
        return (official, type, date)
    }
}
