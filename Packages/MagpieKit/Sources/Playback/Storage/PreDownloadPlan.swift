import Foundation
import MagpieCore

/// Which upcoming songs to pre-download into the cache (spec §6): the next `count` that aren't on the phone yet.
public enum PreDownloadPlan {
    /// The first `count` songs of `upcoming` that aren't local, each once, in queue order.
    public static func songs(upcoming: [Song], count: Int, isLocal: (String) -> Bool) -> [Song] {
        guard count > 0 else { return [] }
        var seen: Set<String> = []
        var out: [Song] = []
        for song in upcoming where !isLocal(song.id) && seen.insert(song.id).inserted {
            out.append(song)
            if out.count == count { break }
        }
        return out
    }
}
