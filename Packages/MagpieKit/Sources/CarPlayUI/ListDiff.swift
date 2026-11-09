import Foundation
import MagpieCore

/// Fits `sections` into a CarPlay list's limits (read at runtime from `CPListTemplate`; often 12 items while driving):
/// the page holding row `start` (rows counted over the list, empty sections left out).
///
/// Round 24 (owner, 2026-11-08): the car's lists stopped at the ceiling with a dead "Showing N of M" row. A list longer
/// than the ceiling is now cut into pages: the last row is "More…" ("10 more, F to J") and every page after the first
/// starts with "Previous…" (D231); `link` says what each opens (the controller puts the page in place of this one,
/// D232). The navigation rows and their sections count against the limits, so a page never exceeds them; letter
/// sections keep their index titles, so CarPlay's scrubber stays where they fit. A list within the limits comes back
/// as it is.
public func clamp(_ sections: [CPSectionModel], maxItems: Int, maxSections: Int, start: Int = 0,
                  link: (CPPageLink) -> RowAction = { _ in .none }) -> [CPSectionModel] {
    let nonEmpty = sections.filter { !$0.rows.isEmpty }
    guard maxItems > 0, maxSections > 0 else { return [] }
    var sectionOfRow: [Int] = []
    for (i, section) in nonEmpty.enumerated() { sectionOfRow += Array(repeating: i, count: section.rows.count) }
    let pages = CPPager.breaks(sectionOfRow, maxItems: maxItems, maxSections: maxSections)
    guard pages.count > 1 else { return pages.first.map { CPPager.content(nonEmpty, rows: $0) } ?? [] }
    let index = pages.firstIndex { $0.contains(start) } ?? (start < 0 ? 0 : pages.count - 1)
    func linkTo(_ i: Int) -> CPPageLink {
        let content = CPPager.content(nonEmpty, rows: pages[i])
        let letters = CPPager.letters(content)
        return CPPageLink(start: pages[i].lowerBound, count: pages[i].count, index: i, pageCount: pages.count,
                          firstLetter: letters?.first, lastLetter: letters?.last, span: CPPager.span(content))
    }
    let previous = index > 0 && CPPager.hasPrevious(maxItems: maxItems) ? linkTo(index - 1) : nil
    let next = index + 1 < pages.count ? linkTo(index + 1) : nil
    return CPPager.assemble(CPPager.content(nonEmpty, rows: pages[index]), previous: previous, next: next,
                            maxSections: maxSections, link: link)
}

/// Round 24 (owner, 2026-11-08): where a page's "More…" or "Previous…" row leads (D231).
public struct CPPageLink: Sendable, Hashable {
    /// The page's first row, counted over the list's rows.
    public var start: Int
    /// How many rows the page shows (navigation rows apart).
    public var count: Int
    /// Its place among the list's pages (0-based), and how many there are.
    public var index: Int?
    public var pageCount: Int?
    /// The first and last letters of a page of letter sections ("F", "J"); nil for other lists.
    public var firstLetter: String?
    public var lastLetter: String?
    /// "F to J" for letters, "Abba to Cure" for other rows; nil when the rows aren't read yet (Songs).
    public var span: String?

    public init(start: Int, count: Int, index: Int? = nil, pageCount: Int? = nil, firstLetter: String? = nil,
                lastLetter: String? = nil, span: String? = nil) {
        self.start = start; self.count = count; self.index = index; self.pageCount = pageCount
        self.firstLetter = firstLetter; self.lastLetter = lastLetter; self.span = span
    }

    /// The opened page's title: its letters ("F–J") when it covers more than one, otherwise its place in the list
    /// ("Mix (2 of 3)"); the list's own title for the first page.
    public func title(listTitle: String) -> String {
        if let firstLetter, let lastLetter, firstLetter != lastLetter { return "\(firstLetter)\u{2013}\(lastLetter)" }
        guard start > 0, let index, let pageCount else { return listTitle }
        return "\(listTitle) (\(index + 1) of \(pageCount))"
    }
}

