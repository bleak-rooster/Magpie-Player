import DesignSystem
import Search
import SwiftUI

/// Round 24 (owner, 2026-11-08): a list with the A–Z bar and more than 25 items gets a header per letter ("A", "B", …,
/// "#"), sticky as a list's section headers are (owner item 7; D225). One source of truth: the headers are the runs
/// `LetterIndex.sections` already gives the bar, never a second fold. On the phone's lists only (Q9). A server-paged
/// list (`PagedLetterList`) has runs only for what it has loaded, so only loaded runs get a header: a header for a
/// letter not yet read would claim rows that aren't there.
struct LetterSectionHeader: View {
    let key: String
    /// Over a scroll view's pinned header (Songs, Albums), not a `List`'s: give it a bar so rows don't show through.
    var pinned = false
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

    var body: some View {
        Text(Self.label(key))
            .font(.headline)
            .foregroundStyle(themed.palette.inkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pinned ? Tokens.Spacing.largeTitleMargin : 0)
            .padding(.vertical, pinned ? Tokens.Spacing.xs : 0)
            .background { if pinned { Rectangle().fill(.bar) } }
            .accessibilityLabel(Self.accessibilityLabel(key))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("letter-header-\(key)")
    }
}

/// A `List`'s rows, one `Section` per letter run when `LetterSectionHeader.runs` says so (the bar's shown state comes
/// from `.letterIndex`, D225), else the rows as they were.
struct LetterSectionedRows<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let sections: [LetterIndex.Section]
    let id: KeyPath<Item, ID>
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
                    LetterSectionHeader(key: run.key)
                }
            }
        }
    }
}
