import Foundation
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

enum Fixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "lidarr"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name).json")
        }
        return data
    }
}

let testBase = URL(string: "https://music.example/lidarr")!
let testKey = "test-key-not-real"

func makeClient(_ transport: MockTransport = MockTransport()) -> (LidarrClient, MockTransport) {
    (LidarrClient(base: testBase, apiKey: testKey, transport: transport), transport)
}

/// A transport answering the endpoints `LidarrAudit.run` reads, from fixtures.
/// `overrides` replace the fixture for a path suffix (the mock matches the first stub, so they go in first).
func auditTransport(_ overrides: [String: Data] = [:]) -> MockTransport {
    let t = MockTransport()
    for (suffix, body) in overrides { t.stub(pathSuffix: suffix, body: body) }
    t.stub(pathSuffix: "/system/status", body: Fixtures.data("system-status"))
    t.stub(pathSuffix: "/health", body: Fixtures.data("health"))
    t.stub(pathSuffix: "/rootfolder", body: Fixtures.data("rootfolder"))
    t.stub(pathSuffix: "/qualityprofile", body: Fixtures.data("qualityprofile"))
    t.stub(pathSuffix: "/system/plugins", body: Fixtures.data("system-plugins"))
    t.stub(pathSuffix: "/config/mediamanagement", body: Fixtures.data("config-mediamanagement"))
    return t
}

func json(_ text: String) -> Data { Data(text.utf8) }
