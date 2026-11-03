import SwiftUI

/// A Settings page: the top-level rows, and the pages entry points elsewhere open directly (T21b).
enum SettingsPage: Hashable {
    /// Round 13 item 14, Accounts & Servers: Navidrome (was Account & Server), Lidarr (was New music), Aurral (was
    /// New music › Aurral), ListenBrainz (was Scrobbling).
    case account, lidarr, aurral, listenBrainz
    case playback, downloads, homeAndLibrary, appearance, about
    /// Y4 (round 12 item 6): Downloads in Lidarr. Round 13: opened from the Lidarr page, no longer a top-level row.
    case lidarrDownloads
    /// Lidarr › Finds.
    case findsSetup
    /// Round 13 (Z3): Settings › CarPlay, the third tab and the car's Home. A top-level row since Z1's Accounts &
    /// Servers rework made room (it first opened from Home & Library).
    case carPlay

    /// Round 13 item 14: the Accounts & Servers section, near the top, in this order.
    static let accountsAndServers: [SettingsPage] = [.account, .lidarr, .aurral, .listenBrainz]
    /// The pages under it.
    static let preferences: [SettingsPage] = [.playback, .downloads, .homeAndLibrary, .carPlay, .appearance, .about]

    /// The top level, in order.
    static var topLevel: [SettingsPage] { accountsAndServers + preferences }

    /// Home's "Finish setting up" › Review: Lidarr while Try isn't available yet, else Finds set-up (the step left).
    static func finishSettingUp(_ availability: TryAvailability) -> [SettingsPage] {
        if case .available = availability { [.lidarr, .findsSetup] } else { [.lidarr] }
    }
}

/// Settings (replaces the Library account menu): one short list of pages that fits one screen at the default text
/// size (T21b), each row with its one-line summary. Round 13 item 14: "Accounts & Servers" first, one row per service
/// (named, as the owner's plan names them), each opening that service's page with all of its settings; then the
/// preferences, whose row titles name no service (§5).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsPage]

    /// `opening`: pages to show on top of the list, for entry points about one of them.
    init(opening pages: [SettingsPage] = []) {
        _path = State(initialValue: pages)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(SettingsPage.accountsAndServers, id: \.self, content: link)
                } header: {
                    Text(SettingsCopy.accountsAndServers)
                        .accessibilityIdentifier("settings-accounts-header")
                }
                Section {
                    ForEach(SettingsPage.preferences, id: \.self, content: link)
                }
            }
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 44)   // one-line service rows stay 44 pt (D15), not the default 52
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings-done")
                }
            }
            .navigationDestination(for: SettingsPage.self) { destination($0) }
            .task(id: model.lidarr) { if model.lidarr != nil, !model.isOffline { _ = await model.lidarrAudit() } }
        }
    }

    private func link(_ page: SettingsPage) -> some View {
        NavigationLink(value: page) { row(page) }
            // Two-line rows 50 pt, one-line rows 44 pt (D15), so the whole list fits 375 × 667 with room for one more
            // two-line row.
            .listRowInsets(.vertical, 3)
            .accessibilityIdentifier(Self.identifier(page))
    }

    @ViewBuilder private func row(_ page: SettingsPage) -> some View {
        switch page {
        case .account:
            SettingsServiceRow(title: SettingsCopy.navidrome, symbol: "server.rack", summary: SettingsSummaries.account(model))
        case .lidarr:
            SettingsServiceRow(title: SettingsCopy.lidarr, symbol: "tray.and.arrow.down", summary: SettingsSummaries.requests(model))
        case .aurral:
            SettingsServiceRow(title: SettingsCopy.aurral, symbol: "sparkles", summary: SettingsSummary(AurralCopy.summary(model)))
        case .listenBrainz:
            SettingsServiceRow(title: SettingsCopy.listenBrainz, symbol: "chart.bar", summary: SettingsSummaries.listenBrainz(model))
        case .playback:
            SettingsRow(title: "Playback", symbol: "play.circle",
                        summary: SettingsSummary(PlaybackSettingsView.summary(model.preferences.playback)))
        case .downloads:
            SettingsRow(title: "Downloads & Storage", symbol: "arrow.down.circle",
                        summary: SettingsSummary(DownloadsSettingsView.summary(model.preferences.downloads)))
        case .homeAndLibrary:
            SettingsRow(title: "Home & Library", symbol: "square.grid.2x2",
                        summary: SettingsSummary(HomeAndLibraryView.summary(model)))
        case .carPlay:
            SettingsRow(title: "CarPlay", symbol: "car", summary: SettingsSummary(
                CarPlaySettingsView.summary(model.preferences.carPlay, discoverSetUp: model.aurralSetUp)))
        case .appearance:
            SettingsRow(title: "Appearance", symbol: "paintpalette", summary: SettingsSummary(SettingsSummaries.appearance(model.theme)))
        case .about:
            SettingsRow(title: "About", symbol: "info.circle", summary: SettingsSummary(AboutView.summary))
        case .lidarrDownloads, .findsSetup:
            EmptyView()   // not top-level rows
        }
    }

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .account: AccountSettingsView(dismissSettings: { dismiss() })
        case .lidarr: RequestsSettingsView()
        case .aurral: AurralSettingsView()
        case .listenBrainz: ScrobblingSettingsView()
        case .playback: PlaybackSettingsView()
        case .downloads: DownloadsSettingsView()
        case .homeAndLibrary: HomeAndLibraryView()
        case .carPlay: CarPlaySettingsView()
        case .appearance: AppearanceView()
        case .lidarrDownloads: LidarrDownloadsView()
        case .about: AboutView()
        case .findsSetup: FindsSetupView()
        }
    }

    /// The rows that were already there keep their identifiers (UI tests use them).
    static func identifier(_ page: SettingsPage) -> String {
        switch page {
        case .account: "settings-account"
        case .lidarr: "settings-lidarr-account"
        case .aurral: "settings-aurral"
        case .listenBrainz: "settings-listenbrainz"
        case .playback: "settings-playback"
        case .downloads: "settings-downloads"
        case .homeAndLibrary: "settings-home-library"
        case .carPlay: "settings-carplay"
        case .appearance: "settings-appearance"
        case .lidarrDownloads: "settings-lidarr-downloads"
        case .about: "settings-about"
        case .findsSetup: "settings-finds"
        }
    }
}

/// Round 13 item 14: the Accounts & Servers words. The rows name their service (the owner's plan names them).
enum SettingsCopy {
    static let accountsAndServers = "Accounts & Servers"
    static let navidrome = "Navidrome"
    static let lidarr = "Lidarr"
    static let aurral = "Aurral"
    static let listenBrainz = "ListenBrainz"
}
