import MagpieCore
import SwiftUI

/// Settings › Home & Library: one page per area's layout (Home here; Task 21 adds Library).
struct HomeAndLibraryView: View {
    @Environment(AppModel.self) private var model

    /// The Settings row's value: how many Home sections show (online).
    static func summary(_ model: AppModel) -> String {
        let count = model.preferences.layout.visibleHomeSections(
            offline: false, hasListenBrainzToken: model.hasListenBrainzToken, carPlay: false).count
        return count == 1 ? "1 section" : "\(count) sections"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HomeLayoutView()
                } label: {
                    LabeledContent("Home", value: Self.summary(model))
                }
                .accessibilityIdentifier("settings-home-layout")
            }
        }
        .navigationTitle("Home & Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
