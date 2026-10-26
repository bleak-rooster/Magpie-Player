import Foundation
import Testing
import os
import MagpieCore
import MagpieTestSupport
@testable import LidarrKit

/// A tiny in-memory Lidarr for profiles and tags: GETs list what exists, POSTs append with a new id.
final class FakeLidarr: Sendable {
    private struct State {
        var quality: [JSONValue]
        var metadata: [JSONValue]
        var tags: [JSONValue] = []
        var nextId = 100
    }
    private let state: OSAllocatedUnfairLock<State>
    let transport = MockTransport()

    init(quality: [JSONValue]? = nil, metadata: [JSONValue]? = nil) {
        let q = quality ?? Self.decode(Fixtures.data("qualityprofile")).arrayValue!
        let m = metadata ?? Self.decode(Fixtures.data("metadataprofile")).arrayValue!
        state = OSAllocatedUnfairLock(initialState: State(quality: q, metadata: m))
        let s = state
        transport.stub(pathSuffix: "/qualityprofile/schema", body: Fixtures.data("qualityprofile-schema"))
        transport.stub(pathSuffix: "/metadataprofile/schema", body: Fixtures.data("metadataprofile-schema"))
        for (path, key) in [("/qualityprofile", \State.quality), ("/metadataprofile", \State.metadata), ("/tag", \State.tags)] {
            transport.stub(pathSuffix: path) { _ in
                .init(status: 200, body: try JSONEncoder().encode(s.withLock { $0[keyPath: key] }))
            }
            transport.stub(method: "POST", pathSuffix: path) { request in
                guard case .object(let body) = Self.decode(request.httpBody ?? Data()) else { return .init(status: 400) }
                let created: JSONValue = s.withLock { st in
                    var o = body
                    o["id"] = .int(st.nextId); st.nextId += 1
                    st[keyPath: key].append(.object(o))
                    return .object(o)
                }
                return .init(status: 201, body: try JSONEncoder().encode(created))
            }
        }
    }

    var quality: [JSONValue] { state.withLock { $0.quality } }
    var metadata: [JSONValue] { state.withLock { $0.metadata } }
    var posts: [URLRequest] { transport.requests.filter { $0.httpMethod == "POST" } }

    static func decode(_ data: Data) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null }
}

private func allowedQualities(_ profile: JSONValue) -> Set<String> {
    var out = Set<String>()
    for item in profile["items"]?.arrayValue ?? [] where item["allowed"]?.boolValue == true {
        if let n = item["quality"]?["name"]?.stringValue { out.insert(n) }
        for c in item["items"]?.arrayValue ?? [] { if let n = c["quality"]?["name"]?.stringValue { out.insert(n) } }
    }
    return out
}

private func allQualityIds(_ profile: JSONValue) -> [Int] {
    (profile["items"]?.arrayValue ?? []).flatMap { item -> [Int] in
        let children = item["items"]?.arrayValue ?? []
        return children.isEmpty ? [item["quality"]?["id"]?.intValue ?? -1]
                                : children.map { $0["quality"]?["id"]?.intValue ?? -1 }
    }
}

private func allowed(_ profile: JSONValue, _ field: String, _ key: String) -> Set<String> {
    Set((profile[field]?.arrayValue ?? []).filter { $0["allowed"]?.boolValue == true }.compactMap { $0[key]?["name"]?.stringValue })
}

