import MagpieCore
import SwiftUI

/// One editor for any `OrderedVisibility` list (Home sections, Library rows): drag handles (always in edit mode), a
/// switch per row, VoiceOver "Move up" and "Move down" actions (D15), a footer line per item, switches that are
/// disabled when turning them off would leave none of `keepingOneOf` showing, and "Reset to default order".
struct OrderedVisibilityEditor<Item: CaseIterable & RawRepresentable & Hashable & Sendable>: View
    where Item.RawValue == String, Item.AllCases: Sendable {
    private let title: String
    @Binding private var list: OrderedVisibility<Item>
    private let defaults: OrderedVisibility<Item>
    private let label: (Item) -> String
    private let footer: (Item) -> String?
    private let keepingOneOf: Set<Item>
    private let extra: AnyView

    init(title: String, list: Binding<OrderedVisibility<Item>>, defaults: OrderedVisibility<Item>,
         label: @escaping (Item) -> String, footer: @escaping (Item) -> String? = { _ in nil },
         keepingOneOf: Set<Item> = [], @ViewBuilder extra: () -> some View = { EmptyView() }) {
        self.title = title
        self._list = list
        self.defaults = defaults
        self.label = label
        self.footer = footer
        self.keepingOneOf = keepingOneOf
        self.extra = AnyView(extra())
    }

    /// Whether `item`'s switch can change: showing always can; hiding can unless it would leave none of `keepingOneOf`.
    static func canToggle(_ item: Item, in list: OrderedVisibility<Item>, keepingOneOf: Set<Item>) -> Bool {
        guard let entry = list.entries.first(where: { $0.item == item }) else { return false }
        var copy = list
        return copy.set(item, visible: !entry.visible, keepingOneOf: keepingOneOf)
    }

    var body: some View {
        List {
            Section {
                ForEach(list.entries, id: \.item) { entry in
                    row(entry)
                }
                .onMove { from, to in list.move(fromOffsets: from, toOffset: to) }
            } footer: {
                Text("Drag to change the order. Switch off what you don't want to see.")
            }
            extra
            Section {
                Button("Reset to default order") { list = defaults }
                    .disabled(list == defaults)
                    .accessibilityIdentifier("layout-reset")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: OrderedVisibility<Item>.Entry) -> some View {
        let item = entry.item
        let entries = list.entries
        let index = entries.firstIndex { $0.item == item } ?? 0
        return Toggle(isOn: Binding(
            get: { entry.visible },
            set: { on in
                var changed = list
                if changed.set(item, visible: on, keepingOneOf: keepingOneOf) { list = changed }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label(item))
                if let note = footer(item) {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!Self.canToggle(item, in: list, keepingOneOf: keepingOneOf))
        .frame(minHeight: 44)
        .accessibilityIdentifier("layout-\(item.rawValue)")
        .accessibilityActions {
            if index > 0 { Button("Move up") { list.moveUp(item) } }
            if index < entries.count - 1 { Button("Move down") { list.moveDown(item) } }
        }
    }
}
