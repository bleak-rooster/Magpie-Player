import Foundation
import MagpieCore
import os

/// Round 27 H (owner, 2026-11-14): "In carplay, in the home screen, it should present the flows as the latest one that
/// was played" and Home's "based on last played" (D297, D298). When each Discover playlist (an Aurral flow or playlist)
/// last started playing on this phone or in the car, by playlist id. The quick grid's history keeps only 16 plays, too
/// few to order every flow, so these are kept apart.
enum FlowPlays {
    /// The most plays kept: past it the oldest go.
    static let limit = 300

    /// `plays` with `id` played at `date`, at most `limit` (the oldest dropped).
    static func noting(_ id: String, at date: Date, in plays: [String: Date]) -> [String: Date] {
        var plays = plays
        plays[id] = date
        return bounded(plays)
    }

    /// The newest `limit` of `plays` (equal dates keep the smaller id, so the cut is stable).
    static func bounded(_ plays: [String: Date]) -> [String: Date] {
        guard plays.count > limit else { return plays }
        let kept = plays.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// The flow plays on disk, one small file per account next to Home's saved shelves and the quick grid's history
/// (`QuickAccessStore`), so sign-out removes it with them (`HomeShelfCache.removeAll`). Playlist ids and dates only;
/// excluded from backup.
struct FlowPlaysStore {
    let url: URL

    init(root: URL, scope: String) {
        url = HomeShelfCache.directory(root: root).appending(path: "\(scope).flowplays.json")
    }

    /// The saved plays; none when there is no file or it doesn't read. Bounded whatever the file says.
    func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: url), data.count <= HomeShelfCache.maxBytes,
              let plays = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return FlowPlays.bounded(plays)
    }

    func save(_ plays: [String: Date]) {
        do {
            try AtomicFile.write(plays, to: url)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var saved = url
            try saved.setResourceValues(values)
        } catch {
            Log.logger("home").error("cannot save the flow plays: \(Log.category(of: error), privacy: .public)")
        }
    }
}
