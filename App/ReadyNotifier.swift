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

    func post(id: String, title: String, body: String) {
        #if DEBUG
        postedForTesting.append("ready-\(id)")
        #endif
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "ready-\(id)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