/// Round 24 (owner, 2026-11-08): a page of a list, as a destination (D231, D232). The page is found again by its
/// first row (`start`), so a new ceiling lays the pages out again around the same rows.
public struct CPPageRef: Sendable, Hashable {
    /// What the list is (nil for a tab's own list or Up Next); a song group reads the page's songs from it.
    public var base: CPDestination?
    /// The list's own title, for the pages' "(2 of 3)".
    public var baseTitle: String
    /// This page's title.
    public var title: String
    public var start: Int

    public init(base: CPDestination?, baseTitle: String, title: String, start: Int) {
        self.base = base; self.baseTitle = baseTitle; self.title = title; self.start = start
    }

    /// What a page link of the list `base` titled `baseTitle` opens.
    public static func action(base: CPDestination?, baseTitle: String) -> @Sendable (CPPageLink) -> RowAction {
        { link in
            .open(.page(CPPageRef(base: base, baseTitle: baseTitle, title: link.title(listTitle: baseTitle),
                                  start: link.start)))
        }
    }
}

/// Round 24 (owner, 2026-11-08): the pages of a list too long for the car (D231). Pure, so the rules are unit-tested.
public enum CPPager {
    /// Row ids of the navigation rows; a list that already has them was paged by its own reads (a song group).
    public static let idPrefix = "page."
    static let moreTitle = "More\u{2026}"
    static let previousTitle = "Previous\u{2026}"

    /// Whether pages after the first start with "Previous…": a page needs room for it, a row and "More…".
    static func hasPrevious(maxItems: Int) -> Bool { maxItems >= 3 }

    /// The navigation rows sit in sections of their own when there is room for them and a section of rows.
    static func ownSections(maxSections: Int) -> Bool { maxSections >= 3 }

    /// The rows each page shows, for rows filed under `sectionOfRow` (section indices, in order). A page takes as many
    /// rows as fit with its navigation rows (and their sections) inside the limits; the last page needs no "More…".
    /// Every page shows at least one row, so the pages always end; with room for fewer than two rows a list can't be
    /// paged and shows its first row only.
    public static func breaks(_ sectionOfRow: [Int], maxItems: Int, maxSections: Int) -> [Range<Int>] {
        let total = sectionOfRow.count
        guard total > 0, maxItems > 0, maxSections > 0 else { return [] }
        guard maxItems >= 2 else { return [0..<1] }
        let own = ownSections(maxSections: maxSections)
        var pages: [Range<Int>] = []
        var start = 0
        while start < total {
            let previous = start > 0 && hasPrevious(maxItems: maxItems) ? 1 : 0
            func fitting(next: Int) -> Int {
                let items = maxItems - previous - next
                let sections = maxSections - (own ? previous + next : 0)
                var n = 0, touched = 0, last = -1
                while start + n < total, n < items {
                    let section = sectionOfRow[start + n]
                    if section != last {
                        guard touched < sections else { break }
                        touched += 1
                        last = section
                    }
                    n += 1
                }
                return n
            }
            if start + fitting(next: 0) == total {
                pages.append(start..<total)
                break
            }
            let n = max(1, fitting(next: 1))
            pages.append(start..<(start + n))
            start += n
        }
        return pages
    }

    /// The breaks for `rowCount` rows in one section (a song group, read a page at a time).
    public static func breaks(rowCount: Int, maxItems: Int, maxSections: Int) -> [Range<Int>] {
        breaks(Array(repeating: 0, count: max(0, rowCount)), maxItems: maxItems, maxSections: maxSections)
    }

    /// The sections holding `rows` (positions over the rows of `sections`, none empty), each keeping its header and
    /// index title.
    static func content(_ sections: [CPSectionModel], rows: Range<Int>) -> [CPSectionModel] {
        var out: [CPSectionModel] = []
        var position = 0
        for section in sections {
            let lower = max(rows.lowerBound, position), upper = min(rows.upperBound, position + section.rows.count)
            if lower < upper {
                out.append(CPSectionModel(header: section.header,
                                          rows: Array(section.rows[(lower - position)..<(upper - position)]),
                                          indexTitle: section.indexTitle))
            }
            position += section.rows.count
        }
        return out
    }

