import SwiftUI

@main
struct MagpieApp: App {
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
