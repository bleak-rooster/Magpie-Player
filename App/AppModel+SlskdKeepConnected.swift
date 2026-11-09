import Foundation
import SlskdKit
import SwiftUI

/// Round 24 (owner, 2026-11-08): "Keep Soulseek connected". While it is on (per slskd, off by default, only with slskd
/// connected), Magpie checks slskd's connection to Soulseek whenever it can: a minute apart while Magpie is open or
/// playing (30 s after an ask, to judge it), and in iOS's background refresh pass when iOS allows it (never guaranteed).
/// A check that finds slskd disconnected and not on its way back asks it once to reconnect (`SlskdKeepConnected`, through
/// slskd's write gate). After three failed checks spanning at least ten minutes the owner is told once per outage: a
/// local notification (asked for when the switch is turned on, never at launch) and, whether or not notifications are
/// allowed, a banner on Home and the slskd page. A check that can't be read is not a failure. Nothing leaves the phone
/// but the checks themselves. (D217–D221)
@MainActor @Observable
final class SlskdKeepConnectedState {
    /// The switch, as saved for the connected slskd.
    var isOn = false
    /// The last check or read (nil before one).
    var lastCheck: SlskdCheck?
    /// The outage so far (saved per slskd).
    var outage = SlskdOutage()
    /// Whether notifications may be shown, as last asked (nil before the switch was first turned on this launch).
    var notificationsAllowed: Bool?
    /// A notification's tap: open the slskd page.
    var opensPage = false
    /// Where the outage notification goes (tests substitute their own).
    @ObservationIgnored var notifier: any SlskdOutageNotifying = ReadyNotifier.shared
    /// The time checks are counted in (tests move it by hand).
    @ObservationIgnored var clock: @Sendable () -> Date = { Date() }
    /// Whether switching on starts the minute-by-minute checks (tests drive the checks themselves).
    @ObservationIgnored var runsLoop = !AppModel.isHostedTest
    @ObservationIgnored var loop: Task<Void, Never>?
    /// Fix round 1 I3: the connected slskd's check, with its one gate, made once per slskd (`scope`) by
    /// AppModel+Slskd and dropped when slskd changes.
    @ObservationIgnored var checker: (scope: String, run: @Sendable () async -> SlskdCheck)?
    /// Fix round 1 I3: the check under way; another caller joins it instead of starting a second.
    @ObservationIgnored var inFlight: Task<SlskdCheck?, Never>?
    /// Fix round 1 M6: Settings sheets on screen. A tap on the notification while one is open navigates in it instead
    /// of presenting another sheet (which SwiftUI would not show).
    @ObservationIgnored var settingsShown = 0

    /// Home's banner: only once the owner is to be told (three failed checks over ten minutes), while it lasts.
    var homeBanner: String? {
        guard isOn, outage.notified, let since = outage.since else { return nil }
        return SlskdKeepCopy.disconnectedSince(since)
    }

    /// The page's line: from the first failed check.
    var pageBanner: String? {
        guard isOn, let since = outage.since else { return nil }
        return SlskdKeepCopy.disconnectedSince(since)
    }

    func reset() {
        loop?.cancel()
        loop = nil
        inFlight?.cancel()
        inFlight = nil
        checker = nil
        isOn = false
        lastCheck = nil
        outage = SlskdOutage()
    }
}

/// Posts the outage notification. `ReadyNotifier` in the app.
@MainActor
protocol SlskdOutageNotifying: AnyObject {
    /// Asks iOS (the system prompt the first time); true when notifications may be shown.
    func requestPermission() async -> Bool
    /// Whether notifications may show now, without asking (nil: not decided yet).
    func permissionStatus() async -> Bool?
    func postSlskdOutage(title: String, body: String)
}

