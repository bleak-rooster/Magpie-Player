import SwiftUI

/// A Settings page: the top-level rows, and the pages entry points elsewhere open directly (T21b).
enum SettingsPage: Hashable {
    case account, playback, downloads, scrobbling, homeAndLibrary, appearance, requests, about
    /// Requests › Finds.
    case findsSetup

    /// The top level, in order.
    static let topLevel: [SettingsPage] = [.account, .playback, .downloads, .scrobbling, .homeAndLibrary, .appearance, .requests, .about]

    /// Home's "Finish setting up" › Review: Requests while Try isn't available yet, else Finds set-up (the step left).
    static func finishSettingUp(_ availability: TryAvailability) -> [SettingsPage] {
        if case .available = availability { [.requests, .findsSetup] } else { [.requests] }
    }
}

/// Settings (replaces the Library account menu): one short list of pages that fits one screen at the default text
/// size (T21b), each row with its one-line summary. Row titles name no service (§5); the pages may.
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
            List(SettingsPage.topLevel, id: \.self) { page in
                NavigationLink(value: page) { row(page) }
                    .listRowInsets(.vertical, 6)   // two-line rows, still over 44 pt, so all eight fit 375 × 667
                    .accessibilityIdentifier(Self.identifier(page))
            }
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

    @ViewBuilder private func row(_ page: SettingsPage) -> some View {
        switch page {
        case .account:
            SettingsRow(title: "Account & Server", symbol: "server.rack", summary: SettingsSummaries.account(model))
        case .playback:
            SettingsRow(title: "Playback", symbol: "play.circle",
                        summary: SettingsSummary(PlaybackSettingsView.summary(model.preferences.playback)))
        case .downloads:
            SettingsRow(title: "Downloads & Storage", symbol: "arrow.down.circle",
                        summary: SettingsSummary(DownloadsSettingsView.summary(model.preferences.downloads)))
        case .scrobbling:
            SettingsRow(title: "Scrobbling", symbol: "chart.bar", summary: SettingsSummary(AppModel.scrobblingSummary(
                model.preferences.scrobbling, countPlays: model.countPlays, hasToken: model.hasListenBrainzToken)))
        case .homeAndLibrary:
            SettingsRow(title: "Home & Library", symbol: "square.grid.2x2",
                        summary: SettingsSummary(HomeAndLibraryView.summary(model)))
        case .appearance:
            SettingsRow(title: "Appearance", symbol: "paintpalette", summary: SettingsSummary(SettingsSummaries.appearance(model.theme)))
        case .requests:
            SettingsRow(title: "New music", symbol: "tray.and.arrow.down", summary: SettingsSummaries.requests(model))
        case .about:
            SettingsRow(title: "About", symbol: "info.circle", summary: SettingsSummary(AboutView.summary))
        case .findsSetup:
            EmptyView()   // not a top-level row
        }
    }

    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .account: AccountSettingsView(dismissSettings: { dismiss() })
        case .playback: PlaybackSettingsView()
        case .downloads: DownloadsSettingsView()
        case .scrobbling: ScrobblingSettingsView()
        case .homeAndLibrary: HomeAndLibraryView()
        case .appearance: AppearanceView()
        case .requests: RequestsSettingsView()
        case .about: AboutView()
        case .findsSetup: FindsSetupView()
        }
    }

    /// The rows that were already there keep their identifiers (UI tests use them).
    static func identifier(_ page: SettingsPage) -> String {
        switch page {
        case .account: "settings-account"
        case .playback: "settings-playback"
        case .downloads: "settings-downloads"
        case .scrobbling: "settings-scrobbling"
        case .homeAndLibrary: "settings-home-library"
        case .appearance: "settings-appearance"
        case .requests: "settings-requests"
        case .about: "settings-about"
        case .findsSetup: "settings-finds"
        }
    }
}
