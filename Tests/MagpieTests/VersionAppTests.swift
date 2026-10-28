import Foundation
import Testing
@testable import Magpie

// 0.0.1: the version literal lives only in project.yml; the bundle, Settings and the MusicBrainz user agent read it.
@Suite struct VersionAppTests {
    @Test func bundleVersionComesFromProjectYml() throws {
        let yml = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "project.yml"), encoding: .utf8)
        let line = try #require(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        let declared = line.split(separator: "\"")[1]
        #expect(declared == "0.0.1")
        #expect(AppModel.marketingVersion == String(declared))
        #expect(SettingsView.version.hasPrefix("\(declared) ("))
    }
}
