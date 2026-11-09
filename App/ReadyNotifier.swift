import Foundation
import UserNotifications

/// D7: "Ready" local notifications, posted only while the app runs (no push, no Live Activity in v1).
/// Shown as a banner in the foreground too.
@MainActor
final class ReadyNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReadyNotifier()

    private var asked = false
    private var center: UNUserNotificationCenter { .current() }

    /// Asks once per launch, on the first Try (never at launch).
    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    #if DEBUG
    /// Tests: the identifiers of the notifications posted (R16: a request that turns ready away from its screen).
    var postedForTesting: [String] = []
    #endif

    func post(id: String, title: String, body: String) { post(identifier: "ready-\(id)", title: title, body: body) }

    /// Round 15 C3 (D138): a rejected find's playlist clean-up finished while Magpie was in the background.
    func postLetGo(id: String, title: String, body: String) { post(identifier: "letgo-\(id)", title: title, body: body) }

    /// Round 17: a song that couldn't be brought in (nothing holding it could be found).
    func postFailed(id: String, title: String, body: String) { post(identifier: "failed-\(id)", title: title, body: body) }

    /// Round 24 (D219, D221): slskd stayed disconnected from Soulseek. One identifier, so a later outage replaces it; its
    /// category opens the slskd page when tapped. The text names no host, key or address.
    func postSlskdOutage(title: String, body: String) {
        post(identifier: Self.slskdOutageCategory, title: title, body: body, category: Self.slskdOutageCategory)
    }

    nonisolated static let slskdOutageCategory = "slskd-outage"

    /// Round 24 (D221): "Keep Soulseek connected" switched on asks (the system prompt the first time; never at launch).
    /// True when notifications may show.
    func requestPermission() async -> Bool {
        center.delegate = self
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Round 24: whether notifications may show now, without asking (nil: not decided yet).
    func permissionStatus() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        case .denied: false
        default: nil
        }
    }

    /// Round 24: becomes the delegate at launch while "Keep Soulseek connected" is on, so a tap on its notification
    /// that launched Magpie still opens the page.
    func listen() { center.delegate = self }

    private func post(identifier: String, title: String, body: String, category: String? = nil) {
        #if DEBUG
        postedForTesting.append(identifier)
        #endif
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Round 24 (D219): a tap on the slskd outage notification opens Settings › Soulseek (slskd).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.slskdOutageCategory else { return }
        await MainActor.run { AppModel.shared.slskdKeep.opensPage = true }
    }
}

extension ReadyNotifier: SlskdOutageNotifying {}