/// The words of "Keep Soulseek connected" (Settings › Soulseek (slskd), the notification and the banner). Named only
/// there: slskd's own page, and the outage it is about.
enum SlskdKeepCopy {
    static let toggle = "Keep Soulseek connected"
    static let footer = "Magpie checks that slskd is connected to Soulseek while it can, and asks it to reconnect. Checks only happen while Magpie is open, playing, or when iOS allows it in the background."
    static let notificationsOn = "If it stays disconnected, Magpie lets you know."
    static let notificationsOff = "Notifications are off, so Magpie can only tell you inside the app."
    static let needsSlskd = "Connect slskd first."
    static let notificationTitle = "slskd isn\u{2019}t connected to Soulseek"
    static let notificationBody = "Magpie asked it to reconnect and it still can\u{2019}t. Music coming through Soulseek will wait."
    static let connected = "Connected to Soulseek"
    static let connecting = "Connecting to Soulseek"
    static let disconnected = "Not connected to Soulseek"
    static let unreachable = "Can\u{2019}t reach slskd"
    static let unknown = "slskd didn\u{2019}t say whether it\u{2019}s connected"
    static let keyCannotReconnect = "slskd didn\u{2019}t let this API key ask it to reconnect. Connect again with a key that has read-write rights."
    static let bannerHint = "Opens slskd\u{2019}s settings"

    /// "slskd has been disconnected since 14:05" (the time in the phone's own format).
    static func disconnectedSince(_ date: Date, locale: Locale = .autoupdatingCurrent,
                                  timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return "slskd has been disconnected since \(date.formatted(style))"
    }

    /// The state line of the page: text plus its symbol (D3).
    static func state(_ check: SlskdCheck) -> (text: String, symbol: String) {
        switch check {
        case .connected: (connected, "checkmark.circle")
        case .transitioning: (connecting, "arrow.triangle.2.circlepath")
        case .down, .keyCannotReconnect: (disconnected, "exclamationmark.triangle")
        case .unreachable: (unreachable, "wifi.exclamationmark")
        case .unknown: (unknown, "questionmark.circle")
        }
    }
}

extension AppModel {
    /// Why the switch can't be turned on (nil when it can).
    var slskdKeepConnectedUnavailableReason: String? { slskd == nil ? SlskdKeepCopy.needsSlskd : nil }

    /// The footer's notification line: nil until the switch is on.
    var slskdKeepNotificationLine: String? {
        guard slskdKeep.isOn, let allowed = slskdKeep.notificationsAllowed else { return nil }
        return allowed ? SlskdKeepCopy.notificationsOn : SlskdKeepCopy.notificationsOff
    }

    /// The switch. On: saved first (the record the gate reads), then notifications asked for, then one check, then the
    /// checks go on. Off: saved, the checks stop and the outage is forgotten.
    func setSlskdKeepConnected(_ on: Bool) async {
        guard on else {
            saveSlskdKeepConnected(false)
            slskdKeep.reset()
            saveSlskdOutage()
            return
        }
        guard slskdKeepConnectedUnavailableReason == nil else { return }
        saveSlskdKeepConnected(true)
        slskdKeep.isOn = true
        slskdKeep.notificationsAllowed = await slskdKeep.notifier.requestPermission()
        let first = await checkSlskdKeepConnected()
        startSlskdKeepConnectedLoop(after: first)
    }

    /// One check (the loop's, the background pass's, the page's, or the switch's first). Nil when nothing was checked:
    /// the switch is off, slskd isn't connected, Magpie is offline (Task 14: nothing is sent), or the check was cancelled
    /// (the background pass's time ran out). Fix round 1 I3: single-flight: while one runs, another caller joins it, so
    /// one check is one read, at most one ask, and one count. Cancelling the caller cancels the check.
    @discardableResult
    func checkSlskdKeepConnected() async -> SlskdCheck? {
        if let running = slskdKeep.inFlight { return await running.value }
        let task = Task { await self.performSlskdKeepConnectedCheck() }
        slskdKeep.inFlight = task
        let check = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if slskdKeep.inFlight == task { slskdKeep.inFlight = nil }
        return check
    }

    private func performSlskdKeepConnectedCheck() async -> SlskdCheck? {
        guard slskdKeep.isOn, !isOffline, let check = await runSlskdKeepConnectedCheck() else { return nil }
        guard slskdKeep.isOn, !Task.isCancelled else { return nil }   // turned off, or out of time, while it ran
        slskdKeep.lastCheck = check
        if slskdKeep.outage.record(check, at: slskdKeep.clock()), slskdKeep.notificationsAllowed != false {
            slskdKeep.notifier.postSlskdOutage(title: SlskdKeepCopy.notificationTitle, body: SlskdKeepCopy.notificationBody)
        }
        saveSlskdOutage()
        return check
    }

