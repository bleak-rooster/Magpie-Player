import SwiftUI
import UIKit

@main
struct MagpieApp: App {
    @UIApplicationDelegateAdaptor(MagpieAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        RequestsBackgroundRefresh.register()   // R16: before launch finishes, as BGTaskScheduler requires
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// R1: the system relaunches (or wakes) Magpie when background downloads finish. The fetcher remakes the session so
/// its events arrive, the app stores what came, and then the system is told.
final class MagpieAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundAudioFetcher.identifier else { return completionHandler() }
        _ = AppModel.shared   // signs back in, so the downloads manager is there to take the files
        nonisolated(unsafe) let completion = completionHandler
        BackgroundAudioFetcher.shared.handleEvents { completion() }
    }
}