@Suite struct ProvisionerTests {
    @Test func createIfAbsent() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)

        let first = try await Provisioner().ensure(gate: gate, client: client)
        #expect(first.created == ["Magpie Fast Start", "Magpie Lossless", "Magpie Finds", "Magpie Albums+EPs",
                                  "magpie", "magpie-find"])
        #expect(fake.posts.count == 6)
        #expect(fake.posts.allSatisfy { $0.httpMethod == "POST" })   // never PUT/DELETE an existing profile
        #expect(await gate.changeLog().count == 6)

        // Bodies come from the schemas: every quality present once, only the wanted ones allowed.
        let schemaIds = allQualityIds(FakeLidarr.decode(Fixtures.data("qualityprofile-schema"))).sorted()
        let fast = try #require(fake.quality.first { $0["name"]?.stringValue == "Magpie Fast Start" })
        #expect(allowedQualities(fast) == ["MP3-320", "MP3-VBR-V0"])
        #expect(fast["cutoff"]?.intValue == 4)          // MP3-320
        #expect(fast["upgradeAllowed"]?.boolValue == false)
        #expect(allQualityIds(fast).sorted() == schemaIds)
        let lossless = try #require(fake.quality.first { $0["name"]?.stringValue == "Magpie Lossless" })
        #expect(allowedQualities(lossless) == ["FLAC"])
        #expect(lossless["cutoff"]?.intValue == 6)      // FLAC
        #expect(lossless["upgradeAllowed"]?.boolValue == true)
        #expect(allQualityIds(lossless).sorted() == schemaIds)

        let finds = try #require(fake.metadata.first { $0["name"]?.stringValue == "Magpie Finds" })
        #expect(allowed(finds, "primaryAlbumTypes", "albumType") == ["Album", "EP", "Single"])   // A1
        #expect(allowed(finds, "secondaryAlbumTypes", "albumType") == ["Studio"])
        #expect(allowed(finds, "releaseStatuses", "releaseStatus") == ["Official"])
        #expect(finds["secondaryAlbumTypes"]?.arrayValue?.count == 11)
        let albums = try #require(fake.metadata.first { $0["name"]?.stringValue == "Magpie Albums+EPs" })
        #expect(allowed(albums, "primaryAlbumTypes", "albumType") == ["Album", "EP"])

        // Second run: everything is found by name and matches, so nothing is posted.
        let second = try await Provisioner().ensure(gate: gate, client: client)
        #expect(second.created.isEmpty)
        #expect(fake.posts.count == 6)
        #expect(second.fastStartProfileId == first.fastStartProfileId)
        #expect(second.losslessProfileId == first.losslessProfileId)
        #expect(second.findsMetadataProfileId == first.findsMetadataProfileId)
        #expect(second.albumsEPsMetadataProfileId == first.albumsEPsMetadataProfileId)
        #expect(second.magpieTagId == first.magpieTagId)
        #expect(second.findTagId == first.findTagId)

        // The audit now sees all four profiles by exact name.
        let quality = try JSONEncoder().encode(fake.quality), metadata = try JSONEncoder().encode(fake.metadata)
        let (auditClient, _) = makeClient(auditTransport(["/qualityprofile": quality, "/metadataprofile": metadata]))
        #expect(await LidarrAudit.run(auditClient).hasMagpieProfiles)

        // Off switch: nothing left to create, so provisioning still answers without writing.
        await gate.setEnabled(false)
        #expect(try await Provisioner().ensure(gate: gate, client: client).created.isEmpty)
    }

    @Test func conflictStops() async throws {
        // An owner profile called "Magpie Lossless" that allows MP3 instead: never overwritten, nothing created.
        var owners = FakeLidarr.decode(Fixtures.data("qualityprofile")).arrayValue!
        guard case .object(var lossy) = owners[0] else { Issue.record("fixture"); return }
        lossy["id"] = .int(42)
        lossy["name"] = .string("Magpie Lossless")
        owners.append(.object(lossy))
        let fake = FakeLidarr(quality: owners)
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)

        await #expect(throws: ProvisionError.conflict("Magpie Lossless")) {
            _ = try await Provisioner().ensure(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
        #expect(fake.transport.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(await gate.changeLog().isEmpty)
    }

    @Test func conflictOnMetadataAndOnCaseOnlyName() async throws {
        let finds = JSONValue.object(["id": .int(9), "name": .string("Magpie Finds"),
                                      "primaryAlbumTypes": .array([]), "secondaryAlbumTypes": .array([]),
                                      "releaseStatuses": .array([])])
        let fake = FakeLidarr(metadata: [finds])
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: true)
        await #expect(throws: ProvisionError.conflict("Magpie Finds")) {
            _ = try await Provisioner().ensure(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)

        let caseOnly = FakeLidarr(quality: [.object(["id": .int(3), "name": .string("magpie fast start"), "items": .array([])])])
        let (client2, _) = makeClient(caseOnly.transport)
        let gate2 = await GateEnv().gate(client2, enabled: true)
        await #expect(throws: ProvisionError.conflict("Magpie Fast Start")) {
            _ = try await Provisioner().ensure(gate: gate2, client: client2)
        }
        #expect(caseOnly.posts.isEmpty)
    }

    @Test func disabledGateWritesNothing() async throws {
        let fake = FakeLidarr()
        let (client, _) = makeClient(fake.transport)
        let gate = await GateEnv().gate(client, enabled: false)
        await #expect(throws: WriteGateError.disabled) {
            _ = try await Provisioner().ensure(gate: gate, client: client)
        }
        #expect(fake.posts.isEmpty)
    }
}
