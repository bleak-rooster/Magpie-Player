import DesignSystem
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
            // Round 27 H (owner, 2026-11-14): every album grid's covers, Large or Small (D296).
            Section {
                Picker(AlbumCoversCopy.setting, selection: Binding(
                    get: { model.preferences.layout.albumCovers },
                    set: { size in model.updatePreferences { $0.layout.albumCovers = size } })) {
                    ForEach(AlbumCoverSize.allCases, id: \.self) { Text(AlbumCoversCopy.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: Tokens.minHitSize)
                .accessibilityIdentifier("settings-album-covers")
            } header: {
                Text(AlbumCoversCopy.setting)
            } footer: {
                Text(AlbumCoversCopy.accessibilityNote)   // fix round 1 (design H1): always shown
            }
            // Round 27 H (owner, 2026-11-14): Your flows on Home, by last played or A to Z (D298), and (Q3) D190's one
            // "everyone's" switch, shown here too. Only with Aurral: Home has no flows without it.
            if Self.showsFlowsSection(model) {
                Section {
                    Picker(HomeFlowsCopy.order, selection: Binding(get: { model.preferences.layout.homeFlowsOrder },
                                                                   set: { model.setHomeFlowsOrder($0) })) {
                        ForEach(HomeFlowsOrder.allCases, id: \.self) { Text(HomeFlowsCopy.title($0)).tag($0) }
                    }
                    .accessibilityIdentifier("settings-home-flows-order")
                } header: {
                    Text(HomeFlowsCopy.section)
                } footer: {
                    // Fix round 1 (M2): it describes Last played only.
                    if let footer = HomeFlowsCopy.footer(model.preferences.layout.homeFlowsOrder) { Text(footer) }
                }
                Section {
                    Toggle(EveryonesFlowsCopy.toggle, isOn: Binding(get: { model.showEveryonesFlows },
                                                                    set: { model.showEveryonesFlows = $0 }))
                        .accessibilityIdentifier("settings-home-everyones-flows")
                } footer: {
                    Text(HomeFlowsCopy.everyoneFooter)   // fix round 1 (design M4): it isn't only Home's
                }
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

    /// Round 27 H (D298): Your flows on Home shows only while Aurral is set up (no dead controls without it).
    static func showsFlowsSection(_ model: AppModel) -> Bool { model.aurralSetUp }
}

/// Round 27 H (D298): the words for Your flows on Home (Settings › Home & Library).
enum HomeFlowsCopy {
    static let section = "Your flows on Home"
    static let order = "Order"
    static let lastPlayedFooter = "Flows you\u{2019}ve played lately come first; the rest follow A to Z."
    /// D190's footer, and (fix round 1, design M4) what else the one switch governs.
    static let everyoneFooter = EveryonesFlowsCopy.footer + " This also applies to Discover and the car."

    /// Fix round 1 (M2): the Order footer, shown only for Last played.
    static func footer(_ order: HomeFlowsOrder) -> String? { order == .lastPlayed ? lastPlayedFooter : nil }

    static func title(_ order: HomeFlowsOrder) -> String {
        switch order {
        case .lastPlayed: "Last played"
        case .alphabetical: "A to Z"
        }
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
        case .worldwide: DiscoverPagesCopy.worldwide   // round 15 C2: Trending's default chart (D132)
        case .genre(let id): model.chartTitle(.genre(id))
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
                if AurralFeeds.worldwideChartPlaylist != nil {
                    choice(DiscoverPagesCopy.worldwide, note: nil, value: .worldwide, selected: selected)
                }
                if case .genre(let id) = selected {   // a genre chart made the default on Trending
                    choice(model.chartTitle(.genre(id)), note: nil, value: selected, selected: selected)
                }
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
