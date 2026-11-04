import Foundation

/// One generic ordered list of items with a visibility switch each. Used by Home sections and Library rows.
public struct OrderedVisibility<Item: CaseIterable & RawRepresentable & Hashable & Sendable>: Codable, Hashable, Sendable
    where Item.RawValue == String, Item.AllCases: Sendable {
    public struct Entry: Hashable, Sendable {
        public var item: Item
        public var visible: Bool
        public init(item: Item, visible: Bool) { self.item = item; self.visible = visible }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry]) { self.entries = entries }

    public var visibleItems: [Item] { entries.filter(\.visible).map(\.item) }

    /// false (and no change) when hiding `item` would leave no visible item among `keepingOneOf`.
    @discardableResult
    public mutating func set(_ item: Item, visible: Bool, keepingOneOf required: Set<Item>) -> Bool {
        guard let index = entries.firstIndex(where: { $0.item == item }) else { return false }
        if !visible, required.contains(item) {
            let others = entries.contains { $0.item != item && $0.visible && required.contains($0.item) }
            if !others { return false }
        }
        entries[index].visible = visible
        return true
    }

    /// `Array.move(fromOffsets:toOffset:)` of SwiftUI, without needing SwiftUI.
    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.filter { entries.indices.contains($0) }.map { entries[$0] }
        guard !moving.isEmpty else { return }
        let before = fromOffsets.filter { $0 < toOffset }.count
        for index in fromOffsets.reversed() where entries.indices.contains(index) { entries.remove(at: index) }
        entries.insert(contentsOf: moving, at: max(0, min(entries.count, toOffset - before)))
    }

    public mutating func moveUp(_ item: Item) {
        guard let index = entries.firstIndex(where: { $0.item == item }), index > 0 else { return }
        entries.swapAt(index, index - 1)
    }

    public mutating func moveDown(_ item: Item) {
        guard let index = entries.firstIndex(where: { $0.item == item }), index < entries.count - 1 else { return }
        entries.swapAt(index, index + 1)
    }

    /// Drops duplicates (first wins), then appends items missing from `defaults` with their default visibility.
    public func normalised(against defaults: OrderedVisibility) -> OrderedVisibility {
        normalised(against: defaults, insertingAfterPredecessor: [])
    }

    /// As `normalised(against:)`, except that a missing item in `afterPredecessor` goes right after the nearest item
    /// before it in `defaults` (round 14 A4: Library's Trending and Recommended after Discover), once the others have
    /// been appended; with none of its predecessors present, it goes first.
    public func normalised(against defaults: OrderedVisibility, insertingAfterPredecessor afterPredecessor: Set<Item>)
        -> OrderedVisibility {
        var seen = Set<Item>()
        var result = entries.filter { seen.insert($0.item).inserted }
        for entry in defaults.entries where !seen.contains(entry.item) && !afterPredecessor.contains(entry.item) {
            result.append(entry)
            seen.insert(entry.item)
        }
        for (index, entry) in defaults.entries.enumerated() where !seen.contains(entry.item) {
            let before = defaults.entries[..<index].reversed().first { d in seen.contains(d.item) }
            let at = before.flatMap { b in result.firstIndex { $0.item == b.item } }.map { $0 + 1 } ?? 0
            result.insert(entry, at: at)
            seen.insert(entry.item)
        }
        return OrderedVisibility(result)
    }

    // MARK: Coding: `[{"id": rawValue, "visible": Bool}]`, lossy element by element.

    private struct Stored: Codable { var id: String; var visible: Bool }
    private struct Skip: Decodable {}

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Entry] = []
        while !container.isAtEnd {
            // A failed decode leaves the container where it was, so a bad element is skipped explicitly.
            if let stored = try? container.decode(Stored.self) {
                if let item = Item(rawValue: stored.id) { result.append(Entry(item: item, visible: stored.visible)) }
            } else if (try? container.decode(Skip.self)) == nil {
                break   // an element that can't even be skipped; the rest is unreadable
            }
        }
        self.entries = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for entry in entries { try container.encode(Stored(id: entry.item.rawValue, visible: entry.visible)) }
    }
}