    /// The page, opened: one read of slskd's state (nothing is sent) when the switch is off, so the page and the
    /// Settings row say whether slskd answers.
    func refreshSlskdState() async {
        if slskdKeep.isOn, slskdKeep.notificationsAllowed == nil {   // a relaunch: the footer's line, without asking
            slskdKeep.notificationsAllowed = await slskdKeep.notifier.permissionStatus()
        }
        guard slskd != nil, !isOffline else { return }
        if slskdKeep.isOn {
            await checkSlskdKeepConnected()
        } else {
            slskdKeep.lastCheck = await readSlskdServerState()
        }
    }

    /// While the switch is on: a check a minute (30 s after an ask). Suspended with the app; while audio plays the app
    /// keeps running, and so do the checks.
    func startSlskdKeepConnectedLoop(after last: SlskdCheck? = nil) {
        slskdKeep.loop?.cancel()
        slskdKeep.loop = nil
        guard slskdKeep.isOn, slskdKeep.runsLoop else { return }
        slskdKeep.loop = Task { [weak self] in
            var last = last
            while !Task.isCancelled {
                let wait = last == .down(asked: true) ? SlskdKeepConnected.checkAfterAsking : SlskdKeepConnected.checkInterval
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                last = await self.checkSlskdKeepConnected()
            }
        }
    }

    /// iOS's background pass (`RequestsBackgroundRefresh`, D220): the slskd check gets at most this long, and is
    /// cancelled past it (fix round 1 I2, M2); the runner gets what is left of the pass.
    static let slskdBackgroundLimit: Duration = .seconds(10)

    /// The saved outage of the connected slskd, read with the switch.
    func readSlskdKeepConnected() {
        slskdKeep.loop?.cancel()
        slskdKeep.loop = nil
        slskdKeep.inFlight?.cancel()
        slskdKeep.inFlight = nil
        slskdKeep.checker = nil   // fix round 1 I3: a new slskd (or none) gets its own gate
        slskdKeep.isOn = slskdKeepConnectedSaved
        slskdKeep.lastCheck = nil
        slskdKeep.outage = slskdOutageKey.flatMap { gateDefaults.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(SlskdOutage.self, from: $0) } ?? SlskdOutage()
        if slskdKeep.isOn {
            if notifications { ReadyNotifier.shared.listen() }   // a tap on the notification opens the page
            startSlskdKeepConnectedLoop()
        }
    }

    private var slskdOutageKey: String? { slskdScope.map { "magpie.slskd.outage.\($0)" } }

    func saveSlskdOutage() {
        guard let key = slskdOutageKey else { return }
        if slskdKeep.outage == SlskdOutage() {
            gateDefaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(slskdKeep.outage) {
            gateDefaults.set(data, forKey: key)
        }
    }

    /// Forgets the switch's outage for a slskd going away (`scope`: the one replaced or disconnected).
    func forgetSlskdOutage(scope: String) {
        gateDefaults.removeObject(forKey: "magpie.slskd.outage.\(scope)")
    }
}

/// Home's banner while slskd has been disconnected past the bound (D219): text and a symbol, a tap opens the page.
struct SlskdOutageBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.slskdKeep.homeBanner {
            Button {
                model.slskdKeep.opensPage = true
            } label: {
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(SlskdKeepCopy.bannerHint)
            .accessibilityIdentifier("slskd-outage-banner")
        }
    }
}

extension View {
    /// Opens Settings › Soulseek (slskd) when the outage notification or Home's banner asks for it.
    func slskdPagePresenter() -> some View { modifier(SlskdPagePresenter()) }
}

/// Fix round 1 M6: a Settings sheet that is already open takes the request itself (`SettingsView` opens the page in its
/// own navigation); otherwise this presents Settings on the slskd page.
private struct SlskdPagePresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var presents = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presents) { SettingsView(opening: [.slskd]) }
            .onChange(of: model.slskdKeep.opensPage, initial: true) { _, opens in
                guard opens, SlskdPageRoute.route(settingsShown: model.slskdKeep.settingsShown) == .present else { return }
                model.slskdKeep.opensPage = false
                presents = true
            }
    }
}

/// Fix round 1 M6: where a request to open the slskd page goes.
enum SlskdPageRoute: Equatable {
    /// No Settings sheet is open: present one on the slskd page.
    case present
    /// A Settings sheet is open: open the page in it.
    case navigate

    static func route(settingsShown: Int) -> SlskdPageRoute { settingsShown > 0 ? .navigate : .present }
}
