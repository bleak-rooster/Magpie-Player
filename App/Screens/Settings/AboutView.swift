import SwiftUI

/// Settings › About: the version (`AppModel.marketingVersion`, from project.yml) and the build.
struct AboutView: View {
    static var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(AppModel.marketingVersion) (\(build))"
    }

    /// The Settings row's value, "Version 0.0.1 (3)".
    static var summary: String { "Version \(version)" }

    var body: some View {
        Form {
            LabeledContent("Magpie", value: Self.version)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
