import DesignSystem
import Search
import SwiftUI

/// Round 24 (owner, 2026-11-08): a list with the A–Z bar and more than 25 items gets a header per letter ("A", "B", …,
/// "#"), sticky as a list's section headers are (owner item 7; D225). One source of truth: the headers are the runs
/// `LetterIndex.sections` already gives the bar, never a second fold. On the phone's lists only (Q9). A server-paged
/// list (`PagedLetterList`) has runs only for what it has loaded, so only loaded runs get a header: a header for a
/// letter not yet read would claim rows that aren't there. A list can have two "#" runs (digits sort first, other
/// scripts last), so a header is named by its key and where its run starts.
struct LetterSectionHeader: View {
    let run: LetterIndex.Section
    /// Over a scroll view's pinned header (Songs, Albums, Genres, Downloads), not a `List`'s: give it a bar so rows
    /// don't show through, on the page's margins.
    var pinned = false
    @Environment(\.letterLayoutProbe) private var probe
    private let themed = Themed()

    /// Headers only above this many items.
    static let minimumItems = 25

    /// The runs that get a header: all of them when more than `minimumItems` items are shown and the bar is on screen
    /// (not hidden by accessibility text sizes or a short screen, D15), else none.
    static func runs(_ sections: [LetterIndex.Section], itemCount: Int, barShown: Bool) -> [LetterIndex.Section] {
        guard barShown, itemCount > minimumItems,
              let last = sections.last, last.range.upperBound == itemCount else { return [] }   // runs of this list only
        return sections
    }

    static func label(_ key: String) -> String { key }

    /// "#" read as words: VoiceOver would say "number".
    static func accessibilityLabel(_ key: String) -> String { key == "#" ? "Numbers and symbols" : key }

    /// The header's scroll id and accessibility identifier: its key and its run's start, so two "#" runs differ.
    static func id(_ run: LetterIndex.Section) -> String { "letter-header-\(run.key)-\(run.range.lowerBound)" }

    /// Where a scroll goes to bring an item in view.
    enum ScrollTarget: Hashable {
        /// A run's header: the item starts the run, so it shows with its letter above it.
        case header(String)
        /// An item (its index), put at the top.
        case item(Int)
    }

    /// Where to scroll so the item at `index` lands below its sticky header, never under it (fix round 1, I2): the
    /// header of its run when the item is on the run's first row; further in, the item a row before it (the header
    /// pins over that row); with no headers, the item itself. `rowLength`: items per row (a grid's columns).
    static func scrollTarget(index: Int, runs: [LetterIndex.Section], rowLength: Int = 1) -> ScrollTarget {
        guard let run = runs.first(where: { $0.range.contains(index) }) else { return .item(index) }
        let step = max(1, rowLength)
        return index - run.range.lowerBound < step ? .header(id(run)) : .item(index - step)
    }

    /// `scrollTarget` as a scroll id, with the items' ids.
    static func scrollID<ID: Hashable>(index: Int, runs: [LetterIndex.Section], rowLength: Int = 1,
                                       ids: (Int) -> ID) -> AnyHashable {
        switch scrollTarget(index: index, runs: runs, rowLength: rowLength) {
        case .header(let id): AnyHashable(id)
        case .item(let i): AnyHashable(ids(i))
        }
    }

    var body: some View {
        let key = run.key
        Text(Self.label(key))
            .font(.headline)
            .foregroundStyle(themed.palette.inkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pinned ? Tokens.Spacing.largeTitleMargin : 0)
            .padding(.vertical, pinned ? Tokens.Spacing.xs : 0)
            .background { if pinned { Rectangle().fill(.bar) } }
            .accessibilityLabel(Self.accessibilityLabel(key))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(Self.id(run))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe?(Self.id(run), $0) }
            .id(Self.id(run))
    }
}

extension EnvironmentValues {
    /// Tests only: where each letter header is on screen (fix round 1, I1/I2).
    @Entry var letterLayoutProbe: (@MainActor (String, CGRect) -> Void)?
}

/// A list's rows, one `Section` per letter run when `LetterSectionHeader.runs` says so (the bar's shown state comes
/// from `.letterIndex`, D225), else the rows as they were. In a `List` (sticky system headers) or, `pinned`, in a
/// `LazyVStack(pinnedViews: [.sectionHeaders])`.
struct LetterSectionedRows<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let sections: [LetterIndex.Section]
    let id: KeyPath<Item, ID>
    var pinned = false
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.letterIndexShown) private var barShown

    var body: some View {
        let runs = LetterSectionHeader.runs(sections, itemCount: items.count, barShown: barShown)
        if runs.isEmpty {
            ForEach(items, id: id) { row($0) }
        } else {
            ForEach(runs, id: \.range.lowerBound) { run in
                Section {
                    ForEach(items[run.range], id: id) { row($0) }
                } header: {
                    LetterSectionHeader(run: run, pinned: pinned)
                }
            }
        }
    }
}

extension ScrollViewProxy {
    /// A letter jump to the item at `index` (D225, fix round 1 I2): to its run's header when headers show, so the
    /// item is never under its own sticky header. The bar picked the letter, so it is on screen.
    @MainActor func scrollToLetter<ID: Hashable>(index: Int, sections: [LetterIndex.Section], itemCount: Int,
                                      barShown: Bool = true, rowLength: Int = 1, ids: (Int) -> ID) {
        let runs = LetterSectionHeader.runs(sections, itemCount: itemCount, barShown: barShown)
        scrollTo(LetterSectionHeader.scrollID(index: index, runs: runs, rowLength: rowLength, ids: ids), anchor: .top)
    }
}
