import DesignSystem
import Foundation
import MagpieCore
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

    /// Finish setting up's Review and Try's Open Settings land on Requests; with only Finds left, on Finds set-up.
    @Test func entryPointsOpenTheirPage() {
        #expect(SettingsPage.finishSettingUp(.changesOff) == [.requests])
        #expect(SettingsPage.finishSettingUp(.addressNotAllowed) == [.requests])
        #expect(SettingsPage.finishSettingUp(.available(.standard)) == [.requests, .findsSetup])
        #expect(SettingsPage.topLevel == [.account, .playback, .downloads, .scrobbling, .homeAndLibrary, .appearance, .requests, .about])
    }

    @Test func topLevelFitsSmallestPhone() async throws {
        let name = "settings-small-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)

        let window = try await Self.host(model)
        defer { window.isHidden = true }
        let list = try #require(Self.scrollView(in: window), "the top level is a list")
        let rows = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
        #expect(rows == 8, "eight pages")
        let visible = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
        print("T21b settings: content \(list.contentSize.height) pt in \(visible) pt visible")
        #expect(list.contentSize.height <= visible, "the top level scrolls at the default text size")
        try Self.render(window, "settings-375x667.png")

        let axWindow = try await Self.host(model, typeSize: .accessibility2)
        defer { axWindow.isHidden = true }
        try Self.render(axWindow, "settings-375x667-ax2.png")
    }

    private static func host(_ model: AppModel, typeSize: DynamicTypeSize = .large) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        let view = SettingsView().environment(model).magpieTheme(model.theme).environment(\.dynamicTypeSize, typeSize)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        return window
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