    /// A page of letter sections: its first and last letters.
    static func letters(_ content: [CPSectionModel]) -> (first: String, last: String)? {
        let keys = content.compactMap(\.indexTitle)
        guard keys.count == content.count, let first = keys.first, let last = keys.last else { return nil }
        return (first, last)
    }

    /// "F to J" (letters) or "Abba to Cure" (first and last row); one name when they are the same.
    static func span(_ content: [CPSectionModel]) -> String? {
        let (first, last) = letters(content)
            ?? (content.first?.rows.first?.title ?? "", content.last?.rows.last?.title ?? "")
        guard !first.isEmpty else { return nil }
        return first == last ? first : "\(first) to \(last)"
    }

    /// A page's sections: "Previous…" first, the rows, "More…" last; the navigation rows in sections of their own when
    /// they fit, otherwise in the first and last of the page's sections.
    public static func assemble(_ content: [CPSectionModel], previous: CPPageLink?, next: CPPageLink?, maxSections: Int,
                                link: (CPPageLink) -> RowAction) -> [CPSectionModel] {
        var sections = content
        let back = previous.map {
            CPRowModel(id: idPrefix + "previous", title: previousTitle, detail: $0.span, action: link($0))
        }
        let more = next.map { next in
            CPRowModel(id: idPrefix + "more", title: moreTitle,
                       detail: "\(next.count) more" + (next.span.map { ", \($0)" } ?? ""), action: link(next))
        }
        let navigation = (back == nil ? 0 : 1) + (more == nil ? 0 : 1)
        if ownSections(maxSections: maxSections), sections.count + navigation <= maxSections {
            if let back { sections.insert(CPSectionModel(header: nil, rows: [back]), at: 0) }
            if let more { sections.append(CPSectionModel(header: nil, rows: [more])) }
        } else if !sections.isEmpty {
            if let back { sections[0].rows.insert(back, at: 0) }
            if let more { sections[sections.count - 1].rows.append(more) }
        }
        return sections
    }

    /// Whether `sections` already hold navigation rows (a song group pages by its own reads).
    static func isPaged(_ sections: [CPSectionModel]) -> Bool {
        sections.contains { $0.rows.contains { $0.id.hasPrefix(idPrefix) } }
    }
}

/// True when the list's shape changed (sections, headers, or row ids and their order) and the
/// sections must be replaced. Anything else (text, detail, playing, artwork, action) is updated
/// in place on the existing items, so a list being browsed never jumps (Amperfy #647).
public func needsRebuild(old: [CPSectionModel], new: [CPSectionModel]) -> Bool {
    guard old.count == new.count else { return true }
    for (a, b) in zip(old, new) {
        if a.header != b.header || a.indexTitle != b.indexTitle || a.rows.map(\.id) != b.rows.map(\.id) { return true }
    }
    return false
}

/// Orders the search template's answers. Each keystroke starts a query; queries can finish out
/// of order. Only the newest query's results are shown; an older one that finishes (or is
/// cancelled) later hands back what is already showing, never an empty list that would blank
/// the newer results.
public struct LatestResults<Item> {
    public private(set) var generation = 0
    /// The list most recently handed to the system.
    public private(set) var delivered: [Item] = []

    public init() {}

    /// A new query starts; returns its ticket.
    public mutating func begin() -> Int {
        generation += 1
        return generation
    }

    public func isCurrent(_ ticket: Int) -> Bool { ticket == generation }

    /// What the query with `ticket` should complete with: its own `items` when it is the newest
    /// (they become what's showing), otherwise what is showing already.
    public mutating func complete(_ ticket: Int, with items: [Item]) -> [Item] {
        guard isCurrent(ticket) else { return delivered }
        delivered = items
        return items
    }

    /// A superseded or cancelled query completes with what is showing.
    public func stale() -> [Item] { delivered }
}
