import BackgroundTasks
import Foundation
import MagpieCore
import MagpieTestSupport
import os
import SlskdKit
import Testing
@testable import Magpie

/// Round 24 (owner, 2026-11-08): slskd gets its own page under Accounts & Servers (no longer under Lidarr), with "Keep
/// Soulseek connected": off by default, only with slskd connected; switching it on asks for notifications and checks
/// once; checks ask a disconnected slskd to reconnect; the owner is told after three failed checks over at least ten
/// minutes, once per outage, by a local notification when allowed and always by a banner on Home and the page.
/// (D216–D221)
@MainActor
@Suite(.serialized) struct SlskdKeepConnectedAppTests {
    let slskd = FakeSlskd()
    let store = SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)"))
    let gateSuite = "magpie-tests-gate-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "SlskdKeepConnectedAppTests.\(UUID().uuidString)")!
    let slskdStore = InMemorySlskdStore()
    let notifier = FakeOutageNotifier()
    let clock = TestClock()
    static let base = URL(string: "https://nas.local/slskd")!

    /// A notifier that says what it was asked.
    final class FakeOutageNotifier: SlskdOutageNotifying {
        var allows = true
        var asked = 0
        var posted: [(title: String, body: String)] = []
        /// The order of what happened (the permission is asked before the first check).
        var events: [String] = []
        func requestPermission() async -> Bool {
            asked += 1
            events.append("asked")
            return allows
        }
        func postSlskdOutage(title: String, body: String) { posted.append((title, body)) }
        func permissionStatus() async -> Bool? { allows }
    }

    final class TestClock: Sendable {
        private let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    func makeModel(connected: Bool = true) -> AppModel {
        if connected { try? slskdStore.save(SlskdConnection(base: Self.base, apiKey: "test-slskd-key")) }
        let model = AppModel(store: store, lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(),
                             matchIndexDirectory: nil, dataDirectory: nil, gateDefaultsSuite: gateSuite, transport: slskd,
                             probeTransport: slskd, engine: FakeEngine(), defaults: defaults, systemNowPlaying: false,
                             notifications: false)
        model.slskdKeep.notifier = notifier
        model.slskdKeep.runsLoop = false   // checks are driven by the test
        let clock = self.clock
        model.slskdKeep.clock = { clock.now }
        model.slskdStore = slskdStore
        model.readSlskdConnection()
        return model
    }

    var serverReads: Int { slskd.requests.filter { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/api/v0/server") == true }.count }
    var connects: Int { slskd.requests.filter { $0.httpMethod == "PUT" }.count }

    // MARK: - The page

    @Test func settings_slskdIsTopLevelAndLidarrRowGone() {
        #expect(SettingsPage.accountsAndServers == [.account, .lidarr, .aurral, .listenBrainz, .slskd])
        #expect(SettingsPage.topLevel.prefix(5) == [.account, .lidarr, .aurral, .listenBrainz, .slskd])
        #expect(SettingsView.identifier(.slskd) == "settings-slskd", "the identifier is kept")
        #expect(!RequestsSettingsView.pageLinks.contains(.slskd), "Lidarr's page no longer opens it")
        #expect(RequestsSettingsView.pageLinks == [.lidarrDownloads])
    }

    @Test func rowSummary() {
        #expect(SlskdCopy.rowSummary(connected: false, lastCheck: nil) == SettingsSummary("Not set up"))
        #expect(SlskdCopy.rowSummary(connected: true, lastCheck: nil) == SettingsSummary("Connected"))
        #expect(SlskdCopy.rowSummary(connected: true, lastCheck: .connected) == SettingsSummary("Connected"))
        #expect(SlskdCopy.rowSummary(connected: true, lastCheck: .down(asked: true)) == SettingsSummary("Connected"))
        #expect(SlskdCopy.rowSummary(connected: true, lastCheck: .unreachable)
                == SettingsSummary("Not reachable", symbol: "exclamationmark.triangle"))
    }

    /// The plan's words, verbatim.
    @Test func copy() {
        #expect(SlskdKeepCopy.toggle == "Keep Soulseek connected")
        #expect(SlskdKeepCopy.footer == "Magpie checks that slskd is connected to Soulseek while it can, and asks it to reconnect. Checks only happen while Magpie is open, playing, or when iOS allows it in the background.")
        #expect(SlskdKeepCopy.notificationTitle == "slskd isn\u{2019}t connected to Soulseek")
        #expect(SlskdKeepCopy.notificationBody == "Magpie asked it to reconnect and it still can\u{2019}t. Music coming through Soulseek will wait.")
        #expect(SlskdKeepCopy.notificationsOff == "Notifications are off, so Magpie can only tell you inside the app.")
        #expect(SlskdKeepCopy.unreachable == "Can\u{2019}t reach slskd")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 14, minute: 5))!
        #expect(SlskdKeepCopy.disconnectedSince(date, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
                == "slskd has been disconnected since 14:05")
    }

    // MARK: - The switch

    @Test func toggleOffWithoutSlskdWithTheReason() async {
        let model = makeModel(connected: false)
        #expect(!model.slskdKeep.isOn)
        #expect(model.slskdKeepConnectedUnavailableReason == SlskdKeepCopy.needsSlskd)
        await model.setSlskdKeepConnected(true)
        #expect(!model.slskdKeep.isOn && notifier.asked == 0 && slskd.requests.isEmpty)
    }

    @Test func offByDefaultAndChecksNothing() async {
        let model = makeModel()
        #expect(!model.slskdKeep.isOn)
        #expect(model.slskdKeepConnectedUnavailableReason == nil)
        #expect(await model.checkSlskdKeepConnected() == nil)
        #expect(slskd.requests.isEmpty)
    }

    @Test func switchingOnAsksForNotificationsThenChecksOnce() async {
        let model = makeModel()
        await model.setSlskdKeepConnected(true)
        #expect(model.slskdKeep.isOn)
        #expect(notifier.asked == 1)
        #expect(serverReads == 1, "one check")
        #expect(connects == 0, "connected: nothing sent")
        #expect(model.slskdKeep.lastCheck == .connected)
        #expect(model.slskdKeep.notificationsAllowed == true)
        // Saved: a relaunch reads it back.
        let again = makeModel()
        #expect(again.slskdKeep.isOn)
        // Off: forgotten.
        await model.setSlskdKeepConnected(false)
        #expect(!model.slskdKeep.isOn && !makeModel().slskdKeep.isOn)
    }

    @Test func aDisconnectedSlskdIsAskedToReconnect() async {
        let model = makeModel()
        slskd.with { $0.serverConnected = false }
        await model.setSlskdKeepConnected(true)
        #expect(connects == 1)
        #expect(model.slskdKeep.lastCheck == .down(asked: true))
        clock.advance(30)
        #expect(await model.checkSlskdKeepConnected() == .connected)
        #expect(model.slskdKeep.outage == SlskdOutage(), "a connected read ends it")
        #expect(slskd.requests.allSatisfy { $0.httpMethod == "GET" || $0.httpMethod == "PUT" }, "never a disconnect")
    }

    // MARK: - Telling the owner

    /// Three failed checks over at least ten minutes: one notification with the plan's words, and the banner; once per
    /// outage, again after a connected read.
    @Test func outageIsToldOnceWithTheBanner() async {
        let model = makeModel()
        slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        await model.setSlskdKeepConnected(true)
        for _ in 0..<10 {
            clock.advance(60)
            _ = await model.checkSlskdKeepConnected()
        }
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.title == SlskdKeepCopy.notificationTitle)
        #expect(notifier.posted.first?.body == SlskdKeepCopy.notificationBody)
        #expect(model.slskdKeep.homeBanner != nil)
        #expect(model.slskdKeep.homeBanner?.hasPrefix("slskd has been disconnected since ") == true)
        // Back: the banner goes, and a later outage is told again.
        slskd.with { $0.serverConnected = true }
        _ = await model.checkSlskdKeepConnected()
        #expect(model.slskdKeep.homeBanner == nil)
        slskd.with { $0.serverConnected = false }
        for _ in 0..<12 {
            clock.advance(61)
            _ = await model.checkSlskdKeepConnected()
        }
        #expect(notifier.posted.count == 2)
    }

    @Test func notification_deniedFallsBackToBanner() async {
        notifier.allows = false
        let model = makeModel()
        slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        await model.setSlskdKeepConnected(true)
        #expect(model.slskdKeep.notificationsAllowed == false)
        #expect(model.slskdKeepNotificationLine == SlskdKeepCopy.notificationsOff)
        for _ in 0..<10 {
            clock.advance(60)
            _ = await model.checkSlskdKeepConnected()
        }
        #expect(notifier.posted.isEmpty, "not posted where it can't show")
        #expect(model.slskdKeep.homeBanner?.hasPrefix("slskd has been disconnected since ") == true, "the banner says it")
    }

    @Test func unreachableChecksAreNotFailures() async {
        let model = makeModel()
        await model.setSlskdKeepConnected(true)
        slskd.with { $0.down = true }
        for _ in 0..<15 {
            clock.advance(60)
            #expect(await model.checkSlskdKeepConnected() == .unreachable)
        }
        #expect(notifier.posted.isEmpty && model.slskdKeep.homeBanner == nil)
        #expect(model.slskdKeep.outage == SlskdOutage())
        #expect(SlskdCopy.rowSummary(connected: true, lastCheck: model.slskdKeep.lastCheck).text == "Not reachable")
        #expect(connects == 0)
    }

    /// Offline mode On sends nothing (Task 14), so it checks nothing either.
    @Test func offlineChecksNothing() async {
        let model = makeModel()
        await model.setSlskdKeepConnected(true)
        let before = slskd.requests.count
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.checkSlskdKeepConnected() == nil)
        #expect(slskd.requests.count == before)
    }

    @Test func disconnectingSlskdForgetsTheSwitchAndTheOutage() async {
        let model = makeModel()
        slskd.with { s in s.serverConnected = false; s.connectReconnects = false }
        await model.setSlskdKeepConnected(true)
        model.disconnectSlskd()
        #expect(!model.slskdKeep.isOn && model.slskdKeep.outage == SlskdOutage() && model.slskdKeep.lastCheck == nil)
        #expect(model.slskdKeep.homeBanner == nil)
        // The same slskd connected again starts off.
        try? await model.connectSlskd(base: Self.base, apiKey: "test-slskd-key")
        #expect(!model.slskdKeep.isOn)
    }

    // MARK: - In the background

    /// iOS's background pass checks slskd too (best effort), even without Lidarr, and asks for the next pass while the
    /// switch is on.
    @Test func theBackgroundPassChecksSlskd() async throws {
        let model = makeModel()
        await model.setSlskdKeepConnected(true)
        let reads = serverReads
        let submitted = OSAllocatedUnfairLock(initialState: 0)
        let record: (BGTaskRequest) async throws -> Void = { _ in submitted.withLock { $0 += 1 } }
        #expect(await model.backgroundRequestPass(submit: record))
        #expect(serverReads == reads + 1)
        #expect(await eventually { submitted.withLock { $0 } == 1 })
        await model.setSlskdKeepConnected(false)
        #expect(await model.backgroundRequestPass(submit: record) == false, "nothing to do")
    }
}
