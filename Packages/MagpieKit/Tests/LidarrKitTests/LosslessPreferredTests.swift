import Foundation
import Testing
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// Round 15 C3 (owner answer 4, D136): the main library's quality is "Magpie Lossless Preferred": FLAC, with MP3-320 /
/// V0 only as a fallback, cutoff FLAC and upgrades on. Finds keep Fast Start (MP3).
@Suite struct LosslessPreferredTests {
    @Test func madeOnceThroughTheGateThenReused() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        let id = try await Provisioner().ensureLosslessPreferred(gate: gate, client: client)
        #expect(fake.posts.count == 1)
        let made = try #require(fake.quality.first { $0["id"]?.intValue == id })
        #expect(made["name"]?.stringValue == "Magpie Lossless Preferred")
        #expect(Provisioner.matches(made, Provisioner.losslessPreferredSpec), "FLAC + MP3-320 + V0, cutoff FLAC, upgrades on")
        #expect(made["upgradeAllowed"]?.boolValue == true)
        #expect(try await Provisioner().ensureLosslessPreferred(gate: gate, client: client) == id)
        #expect(fake.posts.count == 1, "reused, never made twice")
    }

    @Test func aSameNamedProfileSetUpDifferentlyIsNeverChanged() async throws {
        var owners = FakeLidarr.decode(Fixtures.data("qualityprofile")).arrayValue!
        guard case .object(var other) = owners[0] else { Issue.record("fixture"); return }
        other["id"] = .int(77)
        other["name"] = .string("Magpie Lossless Preferred")
        owners.append(.object(other))
        let fake = FakeLidarr(quality: owners)
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        await #expect(throws: ProvisionError.conflict("Magpie Lossless Preferred")) {
            _ = try await Provisioner().ensureLosslessPreferred(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
    }

    @Test func withChangesOffNothingIsMade() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: false)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await Provisioner().ensureLosslessPreferred(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
    }
}
