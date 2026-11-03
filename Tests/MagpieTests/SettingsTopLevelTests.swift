import DesignSystem
import Foundation
import MagpieCore
import MagpieTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Magpie

/// T21b: Settings is a short list of eight pages, each row with its one-line summary, that fits the smallest iOS 27
/// phone (375 × 667 pt) without scrolling at the default text size (at accessibility sizes it may scroll, D15).
/// Entry points open the page they are about: Finish setting up and Try open Requests (or Finds set-up).
@MainActor @Suite(.serialized) struct SettingsTopLevelTests {
    private let home = URL(string: "http://homeserver:4533")!
    private let publicPlain = URL(string: "http://music.example.com:4533")!

    @Test func accountSummaryNamesServerAndUserOrWarns() {
        #expect(SettingsSummaries.account(bases: [home], username: "jordan", localNetworkDenied: false)
            == SettingsSummary("homeserver · jordan"))
        // D3: the warning is text plus its symbol.
        #expect(SettingsSummaries.account(bases: [home, publicPlain], username: "jordan", localNetworkDenied: false)
            == SettingsSummary("Not encrypted", symbol: "lock.open"))
        #expect(SettingsSummaries.account(bases: [home], username: "jordan", localNetworkDenied: true)
            == SettingsSummary("Local network access is off", symbol: "network.slash"))
        #expect(SettingsSummaries.account(bases: [], username: nil, localNetworkDenied: false) == SettingsSummary("Not signed in"))
    }

    @Test func requestsSummaryNamesNoService() {
        #expect(SettingsSummaries.requests(connected: false, awaitingConsent: false, finds: .off) == SettingsSummary("Not connected"))
        #expect(SettingsSummaries.requests(connected: true, awaitingConsent: false, finds: .on) == SettingsSummary("Connected · Finds on"))
        #expect(SettingsSummaries.requests(connected: true, awaitingConsent: false, finds: .off) == SettingsSummary("Connected · Finds off"))
        #expect(SettingsSummaries.requests(connected: true, awaitingConsent: false, finds: .notFinished)
            == SettingsSummary("Connected · Finds not finished"))
        #expect(SettingsSummaries.requests(connected: true, awaitingConsent: true, finds: .on)
            == SettingsSummary("Allow This Address needed", symbol: "lock.open"))
        // Offline every Lidarr action is disabled (Task 14); the row says so, with its symbol (D3).
        #expect(SettingsSummaries.requests(connected: true, awaitingConsent: false, finds: .on, offline: true)
            == SettingsSummary("You're offline", symbol: "wifi.slash"))
    }

    /// Fix round: sign-out erases this account's downloads, so it asks first.
    @Test func signOutAsksFirst() {
        #expect(AccountCopy.signOutTitle == "Sign out?")
        #expect(AccountCopy.signOutMessage == "Songs downloaded to this phone will be removed.")
        #expect(AccountCopy.signOutConfirm == "Sign Out")
    }

    @Test func otherSummaries() {
        #expect(SettingsSummaries.appearance(Theme(character: .signature, accent: .sheen)) == "Signature · Sheen")
        #expect(SettingsSummaries.appearance(Theme(character: .classic, accent: .ultramarine)) == "Classic · Ultramarine")
        #expect(PlaybackSettingsView.summary(.defaultValue) == "Original · AAC 160 kbps on mobile")
        var same = PlaybackPreferences.defaultValue
        same.cellular = .original
        #expect(PlaybackSettingsView.summary(same) == "Original")
        #expect(AboutView.summary == "Version \(AboutView.version)")
        #expect(AboutView.version.hasPrefix("\(AppModel.marketingVersion) ("))
    }

    /// Finish setting up's Review and Try's Open Settings land on the Lidarr page; with only Finds left, on Finds
    /// set-up.
    @Test func entryPointsOpenTheirPage() {
        #expect(SettingsPage.finishSettingUp(.changesOff) == [.lidarr])
        #expect(SettingsPage.finishSettingUp(.addressNotAllowed) == [.lidarr])
        #expect(SettingsPage.finishSettingUp(.available(.standard)) == [.lidarr, .findsSetup])
    }

    /// Round 13 item 14: "Accounts & Servers" near the top, one row per service in the owner's order, each opening
    /// that service's page; the preferences after it. The old rows (Account & Server, New music, Scrobbling, and
    /// Downloads in Lidarr) are gone from the top level.
    @Test func accountsAndServersFirst() {
        #expect(SettingsCopy.accountsAndServers == "Accounts & Servers")
        #expect(SettingsPage.accountsAndServers == [.account, .lidarr, .aurral, .listenBrainz])
        #expect(SettingsPage.topLevel == [.account, .lidarr, .aurral, .listenBrainz,
                                          .playback, .downloads, .homeAndLibrary, .appearance, .about])
        #expect(SettingsPage.accountsAndServers.map(SettingsView.identifier)
                == ["settings-account", "settings-lidarr-account", "settings-aurral", "settings-listenbrainz"])
        #expect([SettingsCopy.navidrome, SettingsCopy.lidarr, SettingsCopy.aurral, SettingsCopy.listenBrainz]
                == ["Navidrome", "Lidarr", "Aurral", "ListenBrainz"])
    }

    /// Round 13 item 14: the ListenBrainz row says whether there's a token and where plays go.
    @Test func listenBrainzSummary() {
        #expect(SettingsSummaries.listenBrainz(hasToken: false, rejected: false, scrobbling: "Navidrome \u{00B7} 50%")
                == SettingsSummary("No token"))
        #expect(SettingsSummaries.listenBrainz(hasToken: true, rejected: false, scrobbling: "Off")
                == SettingsSummary("Token saved \u{00B7} Plays off"))
        #expect(SettingsSummaries.listenBrainz(hasToken: true, rejected: true, scrobbling: "Off")
                == SettingsSummary("Token not accepted", symbol: "exclamationmark.triangle"))
    }

    /// Round 13 item 14: Navidrome's page says what each library is for.
    @Test func libraryRoles() {
        let role = { (id: Int, listed: [Int]?) in
            AccountCopy.libraryRole(id, main: 1, listed: listed, finds: 3, discover: [2])
        }
        #expect(role(1, [1, 4]) == "Main library")
        #expect(role(2, [1, 4]) == "Discover")
        #expect(role(3, [1, 4]) == "Finds")
        #expect(role(4, [1, 4]) == "Shown")
        #expect(role(5, [1, 4]) == "Not shown")
        #expect(role(5, nil) == "Shown", "nothing listed: every library shows")
    }

    /// Signed in to a long plain-http public address (the "Not encrypted" warning row) with Lidarr connected, and
    /// measured inside a real page-sheet presentation, as the app shows Settings.
    @Test func topLevelFitsSmallestPhone() async throws {
        let name = "settings-small-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let gateSuite = "settings-small-gate-\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults(suiteName: gateSuite)?.removePersistentDomain(forName: gateSuite)
        }
        let transport = HostSwitchTransport()
        transport.inner.stub(pathSuffix: "/rest/ping", body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8))
        transport.inner.stub(method: "POST", pathSuffix: "/auth/login", body: Data(#"""
        {"id":"u1","isAdmin":true,"name":"Admin","subsonicSalt":"salt","subsonicToken":"tok","token":"jwt","username":"a-rather-long-username"}
        """#.utf8))
        transport.inner.stub(pathSuffix: "/api/song", body: Data("[]".utf8), headers: ["X-Total-Count": "0"])
        transport.inner.stub(pathSuffix: "/api/v1/system/status", body: Data(#"{"version":"3.2.0","instanceName":"Lidarr","authentication":"forms"}"#.utf8))
        transport.inner.stub(pathSuffix: "/api/v1/rootfolder", body: Data(#"[{"id":1,"path":"/music"}]"#.utf8))
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                             dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: transport, probeTransport: transport,
                             engine: FakeEngine(), defaults: defaults, systemNowPlaying: false, notifications: false)
        let server = URL(string: "http://a-very-long-music-server-name.example.com:4533")!
        model.allowPlainHTTP([server])
        try await model.signIn(urls: [server], username: "a-rather-long-username", password: "pw")
        _ = try await model.connectLidarr(base: URL(string: "http://192.168.1.2:8686")!, apiKey: "key")
        defer { model.signOut() }
        #expect(SettingsSummaries.account(model) == SettingsSummary("Not encrypted", symbol: "lock.open"))
        #expect(SettingsSummaries.requests(model).text.hasPrefix("Connected · Finds "))

        let (window, sheet) = try await Self.host(model)
        defer { window.isHidden = true }
        let list = try #require(Self.scrollView(in: sheet.view), "the top level is a list")
        let rows = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
        #expect(rows == 9, "round 13: four accounts and servers, then five pages")
        let visible = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
        print("T21b settings: content \(list.contentSize.height) pt in \(visible) pt visible (sheet \(sheet.view.frame))")
        #expect(sheet.view.frame.height < 667, "measured inside the sheet, not the whole window")
        #expect(list.contentSize.height <= visible, "the top level scrolls at the default text size")
        #expect(visible - list.contentSize.height >= 50, "round 13: room for one more two-line row (Z3's CarPlay)")
        try Self.render(window, "settings-375x667.png")

        let (axWindow, _) = try await Self.host(model, typeSize: .accessibility2)
        defer { axWindow.isHidden = true }
        try Self.render(axWindow, "settings-375x667-ax2.png")
    }

    /// Settings presented as a page sheet over a 375 × 667 window, as Library and Home present it.
    private static func host(_ model: AppModel, typeSize: DynamicTypeSize = .large) async throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.rootViewController = root
        window.isHidden = false
        let view = SettingsView().environment(model).magpieTheme(model.theme).environment(\.dynamicTypeSize, typeSize)
        let sheet = UIHostingController(rootView: view)
        sheet.modalPresentationStyle = .pageSheet
        root.present(sheet, animated: false)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            sheet.view.layoutIfNeeded()
        }
        return (window, sheet)
    }

    private static func scrollView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// Draws the window to a PNG in the app's tmp folder, for the report.
    private static func render(_ window: UIWindow, _ file: String) throws {
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        try image.pngData()?.write(to: out)
        print("T21b settings render: \(out.path)")
    }
}
