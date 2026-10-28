import Foundation
import Testing
@testable import Magpie

// T2 (spec §8, revised): every configuration ships `NSAppTransportSecurity { NSAllowsArbitraryLoads: true }`, so
// ATS lets plain http through anywhere and Magpie's consent gate is the control (`ConsentGateTests`). The
// "needs HTTPS" pre-refusal stays for any build without arbitrary loads, and stays matched to local-networking ATS.

/// What iOS does with a plain-http URL given an ATS dictionary (the documented rules Magpie relies on).
private struct ATSOracle {
    let ats: [String: Any]
    func blocks(_ url: URL) -> Bool {
        let overrides = ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"]
        if ats["NSAllowsArbitraryLoads"] as? Bool == true, overrides.allSatisfy({ ats[$0] == nil }) { return false }
        guard ats["NSAllowsLocalNetworking"] as? Bool == true else { return true }
        return !(ServerAddress.isLoopback(url) || ServerAddress.isLocalNetwork(url))
    }
}

@Suite struct ATSReleasePolicyTests {
    /// The generated `App/Info.plist` (`xcodegen generate` writes it from `project.yml`): what every configuration ships.
    static var releaseATS: [String: Any] {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "App/Info.plist")
        return (NSDictionary(contentsOf: plist) as! [String: Any])["NSAppTransportSecurity"] as! [String: Any]
    }

    @Test func releaseDictionaryIsArbitraryLoadsOnly() {
        #expect(Self.releaseATS as NSDictionary == ["NSAllowsArbitraryLoads": true] as NSDictionary)
        #expect(AppModel.allowsArbitraryLoads(ats: Self.releaseATS))
    }

    /// Any one of the overrides makes iOS ignore arbitrary loads, so `allowsArbitraryLoads(ats:)` says no.
    @Test(arguments: ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"])
    func anOverrideCancelsArbitraryLoads(_ key: String) {
        #expect(!AppModel.allowsArbitraryLoads(ats: ["NSAllowsArbitraryLoads": true, key: true]))
        #expect(!AppModel.allowsArbitraryLoads(ats: ["NSAllowsArbitraryLoads": false]))
        #expect(!AppModel.allowsArbitraryLoads(ats: nil))
    }

    @Test(arguments: ["http://homeserver:4533", "http://192.168.0.77:4533", "http://10.0.0.5:4533", "http://nas.local:4533",
                      "http://100.64.10.20:4533", "http://homebox.tail1234.ts.net:4533", "http://music.example.com", "http://8.8.8.8"])
    func gateAgreesWithReleaseATS(_ text: String) {
        let url = URL(string: text)!
        let gate = ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: AppModel.allowsArbitraryLoads(ats: Self.releaseATS))
        #expect(gate == ATSOracle(ats: Self.releaseATS).blocks(url))
        #expect(!gate)
    }

    @Test func preRefusalPathStillMatchesLocalNetworkingATS() {
        let localOnly: [String: Any] = ["NSAllowsLocalNetworking": true]
        for text in ["http://100.64.10.20:4533", "http://nas:4533", "http://music.example.com"] {
            let url = URL(string: text)!
            #expect(ServerAddress.atsBlocksPlainHTTP(url, allowsArbitraryLoads: false) == ATSOracle(ats: localOnly).blocks(url))
        }
    }
}
