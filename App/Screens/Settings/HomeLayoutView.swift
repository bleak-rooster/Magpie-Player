import MagpieCore
import SwiftUI

/// Settings › Home & Library › Home (spec §3), and Edit Home: Home's sections in order, each with its switch.
/// Round 14 A6: each shelf's card size and item count (and Because you like's rows) in a menu on its row; sections
/// whose service is missing listed greyed with "Needs Aurral"; Reset restores the order, switches and settings.
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

    /// The service `section` needs that isn't set up now; nil when it can show (Made for you keeps its own footer).
    static func missing(_ section: HomeSection, aurralSetUp: Bool, lidarrConnected: Bool) -> HomeService? {
        switch section.need {
        case .aurral: aurralSetUp ? nil : .aurral
        case .lidarr: lidarrConnected ? nil : .lidarr
        case .listenBrainz, nil: nil
        }
    }

    /// The row's note: what it needs while that's missing, else its footer.
    static func note(_ section: HomeSection, aurralSetUp: Bool, lidarrConnected: Bool) -> String? {
        if let need = missing(section, aurralSetUp: aurralSetUp, lidarrConnected: lidarrConnected) { return need.needsLabel }
        return section.need == .aurral ? nil : footer(section)
    }

    var body: some View {
        let aurral = model.aurralSetUp, lidarr = model.lidarr != nil
        OrderedVisibilityEditor(
            title: "Home",
            list: Binding(get: { model.preferences.layout.home },
                          set: { home in model.updatePreferences { $0.layout.home = home } }),
            defaults: LayoutPreferences.defaultValue.home,
            label: \.title,
            footer: { Self.note($0, aurralSetUp: aurral, lidarrConnected: lidarr) },
            greyed: { Self.missing($0, aurralSetUp: aurral, lidarrConnected: lidarr) != nil },
            accessory: { section in section.hasCountSetting ? AnyView(HomeSectionSettingsMenu(section: section)) : nil },
            reset: { model.updatePreferences { $0.layout.resetHome() } },
            isDefault: model.preferences.layout.isDefaultHome)
    }
}

/// A Home row's settings: card size, item count, and for Because you like how many rows. Changes apply at once.
struct HomeSectionSettingsMenu: View {
    @Environment(AppModel.self) private var model
    let section: HomeSection

    var body: some View {
        let style = model.preferences.layout.style(for: section)
        Menu {
            if section.hasCardSettings {
                Picker("Card size", selection: binding(style, \.size)) {
                    ForEach(HomeCardSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Picker("Items", selection: binding(style, \.count)) {
                ForEach(section == .quickAccess ? HomeSectionStyle.quickAccessCounts : HomeSectionStyle.counts, id: \.self) {
                    Text("\($0)").tag($0)
                }
            }
            .pickerStyle(.menu)
            if section == .becauseYouLike {
                Picker("Rows", selection: Binding(get: { model.preferences.layout.becauseYouLikeRows },
                                                  set: { rows in model.updatePreferences { $0.layout.becauseYouLikeRows = rows } })) {
                    ForEach(Array(HomeSectionStyle.becauseYouLikeRange), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(section.title) settings")
        .accessibilityValue(HomeLayoutCopy.settingsValue(section, style: style,
                                                         rows: model.preferences.layout.becauseYouLikeRows))
        .accessibilityIdentifier("layout-settings-\(section.rawValue)")
    }

    private func binding<Value>(_ style: HomeSectionStyle, _ path: WritableKeyPath<HomeSectionStyle, Value>) -> Binding<Value> {
        Binding(get: { style[keyPath: path] },
                set: { value in
                    var changed = model.preferences.layout.style(for: section)
                    changed[keyPath: path] = value
                    model.updatePreferences { $0.layout.setStyle(changed, for: section) }
                })
    }
}

enum HomeLayoutCopy {
    /// VoiceOver's value on a row's settings button: "Medium cards, 12 items"; "8 items"; with rows for Because you like.
    static func settingsValue(_ section: HomeSection, style: HomeSectionStyle, rows: Int) -> String {
        var parts: [String] = []
        if section.hasCardSettings { parts.append("\(style.size.title) cards") }
        parts.append(style.count == 1 ? "1 item" : "\(style.count) items")
        if section == .becauseYouLike { parts.append(rows == 1 ? "1 row" : "\(rows) rows") }
        return parts.joined(separator: ", ")
    }
}
