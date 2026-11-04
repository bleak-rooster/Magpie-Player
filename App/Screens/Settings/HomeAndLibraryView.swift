import MagpieCore
import SwiftUI

/// Settings › Home & Library: one page per area's layout, Home and Library. (CarPlay's is a top-level row, round 13.)
struct HomeAndLibraryView: View {
    @Environment(AppModel.self) private var model

    /// The Settings row's value: how many Home sections and Library rows show (online), "3 sections · 7 rows".
    static func summary(_ model: AppModel) -> String {
        "\(homeSummary(model)) · \(LibraryLayoutView.summary(model))"
    }

    /// The Home row's value: how many Home sections show (online).
    static func homeSummary(_ model: AppModel) -> String {
        // Round 14 A6: a section needing a missing service doesn't count (it isn't on Home).
        let count = model.preferences.layout.visibleHomeSections(
            offline: false, hasListenBrainzToken: model.hasListenBrainzToken, discoverSetUp: model.aurralSetUp,
            outside: model.homeOutsideSections).count
        return count == 1 ? "1 section" : "\(count) sections"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HomeLayoutView()
                } label: {
                    LabeledContent("Home", value: Self.homeSummary(model))
                }
                .accessibilityIdentifier("settings-home-layout")
                NavigationLink {
                    LibraryLayoutView()
                } label: {
                    LabeledContent("Library", value: LibraryLayoutView.summary(model))
                }
                .accessibilityIdentifier("settings-library-layout")
            }
        }
        .navigationTitle("Home & Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
