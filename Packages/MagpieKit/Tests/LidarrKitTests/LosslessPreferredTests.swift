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

/// Round 17 (owner, 2026-11-05): "Magpie Finds Any Format", for a find with no MP3, from Lidarr's real schema.
@Suite struct AnyFormatProfileTests {
    @Test func allowsPlayableFormatsWithMP3First() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Fixtures.data("qualityprofile-schema"))
        let body = try Provisioner.anyFormatBody(schema: schema)
        let items = body["items"]?.arrayValue ?? []
        var allowed = Set<String>()
        for item in items where item["allowed"]?.boolValue == true {
            if let n = item["quality"]?["name"]?.stringValue { allowed.insert(n) }
        }
        #expect(allowed == Provisioner.anyFormatQualities)
        #expect(!allowed.contains("WMA") && !allowed.contains("APE") && !allowed.contains("MP3-128"))
        #expect(items.suffix(2).map { $0["quality"]?["name"]?.stringValue } == ["MP3-VBR-V0", "MP3-320"])
        #expect(body["cutoff"]?.intValue == 4)   // MP3-320
        #expect(body["upgradeAllowed"]?.boolValue == false)
        #expect(body["name"]?.stringValue == Provisioner.anyFormatName)
        #expect(Provisioner.matches(body.merging(id: 9), Provisioner.anyFormatSpec(schema: schema)))
    }
}

private extension JSONValue {
    func merging(id: Int) -> JSONValue {
        guard var o = objectValue else { return self }
        o["id"] = .int(id)
        return .object(o)
    }
}

/// Round 19 (owner, 2026-11-05: popular singles): "Magpie Finds Extras", for a find whose song is only on a soundtrack
/// or remix release (HUNTR/X "Golden", a film's song), from Lidarr's real schema: made once, reused, never changed.
@Suite struct FindsExtrasTests {
    @Test func madeOnceThroughTheGateThenReused() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        let id = try await Provisioner().ensureFindsExtras(gate: gate, client: client)
        #expect(fake.posts.count == 1)
        let made = try #require(fake.metadata.first { $0["id"]?.intValue == id })
        #expect(made["name"]?.stringValue == "Magpie Finds Extras")
        #expect(Provisioner.matches(made, Provisioner.findsExtrasSpec), "Album/EP/Single; Studio, Soundtrack, Remix; Official")
        #expect(try await Provisioner().ensureFindsExtras(gate: gate, client: client) == id)
        #expect(fake.posts.count == 1, "reused, never made twice")
    }

    @Test func aSameNamedProfileSetUpDifferentlyIsNeverChanged() async throws {
        var owners = FakeLidarr.decode(Fixtures.data("metadataprofile")).arrayValue!
        guard case .object(var other) = owners[0] else { Issue.record("fixture"); return }
        other["id"] = .int(77)
        other["name"] = .string("Magpie Finds Extras")
        owners.append(.object(other))
        let fake = FakeLidarr(metadata: owners)
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        await #expect(throws: ProvisionError.conflict("Magpie Finds Extras")) {
            _ = try await Provisioner().ensureFindsExtras(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
    }

    @Test func withChangesOffNothingIsMade() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: false)
        await #expect(throws: WriteGateError.disabled) { _ = try await Provisioner().ensureFindsExtras(gate: gate, client: client) }
        #expect(fake.posts.isEmpty)
    }
}
