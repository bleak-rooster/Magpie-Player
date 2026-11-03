import MagpieCore
import SwiftUI

/// Settings › Home & Library › Home (spec §3): Home's sections in order, each with its switch.
struct HomeLayoutView: View {
    @Environment(AppModel.self) private var model

    /// The line under a section that doesn't always show.
    static func footer(_ section: HomeSection) -> String? {
        switch section {
        case .madeForYou: "Shows when a ListenBrainz token is saved"
        case .downloaded: "Shows on its own when you're offline"
        case .discover: "Shows once you sign in to Aurral in Settings"
        default: nil
        }
    }

    var body: some View {
        OrderedVisibilityEditor(
            title: "Home",
            list: Binding(get: { model.preferences.layout.home },
                          set: { home in model.updatePreferences { $0.layout.home = home } }),
            defaults: LayoutPreferences.defaultValue.home,
            label: \.title,
            footer: Self.footer)
    }
}
