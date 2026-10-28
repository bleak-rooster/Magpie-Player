import Foundation

extension AppModel {
    /// The app's marketing version, read from the bundle (project.yml's `MARKETING_VERSION` is the only source).
    nonisolated static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
