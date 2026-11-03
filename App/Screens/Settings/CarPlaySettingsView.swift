import MagpieCore
import SwiftUI

/// Settings › CarPlay (round 13 items 10 and 11): the tab between Library and Search, and what the car's Home shows.
struct CarPlaySettingsView: View {
    @Environment(AppModel.self) private var model

    /// The row's line in Settings: "Playlists tab · Home as on iPhone".
    static func summary(_ car: CarPlayPreferences, discoverSetUp: Bool) -> String {
        "\(car.tab(discoverSetUp: discoverSetUp).title) tab \u{00B7} " + (car.home == nil ? "Home as on iPhone" : "Own Home")
    }

    var body: some View {
        let car = model.preferences.carPlay
        let discover = model.aurralSetUp
        List {
            Section {
                Picker("Third tab", selection: Binding(get: { car.tab(discoverSetUp: discover) },
                                                       set: { tab in model.updatePreferences { $0.carPlay.thirdTab = tab } })) {
                    ForEach(CarPlayTab.choices(discoverSetUp: discover), id: \.self) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("carplay-third-tab")
            } footer: {
                Text("The tab between Library and Search.")
            }
            Section {
                NavigationLink {
                    CarPlayHomeLayoutView()
                } label: {
                    LabeledContent("Home", value: car.home == nil ? "As on iPhone" : "Own")
                }
                .accessibilityIdentifier("carplay-home")
            } footer: {
                Text("Choose the shelves CarPlay's Home shows, and their order.")
            }
        }
        .navigationTitle("CarPlay")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › CarPlay › Home: the car's shelves, ordered and switched on or off. Until changed it is the phone's Home
/// (Settings › Home & Library › Home); "Same as iPhone" goes back to following it.
struct CarPlayHomeLayoutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let phone = model.preferences.layout.home
        let following = model.preferences.carPlay.home == nil
        OrderedVisibilityEditor(
            title: "CarPlay Home",
            list: Binding(get: { model.preferences.carPlay.homeList(following: model.preferences.layout.home) },
                          set: { list in model.updatePreferences { $0.carPlay.home = list } }),
            defaults: CarPlayPreferences.defaultValue.homeList(following: phone),
            label: \.title,
            footer: { HomeLayoutView.footer($0.section) }) {
            Section {
                Toggle("Same as iPhone", isOn: Binding(
                    get: { following },
                    set: { on in
                        model.updatePreferences {
                            $0.carPlay.home = on ? nil : $0.carPlay.homeList(following: $0.layout.home)
                        }
                    }))
                .accessibilityIdentifier("carplay-home-follow")
            } footer: {
                Text("While this is on, CarPlay's Home follows your iPhone's Home. Changing anything here turns it off.")
            }
        }
    }
}
