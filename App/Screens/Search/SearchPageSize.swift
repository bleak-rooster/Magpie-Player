import Foundation

/// Search's batch size override (round 12, Y1). UI tests only: with `-MagpieUITesting YES -MagpieSearchPageSize 5` the
/// small dev library has several batches to load. A production launch never passes these, so it always uses the
/// built-in sizes (20 songs, 10 albums, 10 artists).
enum SearchPageSize {
    static func override(_ defaults: UserDefaults) -> Int? {
        guard defaults.string(forKey: "MagpieUITesting") == "YES" else { return nil }
        let n = defaults.integer(forKey: "MagpieSearchPageSize")
        return n > 0 ? n : nil
    }
}
