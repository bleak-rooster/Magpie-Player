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
            // Round 14 A4 fix round 1 (owner): whose top songs Trending shows.
            if model.aurralFeeds?.can.trending == true {
                Section {
                    NavigationLink {
                        ChartsCountryView()
                    } label: {
                        LabeledContent(DiscoverPagesCopy.chartsCountry, value: ChartsCountryView.summary(model))
                    }
                    .accessibilityIdentifier("settings-charts-country")
                }
            }
            // Round 14 A3 (owner answer 6): where every artist page's Top songs come from.
            Section {
                NavigationLink {
                    ArtistTopSongsView()
                } label: {
                    LabeledContent(ArtistTopSongsView.title, value: ArtistTopSongsView.summary(model))
                }
                .accessibilityIdentifier("settings-artist-top-songs")
            }
        }
        .navigationTitle("Home & Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Home & Library › Charts country: Automatic (the phone's region when it has a chart, else the server's),
/// the server's region, or any country with a chart (searchable, names in the phone's language).
struct ChartsCountryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    static func summary(_ model: AppModel) -> String {
        switch model.preferences.layout.chartsCountry {
        case .automatic: DiscoverPagesCopy.chartsAutomatic
        case .server: DiscoverPagesCopy.chartsServer
        case .country(let code): DiscoverPagesCopy.regionName(code)
        }
    }

    /// The countries with a chart, by name.
    static var countries: [(code: String, name: String)] {
        AurralFeeds.chartPlaylists.keys.map { ($0, DiscoverPagesCopy.regionName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let selected = model.preferences.layout.chartsCountry
        let shown = Self.countries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        List {
            Section {
                choice(DiscoverPagesCopy.chartsAutomatic, note: DiscoverPagesCopy.chartsAutomaticNote, value: .automatic,
                       selected: selected)
                choice(DiscoverPagesCopy.chartsServer, note: nil, value: .server, selected: selected)
            }
            Section {
                ForEach(shown, id: \.code) { country in
                    choice(country.name, note: nil, value: .country(country.code), selected: selected)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(DiscoverPagesCopy.chartsCountry)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ title: String, note: String?, value: ChartsCountry, selected: ChartsCountry) -> some View {
        Button {
            model.updatePreferences { $0.layout.chartsCountry = value }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if value == selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(value == selected ? .isSelected : [])
        .accessibilityIdentifier("charts-country-\(value.stored)")
    }
}
