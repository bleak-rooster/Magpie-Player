import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import Testing
@testable import Requests

/// R18 on the dev stack, on the test's own fixture only: the release-types profile is made once (idempotent), the
/// test artist (Judie Tzuke, which the dev Lidarr doesn't have) is added with it and Follow new releases off, the gate
/// lets Magpie change that artist's metadata profile and refuses it for an artist the ledger doesn't prove is
/// Magpie's. Removes the artist, and the profile when this run made it (dev helper; Magpie itself never deletes one).
@Suite(.serialized, .enabled(if: TryDevStack.enabled, "set MAGPIE_IT=1 (scripts/it.sh) to run integration tests"))
struct DownloadChoicesIT {
    /// Unusual on purpose, so an existing profile of the owner's is never reused or removed.
    static let types = ReleaseTypes(kinds: .albums, studio: true, soundtrack: true, live: true)

    @Test func releaseTypesOnDevStack() async throws {
        try await TryDevStack.exclusive { try await run() }
    }

    private func run() async throws {
        let client = try await TryDevStack.client()
        let artist = TryIT.artist
        do {
            guard try await client.artistLookupJSON(mbid: artist) != nil else {
                print("SKIP DownloadChoicesIT: Lidarr's metadata server doesn't know the test artist")
                return
            }
        } catch {
            print("SKIP DownloadChoicesIT: external metadata server unreachable (\(error))")
            return
        }
        try #require(try await client.artists().first { $0.foreignArtistId == artist } == nil,
                     "the dev Lidarr already has the test artist; remove it (it was left by an earlier run)")
        let profileExisted = try await client.metadataProfiles().contains { $0.name == Self.types.profileName }

        let dir = FileManager.default.temporaryDirectory.appending(path: "magpie-choices-\(UUID().uuidString)")
        let suite = "magpie-choices-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let roots: @Sendable () async -> WriteConfinement.Roots = { WriteConfinement.Roots(mainRoot: "/music/library", findsRoot: "/music/samples", findTagId: nil) }
        let ledger = Ledger(fileURL: dir.appending(path: "ledger.json"), instance: client.instanceScope)
        let gate = LidarrWriteGate(client: client, logURL: dir.appending(path: "log.json"), defaultsSuite: suite,
                                   confinement: WriteConfinement(ledger: ledger, roots: roots))
        await gate.setEnabled(true)
        let provisioned = try await Provisioner().ensure(gate: gate, client: client)
        let setup = RequestRunner.Setup(rootFolderPath: "/music/library", qualityProfileId: provisioned.losslessProfileId,
                                        metadataProfileId: provisioned.findsMetadataProfileId,
                                        tagIds: [provisioned.magpieTagId])

        var createdId: Int?
        var profileId: Int?
        do {
            let id = try await ArtistLidarr.add(mbid: artist, lidarr: client, gate: gate, ledger: ledger, setup: setup,
                                                follow: false, types: Self.types)
            createdId = id
            let profile = try #require(try await client.metadataProfiles().first { $0.name == Self.types.profileName })
            profileId = profile.id
            let added = try await client.artist(id: id)
            #expect(added.metadataProfileId == profile.id && added.qualityProfileId == provisioned.losslessProfileId)
            #expect(added.monitorNewItems?.lowercased() == "none")
            #expect(try await ledger.createdArtist(added))

            // Idempotent: asked again, the same profile, and no second create.
            #expect(try await Provisioner().ensureReleaseTypes(Self.types, gate: gate, client: client) == profile.id)
            let creates = await gate.changeLog().filter { $0.method == "POST" && $0.path.hasSuffix("metadataprofile") }
            #expect(creates.count == (profileExisted ? 0 : 1))

            // The gate: Magpie's artist may move to another Magpie profile…
            _ = try await gate.send("PUT", "artist/editor",
                                    body: JSONValue.object(["artistIds": .array([.int(id)]),
                                                            "metadataProfileId": .int(provisioned.findsMetadataProfileId)]))
            #expect(try await client.artist(id: id).metadataProfileId == provisioned.findsMetadataProfileId)
            // …never to a profile that isn't Magpie's…
            if let owners = try await client.metadataProfiles().first(where: { !$0.name.hasPrefix("Magpie ") }) {
                await #expect(throws: WriteGateError.self) {
                    _ = try await gate.send("PUT", "artist/editor",
                                            body: JSONValue.object(["artistIds": .array([.int(id)]),
                                                                    "metadataProfileId": .int(owners.id)]))
                }
            }
            // …and an artist the ledger doesn't prove is Magpie's is never changed.
            let strangerLedger = Ledger(fileURL: dir.appending(path: "other.json"), instance: client.instanceScope)
            let stranger = LidarrWriteGate(client: client, logURL: dir.appending(path: "log2.json"), defaultsSuite: suite,
                                           confinement: WriteConfinement(ledger: strangerLedger, roots: roots))
            await #expect(throws: WriteGateError.forbidden("not an artist Magpie added")) {
                _ = try await stranger.send("PUT", "artist/editor",
                                            body: JSONValue.object(["artistIds": .array([.int(id)]),
                                                                    "metadataProfileId": .int(profile.id)]))
            }
            #expect(try await client.artist(id: id).metadataProfileId == provisioned.findsMetadataProfileId)
        } catch {
            Issue.record(error)
        }

        // Clean up only what this test created.
        if let createdId {
            try await TryIT.waitForRefresh(client)
            _ = try await FindsIT.devLidarr("DELETE", "artist/\(createdId)",
                                            query: ["deleteFiles": "false", "addImportListExclusion": "false"])
            #expect(try await client.artists().first { $0.foreignArtistId == artist } == nil)
        }
        if !profileExisted, let profileId {
            _ = try await FindsIT.devLidarr("DELETE", "metadataprofile/\(profileId)")
            #expect(try await !client.metadataProfiles().contains { $0.id == profileId })
        }
    }
}
