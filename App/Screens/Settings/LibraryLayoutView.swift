import MagpieCore
import SwiftUI

/// Settings › Home & Library › Library (spec §3, Task 21): the Library's rows in order, each with its switch (one of the
/// rows that always apply stays on), and the Recently added grid's switch.
struct LibraryLayoutView: View {
    @Environment(AppModel.self) private var model

    /// The line under a row that doesn't always show.
    static func footer(_ row: LibraryRow) -> String? {
        switch row {
        case .finds: "Shows once your Finds folder is set up"
        case .requests: "Shows when Lidarr is connected"
        default: nil
        }
    }

    /// The Settings row's value: how many rows the Library shows (online).
    static func summary(_ model: AppModel) -> String {
        let count = model.preferences.layout.visibleLibraryRows(
            offline: false, findsSetUp: model.findsSetup?.library != nil, lidarrConnected: model.lidarr != nil,
            carPlay: false).count
        return count == 1 ? "1 row" : "\(count) rows"
    }

    var body: some View {
        OrderedVisibilityEditor(
            title: "Library",
            list: Binding(get: { model.preferences.layout.library },
                          set: { library in model.updatePreferences { $0.layout.library = library } }),
            defaults: LayoutPreferences.defaultValue.library,
            label: \.title,
            footer: Self.footer,
            keepingOneOf: LayoutPreferences.alwaysAvailableRows) {
            Section {
                Toggle("Recently added", isOn: Binding(
                    get: { model.preferences.layout.showsRecentlyAdded },
                    set: { on in model.updatePreferences { $0.layout.showsRecentlyAdded = on } }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("layout-recently-added")
            } footer: {
                Text("At least one row stays visible.")
            }
            Section {
                // R11: the same preference as the Artists page's filter menu; the car follows it too.
                Toggle("Album artists only", isOn: Binding(
                    get: { model.preferences.layout.albumArtistsOnly },
                    set: { on in model.updatePreferences { $0.layout.albumArtistsOnly = on } }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("layout-album-artists-only")
            } footer: {
                Text("Off, Artists also lists people who only appear on songs.")
            }
        }
    }
}
