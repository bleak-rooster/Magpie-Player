import Foundation

/// Reads of what plays next that don't build the whole `upcoming` list (QC): a library-sized queue is thousands of
/// entries, and these run on the main actor on every queue edit and every playback tick.
public extension PlayQueue {
    /// `upcoming.count`, in constant time.
    var upcomingCount: Int {
        upNext.count + (currentIndex.map { main.count - $0 - 1 } ?? 0)
    }

    /// `upcoming.first`, in constant time.
    var nextUp: QueueEntry? {
        if let first = upNext.first { return first }
        guard let i = currentIndex, i + 1 < main.count else { return nil }
        return main[i + 1]
    }

    /// The first `limit` upcoming entries that pass `include`, in order. Stops as soon as it has them.
    func upcoming(limit: Int, where include: (QueueEntry) -> Bool = { _ in true }) -> [QueueEntry] {
        guard limit > 0 else { return [] }
        var out: [QueueEntry] = []
        out.reserveCapacity(limit)
        let rest = currentIndex.map { main[($0 + 1)...] } ?? []
        for entry in [upNext[...], rest].joined() where include(entry) {
            out.append(entry)
            if out.count == limit { break }
        }
        return out
    }
}
