import Foundation
import MagpieCore
import Search

// Round 12 item 2 (Y2): the car's long lists (Artists, Albums, Playlists) in A–Z. Under the car's limits a list is one
// section per letter ("#", then A–Z) with CarPlay's letter scrubber (`indexTitle`). Over them, the list opens with a
// letters screen: one row per letter, merged into ranges ("X–Z") only while the screen wouldn't fit, and a letter over
// the item limit split into pages ("S (1 of 3)"). A group's list is a third screen; its rows open their page as on a
// list under the limit (owner ruling: D12 allows CarPlay's depth of 5, tab → letters → group → page → Now Playing).

/// What a lettered list holds, for the letters screen's counts.
public enum CPLetterKind: Sendable, Hashable {
    case artists, albums, playlists
    /// Round 13: Songs' letter groups.
    case songs

    func count(_ n: Int) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    /// Round 13: an empty letter group's line ("No artists").
    var none: String { "No \(plural)" }

    private var singular: String {
        switch self {
        case .artists: "artist"
        case .albums: "album"
        case .playlists: "playlist"
        case .songs: "song"
        }
    }

    private var plural: String { singular + "s" }
}

/// One row of the letters screen: a run of the sorted list.
public struct CPLetterGroup: Sendable, Hashable {
    public var firstKey: String
    public var lastKey: String
    /// Positions in the sorted list.
    public var range: Range<Int>
    /// When one letter is split into pages: this page (1-based) and how many there are.
    public var pageIndex: Int?
    public var pageCount = 0

    /// "A", "X–Z", or "S (2 of 3)".
    public var title: String {
        if let pageIndex { return "\(firstKey) (\(pageIndex) of \(pageCount))" }
        return firstKey == lastKey ? firstKey : "\(firstKey)\u{2013}\(lastKey)"
    }

    /// Stable across reloads, distinct within the screen.
    var id: String {
        "letters.\(firstKey)-\(lastKey)" + (pageIndex.map { ".\($0)" } ?? "")
    }
}

/// One item of a lettered list and the letter it files under.
struct CPLetterEntry: Sendable {
    var key: String
    var sortName: String
    var row: CPRowModel
}

extension CarPlayRows {
    /// The letters screen's groups for `runs` (each letter's count, in list order) within `maxItems` rows. Letters
    /// stay apart while they fit; otherwise the smallest neighbouring pair merges first (leftmost on a tie), a merge
    /// never going past a page. A letter over a page is split into pages. When pages alone would overflow the screen,
    /// pages grow until it fits (the group lists are then clamped by the car).
    public static func letterGroups(_ runs: [(String, Int)], maxItems: Int) -> [CPLetterGroup] {
        let runs = runs.filter { $0.1 > 0 }
        let limit = max(1, maxItems)
        let total = runs.reduce(0) { $0 + $1.1 }
        var page = limit
        while true {
            let groups = groups(runs, page: page, limit: limit)
            if groups.count <= limit || page >= total { return groups }
            page += max(1, page / 2)
        }
    }

    private static func groups(_ runs: [(String, Int)], page: Int, limit: Int) -> [CPLetterGroup] {
        var groups: [CPLetterGroup] = []
        var offset = 0
        for (key, count) in runs {
            if count > page {
                let pages = (count + page - 1) / page
                for p in 0..<pages {
                    groups.append(CPLetterGroup(firstKey: key, lastKey: key,
                                                range: (offset + p * page)..<min(offset + (p + 1) * page, offset + count),
                                                pageIndex: p + 1, pageCount: pages))
                }
            } else {
                groups.append(CPLetterGroup(firstKey: key, lastKey: key, range: offset..<(offset + count)))
            }
            offset += count
        }
        while groups.count > limit {
            var best: Int?
            for i in groups.indices.dropLast() {
                let a = groups[i], b = groups[i + 1]
                guard a.pageIndex == nil, b.pageIndex == nil, a.range.count + b.range.count <= page else { continue }
                if best.map({ a.range.count + b.range.count < groups[$0].range.count + groups[$0 + 1].range.count }) ?? true {
                    best = i
                }
            }
            guard let i = best else { break }
            groups[i] = CPLetterGroup(firstKey: groups[i].firstKey, lastKey: groups[i + 1].lastKey,
                                      range: groups[i].range.lowerBound..<groups[i + 1].range.upperBound)
            groups.remove(at: i + 1)
        }
        return groups
    }

    /// Sorts `entries` by letter ("#" first, as the phone's index) then name, and lays them out: letter sections when
    /// they fit the car's limits, otherwise the letters screen.
    /// - Parameter note: a last row saying the list is incomplete ("Showing 5000 of 6100"); it takes one of the rows.
    static func lettered(_ entries: [CPLetterEntry], kind: CPLetterKind, maxItems: Int, maxSections: Int,
                         note: String? = nil) -> [CPSectionModel] {
        guard !entries.isEmpty else { return state(.empty) }
        let noteRow = note.map { CPRowModel(id: "az.more", title: $0, action: .none) }
        let maxItems = noteRow == nil ? maxItems : max(1, maxItems - 1)
        let maxSections = noteRow == nil ? maxSections : max(1, maxSections - 1)
        let order = Dictionary(uniqueKeysWithValues: LetterIndex.letters.enumerated().map { ($1, $0) })
        let sorted = entries.enumerated().sorted { l, r in
            let (a, b) = (l.element, r.element)
            if a.key != b.key { return (order[a.key] ?? 0) < (order[b.key] ?? 0) }
            let byName = a.sortName.localizedStandardCompare(b.sortName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return l.offset < r.offset
        }.map(\.element)
        var runs: [(String, Int)] = []
        for entry in sorted {
            if let last = runs.last, last.0 == entry.key { runs[runs.count - 1].1 += 1 } else { runs.append((entry.key, 1)) }
        }
        let noteSection = noteRow.map { [CPSectionModel(header: nil, rows: [$0])] } ?? []
        if sorted.count <= maxItems, runs.count <= maxSections {
            return letterSections(sorted) + noteSection
        }
        let groups = letterGroups(runs, maxItems: maxItems)
        let rows = groups.map { group -> CPRowModel in
            let members = Array(sorted[group.range])
            let detail = group.pageIndex == nil ? kind.count(members.count)
                : "\(members.first?.row.title ?? "") to \(members.last?.row.title ?? "")"
            return CPRowModel(id: group.id, title: group.title, detail: detail,
                              action: .open(.letterGroup(title: group.title, sections: letterSections(members))))
        }
        return [CPSectionModel(header: nil, rows: rows + (noteRow.map { [$0] } ?? []))]
    }

    /// One section per letter, headed and indexed by it.
    static func letterSections(_ entries: [CPLetterEntry]) -> [CPSectionModel] {
        var sections: [CPSectionModel] = []
        for entry in entries {
            if sections.last?.header == entry.key {
                sections[sections.count - 1].rows.append(entry.row)
            } else {
                sections.append(CPSectionModel(header: entry.key, rows: [entry.row], indexTitle: entry.key))
            }
        }
        return sections
    }

    static func letterEntry(name: String, articles: [String], row: CPRowModel) -> CPLetterEntry {
        CPLetterEntry(key: LetterIndex.key(name, ignoringArticles: articles),
                      sortName: String(LetterIndex.sortName(name, ignoringArticles: articles)), row: row)
    }
}
