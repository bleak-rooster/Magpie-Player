import Foundation

/// Fits `sections` into a CarPlay list's limits (read at runtime from `CPListTemplate`; often 12
/// items while driving). Empty sections go first, then sections past `maxSections`, then rows past
/// `maxItems`. When anything is cut, the last row says how much is shown, so a list never stops
/// silently partway (Amperfy #779/#764).
public func clamp(_ sections: [CPSectionModel], maxItems: Int, maxSections: Int) -> [CPSectionModel] {
    let nonEmpty = sections.filter { !$0.rows.isEmpty }
    let total = nonEmpty.reduce(0) { $0 + $1.rows.count }
    guard maxItems > 0, maxSections > 0 else { return [] }

    var kept: [CPSectionModel] = []
    var budget = maxItems
    for section in nonEmpty.prefix(maxSections) where budget > 0 {
        let rows = Array(section.rows.prefix(budget))
        budget -= rows.count
        kept.append(CPSectionModel(header: section.header, rows: rows, indexTitle: section.indexTitle))
    }

    let shown = kept.reduce(0) { $0 + $1.rows.count }
    guard shown < total, maxItems > 1, var last = kept.popLast() else { return kept }
    last.rows.removeLast()
    last.rows.append(CPRowModel(id: "clamp.more", title: "Showing \(shown - 1) of \(total)", action: .none))
    kept.append(last)
    return kept
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
